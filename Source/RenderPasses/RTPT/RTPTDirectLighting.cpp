#include "RTPT.h"
#include "Scene/Lights/Light.h"
#include "Scene/Lights/LightCollection.h"
#include "Utils/Timing/Profiler.h"
#include <algorithm>
#include <limits>
#include <tuple>
#include <unordered_set>

namespace
{
constexpr uint32_t kEmissive = 1u;
constexpr uint32_t kPoint = 2u;
struct DILightInfo
{
    uint32_t kind = 0u;
    uint32_t sourceIndex = 0u;
    uint32_t stable0 = 0u;
    uint32_t stable1 = 0u;
    uint32_t generation = 0u;
    float sourcePMF = 0.f;
    uint32_t pad0 = 0u;
    uint32_t pad1 = 0u;
};
static_assert(sizeof(DILightInfo) == 32u);

uint64_t reflectedStride(const ShaderVar& var)
{
    FALCOR_CHECK(var.isValid() && var.getType(), "Missing ReSTIR DI buffer reflection.");
    const auto* type = var.getType()->unwrapArray()->asResourceType();
    FALCOR_CHECK(type && type->getStructType(), "Invalid ReSTIR DI structured-buffer reflection.");
    return type->getStructType()->getSlangTypeLayout()->getStride();
}
}

void RTPT::invalidateDirectLighting(bool preserveReGIR)
{
    invalidateDIReuse();
    if (preserveReGIR)
    {
        // Catalogue ranks/defines may change while stable ReGIR IDs and cell
        // memberships remain reusable. Only recreate the dependent Initial pass.
        mpReGIRInitial = nullptr;
        mReGIRInitialActive = mReGIRInitialPreparationFailed = false;
        mReGIRInitialFallbackReason.clear();
    }
    else invalidateReGIR();
    mpDIComputePass = mpDIInitialPass = mpDIShadePass = nullptr;
    mpDILightCatalog = mpDIUncoveredAnalyticIndices = mpDIReservoirs = mpDISampleRecords = mpDIResults = nullptr;
    mDICatalogSignature.clear();
    mReGIRIdToCatalogData.clear();
    mDIPrepared = mDIActive = mDIPreparationFailed = false;
    mDILightCount = mDIEmissiveCount = mDIPointCount = mDIUncoveredAnalyticCount = mDICoverageMask = 0u;
    mDIFallbackReason.clear();
}

