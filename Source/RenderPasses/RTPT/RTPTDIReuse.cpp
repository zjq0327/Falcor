#include "RTPT.h"
#include "Utils/Timing/Profiler.h"
#include <algorithm>
#include <cmath>
#include <limits>

void RTPT::resetDIHistory(const std::string& reason)
{
    mDIHistoryAvailable = mDIHistoryReadValid = false;
    mDIHistoryFrames = 0u;
    mDIHistoryResetReason = reason;
}

void RTPT::invalidateDIReuse()
{
    mpDIReuseInitialPass = mpDITemporalPass = mpDISpatialPass = mpDIReuseShadePass = nullptr;
    mpDIPreviousPrimarySurfaces = mpDINeighborOffsets = nullptr;
    mDIReusePrepared = mDIReusePreparationFailed = false;
    mDITemporalActive = mDISpatialActive = false;
    mDIFinalInputBank = 0u;
    mDIReuseFallbackReason.clear();
    resetDIHistory("DI resources invalidated");
}

bool RTPT::prepareDIReuse()
{
    mDITemporalActive = mDISpatialActive = mDIHistoryReadValid = false;
    mDIFinalInputBank = 0u;
    if (!mRestirDITemporalEnabled && !mRestirDISpatialEnabled)
    {
        resetDIHistory("Temporal and spatial reuse disabled");
        return false;
    }
    if (mDIReusePreparationFailed) return false;
    if (!mDIReusePrepared)
    {
        try
        {
            const uint64_t pixels = uint64_t(mFrameDim.x) * mFrameDim.y;
            FALCOR_CHECK(pixels > 0u && pixels <= std::numeric_limits<uint32_t>::max() / 4u,
                "ReSTIR DI reuse exceeds its four-bank index range.");
            // Four independent bank regions (Initial, Temporal, Spatial, history)
            // plus the immutable previous primary records. The old N-element
            // base bank is replaced only after every preparation step succeeds.
            const uint64_t pairStride = mpDIReservoirs->getStructSize() + mpDISampleRecords->getStructSize();
            const uint64_t bytes = 4u * pixels * pairStride + mpDIResults->getSize() +
                pixels * mpPrimarySurfaces->getStructSize() + 256u * sizeof(float2) +
                mpDILightCatalog->getSize() + mpDIUncoveredAnalyticIndices->getSize();
            FALCOR_CHECK(bytes <= (uint64_t(mRestirDIBudgetMB) << 20),
                "ReSTIR DI reuse needs {} bytes, exceeding its {} MiB budget. Initial remains available.", bytes, mRestirDIBudgetMB);
            auto defines = mpDIInitialPass->getProgram()->getDefines();
            defines.add("RTPT_DI_REUSE_ENABLED", "1");
            auto makePass = [&](const char* path)
            {
                ProgramDesc desc;
                desc.addShaderModules(mpScene->getShaderModules());
                desc.addTypeConformances(mpScene->getTypeConformances());
                desc.addShaderLibrary(path).csEntry("main");
                if (mEnablePG || mEnableSHARC)
                {
                    desc.setShaderModel(ShaderModel::SM6_6);
                    desc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
                }
                return ComputePass::create(mpDevice, desc, defines, true);
            };
            auto initial = makePass("RenderPasses/RTPT/ReSTIRDI/RTPTDIInitial.cs.slang");
            auto temporal = mRestirDITemporalEnabled ? makePass("RenderPasses/RTPT/ReSTIRDI/RTPTDITemporal.cs.slang") : nullptr;
            auto spatial = mRestirDISpatialEnabled ? makePass("RenderPasses/RTPT/ReSTIRDI/RTPTDISpatial.cs.slang") : nullptr;
            auto shade = makePass("RenderPasses/RTPT/ReSTIRDI/RTPTDIShade.cs.slang");
            auto initialVar = initial->getRootVar();
            shade->getRootVar();
            if (temporal) temporal->getRootVar();
            if (spatial) spatial->getRootVar();
            auto reservoirs = mpDevice->createStructuredBuffer(initialVar["gDIReservoirs"], uint32_t(pixels * 4u));
            auto samples = mpDevice->createStructuredBuffer(initialVar["gDISampleRecords"], uint32_t(pixels * 4u));
            FALCOR_CHECK(reservoirs->getStructSize() == mpDIReservoirs->getStructSize() &&
                samples->getStructSize() == mpDISampleRecords->getStructSize(), "ReSTIR DI reuse bank layout changed.");
            auto previous = mpDevice->createStructuredBuffer(mpPrimarySurfaces->getStructSize(), uint32_t(pixels));
            std::vector<float2> offsets(256u);
            // Fixed disk table, independently rotated through by SDK random
            // starts. Skip radius zero and let SDK geometry/material gates act.
            constexpr float goldenAngle = 2.39996322972865332f;
            for (uint32_t index = 0u; index < offsets.size(); ++index)
            {
                const float radius = std::sqrt((float(index) + 0.5f) / float(offsets.size()));
                const float angle = float(index) * goldenAngle;
                offsets[index] = radius * float2(std::cos(angle), std::sin(angle));
            }
            auto neighbors = mpDevice->createTypedBuffer(ResourceFormat::RG32Float, uint32_t(offsets.size()),
                ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, offsets.data());
            mpDIReuseInitialPass = initial;
            mpDITemporalPass = temporal;
            mpDISpatialPass = spatial;
            mpDIReuseShadePass = shade;
            mpDIReservoirs = reservoirs;
            mpDISampleRecords = samples;
            mpDIPreviousPrimarySurfaces = previous;
            mpDINeighborOffsets = neighbors;
            mDIReusePrepared = true;
            mDIReuseFallbackReason.clear();
            resetDIHistory("DI reuse resources created");
        }
        catch (const std::exception& error)
        {
            const std::string reason = error.what();
            invalidateDIReuse();
            mDIReusePreparationFailed = true;
            mDIReuseFallbackReason = reason;
            resetDIHistory("DI reuse preparation failed");
            logWarning("ReSTIR DI reuse preparation failed; retaining Initial RIS: {}", reason);
            return false;
        }
    }
    if (mDIHistoryAvailable)
    {
        if (mDIHistoryGeneration != mDICatalogGeneration || mDIHistoryFrameStamp + 1u != mPrimaryFrameStamp)
            resetDIHistory("DI history generation or frame continuity changed");
        else
        {
            const auto camera = mpScene->getCamera();
            const float3 direction = camera->getTarget() - camera->getPosition();
            const float distance = length(direction);
            const float3 forward = distance > 1e-5f ? direction / distance : mDIPreviousCameraForward;
            if (dot(forward, mDIPreviousCameraForward) < 0.5f ||
                length(camera->getPosition() - mDIPreviousCameraPosition) > std::max(1.f, 0.5f * distance))
                resetDIHistory("Camera cut");
        }
    }
    mDITemporalActive = mRestirDITemporalEnabled;
    mDISpatialActive = mRestirDISpatialEnabled;
    mDIHistoryReadValid = mDITemporalActive && mDIHistoryAvailable;
    if (mDIHistoryReadValid) mDIHistoryResetReason.clear();
    mDIFinalInputBank = mDISpatialActive ? 2u : (mDITemporalActive ? 1u : 0u);
    return true;
}

