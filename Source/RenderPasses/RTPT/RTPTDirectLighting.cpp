#include "RTPT.h"
#include "Utils/Timing/Profiler.h"
#include <limits>

namespace
{
uint64_t reflectedStride(const ShaderVar& var)
{
    FALCOR_CHECK(var.isValid() && var.getType(), "Missing ReSTIR DI buffer reflection.");
    const auto* type = var.getType()->unwrapArray()->asResourceType();
    FALCOR_CHECK(type && type->getStructType(), "Invalid ReSTIR DI structured-buffer reflection.");
    return type->getStructType()->getSlangTypeLayout()->getStride();
}
}

void RTPT::invalidateDirectLighting()
{
    invalidateDIReuse();
    // ReGIR Initial is the DI variant that uses cell candidates.
    mpReGIRInitial = nullptr;
    mReGIRInitialActive = mReGIRInitialPreparationFailed = false;
    mReGIRInitialFallbackReason.clear();
    mpDIComputePass = mpDIInitialPass = mpDIShadePass = nullptr;
    mpDIReservoirs = mpDISampleRecords = mpDIResults = nullptr;
    mDIPreparedCatalogGeneration = 0u;
    mDIPrepared = mDIActive = mDIPreparationFailed = false;
    mDIFallbackReason.clear();
}

bool RTPT::prepareDirectLighting(bool catalogReady)
{
    mDIActive = mDIPrepared = false;
    mDITemporalActive = mDISpatialActive = mDIHistoryReadValid = false;
    mDIFinalInputBank = 0u;
    if (!mRestirDIEnabled)
    {
        resetDIHistory("DI disabled");
        mDIFallbackReason.clear();
        return false;
    }
    if (!mStagesActive)
    {
        resetDIHistory("Primary Surface unavailable");
        mDIFallbackReason = "Primary Surface / Final Signal Resolve unavailable";
        return false;
    }
    if (!mEnableNRD || mSamplesPerPixel != 1u)
    {
        resetDIHistory("DI input mode changed");
        mDIFallbackReason = "Initial DI requires NRD input mode and one sample per pixel";
        return false;
    }
    if (!mUseNEE)
    {
        resetDIHistory("Next-event estimation disabled");
        mDIFallbackReason = "Next-event estimation is disabled";
        return false;
    }
    if (!catalogReady)
    {
        const auto& reason = mLightCatalog.getFailure();
        if (mpDIComputePass || mDIFallbackReason != reason)
        {
            invalidateDirectLighting();
            mDIFallbackReason = reason;
            logWarning("ReSTIR DI catalogue preparation failed; using original root lighting: {}", reason);
        }
        return false;
    }

    const auto& catalog = mLightCatalog.getSnapshot();
    if (mDIPreparedCatalogGeneration != catalog.generation)
    {
        invalidateDirectLighting();
        mDIPreparedCatalogGeneration = catalog.generation;
    }
    if (mDIPreparationFailed) return false;
    if (mpDIComputePass && mpDIResults)
    {
        mDIPrepared = mDIActive = true;
        mDIFallbackReason.clear();
        return true;
    }

    try
    {
        const uint64_t pixelCount = uint64_t(mFrameDim.x) * mFrameDim.y;
        FALCOR_CHECK(pixelCount > 0u && pixelCount <= std::numeric_limits<uint32_t>::max(), "Invalid DI image dimensions.");

        auto defines = mpStageComputePass->getProgram()->getDefines();
        defines.add("RTPT_USE_RESTIR_DI", "1");
        mpDIComputePass = ComputePass::create(mpDevice, mpStageComputePass->getProgram()->getDesc(), defines, true);
        auto makeScenePass = [&](const char* path)
        {
            return ComputePass::create(mpDevice, makeSceneProgramDesc(path), defines, true);
        };
        mpDIInitialPass = makeScenePass("RenderPasses/RTPT/ReSTIRDI/RTPTDIInitial.cs.slang");
        mpDIShadePass = makeScenePass("RenderPasses/RTPT/ReSTIRDI/RTPTDIShade.cs.slang");
        const auto initialVar = mpDIInitialPass->getRootVar();
        const auto shadeVar = mpDIShadePass->getRootVar();
        FALCOR_CHECK(reflectedStride(initialVar["gDILightCatalog"]) == RTPTLightCatalog::kLightStride,
            "ReSTIR DI host catalogue layout mismatch.");
        const uint64_t pixelStride = reflectedStride(initialVar["gDIReservoirs"]) +
            reflectedStride(initialVar["gDISampleRecords"]) + reflectedStride(shadeVar["gDIResults"]);
        const uint64_t bytes = pixelCount * pixelStride + catalog.getBytes();
        const uint64_t budget = uint64_t(mRestirDIBudgetMB) << 20;
        FALCOR_CHECK(bytes <= budget, "ReSTIR DI needs {} bytes, exceeding its {} MiB budget.", bytes, mRestirDIBudgetMB);

        mpDIReservoirs = mpDevice->createStructuredBuffer(initialVar["gDIReservoirs"], uint32_t(pixelCount));
        mpDISampleRecords = mpDevice->createStructuredBuffer(initialVar["gDISampleRecords"], uint32_t(pixelCount));
        mpDIResults = mpDevice->createStructuredBuffer(shadeVar["gDIResults"], uint32_t(pixelCount));
        bindDIMainResources(mpDIComputePass->getRootVar());
        mDIPrepared = mDIActive = true;
        mDIFallbackReason.clear();
        return true;
    }
    catch (const std::exception& error)
    {
        const std::string reason = error.what();
        invalidateDirectLighting();
        mDIPreparedCatalogGeneration = catalog.generation;
        mDIPreparationFailed = true;
        mDIFallbackReason = reason;
        if (!mReGIREnabled) logWarning("ReSTIR DI preparation failed; using original root lighting: {}", reason);
        return false;
    }
}

