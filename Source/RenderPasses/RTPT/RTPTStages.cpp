#include "RTPT.h"
#include "Utils/Timing/Profiler.h"
#include <algorithm>
#include <limits>
#include <utility>

namespace
{
// This threshold accounts only for the per-pixel stage buffers.
constexpr uint64_t kStageResourceBudgetBytes = 1ull << 30;

uint64_t structuredStride(const ShaderVar& var)
{
    FALCOR_CHECK(var.isValid() && var.getType(), "RTPT stage buffer reflection is missing its resource.");
    const auto* type = var.getType()->unwrapArray()->asResourceType();
    FALCOR_CHECK(type && type->getStructType(), "RTPT stage buffer reflection is missing its structure.");
    return type->getStructType()->getSlangTypeLayout()->getStride();
}
}

void RTPT::invalidateStages(bool preserveGRISHistory)
{
    invalidateGRIS(true, preserveGRISHistory);
    invalidateDirectLighting();
    mLightCatalog.retry();
    // Release parameter blocks as well as our own references before reallocating.
    mpStageComputePass = mpPrimarySurfacePass = mpFinalSignalResolve = nullptr;
    mpPrimarySurfaces = mpSignalRecords = nullptr;
    // A proposal-only program rebuild keeps the same pixel domain. Marking
    // its dimensions unknown would make prepareStages() discard the history
    // a second time before it can bind the replacement programs.
    mStageResourceDim = preserveGRISHistory ? mFrameDim : uint2(0u);
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

bool RTPT::canUseGRISReferenceReuse() const
{
    // The flattened ReGIR tail owns the complete cell-only local-light domain.
    // Mixed screen-DI/remaining-light transport keeps its existing local path
    // until its endpoint and complementary MIS contracts are implemented.
    const bool compatibleReGIR = !mReGIREnabled || (!mRestirDIEnabled && mReGIRSecondaryEnabled);
    return compatibleReGIR && !(mEnableSHARC && mSHARCEnabled && mSHARCUseCache);
}

bool RTPT::canUseGRISTemporal() const
{
    const bool compatibleReGIR = !mReGIREnabled || mRestirDIEnabled || mReGIRSecondaryEnabled;
    return mGRISTemporalEnabled && mGRISEnabled && mEnableNRD && mSamplesPerPixel == 1u &&
        !mUseRussianRoulette && compatibleReGIR;
}

bool RTPT::canUseGRISAlternating() const
{
    // Complete fresh paths choose their root through BSDF sampling every frame.
    return false;
}

void RTPT::resetGRISHistory()
{
    ++mGRISHistoryGeneration;
    mGRISHistoryFrame.historyValid = false;
    mGRISHistoryReadValid = false;
    mGRISHistoryReplayActive = false;
    mGRISHistoryReferenceDomain = false;
}

void RTPT::invalidateGRIS(bool clearTemporalFailure, bool preserveHistory)
{
    // Only the fixed-x2 reference representation can outlive a proposal-only
    // specialization change. Frame dimensions and the reflected layout are
    // checked again when the replacement programs are prepared.
    const bool keepHistory = preserveHistory && mpGRISHistory && mGRISHistoryReferenceDomain &&
        all(mGRISHistoryFrame.previousFrameDim == mFrameDim);
    mpGRISGeneratePass = mpGRISSpatialPass = mpGRISShadePass = mpGRISMainPass = nullptr;
    mpGRISTemporalPass = mpGRISPublishHistoryPass = mpGRISLocalPass = nullptr;
    mpGRISCandidates = mpGRISSpatialInput = mpGRISLocalPrefixes = mpGRISShadedIndirect = nullptr;
    if (!keepHistory)
    {
        mpGRISHistory = nullptr;
        resetGRISHistory();
    }
    else
    {
        // This flag reports the current dispatch, not merely a retained buffer.
        mGRISHistoryReadValid = mGRISHistoryReplayActive = false;
    }
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
    const bool replaySharc = false;
    if (mGRISTemporalEnabled && !temporalSupported)
        logWarningOnce("RTPT GRIS Temporal requires compatible lighting, internal NRD signals, one sample per pixel, and RR disabled.");
    const bool supportedLighting = !mReGIREnabled || diActive || mReGIRSecondaryEnabled;
    const bool spatialEnabled = mGRISSpatialEnabled && supportedLighting;
    const bool referenceReuse = canUseGRISReferenceReuse();
    if (mGRISSpatialEnabled && !spatialEnabled)
        logWarningOnce("RTPT GRIS spatial reuse at x2 requires compatible lighting; using local paths.");
    const bool alternating = false;
    // Local-only GRIS uses the same full-path record as spatial and temporal reuse.
    const bool captureSuffix = true;
    const bool blendX1Cache = false;

    if (mpGRISMainPass && bool(mpGRISSpatialPass) == (spatialEnabled && !temporalEnabled) &&
        bool(mpGRISTemporalPass) == temporalEnabled &&
        mpGRISGeneratePass->getProgram()->getDefines().count("RTPT_GRIS_PG_PREFIX_DEPTH") != 0 &&
        mpGRISGeneratePass->getProgram()->getDefines().find("RTPT_GRIS_PG_PREFIX_DEPTH")->second == std::to_string(mGRISPGPrefixDepth) &&
        (mpGRISGeneratePass->getProgram()->getDefines().count("RTPT_GRIS_SHARC_REPLAY") != 0) == replaySharc &&
        (mpGRISGeneratePass->getProgram()->getDefines().count("RTPT_GRIS_SHARC_X1_BLEND") != 0) == blendX1Cache &&
        (mpGRISMainPass->getProgram()->getDefines().count("RTPT_GRIS_ALTERNATING") != 0) == alternating &&
        mpGRISMainPass->getProgram()->getDefines().count("RTPT_GRIS_REFERENCE_REUSE") != 0 &&
        mpGRISMainPass->getProgram()->getDefines().find("RTPT_GRIS_REFERENCE_REUSE")->second == (referenceReuse ? "1" : "0") &&
        (mpGRISMainPass->getProgram()->getDefines().count("RTPT_USE_RESTIR_DI") != 0) == diActive)
        return true;

    const bool preserveHistory = temporalEnabled && referenceReuse && mGRISHistoryReferenceDomain &&
        mpGRISHistory && all(mGRISHistoryFrame.previousFrameDim == mFrameDim);
    invalidateGRIS(false, preserveHistory);
    try
    {
        auto baseDefines = baseMainPass->getProgram()->getDefines();
        baseDefines.add("RTPT_GRIS_REFERENCE_REUSE", referenceReuse ? "1" : "0");
        baseDefines.add("RTPT_GRIS_PG_PREFIX_DEPTH", std::to_string(mGRISPGPrefixDepth));
        if (alternating) baseDefines.add("RTPT_GRIS_ALTERNATING", "1");
        auto generateDefines = baseDefines;
        if (captureSuffix) generateDefines.add("RTPT_GRIS_SPATIAL", "1");
        if (replaySharc) generateDefines.add("RTPT_GRIS_SHARC_REPLAY", "1");
        if (blendX1Cache) generateDefines.add("RTPT_GRIS_SHARC_X1_BLEND", "1");
        const auto generateDesc = makeSceneProgramDesc("RenderPasses/RTPT/GRIS/RTPTGRISGenerate.cs.slang");
        mpGRISGeneratePass = ComputePass::create(mpDevice, generateDesc, generateDefines, true);

        DefineList shadeDefines;
        shadeDefines.add("RTPT_GRIS_REFERENCE_REUSE", referenceReuse ? "1" : "0");
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
            if (spatialEnabled) reuseDefines.add("RTPT_GRIS_SPATIAL_REUSE", "1");
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
        const uint64_t candidateStride = structuredStride(candidateVar);
        const uint64_t freshStride = structuredStride(spatialInputVar);
        const uint64_t prefixStride = structuredStride(prefixVar);
        FALCOR_CHECK(structuredStride(reusePass->getRootVar()["gGRISSpatialInput"]) == freshStride,
            "RTPT GRIS Generate and Reuse disagree on the fresh path record layout.");
        FALCOR_CHECK(structuredStride(mpGRISShadePass->getRootVar()["gGRISCandidates"]) == candidateStride,
            "RTPT GRIS Reuse and Shade disagree on the selected path record layout.");
        FALCOR_CHECK(structuredStride(mpGRISMainPass->getRootVar()["gGRISShadedIndirect"]) == structuredStride(shadedVar),
            "RTPT GRIS Shade and Main disagree on the shaded indirect layout.");
        FALCOR_CHECK(structuredStride(mpGRISShadePass->getRootVar()["gGRISLocalPrefixes"]) == prefixStride,
            "RTPT GRIS Generate and Shade disagree on the local contribution layout.");
        if (temporalEnabled)
        {
            FALCOR_CHECK(structuredStride(mpGRISTemporalPass->getRootVar()["gGRISHistory"]) == historyStride,
                "RTPT GRIS Temporal and PublishHistory disagree on the history layout.");
            FALCOR_CHECK(structuredStride(mpGRISPublishHistoryPass->getRootVar()["gGRISSpatialInput"]) == candidateStride,
                "RTPT GRIS PublishHistory must consume the selected path record.");
        }
        const uint64_t grisBytes = pixelCount * (candidateStride + spatialStride + structuredStride(shadedVar) + historyStride);
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
        if (temporalEnabled)
        {
            if (mpGRISHistory && (mpGRISHistory->getStructSize() != historyStride ||
                mpGRISHistory->getElementCount() != pixelCount))
            {
                // Matching allocation size alone is not a layout contract.
                // Never reinterpret a retained reservoir with another stride.
                mpGRISHistory = nullptr;
                resetGRISHistory();
            }
            if (!mpGRISHistory) mpGRISHistory = mpDevice->createStructuredBuffer(historyVar, uint32_t(pixelCount));
        }
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
    const float3 cameraPosition = mpScene->getCamera()->getPosition();
    GrisTemporalSnapshot snapshot;
    if (mpGRISTemporalPass)
    {
        const bool pg = mGRISPGPrefixDepth > 0u && mEnablePG && mPGSettings.enabled && mPGSettings.useGuiding;
        const bool sharc = mEnableSHARC && mSHARCEnabled && mSHARCUseCache;
        if (pg)
        {
            snapshot.pgVersion = mpPG->getReadSnapshotVersion();
            snapshot.pgGeneration = mpPG->getGeneration();
        }
        if (sharc) snapshot.sharcVersion = mSHARCResolveVersion;
        if (mReGIRActive && mReGIRSecondaryEnabled) snapshot.regirDomainGeneration = mReGIRDomainGeneration;
        // Both the guide lookup and SHaRC's voxel LOD depend on the camera origin.
        if (pg || sharc) snapshot.cameraPosition = cameraPosition;
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
        const auto reuseVar = reusePass->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, reuseVar["gScene"]);
        mpSampleGenerator->bindShaderData(reuseVar);
        bindMainParams(reuseVar);
        bindPrimarySettings(reuseVar);
        reuseVar["gPrimarySurfaces"] = mpPrimarySurfaces;
        if (mpEnvMapSampler && reuseVar.hasMember("gEnvMapSampler"))
            mpEnvMapSampler->bindShaderData(reuseVar["gEnvMapSampler"]);
        if (mpGRISTemporalPass)
        {
            const auto& history = mGRISHistoryFrame;
            const auto& defines = reusePass->getProgram()->getDefines();
            const bool canReplay = defines.count("RTPT_GRIS_SHARC_REPLAY") != 0;
            const auto referenceMode = defines.find("RTPT_GRIS_REFERENCE_REUSE");
            const bool referenceReuse = referenceMode != defines.end() && referenceMode->second == "1";
            mGRISHistoryReadValid = history.historyValid && history.historyGeneration == mGRISHistoryGeneration &&
                history.previousFrameStamp == mPrimaryFrameStamp - 1u && all(history.previousFrameDim == mFrameDim) &&
                history.snapshot.isCompatible(snapshot, canReplay, referenceReuse);
            mGRISHistoryReplayActive = mGRISHistoryReadValid && canReplay && history.snapshot.sharcVersion != snapshot.sharcVersion;
            const auto settings = reuseVar["gGRISTemporalSettings"];
            settings["previousViewProj"] = history.previousViewProj;
            settings["previousCameraPosition"] = history.previousCameraPosition;
            settings["previousFrameDim"] = history.previousFrameDim;
            settings["historyValid"] = mGRISHistoryReadValid ? 1u : 0u;
            if (canReplay)
            {
                settings["replayHistory"] = mGRISHistoryReplayActive ? 1u : 0u;
                if (diActive && reuseVar.hasMember("gDISettings")) bindDIMainResources(reuseVar);
            }
            reuseVar["gGRISHistory"] = mpGRISHistory;
        }
        if (mReGIREnabled) bindReGIRTransport(reuseVar);
        if (mEnableSHARC && reuseVar.hasMember("gSharc")) bindSHARC(reuseVar);
        reuseVar[alternating ? "gGRISFresh" : "gGRISSpatialInput"] = mpGRISSpatialInput;
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
        pRenderContext->uavBarrier(mpGRISCandidates.get());
        // The read-to-write resource transition orders this overwrite after Temporal.
        const auto publishVar = mpGRISPublishHistoryPass->getRootVar();
        bindPrimarySettings(publishVar);
        publishVar["gGRISSpatialInput"] = mpGRISCandidates;
        publishVar["gGRISHistory"] = mpGRISHistory;
        FALCOR_PROFILE(pRenderContext, "GRISPublishHistory");
        mpGRISPublishHistoryPass->execute(pRenderContext, uint3(mFrameDim, 1u));
        pRenderContext->uavBarrier(mpGRISHistory.get());
        mGRISHistoryFrame = {mpScene->getCamera()->getViewProjMatrix(), cameraPosition, mFrameDim, mPrimaryFrameStamp,
            mGRISHistoryGeneration, true, snapshot};
        const auto& historyDefines = mpGRISTemporalPass->getProgram()->getDefines();
        const auto historyMode = historyDefines.find("RTPT_GRIS_REFERENCE_REUSE");
        mGRISHistoryReferenceDomain = historyMode != historyDefines.end() && historyMode->second == "1";
    }
    pRenderContext->uavBarrier(mpGRISCandidates.get());
    if (!alternating) pRenderContext->uavBarrier(mpGRISLocalPrefixes.get());
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
        (mpGRISTemporalPass && mpGRISTemporalPass->getProgram()->getDefines().count("RTPT_GRIS_SPATIAL_REUSE") != 0);
    props["grisAlternatingActive"] = bool(mpGRISSpatialInput) && !mpGRISLocalPrefixes;
    props["grisPGPrefixDepth"] = mGRISPGPrefixDepth;
    const bool pgProposalActive = mGRISPGPrefixDepth > 0u && mEnablePG && mPGSettings.enabled && mPGSettings.useGuiding;
    props["grisPGProposalActive"] = pgProposalActive;
    bool referenceReuse = false;
    bool regirOnly = false;
    if (mpGRISMainPass)
    {
        const auto& defines = mpGRISMainPass->getProgram()->getDefines();
        const auto mode = defines.find("RTPT_GRIS_REFERENCE_REUSE");
        referenceReuse = mode != defines.end() && mode->second == "1";
        const auto regirMode = defines.find("RTPT_REGIR_ONLY");
        regirOnly = regirMode != defines.end() && regirMode->second == "1";
    }
    props["grisReferenceReuseEnabled"] = referenceReuse;
    props["grisPGSnapshotDependent"] = bool(mpGRISTemporalPass) && pgProposalActive && !referenceReuse;
    props["grisReGIRPathReuseEnabled"] = referenceReuse && regirOnly;
    props["grisReferenceReuseReason"] = referenceReuse ? std::string{} : !mpGRISMainPass
        ? std::string("GRIS is inactive") : mEnableSHARC && mSHARCEnabled && mSHARCUseCache
        ? std::string("SHaRC cache transport uses complete local paths") : mReGIREnabled && !regirOnly
        ? std::string("ReGIR mixed direct-light transport uses complete local paths") : mReGIREnabled && !mReGIRSecondaryEnabled
        ? std::string("ReGIR reference reuse requires secondary light sampling")
        : std::string("Reference-tail reuse is unavailable");
    props["grisTemporalActive"] = bool(mpGRISTemporalPass);
    props["grisHistoryReadValid"] = mGRISHistoryReadValid;
    props["grisHistoryPublishedValid"] = mGRISHistoryFrame.historyValid;
    props["grisHistoryGeneration"] = mGRISHistoryGeneration;
    props["grisHistoryStoredGeneration"] = mGRISHistoryFrame.historyGeneration;
    props["grisHistoryStoredFrameStamp"] = mGRISHistoryFrame.previousFrameStamp;
    props["grisHistoryReferenceDomain"] = mGRISHistoryReferenceDomain;
    props["grisHistoryReplayActive"] = mGRISHistoryReplayActive;
    props["grisHistoryBytes"] = mpGRISHistory ? mpGRISHistory->getSize() : 0;
    props["grisHistoryStride"] = mpGRISHistory ? mpGRISHistory->getStructSize() : 0u;
    props["grisCandidateStride"] = mpGRISCandidates ? mpGRISCandidates->getStructSize() : 0u;
    props["grisFreshStride"] = mpGRISSpatialInput ? mpGRISSpatialInput->getStructSize() : 0u;
    props["grisLocalContributionStride"] = mpGRISLocalPrefixes ? mpGRISLocalPrefixes->getStructSize() : 0u;
    props["grisShadedStride"] = mpGRISShadedIndirect ? mpGRISShadedIndirect->getStructSize() : 0u;
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