bool RTPT::prepareDirectLighting()
{
    mDIActive = mDIPrepared = false;
    mDITemporalActive = mDISpatialActive = mDIHistoryReadValid = false;
    mDIFinalInputBank = 0u;
    if (!mRestirDIEnabled && !mReGIREnabled)
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

    std::vector<uint64_t> signature;
    uint32_t emissiveCount = 0u, pointCount = 0u, uncoveredCount = 0u, coverage = 0u;
    uint64_t lightCount = 0u;
    try
    {
        const auto& renderSettings = mpScene->getRenderSettings();
        const auto collection = renderSettings.useEmissiveLights ? mpScene->getLightCollection(mpDevice->getRenderContext()) : nullptr;
        // Include zero-flux/culled triangles. Integrated power is not a proof that
        // every texture sample is black, so it never removes proposal support.
        emissiveCount = collection ? collection->getTotalLightCount() : 0u;
        const auto& activeLights = mpScene->getActiveAnalyticLights();
        // Keep the previous active objects alive until this snapshot has its
        // identities. This prevents delete+new between snapshots from reusing a
        // raw address and accidentally inheriting an unrelated light's ID.
        std::unordered_set<const Light*> activeLightPointers;
        activeLightPointers.reserve(activeLights.size());
        for (const auto& light : activeLights) activeLightPointers.insert(light.get());
        for (auto identity = mDILightIdentities.begin(); identity != mDILightIdentities.end();)
        {
            if (activeLightPointers.find(identity->first) == activeLightPointers.end())
                identity = mDILightIdentities.erase(identity);
            else ++identity;
        }
        std::vector<uint32_t> pointIndices, pointIdentities, uncoveredIndices;
        signature = {uint64_t(emissiveCount), uint64_t(renderSettings.useAnalyticLights),
            collection ? uint64_t(collection->getMeshLights().size()) : 0u,
            renderSettings.useAnalyticLights ? uint64_t(activeLights.size()) : 0u};
        if (collection)
            for (const auto& mesh : collection->getMeshLights())
            {
                signature.push_back((uint64_t(mesh.instanceID) << 32) | mesh.triangleOffset);
                signature.push_back((uint64_t(mesh.materialID) << 32) | mesh.triangleCount);
            }
        if (renderSettings.useAnalyticLights)
            for (uint32_t index = 0u; index < activeLights.size(); ++index)
            {
                const auto& light = activeLights[index];
                auto identity = mDILightIdentities.find(light.get());
                if (identity == mDILightIdentities.end())
                {
                    FALCOR_CHECK(mDINextIdentity != 0u, "ReSTIR DI light identity range exhausted.");
                    identity = mDILightIdentities.emplace(light.get(), mDINextIdentity++).first;
                }
                signature.push_back((uint64_t(identity->second) << 32) | uint32_t(light->getType()));
                if (light->getType() == LightType::Point)
                {
                    pointIndices.push_back(index);
                    pointIdentities.push_back(identity->second);
                }
                else uncoveredIndices.push_back(index);
            }
        mDILightIdentityOwners.assign(activeLights.begin(), activeLights.end());
        pointCount = uint32_t(pointIndices.size());
        uncoveredCount = uint32_t(uncoveredIndices.size());
        coverage = (emissiveCount ? kEmissive : 0u) | (pointCount ? kPoint : 0u);
        lightCount = uint64_t(emissiveCount) + pointCount;
        const bool layoutChanged = signature != mDICatalogSignature;
        if (layoutChanged)
        {
            invalidateDirectLighting(true);
            mDICatalogSignature = signature;
        }
        mDIEmissiveCount = emissiveCount;
        mDIPointCount = pointCount;
        mDIUncoveredAnalyticCount = uncoveredCount;
        mDICoverageMask = coverage;
        if (mDIPreparationFailed) return false;
        if (mpDIComputePass && mpDIResults)
        {
            mDIPrepared = true; mDIActive = mRestirDIEnabled;
            mDIFallbackReason.clear();
            return true;
        }

        FALCOR_CHECK(lightCount <= 0x7fffffffu, "ReSTIR DI catalogue exceeds the SDK light-index range.");
        FALCOR_CHECK(lightCount <= (1u << 24),
            "ReSTIR DI uniform proposal exceeds its 24-bit random-number support.");
        mDILightCount = uint32_t(lightCount);
        const uint64_t pixelCount = uint64_t(mFrameDim.x) * mFrameDim.y;
        FALCOR_CHECK(pixelCount > 0u && pixelCount <= std::numeric_limits<uint32_t>::max(), "Invalid DI image dimensions.");

        auto defines = mpStageComputePass->getProgram()->getDefines();
        defines.add("RTPT_USE_RESTIR_DI", "1");
        mpDIComputePass = ComputePass::create(mpDevice, mpStageComputePass->getProgram()->getDesc(), defines, true);
        auto makeScenePass = [&](const char* path)
        {
            ProgramDesc desc;
            desc.addShaderModules(mpScene->getShaderModules());
            desc.addTypeConformances(mpScene->getTypeConformances());
            desc.addShaderLibrary(path).csEntry("main");
            if (mEnablePG || mEnableSHARC || mReGIREnabled)
            {
                desc.setShaderModel(ShaderModel::SM6_6);
                desc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
            }
            return ComputePass::create(mpDevice, desc, defines, true);
        };
        mpDIInitialPass = makeScenePass("RenderPasses/RTPT/ReSTIRDI/RTPTDIInitial.cs.slang");
        mpDIShadePass = makeScenePass("RenderPasses/RTPT/ReSTIRDI/RTPTDIShade.cs.slang");
        auto initialVar = mpDIInitialPass->getRootVar();
        auto shadeVar = mpDIShadePass->getRootVar();
        const uint64_t catalogStride = reflectedStride(initialVar["gDILightCatalog"]);
        FALCOR_CHECK(catalogStride == sizeof(DILightInfo), "ReSTIR DI host catalogue layout mismatch.");
        const uint64_t pixelStride = reflectedStride(initialVar["gDIReservoirs"]) +
            reflectedStride(initialVar["gDISampleRecords"]) + reflectedStride(shadeVar["gDIResults"]);
        const uint64_t bytes = pixelCount * pixelStride + std::max(uint64_t(1), lightCount) * catalogStride +
            uint64_t(std::max(1u, uncoveredCount)) * sizeof(uint32_t);
        const uint64_t budget = uint64_t(mRestirDIBudgetMB) << 20;
        FALCOR_CHECK(bytes <= budget, "ReSTIR DI needs {} bytes, exceeding its {} MiB budget.", bytes, mRestirDIBudgetMB);
        ++mDICatalogGeneration;
        if (mDICatalogGeneration == 0u) ++mDICatalogGeneration;
        std::vector<DILightInfo> catalogue(size_t(std::max(uint64_t(1), lightCount)));
        const float sourcePMF = lightCount > 0u ? 1.f / float(lightCount) : 0.f;
        if (collection)
            for (const auto& mesh : collection->getMeshLights())
                for (uint32_t primitive = 0u; primitive < mesh.triangleCount; ++primitive)
                {
                    const uint32_t index = mesh.triangleOffset + primitive;
                    FALCOR_CHECK(index < emissiveCount, "Invalid emissive catalogue layout.");
                    catalogue[index] = {kEmissive, index, mesh.instanceID, primitive, mDICatalogGeneration, sourcePMF, 0u, 0u};
                }
        for (uint32_t rank = 0u; rank < pointCount; ++rank)
            catalogue[emissiveCount + rank] = {kPoint, pointIndices[rank], pointIdentities[rank], 0u,
                mDICatalogGeneration, sourcePMF, 0u, 0u};
        // pad0 is a separate ReGIR identity. DI keeps its existing kind,
        // stable0/stable1 and generation contract; array compaction only changes
        // the ID-to-current-catalogue mapping used by persistent cell lists.
        for (uint32_t rank = 0u; rank < mDILightCount; ++rank)
        {
            auto& light = catalogue[rank];
            const auto key = std::make_tuple(light.kind, light.stable0, light.stable1);
            auto stable = mReGIRStableLightIds.find(key);
            if (stable == mReGIRStableLightIds.end())
            {
                FALCOR_CHECK(mReGIRNextLightId != 0xffffffffu, "ReGIR stable light identity range exhausted.");
                stable = mReGIRStableLightIds.emplace(key, mReGIRNextLightId++).first;
            }
            light.pad0 = stable->second;
        }
        mReGIRIdToCatalogData.assign(mReGIRNextLightId, 0xffffffffu);
        for (uint32_t rank = 0u; rank < mDILightCount; ++rank)
            mReGIRIdToCatalogData[catalogue[rank].pad0] = rank;
        mpDILightCatalog = mpDevice->createStructuredBuffer(initialVar["gDILightCatalog"], uint32_t(catalogue.size()),
            ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, catalogue.data(), false);
        if (uncoveredIndices.empty()) uncoveredIndices.push_back(0u);
        mpDIUncoveredAnalyticIndices = mpDevice->createStructuredBuffer(sizeof(uint32_t), uint32_t(uncoveredIndices.size()),
            ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, uncoveredIndices.data(), false);
        mpDIReservoirs = mpDevice->createStructuredBuffer(initialVar["gDIReservoirs"], uint32_t(pixelCount));
        mpDISampleRecords = mpDevice->createStructuredBuffer(initialVar["gDISampleRecords"], uint32_t(pixelCount));
        mpDIResults = mpDevice->createStructuredBuffer(shadeVar["gDIResults"], uint32_t(pixelCount));
        // Resolve the consumer layout now. No estimator has been sampled if
        // any resource/layout preparation above fails.
        bindDIMainResources(mpDIComputePass->getRootVar());
        mDIPrepared = true; mDIActive = mRestirDIEnabled;
        mDIFallbackReason.clear();
        return true;
    }
    catch (const std::exception& error)
    {
        const std::string reason = error.what();
        invalidateDirectLighting();
        mDICatalogSignature = signature;
        mDIPreparationFailed = true;
        mDIEmissiveCount = emissiveCount;
        mDIPointCount = pointCount;
        mDIUncoveredAnalyticCount = uncoveredCount;
        mDILightCount = lightCount <= 0x7fffffffu ? uint32_t(lightCount) : 0u;
        mDICoverageMask = coverage;
        mDIFallbackReason = reason;
        if (mReGIREnabled)
            FALCOR_THROW("ReGIR cell-only light catalogue preparation failed; global sampling is disabled: {}", reason);
        logWarning("ReSTIR DI preparation failed; using original root lighting: {}", reason);
        return false;
    }
}

