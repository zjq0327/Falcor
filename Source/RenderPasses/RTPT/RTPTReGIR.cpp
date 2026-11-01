#include "RTPT.h"
#include "Utils/Timing/Profiler.h"
#include <limits>

void RTPT::invalidateReGIR()
{
    mpReGIRContext.reset();
    mpReGIRBuild = mpReGIRInitial = nullptr;
    mpReGIRRIS = nullptr;
    mReGIRRuntime = {};
    mReGIRInitialActive = mReGIRInitialPreparationFailed = false;
    mReGIRInitialFallbackReason.clear();
    mReGIRPrepared = mReGIRActive = mReGIRPreparationFailed = false;
    mReGIRSlotCount = mReGIRBuildFrameStamp = 0u;
    mReGIRFallbackReason.clear();
}

bool RTPT::prepareReGIR(RenderContext* pRenderContext)
{
    mReGIRActive = false;
    if (!mReGIREnabled) return false;
    if (mReGIRPreparationFailed) return false;
    if (!mDIPrepared) { mReGIRFallbackReason = "Local light catalogue unavailable"; return false; }
    try
    {
        if (!mpReGIRContext)
        {
            const uint64_t slots = uint64_t(mReGIRGridSize) * mReGIRGridSize * mReGIRGridSize * mReGIRLightsPerCell;
            const uint64_t elements = slots + 2u; // SDK one global and one environment tile, both unused.
            FALCOR_CHECK(elements * sizeof(uint2) <= (uint64_t(mReGIRBudgetMB) << 20),
                "ReGIR grid needs {} bytes, exceeding {} MiB budget.", elements * sizeof(uint2), mReGIRBudgetMB);
            FALCOR_CHECK(slots <= uint64_t(65535u) * 256u && elements <= std::numeric_limits<uint32_t>::max(),
                "ReGIR grid exceeds compute dispatch or buffer address range.");
            rtxdi::ContextParameters context;
            context.RenderWidth = mFrameDim.x;
            context.RenderHeight = mFrameDim.y;
            context.TileSize = context.TileCount = 1u;
            context.EnvironmentTileSize = context.EnvironmentTileCount = context.NeighborOffsetCount = 1u;
            context.ReGIR.Mode = rtxdi::ReGIRMode::Grid;
            context.ReGIR.GridSize = {mReGIRGridSize, mReGIRGridSize, mReGIRGridSize};
            context.ReGIR.LightsPerCell = mReGIRLightsPerCell;
            mpReGIRContext = std::make_unique<rtxdi::Context>(context);
            mReGIRSlotCount = mpReGIRContext->GetReGIRLightSlotCount();
            FALCOR_CHECK(mReGIRSlotCount == slots && mpReGIRContext->GetRisBufferElementCount() == elements,
                "ReGIR SDK capacity differs from the checked allocation.");
            ProgramDesc desc;
            desc.addShaderModules(mpScene->getShaderModules());
            desc.addTypeConformances(mpScene->getTypeConformances());
            desc.addShaderLibrary("RenderPasses/RTPT/ReGIR/RTPTReGIRBuild.cs.slang").csEntry("main");
            auto defines = mpStageComputePass->getProgram()->getDefines();
            defines.add("RTPT_REGIR_ENABLED", "1");
            if (mEnablePG || mEnableSHARC)
            {
                desc.setShaderModel(ShaderModel::SM6_6);
                desc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
            }
            mpReGIRBuild = ComputePass::create(mpDevice, desc, defines, true);
            mpReGIRRIS = mpDevice->createStructuredBuffer(sizeof(uint2), uint32_t(elements));
        }
        rtxdi::FrameParameters frame;
        frame.frameIndex = mPrimaryFrameStamp + 1u;
        frame.numLocalLights = mDILightCount;
        frame.regirCellSize = mReGIRCellSize;
        frame.regirSamplingJitter = mReGIRSamplingJitter;
        const float3 center = mpScene->getCamera()->getPosition();
        frame.regirCenter = {center.x, center.y, center.z};
        mpReGIRContext->FillRuntimeParameters(mReGIRRuntime, frame);
        FALCOR_CHECK(mReGIRRuntime.enableLocalLightImportanceSampling == 0u,
            "ReGIR numerical guard requires uniform catalogue build candidates.");
        mReGIRPrepared = true;
        if (mDILightCount == 0u)
        {
            mReGIRFallbackReason = "No supported local lights";
            return false; // Never call the SDK's lightCount-1 loop for an empty catalogue.
        }
        auto var = mpReGIRBuild->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        mpSampleGenerator->bindShaderData(var);
        bindDISettings(var);
        var["gDISettings"]["frameStamp"] = mPrimaryFrameStamp + 1u;
        var["gDILightCatalog"] = mpDILightCatalog;
        bindReGIRInitial(var);
        auto settings = var["gReGIRBuildSettings"];
        settings["slotCount"] = mReGIRSlotCount;
        settings["buildSamples"] = mReGIRBuildSamples;
        {
            FALCOR_PROFILE(pRenderContext, "ReGIRBuild");
            mpReGIRBuild->execute(pRenderContext, uint3(mReGIRSlotCount, 1u, 1u));
        }
        // All consumers (including independent sparse training) see one immutable
        // current-frame model. No pixel reservoir or shaded RGB enters this model.
        pRenderContext->uavBarrier(mpReGIRRIS.get());
        mReGIRBuildFrameStamp = mPrimaryFrameStamp + 1u;
        ++mReGIRBuildCount;
        mReGIRActive = true;
        mReGIRFallbackReason.clear();
        return true;
    }
    catch (const std::exception& error)
    {
        const std::string reason = error.what();
        invalidateReGIR();
        mReGIRPreparationFailed = true;
        mReGIRFallbackReason = reason;
        logWarning("ReGIR preparation failed; retaining global light proposals: {}", reason);
        return false;
    }
}

