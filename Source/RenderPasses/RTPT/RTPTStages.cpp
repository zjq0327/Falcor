#include "RTPT.h"
#include "Utils/Timing/Profiler.h"
#include <algorithm>
#include <limits>
#include <utility>

namespace
{
// This threshold accounts only for the per-pixel stage buffers.
constexpr uint64_t kStageResourceBudgetBytes = 1ull << 30;
constexpr uint64_t kGRISHistoryStride = 84u;

uint64_t structuredStride(const ShaderVar& var)
{
    FALCOR_CHECK(var.isValid() && var.getType(), "RTPT stage buffer reflection is missing its resource.");
    const auto* type = var.getType()->unwrapArray()->asResourceType();
    FALCOR_CHECK(type && type->getStructType(), "RTPT stage buffer reflection is missing its structure.");
    return type->getStructType()->getSlangTypeLayout()->getStride();
}
}

void RTPT::invalidateStages()
{
    invalidateGRIS();
    invalidateDirectLighting();
    mLightCatalog.retry();
    // Release parameter blocks as well as our own references before reallocating.
    mpStageComputePass = mpPrimarySurfacePass = mpFinalSignalResolve = nullptr;
    mpPrimarySurfaces = mpSignalRecords = nullptr;
    mStageResourceDim = uint2(0u);
    mStagesActive = false;
    mStagePreparationFailed = false;
    mStageFallbackReason.clear();
}

bool RTPT::prepareStages()
{
    if (any(mStageResourceDim != mFrameDim)) invalidateStages();
    mStageResourceDim = mFrameDim;
    if (mStagePreparationFailed) return false;
    if (mStagesActive) return true;

    try
    {
        const uint64_t pixelCount = uint64_t(mFrameDim.x) * mFrameDim.y;
        FALCOR_CHECK(pixelCount > 0 && pixelCount <= std::numeric_limits<uint32_t>::max(),
            "RTPT primary surface dimensions exceed the structured-buffer index range.");

        auto defines = mpComputePass->getProgram()->getDefines();
        defines.add("RTPT_USE_PRIMARY_SURFACE", "1");
        defines.add("RTPT_SEPARATE_SIGNAL_RESOLVE", mEnableNRD ? "1" : "0");
        mpStageComputePass = ComputePass::create(mpDevice, mpComputePass->getProgram()->getDesc(), defines, true);

        const auto primaryDesc = makeSceneProgramDesc("RenderPasses/RTPT/PrimarySurface/RTPTPrimarySurface.cs.slang");
        mpPrimarySurfacePass = ComputePass::create(mpDevice, primaryDesc, defines, true);
        if (mEnableNRD)
        {
            ProgramDesc resolveDesc;
            resolveDesc.addShaderLibrary("RenderPasses/RTPT/Signal/RTPTFinalSignalResolve.cs.slang").csEntry("main");
            mpFinalSignalResolve = ComputePass::create(mpDevice, resolveDesc, {}, true);
        }
        const auto primaryVar = mpPrimarySurfacePass->getRootVar()["gPrimarySurfaceOutput"];
        const uint64_t primaryStride = structuredStride(primaryVar);
        const uint64_t signalStride = mEnableNRD
            ? structuredStride(mpFinalSignalResolve->getRootVar()["gSignalRecords"]) : 0u;
        const uint64_t stageBytes = pixelCount * (primaryStride + signalStride);
        FALCOR_CHECK(stageBytes <= kStageResourceBudgetBytes || canUseGRISTemporal() || canUseGRISAlternating(),
            "RTPT primary/signal resources exceed their 1 GiB budget ({} pixels, {} + {} bytes per pixel).",
            pixelCount, primaryStride, signalStride);
        if (stageBytes > kStageResourceBudgetBytes)
            logWarningOnce("RTPT Temporal: attempting to allocate {} bytes of primary and signal buffers above 1 GiB.", stageBytes);
        mpPrimarySurfaces = mpDevice->createStructuredBuffer(primaryVar, uint32_t(pixelCount));
        if (mEnableNRD)
            mpSignalRecords = mpDevice->createStructuredBuffer(
                mpFinalSignalResolve->getRootVar()["gSignalRecords"], uint32_t(pixelCount));
        // Compile the consumer layout during preparation, before tracing any ray.
        auto mainVar = mpStageComputePass->getRootVar();
        mainVar["gPrimarySurfaces"] = mpPrimarySurfaces;
        if (mEnableNRD) mainVar["gSignalRecords"] = mpSignalRecords;
        mStagesActive = true;
        mStageFallbackReason.clear();
        return true;
    }
    catch (const std::exception& error)
    {
        const std::string reason = error.what();
        invalidateStages();
        // Retry after a scene/program/resolution change, rather than repeatedly
        // allocating failed resources on every frame. The original pass is ready.
        mStageResourceDim = mFrameDim;
        mStagePreparationFailed = true;
        mStageFallbackReason = reason;
        logWarning("RTPT stage preparation failed; using the original integrator: {}", reason);
        return false;
    }
}