void RTPT::bindLightCatalogSettings(const ShaderVar& settings) const
{
    const auto& catalog = mLightCatalog.getSnapshot();
    settings["lightCount"] = catalog.lightCount;
    settings["generation"] = catalog.generation;
    settings["coverageMask"] = catalog.coverageMask;
    settings["uncoveredAnalyticCount"] = catalog.uncoveredAnalyticCount;
}

void RTPT::bindDISettings(const ShaderVar& rootVar) const
{
    auto settings = rootVar["gDISettings"];
    settings["frameDim"] = mFrameDim;
    settings["sampleIndex"] = mSampleOffset + mSeed * 0x9e3779b9u;
    settings["frameStamp"] = mPrimaryFrameStamp;
    bindLightCatalogSettings(settings);
    settings["candidateCount"] = mRestirDICandidateCount;
    settings["prepared"] = mDIPrepared ? 1u : 0u;
}

void RTPT::bindDIMainResources(const ShaderVar& rootVar) const
{
    bindDISettings(rootVar);
    if (rootVar.hasMember("gDIResults")) rootVar["gDIResults"] = mpDIResults;
    if (rootVar.hasMember("gDIUncoveredAnalyticIndices")) rootVar["gDIUncoveredAnalyticIndices"] = mLightCatalog.getSnapshot().uncoveredAnalyticIndices;
}

void RTPT::executeDirectLighting(RenderContext* pRenderContext)
{
    mReGIRInitialActive = false;
    FALCOR_CHECK(!mReGIREnabled || !mReGIRInitialPreparationFailed,
        "ReGIR cell-only Initial is unavailable; global Initial sampling is disabled: {}", mReGIRInitialFallbackReason);
    const bool reuse = prepareDIReuse();
    auto bind = [&](const ShaderVar& var)
    {
        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        mpSampleGenerator->bindShaderData(var);
        bindDISettings(var);
        var["gDIPrimarySurfaces"] = mpPrimarySurfaces;
        var["gDILightCatalog"] = mLightCatalog.getSnapshot().lights;
        var["gDIReservoirs"] = mpDIReservoirs;
        var["gDISampleRecords"] = mpDISampleRecords;
        if (mReGIREnabled) bindReGIRInitial(var);
        if (reuse)
        {
            bindDIReuseSettings(var, 0u, 0u);
            if (var.hasMember("gDIPreviousPrimarySurfaces")) var["gDIPreviousPrimarySurfaces"] = mpDIPreviousPrimarySurfaces;
            if (var.hasMember("gDINeighborOffsets")) var["gDINeighborOffsets"] = mpDINeighborOffsets;
        }
    };
    auto initialPass = reuse ? mpDIReuseInitialPass : mpDIInitialPass;
    if (mReGIRActive && !mReGIRInitialPreparationFailed)
    {
        try
        {
            if (!mpReGIRInitial || mReGIRInitialReuse != reuse)
            {
                auto defines = initialPass->getProgram()->getDefines();
                defines.add("RTPT_REGIR_ENABLED", "1");
                auto desc = initialPass->getProgram()->getDesc();
                desc.setShaderModel(ShaderModel::SM6_6);
                desc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
                mpReGIRInitial = ComputePass::create(mpDevice, desc, defines, true);
                mReGIRInitialReuse = reuse;
            }
            auto candidateVar = mpReGIRInitial->getRootVar();
            bind(candidateVar);
            bindReGIRInitial(candidateVar);
            initialPass = mpReGIRInitial;
            mReGIRInitialActive = true;
            mReGIRInitialFallbackReason.clear();
        }
        catch (const std::exception& error)
        {
            mpReGIRInitial = nullptr;
            mReGIRInitialPreparationFailed = true;
            mReGIRInitialFallbackReason = error.what();
            FALCOR_THROW("ReGIR cell-only Initial preparation failed; global Initial sampling is disabled: {}", error.what());
        }
    }
    auto initialVar = initialPass->getRootVar();
    if (!mReGIRInitialActive) bind(initialVar);
    {
        FALCOR_PROFILE(pRenderContext, "DIInitial");
        initialPass->execute(pRenderContext, uint3(mFrameDim, 1u));
    }
    pRenderContext->uavBarrier(mpDIReservoirs.get());
    pRenderContext->uavBarrier(mpDISampleRecords.get());
    if (mDITemporalActive)
    {
        auto temporal = mpDITemporalPass->getRootVar();
        bind(temporal);
        bindDIReuseSettings(temporal, 0u, 1u);
        FALCOR_PROFILE(pRenderContext, "DITemporal");
        mpDITemporalPass->execute(pRenderContext, uint3(mFrameDim, 1u));
        pRenderContext->uavBarrier(mpDIReservoirs.get());
        pRenderContext->uavBarrier(mpDISampleRecords.get());
    }
    if (mDISpatialActive)
    {
        auto spatial = mpDISpatialPass->getRootVar();
        bind(spatial);
        bindDIReuseSettings(spatial, mDITemporalActive ? 1u : 0u, 2u);
        FALCOR_PROFILE(pRenderContext, "DISpatial");
        mpDISpatialPass->execute(pRenderContext, uint3(mFrameDim, 1u));
        pRenderContext->uavBarrier(mpDIReservoirs.get());
        pRenderContext->uavBarrier(mpDISampleRecords.get());
    }
    const auto shadePass = reuse ? mpDIReuseShadePass : mpDIShadePass;
    auto shadeVar = shadePass->getRootVar();
    bind(shadeVar);
    shadeVar["gDIResults"] = mpDIResults;
    {
        FALCOR_PROFILE(pRenderContext, "DIFinalShading");
        shadePass->execute(pRenderContext, uint3(mFrameDim, 1u));
    }
    pRenderContext->uavBarrier(mpDIResults.get());
    if (reuse)
    {
        pRenderContext->uavBarrier(mpDIReservoirs.get());
        pRenderContext->uavBarrier(mpDISampleRecords.get());
        publishDIHistory(pRenderContext);
    }
}