void RTPT::bindReGIRInitial(const ShaderVar& var) const
{
    if (var.hasMember("gReGIRRuntime")) var["gReGIRRuntime"].setBlob(&mReGIRRuntime, sizeof(mReGIRRuntime));
    if (var.hasMember("gReGIRRIS")) var["gReGIRRIS"] = mpReGIRRIS;
}

void RTPT::bindReGIRTransport(const ShaderVar& var) const
{
    if (!var.hasMember("gReGIRTransportSettings")) return;
    auto settings = var["gReGIRTransportSettings"];
    settings["center"] = float3(mReGIRRuntime.regirCommon.centerX, mReGIRRuntime.regirCommon.centerY, mReGIRRuntime.regirCommon.centerZ);
    settings["cellSize"] = mReGIRRuntime.regirCommon.cellSize;
    settings["cellCount"] = uint3(mReGIRRuntime.regirGrid.cellsX, mReGIRRuntime.regirGrid.cellsY, mReGIRRuntime.regirGrid.cellsZ);
    settings["lightsPerCell"] = mReGIRLightsPerCell;
    settings["samplingJitter"] = mReGIRRuntime.regirCommon.samplingJitter;
    settings["risBufferOffset"] = mReGIRRuntime.regirCommon.risBufferOffset;
    settings["slotCount"] = mReGIRSlotCount;
    settings["active"] = mReGIRActive ? 1u : 0u;
    settings["lightCount"] = mDILightCount;
    settings["generation"] = mDICatalogGeneration;
    settings["coverageMask"] = mDICoverageMask;
    settings["uncoveredAnalyticCount"] = mDIUncoveredAnalyticCount;
    settings["secondaryEnabled"] = mReGIRSecondaryEnabled ? 1u : 0u;
    settings["trainingEnabled"] = mReGIRTrainingEnabled ? 1u : 0u;
    if (var.hasMember("gReGIRTransportRIS")) var["gReGIRTransportRIS"] = mpReGIRRIS;
    if (var.hasMember("gReGIRTransportCatalog")) var["gReGIRTransportCatalog"] = mpDILightCatalog;
    if (var.hasMember("gReGIRTransportUncoveredAnalyticIndices")) var["gReGIRTransportUncoveredAnalyticIndices"] = mpDIUncoveredAnalyticIndices;
}

Properties RTPT::getReGIRStatistics() const
{
    Properties props;
    props["requested"] = mReGIREnabled;
    props["prepared"] = mReGIRPrepared;
    props["active"] = mReGIRActive;
    props["initialActive"] = mReGIRInitialActive;
    props["initialFallbackReason"] = mReGIRInitialFallbackReason;
    props["slotCount"] = mReGIRSlotCount;
    props["risBufferOffset"] = mReGIRRuntime.regirCommon.risBufferOffset;
    props["risElementCount"] = mpReGIRRIS ? mpReGIRRIS->getElementCount() : 0u;
    props["bytes"] = mpReGIRRIS ? mpReGIRRIS->getSize() : 0u;
    props["budgetBytes"] = uint64_t(mReGIRBudgetMB) << 20;
    props["buildFrameStamp"] = mReGIRBuildFrameStamp;
    props["buildCount"] = mReGIRBuildCount;
    props["buildSamples"] = mReGIRBuildSamples;
    props["lightsPerCell"] = mReGIRLightsPerCell;
    props["gridSize"] = mReGIRGridSize;
    props["cellSize"] = mReGIRCellSize;
    props["gridCenter"] = float3(mReGIRRuntime.regirCommon.centerX, mReGIRRuntime.regirCommon.centerY, mReGIRRuntime.regirCommon.centerZ);
    props["secondaryActive"] = mReGIRActive && mReGIRSecondaryEnabled;
    props["trainingActive"] = mReGIRActive && mReGIRTrainingEnabled &&
        ((mEnablePG && mPGSettings.enabled && mPGSettings.trainingEnabled) || (mEnableSHARC && mSHARCEnabled && !mSHARCFreeze));
    props["fallbackReason"] = mReGIRFallbackReason;
    return props;
}