bool RTPT::canUseGRISTemporal() const
{
    return mGRISTemporalEnabled && canUseGRISAlternating();
}

bool RTPT::canUseGRISAlternating() const
{
    const bool compatibleReGIR = !mReGIREnabled || mRestirDIEnabled || mReGIRSecondaryEnabled;
    return mGRISEnabled && mEnableNRD && mSamplesPerPixel == 1u &&
        !mUseRussianRoulette && mUseNEE && compatibleReGIR;
}

void RTPT::resetGRISHistory()
{
    ++mGRISHistoryGeneration;
    mGRISHistoryFrame.historyValid = false;
    mGRISHistoryReadValid = false;
    mGRISHistoryReplayActive = false;
}

void RTPT::invalidateGRIS(bool clearTemporalFailure)
{
    mpGRISGeneratePass = mpGRISSpatialPass = mpGRISShadePass = mpGRISMainPass = nullptr;
    mpGRISTemporalPass = mpGRISPublishHistoryPass = mpGRISLocalPass = nullptr;
    mpGRISCandidates = mpGRISSpatialInput = mpGRISLocalPrefixes = mpGRISShadedIndirect = nullptr;
    mpGRISHistory = nullptr;
    resetGRISHistory();
    if (clearTemporalFailure) mGRISTemporalFallbackReason.clear();
}

