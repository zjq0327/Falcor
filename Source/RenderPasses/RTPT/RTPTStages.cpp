#include "RTPT.h"
#include "Utils/Timing/Profiler.h"
#include <limits>

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

void RTPT::invalidateStages()
{
    invalidateDirectLighting();
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

        ProgramDesc primaryDesc;
        primaryDesc.addShaderModules(mpScene->getShaderModules());
        primaryDesc.addShaderLibrary("RenderPasses/RTPT/PrimarySurface/RTPTPrimarySurface.cs.slang").csEntry("main");
        primaryDesc.addTypeConformances(mpScene->getTypeConformances());
        if (mEnableSHARC || mEnablePG)
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