void RTPT::bindDIReuseSettings(const ShaderVar& rootVar, uint32_t inputBank, uint32_t outputBank) const
{
    if (!rootVar.hasMember("gDIReuseSettings")) return;
    auto settings = rootVar["gDIReuseSettings"];
    settings["enabled"] = mDIReusePrepared ? 1u : 0u;
    settings["historyValid"] = mDIHistoryReadValid ? 1u : 0u;
    settings["inputBank"] = inputBank;
    settings["outputBank"] = outputBank;
    settings["historyBank"] = 3u;
    settings["historyFrameStamp"] = mDIHistoryFrameStamp;
    settings["historySampleIndex"] = mDIHistorySampleIndex;
    settings["historyGeneration"] = mDIHistoryGeneration;
    settings["maxHistoryLength"] = mRestirDIHistoryLength;
    settings["spatialSamples"] = mRestirDISpatialSamples;
    settings["spatialRadius"] = mRestirDISpatialRadius;
    settings["depthThreshold"] = 0.1f;
    settings["normalThreshold"] = 0.9f;
    settings["bankCount"] = 4u;
    settings["finalInputBank"] = mDIFinalInputBank;
    // Spatial still shades this frame, while Temporal keeps its own history.
    settings["historyInputBank"] = mDITemporalActive ? 1u : mDIFinalInputBank;
    settings["previousViewProj"] = mDIPreviousViewProj;
}

void RTPT::publishDIHistory(RenderContext* pRenderContext)
{
    if (!mDITemporalActive)
    {
        mDIHistoryAvailable = false;
        return;
    }
    // Shade has published the filtered Temporal reservoir to bank 3. Keep the
    // exact camera and primary snapshot that generated that bank together.
    pRenderContext->copyResource(mpDIPreviousPrimarySurfaces.get(), mpPrimarySurfaces.get());
    const auto camera = mpScene->getCamera();
    mDIPreviousViewProj = camera->getViewProjMatrix();
    mDIPreviousCameraPosition = camera->getPosition();
    const float3 direction = camera->getTarget() - camera->getPosition();
    const float distance = length(direction);
    if (distance > 1e-5f) mDIPreviousCameraForward = direction / distance;
    mDIHistoryFrameStamp = mPrimaryFrameStamp;
    mDIHistorySampleIndex = mSampleOffset + mSeed * 0x9e3779b9u;
    mDIHistoryGeneration = mDICatalogGeneration;
    mDIHistoryFrames = std::min(mDIHistoryFrames + 1u, mRestirDIHistoryLength);
    mDIHistoryAvailable = true;
}