bool RTPT::prepareGRIS(const ref<ComputePass>& baseMainPass, bool diActive)
{
    if (!mGRISEnabled) return false;
    if (!mStagesActive || !mEnableNRD || mSamplesPerPixel != 1u || mUseRussianRoulette)
    {
        invalidateGRIS();
        logWarningOnce("RTPT GRIS requires Primary Surface, internal NRD signals, one sample per pixel, and RR disabled.");
        return false;
    }
    if (mReGIREnabled && !mReGIRActive)
    {
        invalidateGRIS();
        logWarningOnce("RTPT GRIS with ReGIR requires a prepared light catalogue.");
        return false;
    }
    const bool temporalSupported = canUseGRISTemporal();
    const bool temporalEnabled = temporalSupported && mGRISTemporalFallbackReason.empty();
    const bool replaySharc = temporalEnabled && mEnableSHARC && mSHARCEnabled && mSHARCUseCache;
    if (mGRISTemporalEnabled && !temporalSupported)
        logWarningOnce("RTPT GRIS Temporal requires compatible NEE and alternating GRIS.");
    const bool supportedLighting = !mReGIREnabled || diActive || mReGIRSecondaryEnabled;
    const bool spatialEnabled = mGRISSpatialEnabled && mUseNEE && supportedLighting;
    if (mGRISSpatialEnabled && !spatialEnabled)
        logWarningOnce("RTPT GRIS spatial reuse at x2 requires compatible NEE; using local paths.");
    const bool alternating = canUseGRISAlternating();
    const bool captureSuffix = spatialEnabled || temporalEnabled || alternating;
    const bool blendX1Cache = alternating && mGRISSharcX1Blend > 0.f && mEnableSHARC && mSHARCEnabled &&
        mSHARCUseCache && mSHARCMinBounce <= 2u && mMaxBounces > 2u;

    if (mpGRISMainPass && bool(mpGRISSpatialPass) == (spatialEnabled && !temporalEnabled) &&
        bool(mpGRISTemporalPass) == temporalEnabled &&
        (mpGRISGeneratePass->getProgram()->getDefines().count("RTPT_GRIS_SHARC_REPLAY") != 0) == replaySharc &&
        (mpGRISGeneratePass->getProgram()->getDefines().count("RTPT_GRIS_SHARC_X1_BLEND") != 0) == blendX1Cache &&
        (mpGRISMainPass->getProgram()->getDefines().count("RTPT_GRIS_ALTERNATING") != 0) == alternating &&
        (mpGRISMainPass->getProgram()->getDefines().count("RTPT_USE_RESTIR_DI") != 0) == diActive)
        return true;

    invalidateGRIS(false);
    try
    {
        auto baseDefines = baseMainPass->getProgram()->getDefines();
        if (alternating) baseDefines.add("RTPT_GRIS_ALTERNATING", "1");
        auto generateDefines = baseDefines;
        if (captureSuffix) generateDefines.add("RTPT_GRIS_SPATIAL", "1");
        if (replaySharc) generateDefines.add("RTPT_GRIS_SHARC_REPLAY", "1");
        if (blendX1Cache) generateDefines.add("RTPT_GRIS_SHARC_X1_BLEND", "1");
        const auto generateDesc = makeSceneProgramDesc("RenderPasses/RTPT/GRIS/RTPTGRISGenerate.cs.slang");
        mpGRISGeneratePass = ComputePass::create(mpDevice, generateDesc, generateDefines, true);

        DefineList shadeDefines;
        if (captureSuffix)
        {
            shadeDefines.add("RTPT_GRIS_SPATIAL", "1");
            if (alternating) shadeDefines.add("RTPT_GRIS_ALTERNATING", "1");
            if (blendX1Cache) shadeDefines.add("RTPT_GRIS_SHARC_X1_BLEND", "1");
            if (const auto it = baseDefines.find("RTPT_REGIR_ONLY"); it != baseDefines.end())
                shadeDefines.add(it->first, it->second);
            if (const auto it = baseDefines.find("HIT_INFO_USE_COMPRESSION"); it != baseDefines.end())
                shadeDefines.add(it->first, it->second);
        }
        if (captureSuffix)
        {
            auto reuseDefines = baseDefines;
            if (alternating && spatialEnabled) reuseDefines.add("RTPT_GRIS_ALTERNATING_SPATIAL", "1");
            if (replaySharc) reuseDefines.add("RTPT_GRIS_SHARC_REPLAY", "1");
            const auto reuseDesc = makeSceneProgramDesc(
                temporalEnabled ? "RenderPasses/RTPT/GRIS/RTPTGRISTemporal.cs.slang" : "RenderPasses/RTPT/GRIS/RTPTGRISSpatial.cs.slang"
            );
            if (temporalEnabled)
            {
                mpGRISTemporalPass = ComputePass::create(mpDevice, reuseDesc, reuseDefines, true);
                ProgramDesc publishDesc;
                publishDesc.addShaderLibrary("RenderPasses/RTPT/GRIS/RTPTGRISPublishHistory.cs.slang").csEntry("main");
                mpGRISPublishHistoryPass = ComputePass::create(mpDevice, publishDesc, baseDefines, true);
            }
            else if (spatialEnabled) mpGRISSpatialPass = ComputePass::create(mpDevice, reuseDesc, reuseDefines, true);
            else mpGRISLocalPass = ComputePass::create(mpDevice, reuseDesc, reuseDefines, true);
        }

        ProgramDesc shadeDesc;
        shadeDesc.addShaderLibrary("RenderPasses/RTPT/GRIS/RTPTGRISShade.cs.slang").csEntry("main");
        mpGRISShadePass = ComputePass::create(mpDevice, shadeDesc, shadeDefines, true);

        auto mainDefines = baseDefines;
        mainDefines.add("RTPT_USE_GRIS", "1");
        mpGRISMainPass = ComputePass::create(mpDevice, baseMainPass->getProgram()->getDesc(), mainDefines, true);

        const auto& reusePass = temporalEnabled ? mpGRISTemporalPass : (spatialEnabled ? mpGRISSpatialPass : mpGRISLocalPass);
        const auto candidateVar = captureSuffix
            ? reusePass->getRootVar()["gGRISSpatialOutput"]
            : mpGRISGeneratePass->getRootVar()["gGRISCandidates"];
        const auto spatialInputVar = captureSuffix
            ? mpGRISGeneratePass->getRootVar()[alternating ? "gGRISFresh" : "gGRISSpatialInput"]
            : ShaderVar{};
        const auto prefixVar = captureSuffix && !alternating ? mpGRISGeneratePass->getRootVar()["gGRISLocalPrefixes"] : ShaderVar{};
        const auto shadedVar = mpGRISShadePass->getRootVar()["gGRISShadedIndirect"];
        const auto historyVar = temporalEnabled ? mpGRISPublishHistoryPass->getRootVar()["gGRISHistory"] : ShaderVar{};
        const uint64_t pixelCount = uint64_t(mFrameDim.x) * mFrameDim.y;
        const uint64_t spatialStride = captureSuffix
            ? structuredStride(spatialInputVar) + (alternating ? 0u : structuredStride(prefixVar))
            : 0u;
        const uint64_t historyStride = temporalEnabled ? structuredStride(historyVar) : 0u;
        if (temporalEnabled)
            FALCOR_CHECK(historyStride == kGRISHistoryStride &&
                structuredStride(mpGRISTemporalPass->getRootVar()["gGRISHistory"]) == historyStride,
                "RTPT GRIS Temporal requires an 84-byte history record in both passes.");
        const uint64_t grisBytes = pixelCount * (structuredStride(candidateVar) + spatialStride + structuredStride(shadedVar) + historyStride);
        const uint64_t stageBytes = mpPrimarySurfaces->getSize() + mpSignalRecords->getSize();
        FALCOR_CHECK(stageBytes + grisBytes <= kStageResourceBudgetBytes || temporalSupported || alternating,
            "RTPT GRIS and primary/signal buffers exceed their 1 GiB budget.");
        if (stageBytes + grisBytes > kStageResourceBudgetBytes)
            logWarningOnce("RTPT GRIS: attempting to allocate {} bytes of combined stage buffers above 1 GiB.", stageBytes + grisBytes);

        mpGRISCandidates = mpDevice->createStructuredBuffer(candidateVar, uint32_t(pixelCount));
        if (captureSuffix)
        {
            mpGRISSpatialInput = mpDevice->createStructuredBuffer(spatialInputVar, uint32_t(pixelCount));
            if (!alternating) mpGRISLocalPrefixes = mpDevice->createStructuredBuffer(prefixVar, uint32_t(pixelCount));
        }
        mpGRISShadedIndirect = mpDevice->createStructuredBuffer(shadedVar, uint32_t(pixelCount));
        if (temporalEnabled) mpGRISHistory = mpDevice->createStructuredBuffer(historyVar, uint32_t(pixelCount));
        mpGRISMainPass->getRootVar()["gGRISShadedIndirect"] = mpGRISShadedIndirect;
        return true;
    }
    catch (const std::exception& error)
    {
        invalidateGRIS(false);
        if (temporalEnabled)
        {
            mGRISTemporalFallbackReason = error.what();
            logWarning("RTPT GRIS Temporal preparation failed; using current-frame GRIS: {}", mGRISTemporalFallbackReason);
            return prepareGRIS(baseMainPass, diActive);
        }
        logWarningOnce("RTPT GRIS preparation failed; using the original integrator: {}", error.what());
        return false;
    }
}

