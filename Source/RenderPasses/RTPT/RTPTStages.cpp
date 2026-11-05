#include "RTPT.h"
#include "Utils/Timing/Profiler.h"
#include <algorithm>
#include <limits>
#include <utility>

namespace
{
// This bounds only the new per-pixel intermediates, not total renderer memory.
constexpr uint64_t kStageResourceBudgetBytes = 1ull << 30;

uint64_t structuredStride(const ShaderVar& var)
{
    FALCOR_CHECK(var.isValid() && var.getType(), "RTPT stage buffer reflection is missing its resource.");
    const auto* type = var.getType()->unwrapArray()->asResourceType();
    FALCOR_CHECK(type && type->getStructType(), "RTPT stage buffer reflection is missing its structure.");
    return type->getStructType()->getSlangTypeLayout()->getStride();
}
}

void RTPT::invalidateStages(bool preserveReGIR)
{
    invalidateGRIS();
    invalidateDirectLighting(preserveReGIR);
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
    if (any(mStageResourceDim != mFrameDim)) invalidateStages(mReGIREnabled);
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

        ProgramDesc primaryDesc;
        primaryDesc.addShaderModules(mpScene->getShaderModules());
        primaryDesc.addShaderLibrary("RenderPasses/RTPT/PrimarySurface/RTPTPrimarySurface.cs.slang").csEntry("main");
        primaryDesc.addTypeConformances(mpScene->getTypeConformances());
        if (mEnableSHARC || mEnablePG || mReGIREnabled)
        {
            primaryDesc.setShaderModel(ShaderModel::SM6_6);
            primaryDesc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
        }
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
        FALCOR_CHECK(pixelCount * (primaryStride + signalStride) <= kStageResourceBudgetBytes,
            "RTPT primary/signal resources exceed their 1 GiB budget ({} pixels, {} + {} bytes per pixel).",
            pixelCount, primaryStride, signalStride);
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

void RTPT::invalidateGRIS()
{
    mpGRISGeneratePass = mpGRISTemporalPass = mpGRISSpatialPass = mpGRISShadePass = mpGRISMainPass = nullptr;
    mpGRISCandidates = mpGRISSpatialInput = mpGRISSpatialOutput = mpGRISShadedIndirect = nullptr;
    mpGRISPreviousPrimarySurface = mpGRISPreviousReservoir = mpGRISTemporalOutput = nullptr;
    invalidateGRISHistory();
}

void RTPT::invalidateGRISHistory()
{
    mGRISHistoryValid = false;
    ++mGRISGeneration;
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
    if (mReGIREnabled && (!mReGIRActive || diActive))
    {
        invalidateGRIS();
        logWarningOnce("RTPT GRIS with ReGIR requires a prepared light catalogue and ReSTIR DI disabled.");
        return false;
    }
    if (mEnablePG && diActive)
    {
        invalidateGRIS();
        logWarningOnce("RTPT GRIS with PG requires ReSTIR DI disabled.");
        return false;
    }

    if (mpGRISMainPass &&
        (mpGRISMainPass->getProgram()->getDefines().count("RTPT_USE_RESTIR_DI") != 0) == diActive)
        return true;

    invalidateGRIS();
    try
    {
        const auto baseDefines = baseMainPass->getProgram()->getDefines();
        const bool spatialEnabled = mGRISSpatialEnabled;
        const bool temporalEnabled = mGRISTemporalEnabled;
        const bool reuseEnabled = spatialEnabled || temporalEnabled;
        auto generateDefines = baseDefines;
        if (reuseEnabled) generateDefines.add("RTPT_GRIS_SPATIAL", "1");
        ProgramDesc generateDesc;
        generateDesc.addShaderModules(mpScene->getShaderModules());
        generateDesc.addTypeConformances(mpScene->getTypeConformances());
        generateDesc.addShaderLibrary("RenderPasses/RTPT/GRIS/RTPTGRISGenerate.cs.slang").csEntry("main");
        if (mEnablePG || mReGIREnabled || mEnableSHARC)
        {
            generateDesc.setShaderModel(ShaderModel::SM6_6);
            generateDesc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
        }
        mpGRISGeneratePass = ComputePass::create(mpDevice, generateDesc, generateDefines, true);

        DefineList shadeDefines;
        if (reuseEnabled) shadeDefines.add("RTPT_GRIS_SPATIAL", "1");
        if (temporalEnabled)
        {
            ProgramDesc temporalDesc;
            temporalDesc.addShaderModules(mpScene->getShaderModules());
            temporalDesc.addTypeConformances(mpScene->getTypeConformances());
            temporalDesc.addShaderLibrary("RenderPasses/RTPT/GRIS/RTPTGRISTemporal.cs.slang").csEntry("main");
            if (mEnablePG || mEnableSHARC || mReGIREnabled)
            {
                temporalDesc.setShaderModel(ShaderModel::SM6_6);
                temporalDesc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
            }
            mpGRISTemporalPass = ComputePass::create(mpDevice, temporalDesc, baseDefines, true);
        }
        if (spatialEnabled)
        {
            ProgramDesc spatialDesc;
            spatialDesc.addShaderModules(mpScene->getShaderModules());
            spatialDesc.addTypeConformances(mpScene->getTypeConformances());
            spatialDesc.addShaderLibrary("RenderPasses/RTPT/GRIS/RTPTGRISSpatial.cs.slang").csEntry("main");
            if (mEnablePG || mReGIREnabled || mEnableSHARC)
            {
                spatialDesc.setShaderModel(ShaderModel::SM6_6);
                spatialDesc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
            }
            mpGRISSpatialPass = ComputePass::create(mpDevice, spatialDesc, baseDefines, true);
        }

        ProgramDesc shadeDesc;
        shadeDesc.addShaderLibrary("RenderPasses/RTPT/GRIS/RTPTGRISShade.cs.slang").csEntry("main");
        mpGRISShadePass = ComputePass::create(mpDevice, shadeDesc, shadeDefines, true);

        auto mainDefines = baseDefines;
        mainDefines.add("RTPT_USE_GRIS", "1");
        mpGRISMainPass = ComputePass::create(mpDevice, baseMainPass->getProgram()->getDesc(), mainDefines, true);

        const auto candidateVar = mpGRISGeneratePass->getRootVar()[reuseEnabled ? "gGRISSpatialInput" : "gGRISCandidates"];
        const auto temporalOutputVar = mpGRISTemporalPass ? mpGRISTemporalPass->getRootVar()["gGRISTemporalOutput"] : ShaderVar{};
        const auto spatialOutputVar = mpGRISSpatialPass ? mpGRISSpatialPass->getRootVar()["gGRISSpatialOutput"] : ShaderVar{};
        const auto shadedVar = mpGRISShadePass->getRootVar()["gGRISShadedIndirect"];
        const uint64_t pixelCount = uint64_t(mFrameDim.x) * mFrameDim.y;
        const uint64_t temporalOutputStride = mpGRISTemporalPass ? structuredStride(temporalOutputVar) : 0u;
        const uint64_t spatialOutputStride = mpGRISSpatialPass ? structuredStride(spatialOutputVar) : 0u;
        const uint64_t grisStride = structuredStride(candidateVar) + 2u * temporalOutputStride + spatialOutputStride +
            structuredStride(shadedVar);
        const uint64_t grisBytes = pixelCount * grisStride + (mpGRISTemporalPass ? mpPrimarySurfaces->getSize() : 0u);
        const uint64_t stageBytes = mpPrimarySurfaces->getSize() + mpSignalRecords->getSize();
        FALCOR_CHECK(stageBytes + grisBytes <= kStageResourceBudgetBytes,
            "RTPT GRIS and primary/signal buffers exceed their 1 GiB budget.");

        if (reuseEnabled)
            mpGRISSpatialInput = mpDevice->createStructuredBuffer(candidateVar, uint32_t(pixelCount));
        else
            mpGRISCandidates = mpDevice->createStructuredBuffer(candidateVar, uint32_t(pixelCount));
        if (mpGRISTemporalPass)
        {
            mpGRISPreviousPrimarySurface = mpDevice->createStructuredBuffer(mpPrimarySurfaces->getStructSize(), uint32_t(pixelCount));
            mpGRISPreviousReservoir = mpDevice->createStructuredBuffer(temporalOutputVar, uint32_t(pixelCount));
            mpGRISTemporalOutput = mpDevice->createStructuredBuffer(temporalOutputVar, uint32_t(pixelCount));
        }
        if (mpGRISSpatialPass)
            mpGRISSpatialOutput = mpDevice->createStructuredBuffer(spatialOutputVar, uint32_t(pixelCount));
        mpGRISShadedIndirect = mpDevice->createStructuredBuffer(shadedVar, uint32_t(pixelCount));
        mpGRISMainPass->getRootVar()["gGRISShadedIndirect"] = mpGRISShadedIndirect;
        return true;
    }
    catch (const std::exception& error)
    {
        invalidateGRIS();
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
    if (mpGRISSpatialInput) generateVar["gGRISSpatialInput"] = mpGRISSpatialInput;
    else generateVar["gGRISCandidates"] = mpGRISCandidates;
    {
        FALCOR_PROFILE(pRenderContext, "GRISGenerate");
        mpGRISGeneratePass->execute(pRenderContext, uint3(mFrameDim, 1u));
    }
    const auto shadeVar = mpGRISShadePass->getRootVar();
    ref<Buffer> reuseResult = mpGRISSpatialInput;
    if (reuseResult) pRenderContext->uavBarrier(reuseResult.get());
    if (mpGRISTemporalPass)
    {
        const auto camera = mpScene->getCamera();
        // Temporal re-evaluates supported histories with the current PG model.
        if (mGRISHistoryValid && (mGRISHistoryGeneration != mGRISGeneration ||
            mGRISHistoryFrameStamp + 1u != mPrimaryFrameStamp || any(mGRISHistoryFrameDim != mFrameDim)))
            invalidateGRISHistory();
        if (mGRISHistoryValid && is_set(camera->getChanges(), Camera::Changes::Movement))
        {
            // Use the camera's existing previous-frame pose to detect a large jump.
            const auto previousPose = inverse(camera->getPrevViewMatrix());
            const float3 direction = camera->getTarget() - camera->getPosition();
            const float distance = length(direction);
            const float3 forward = distance > 1e-5f ? direction / distance : -previousPose.getCol(2).xyz();
            if (dot(forward, -previousPose.getCol(2).xyz()) < 0.5f ||
                length(camera->getPosition() - previousPose.getCol(3).xyz()) > std::max(1.f, 0.5f * distance))
                invalidateGRISHistory();
        }

        const auto temporalVar = mpGRISTemporalPass->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, temporalVar["gScene"]);
        mpSampleGenerator->bindShaderData(temporalVar);
        bindMainParams(temporalVar);
        bindPrimarySettings(temporalVar);
        temporalVar["gPrimarySurfaces"] = mpPrimarySurfaces;
        if (mEnableSHARC && temporalVar.hasMember("gSharc")) bindSHARC(temporalVar);
        if (mEnablePG)
            mpPG->bind(temporalVar, camera->getPosition(), mSHARCSceneScale, mPGFrameIndex, false, false, true);
        if (mReGIREnabled) bindReGIRTransport(temporalVar);
        temporalVar["gGRISSpatialInput"] = reuseResult;
        temporalVar["gGRISPreviousPrimarySurface"] = mpGRISPreviousPrimarySurface;
        temporalVar["gGRISPreviousReservoir"] = mpGRISPreviousReservoir;
        temporalVar["gGRISTemporalOutput"] = mpGRISTemporalOutput;
        const auto history = temporalVar["gGRISTemporalHistory"];
        history["previousViewProj"] = mGRISPreviousViewProj;
        history["previousFrameDim"] = mGRISHistoryFrameDim;
        history["previousFrameStamp"] = mGRISHistoryFrameStamp;
        history["historyGeneration"] = mGRISHistoryGeneration;
        history["historyValid"] = mGRISHistoryValid;
        {
            FALCOR_PROFILE(pRenderContext, "GRISTemporal");
            mpGRISTemporalPass->execute(pRenderContext, uint3(mFrameDim, 1u));
        }
        pRenderContext->uavBarrier(mpGRISTemporalOutput.get());
        reuseResult = mpGRISTemporalOutput;
    }
    if (mpGRISSpatialPass)
    {
        const auto spatialVar = mpGRISSpatialPass->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, spatialVar["gScene"]);
        mpSampleGenerator->bindShaderData(spatialVar);
        bindMainParams(spatialVar);
        bindPrimarySettings(spatialVar);
        spatialVar["gPrimarySurfaces"] = mpPrimarySurfaces;
        if (mEnableSHARC && spatialVar.hasMember("gSharc")) bindSHARC(spatialVar);
        if (mEnablePG)
            mpPG->bind(spatialVar, mpScene->getCamera()->getPosition(), mSHARCSceneScale, mPGFrameIndex, false, false, true);
        if (mReGIREnabled) bindReGIRTransport(spatialVar);
        spatialVar["gGRISSpatialInput"] = reuseResult;
        spatialVar["gGRISSpatialOutput"] = mpGRISSpatialOutput;
        {
            FALCOR_PROFILE(pRenderContext, "GRISSpatial");
            mpGRISSpatialPass->execute(pRenderContext, uint3(mFrameDim, 1u));
        }
        pRenderContext->uavBarrier(mpGRISSpatialOutput.get());
        reuseResult = mpGRISSpatialOutput;
    }
    if (reuseResult)
        shadeVar["gGRISSpatialOutput"] = reuseResult;
    else
    {
        pRenderContext->uavBarrier(mpGRISCandidates.get());
        shadeVar["gGRISCandidates"] = mpGRISCandidates;
    }
    bindPrimarySettings(shadeVar);
    shadeVar["gGRISShadedIndirect"] = mpGRISShadedIndirect;
    {
        FALCOR_PROFILE(pRenderContext, "GRISShade");
        mpGRISShadePass->execute(pRenderContext, uint3(mFrameDim, 1u));
    }
    pRenderContext->uavBarrier(mpGRISShadedIndirect.get());
    if (mpGRISTemporalPass)
    {
        pRenderContext->copyResource(mpGRISPreviousPrimarySurface.get(), mpPrimarySurfaces.get());
        std::swap(mpGRISPreviousReservoir, mpGRISTemporalOutput);
        mGRISPreviousViewProj = mpScene->getCamera()->getViewProjMatrix();
        mGRISHistoryFrameDim = mFrameDim;
        mGRISHistoryFrameStamp = mPrimaryFrameStamp;
        mGRISHistoryGeneration = mGRISGeneration;
        mGRISHistoryValid = true;
    }
}

void RTPT::bindPrimarySettings(const ShaderVar& rootVar) const
{
    auto settings = rootVar["gPrimarySettings"];
    settings["frameDim"] = mFrameDim;
    settings["sampleIndex"] = mSampleOffset + mSeed * 0x9e3779b9u;
    settings["frameStamp"] = mPrimaryFrameStamp;
    settings["prepared"] = mStagesActive ? 1u : 0u;
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
    const uint64_t primaryBytes = mpPrimarySurfaces ? mpPrimarySurfaces->getSize() : 0;
    const uint64_t signalBytes = mpSignalRecords ? mpSignalRecords->getSize() : 0;
    props["primaryBytes"] = primaryBytes;
    props["signalBytes"] = signalBytes;
    props["bytes"] = primaryBytes + signalBytes;
    props["budgetBytes"] = kStageResourceBudgetBytes;
    props["primaryStride"] = mpPrimarySurfaces ? mpPrimarySurfaces->getStructSize() : 0u;
    props["signalStride"] = mpSignalRecords ? mpSignalRecords->getStructSize() : 0u;
    props["frameStamp"] = mPrimaryFrameStamp;
    props["fallbackReason"] = mStageFallbackReason;
    return props;
}