Properties RTPT::getDIStatistics() const
{
    const auto& catalog = mLightCatalog.getSnapshot();
    Properties props;
    props["requested"] = mRestirDIEnabled;
    props["prepared"] = mDIPrepared && mRestirDIEnabled;
    props["active"] = mDIActive;
    props["coverageMask"] = mDIActive ? catalog.coverageMask : 0u;
    props["lightCount"] = catalog.lightCount;
    props["emissiveCount"] = catalog.emissiveCount;
    props["pointCount"] = catalog.pointCount;
    props["uncoveredAnalyticCount"] = catalog.uncoveredAnalyticCount;
    props["generation"] = catalog.generation;
    props["frameStamp"] = mDIActive ? mPrimaryFrameStamp : 0u;
    props["candidateCount"] = mRestirDICandidateCount;
    props["temporalRequested"] = mRestirDITemporalEnabled;
    props["spatialRequested"] = mRestirDISpatialEnabled;
    props["temporalActive"] = mDITemporalActive;
    props["spatialActive"] = mDISpatialActive;
    props["historyValid"] = mDIHistoryReadValid;
    props["historyAvailable"] = mDIHistoryAvailable;
    props["historyFrames"] = mDIHistoryFrames;
    props["historyFrameStamp"] = mDIHistoryFrameStamp;
    props["historyResetReason"] = mDIHistoryResetReason;
    props["reuseFallbackReason"] = mDIReuseFallbackReason;
    props["bankCount"] = mpDIReservoirs ? (mDIReusePrepared ? 4u : 1u) : 0u;
    props["finalInputBank"] = mDIFinalInputBank;
    props["historyInputBank"] = mDITemporalActive ? 1u : mDIFinalInputBank;
    props["bankBytes"] = (mpDIReservoirs ? mpDIReservoirs->getSize() : 0u) +
        (mpDISampleRecords ? mpDISampleRecords->getSize() : 0u);
    props["budgetBytes"] = uint64_t(mRestirDIBudgetMB) << 20;
    uint64_t bytes = catalog.getBytes();
    for (const auto& buffer : {mpDIReservoirs, mpDISampleRecords, mpDIResults,
        mpDIPreviousPrimarySurfaces, mpDINeighborOffsets})
        if (buffer) bytes += buffer->getSize();
    props["bytes"] = bytes;
    props["reservoirStride"] = mpDIReservoirs ? mpDIReservoirs->getStructSize() : 0u;
    props["sampleStride"] = mpDISampleRecords ? mpDISampleRecords->getStructSize() : 0u;
    props["resultStride"] = mpDIResults ? mpDIResults->getStructSize() : 0u;
    props["fallbackReason"] = mDIFallbackReason;
    return props;
}