void RTPT::bindMainParams(const ShaderVar& rootVar) const
{
    auto params = rootVar["gParams"];
    params["frameDim"] = mFrameDim;
    params["samplesPerPixel"] = mSamplesPerPixel;
    params["maxBounces"] = mMaxBounces;
    params["rrStartBounce"] = mRRStartBounce;
    params["seed"] = mSeed;
    params["sampleOffset"] = mSampleOffset;
    params["accumulatedSamples"] = mAccumulate ? mAccumulatedSamples : 0u;
    params["useNEE"] = mUseNEE ? 1u : 0u;
    params["useRussianRoulette"] = mUseRussianRoulette ? 1u : 0u;
    params["accumulate"] = mAccumulate ? 1u : 0u;
}

void RTPT::executeGRIS(RenderContext* pRenderContext, const RenderData& renderData, bool diActive)
{
    const auto& reusePass = mpGRISTemporalPass ? mpGRISTemporalPass : (mpGRISLocalPass ? mpGRISLocalPass : mpGRISSpatialPass);
    const bool alternating = reusePass && !mpGRISLocalPrefixes;
    GrisTemporalSnapshot snapshot;
    if (mpGRISTemporalPass)
    {
        const bool pg = mEnablePG && mPGSettings.enabled && mPGSettings.useGuiding;
        const bool sharc = mEnableSHARC && mSHARCEnabled && mSHARCUseCache;
        if (pg)
        {
            snapshot.pgVersion = mpPG->getReadSnapshotVersion();
            snapshot.pgGeneration = mpPG->getGeneration();
        }
        if (sharc) snapshot.sharcVersion = mSHARCResolveVersion;
        if (mReGIRActive && mReGIRSecondaryEnabled) snapshot.regirDomainGeneration = mReGIRDomainGeneration;
        // Both the guide lookup and SHaRC's voxel LOD depend on the camera origin.
        if (pg || sharc) snapshot.cameraPosition = mpScene->getCamera()->getPosition();
    }
    const auto generateVar = mpGRISGeneratePass->getRootVar();
    mpScene->bindShaderDataForRaytracing(pRenderContext, generateVar["gScene"]);
    mpSampleGenerator->bindShaderData(generateVar);
    if (mpEnvMapSampler && generateVar.hasMember("gEnvMapSampler"))
        mpEnvMapSampler->bindShaderData(generateVar["gEnvMapSampler"]);
    bindMainParams(generateVar);
    bindPrimarySettings(generateVar);
    generateVar["gPrimarySurfaces"] = mpPrimarySurfaces;
    if (mEnableSHARC)
    {
        if (generateVar.hasMember("gSharc")) bindSHARC(generateVar);
        generateVar["gSharcStats"] = renderData.getTexture("sharcStats");
    }
    if (mEnablePG)
        mpPG->bind(generateVar, mpScene->getCamera()->getPosition(), mSHARCSceneScale, mPGFrameIndex, false, false, true);
    if (diActive) bindDIMainResources(generateVar);
    if (mReGIREnabled) bindReGIRTransport(generateVar);
    if (reusePass)
    {
        generateVar[alternating ? "gGRISFresh" : "gGRISSpatialInput"] = mpGRISSpatialInput;
        if (!alternating) generateVar["gGRISLocalPrefixes"] = mpGRISLocalPrefixes;
    }
    else generateVar["gGRISCandidates"] = mpGRISCandidates;
    {
        FALCOR_PROFILE(pRenderContext, "GRISGenerate");
        mpGRISGeneratePass->execute(pRenderContext, uint3(mFrameDim, 1u));
    }
    const auto shadeVar = mpGRISShadePass->getRootVar();
    if (reusePass)
    {
        pRenderContext->uavBarrier(mpGRISSpatialInput.get());
        if (!alternating) pRenderContext->uavBarrier(mpGRISLocalPrefixes.get());
        const auto reuseVar = reusePass->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, reuseVar["gScene"]);
        mpSampleGenerator->bindShaderData(reuseVar);
        bindMainParams(reuseVar);
        bindPrimarySettings(reuseVar);
        if (mpGRISTemporalPass)
        {
            const auto& history = mGRISHistoryFrame;
            const bool canReplay = reusePass->getProgram()->getDefines().count("RTPT_GRIS_SHARC_REPLAY") != 0;
            mGRISHistoryReadValid = history.historyValid && history.historyGeneration == mGRISHistoryGeneration &&
                history.previousFrameStamp == mPrimaryFrameStamp - 1u && all(history.previousFrameDim == mFrameDim) &&
                history.snapshot.isCompatible(snapshot, canReplay);
            mGRISHistoryReplayActive = mGRISHistoryReadValid && canReplay && history.snapshot.sharcVersion != snapshot.sharcVersion;
            const auto settings = reuseVar["gGRISTemporalSettings"];
            settings["previousViewProj"] = history.previousViewProj;
            settings["previousFrameDim"] = history.previousFrameDim;
            settings["historyValid"] = mGRISHistoryReadValid ? 1u : 0u;
            if (canReplay)
            {
                settings["replayHistory"] = mGRISHistoryReplayActive ? 1u : 0u;
                if (mpEnvMapSampler && reuseVar.hasMember("gEnvMapSampler"))
                    mpEnvMapSampler->bindShaderData(reuseVar["gEnvMapSampler"]);
                if (diActive && reuseVar.hasMember("gDISettings")) bindDIMainResources(reuseVar);
            }
            reuseVar["gPrimarySurfaces"] = mpPrimarySurfaces;
            reuseVar["gGRISHistory"] = mpGRISHistory;
        }
        if (mReGIREnabled) bindReGIRTransport(reuseVar);
        if (mEnableSHARC && reuseVar.hasMember("gSharc")) bindSHARC(reuseVar);
        reuseVar[alternating ? "gGRISFresh" : "gGRISSpatialInput"] = mpGRISSpatialInput;
        if (!alternating) reuseVar["gGRISLocalPrefixes"] = mpGRISLocalPrefixes;
        reuseVar["gGRISSpatialOutput"] = mpGRISCandidates;
        {
            FALCOR_PROFILE(pRenderContext, mpGRISTemporalPass ? "GRISTemporal" : (mpGRISSpatialPass ? "GRISSpatial" : "GRISLocal"));
            reusePass->execute(pRenderContext, uint3(mFrameDim, 1u));
        }
        if (alternating) shadeVar["gGRISFresh"] = mpGRISSpatialInput;
        else shadeVar["gGRISLocalPrefixes"] = mpGRISLocalPrefixes;
    }
    if (mpGRISPublishHistoryPass)
    {
        // The read-to-write resource transition orders this overwrite after Temporal.
        const auto publishVar = mpGRISPublishHistoryPass->getRootVar();
        bindPrimarySettings(publishVar);
        publishVar[alternating ? "gGRISFresh" : "gGRISSpatialInput"] = mpGRISSpatialInput;
        if (!alternating) publishVar["gGRISLocalPrefixes"] = mpGRISLocalPrefixes;
        publishVar["gGRISHistory"] = mpGRISHistory;
        FALCOR_PROFILE(pRenderContext, "GRISPublishHistory");
        mpGRISPublishHistoryPass->execute(pRenderContext, uint3(mFrameDim, 1u));
        pRenderContext->uavBarrier(mpGRISHistory.get());
        mGRISHistoryFrame = {mpScene->getCamera()->getViewProjMatrix(), mFrameDim, mPrimaryFrameStamp,
            mGRISHistoryGeneration, true, snapshot};
    }
    pRenderContext->uavBarrier(mpGRISCandidates.get());
    shadeVar["gGRISCandidates"] = mpGRISCandidates;
    bindPrimarySettings(shadeVar);
    shadeVar["gGRISShadedIndirect"] = mpGRISShadedIndirect;
    {
        FALCOR_PROFILE(pRenderContext, "GRISShade");
        mpGRISShadePass->execute(pRenderContext, uint3(mFrameDim, 1u));
    }
    pRenderContext->uavBarrier(mpGRISShadedIndirect.get());
}