void RTPT::bindDISettings(const ShaderVar& rootVar) const
{
    auto settings = rootVar["gDISettings"];
    settings["frameDim"] = mFrameDim;
    settings["sampleIndex"] = mSampleOffset + mSeed * 0x9e3779b9u;
    settings["frameStamp"] = mPrimaryFrameStamp;
    settings["lightCount"] = mDILightCount;
    settings["generation"] = mDICatalogGeneration;
    settings["candidateCount"] = mRestirDICandidateCount;
    settings["coverageMask"] = mDICoverageMask;
    settings["prepared"] = mDIPrepared ? 1u : 0u;
    settings["uncoveredAnalyticCount"] = mDIUncoveredAnalyticCount;
}

void RTPT::bindDIMainResources(const ShaderVar& rootVar) const
{
    bindDISettings(rootVar);
    if (rootVar.hasMember("gDIResults")) rootVar["gDIResults"] = mpDIResults;
    if (rootVar.hasMember("gDIUncoveredAnalyticIndices")) rootVar["gDIUncoveredAnalyticIndices"] = mpDIUncoveredAnalyticIndices;
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
        var["gDILightCatalog"] = mpDILightCatalog;
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
    Properties props;
    props["requested"] = mRestirDIEnabled;
    props["prepared"] = mDIPrepared && mRestirDIEnabled;
    props["active"] = mDIActive;
    props["coverageMask"] = mDIActive ? mDICoverageMask : 0u;
    props["lightCount"] = mDILightCount;
    props["emissiveCount"] = mDIEmissiveCount;
    props["pointCount"] = mDIPointCount;
    props["uncoveredAnalyticCount"] = mDIUncoveredAnalyticCount;
    props["generation"] = mDICatalogGeneration;
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
    props["bankCount"] = mDIReusePrepared ? 4u : 1u;
    props["finalInputBank"] = mDIFinalInputBank;
    props["historyInputBank"] = mDITemporalActive ? 1u : mDIFinalInputBank;
    props["bankBytes"] = (mpDIReservoirs ? mpDIReservoirs->getSize() : 0u) +
        (mpDISampleRecords ? mpDISampleRecords->getSize() : 0u);
    props["budgetBytes"] = uint64_t(mRestirDIBudgetMB) << 20;
    uint64_t bytes = 0u;
    for (const auto& buffer : {mpDILightCatalog, mpDIUncoveredAnalyticIndices, mpDIReservoirs, mpDISampleRecords, mpDIResults,
        mpDIPreviousPrimarySurfaces, mpDINeighborOffsets})
        if (buffer) bytes += buffer->getSize();
    props["bytes"] = bytes;
    props["reservoirStride"] = mpDIReservoirs ? mpDIReservoirs->getStructSize() : 0u;
    props["sampleStride"] = mpDISampleRecords ? mpDISampleRecords->getStructSize() : 0u;
    props["resultStride"] = mpDIResults ? mpDIResults->getStructSize() : 0u;
    props["fallbackReason"] = mDIFallbackReason;
    return props;
}