void RTPT::bindPrimarySettings(const ShaderVar& rootVar) const
{
    auto settings = rootVar["gPrimarySettings"];
    settings["frameDim"] = mFrameDim;
    settings["sampleIndex"] = mSampleOffset + mSeed * 0x9e3779b9u;
    settings["frameStamp"] = mPrimaryFrameStamp;
    settings["prepared"] = mStagesActive ? 1u : 0u;
    settings["grisSharcX1Blend"] = mGRISSharcX1Blend;
}

void RTPT::executePrimarySurface(RenderContext* pRenderContext)
{
    ++mPrimaryFrameStamp;
    auto var = mpPrimarySurfacePass->getRootVar();
    mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    mpSampleGenerator->bindShaderData(var);
    bindPrimarySettings(var);
    var["gPrimarySurfaceOutput"] = mpPrimarySurfaces;
    FALCOR_PROFILE(pRenderContext, "PrimarySurface");
    mpPrimarySurfacePass->execute(pRenderContext, uint3(mFrameDim, 1u));
    pRenderContext->uavBarrier(mpPrimarySurfaces.get());
}

void RTPT::executeFinalSignalResolve(RenderContext* pRenderContext, const RenderData& renderData)
{
    pRenderContext->uavBarrier(mpSignalRecords.get());
    auto var = mpFinalSignalResolve->getRootVar();
    var["gResolveParams"]["frameDim"] = mFrameDim;
    var["gSignalRecords"] = mpSignalRecords;
    var["gColor"] = renderData.getTexture("color");
    var["gNoisyColor"] = renderData.getTexture("noisyColor");
    var["gAccumulation"] = mpAccumulation;
    bindNRDOutputs(var, renderData);
    FALCOR_PROFILE(pRenderContext, "FinalSignalResolve");
    mpFinalSignalResolve->execute(pRenderContext, uint3(mFrameDim, 1u));
}

Properties RTPT::getStageStatistics() const
{
    Properties props;
    props["primaryActive"] = mStagesActive;
    props["finalResolveActive"] = mStagesActive && mEnableNRD;
    props["nrdHistoryReset"] = mNRDHistoryResetThisFrame;
    props["pgTranslationPreservedNRD"] = mPGTranslationPreservedNRDThisFrame;
    props["pgModelReset"] = mPGModelResetThisFrame;
    props["sharcCacheReset"] = mSHARCCacheResetThisFrame;
    props["sceneMotion"] = mSceneMotionThisFrame;
    // execute() advances these counters after rendering; they identify the
    // next sample/update phase when inspected from Python after a frame.
    props["sampleOffset"] = mSampleOffset;
    props["pgFrameIndex"] = mPGFrameIndex;
    props["sharcFrameIndex"] = mSHARCFrameIndex;
    props["sharcMotionBoundsCount"] = uint32_t(mSHARCMotionBoundsCPU.size() / 2);
    props["sharcMotionResponsive"] = mSHARCMotionResponsiveFrames != 0u;
    const uint64_t primaryBytes = mpPrimarySurfaces ? mpPrimarySurfaces->getSize() : 0;
    const uint64_t signalBytes = mpSignalRecords ? mpSignalRecords->getSize() : 0;
    props["primaryBytes"] = primaryBytes;
    props["signalBytes"] = signalBytes;
    uint64_t grisBytes = 0;
    for (const auto& buffer : {mpGRISCandidates, mpGRISSpatialInput, mpGRISLocalPrefixes, mpGRISShadedIndirect, mpGRISHistory})
        grisBytes += buffer ? buffer->getSize() : 0;
    props["grisSpatialActive"] = bool(mpGRISSpatialPass) ||
        (mpGRISTemporalPass && mpGRISTemporalPass->getProgram()->getDefines().count("RTPT_GRIS_ALTERNATING_SPATIAL") != 0);
    props["grisAlternatingActive"] = bool(mpGRISSpatialInput) && !mpGRISLocalPrefixes;
    props["grisTemporalActive"] = bool(mpGRISTemporalPass);
    props["grisHistoryReadValid"] = mGRISHistoryReadValid;
    props["grisHistoryReplayActive"] = mGRISHistoryReplayActive;
    props["grisHistoryBytes"] = mpGRISHistory ? mpGRISHistory->getSize() : 0;
    props["grisHistoryStride"] = mpGRISHistory ? mpGRISHistory->getStructSize() : 0u;
    props["grisTemporalFallbackReason"] = mGRISTemporalFallbackReason;
    props["grisBytes"] = grisBytes;
    props["grisPrefixBytes"] = mpGRISLocalPrefixes ? mpGRISLocalPrefixes->getSize() : 0;
    props["bytes"] = primaryBytes + signalBytes;
    props["totalStageBytes"] = primaryBytes + signalBytes + grisBytes;
    props["budgetBytes"] = kStageResourceBudgetBytes;
    props["primaryStride"] = mpPrimarySurfaces ? mpPrimarySurfaces->getStructSize() : 0u;
    props["signalStride"] = mpSignalRecords ? mpSignalRecords->getStructSize() : 0u;
    props["frameStamp"] = mPrimaryFrameStamp;
    props["fallbackReason"] = mStageFallbackReason;
    return props;
}
