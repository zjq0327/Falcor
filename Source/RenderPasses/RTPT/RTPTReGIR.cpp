#include "RTPT.h"
#include "Utils/Timing/Profiler.h"
#include <algorithm>
#include <limits>
#include <nlohmann/json.hpp>

namespace
{
constexpr uint32_t kReGIRDescriptorBytes = 64u;
constexpr uint32_t kReGIRStateCount = 16u;

uint32_t reGIRCapacity(uint64_t requested)
{
    uint64_t capacity = 1u;
    while (capacity < requested && capacity <= std::numeric_limits<uint32_t>::max()) capacity <<= 1u;
    FALCOR_CHECK(capacity <= std::numeric_limits<uint32_t>::max(), "ReGIR buffer capacity exceeds its 32-bit index range.");
    return uint32_t(capacity);
}

uint64_t reGIRBufferBytes(const ref<Buffer>& buffer)
{
    return buffer ? buffer->getSize() : 0u;
}
}

void RTPT::invalidateReGIR()
{
    mpReGIRBuild = mpReGIRInitial = mpReGIRUpdateLights = mpReGIRUpdateCells = nullptr;
    mpReGIRRIS = mpReGIRCells = mpReGIRCellRequests = mpReGIRCellMeta = nullptr;
    mpReGIRCellEpoch = mpReGIRCellRISFrame = mpReGIRCellLastUsed = mpReGIRCandidateIds = mpReGIRState = nullptr;
    mpReGIRIdToCatalog = mpReGIRLightDescriptors = mpReGIRPreviousLightDescriptors = mpReGIRDirtyLights = nullptr;
    mReGIRInitialActive = mReGIRInitialPreparationFailed = false;
    mReGIRInitialFallbackReason.clear();
    mReGIRPrepared = mReGIRActive = mReGIRPreparationFailed = false;
    mReGIRCellCapacity = mReGIRSlotCount = mReGIRBuildFrameStamp = 0u;
    mReGIRLightIdCapacity = mReGIRPoolCapacity = mReGIRCatalogGeneration = 0u;
    mReGIRFallbackReason.clear();
    // Stable identities outlive buffer/option rebuilds. setScene() owns their
    // reset, so an array compaction or a transient invalidation cannot reuse IDs.
}

bool RTPT::prepareReGIR(RenderContext* pRenderContext)
{
    mReGIRActive = false;
    if (!mReGIREnabled) return false;
    FALCOR_CHECK(!mReGIRPreparationFailed, "ReGIR cell-only resources are unavailable: {}", mReGIRFallbackReason);
    FALCOR_CHECK(mDIPrepared && mpDILightCatalog, "ReGIR cell-only sampling requires a prepared light catalogue.");
    FALCOR_CHECK(mRestirDIEnabled || !mUseNEE || mDIUncoveredAnalyticCount == 0u,
        "ReGIR-only light sampling supports emissive triangles and point lights. The scene contains {} unsupported analytic lights.",
        mDIUncoveredAnalyticCount);

    const uint64_t budgetBytes = uint64_t(mReGIRBudgetMB) << 20u;
    const uint64_t requestedCells = uint64_t(mReGIRGridSize) * mReGIRGridSize * mReGIRGridSize;
    const uint32_t cellCapacity = reGIRCapacity(std::max(uint64_t(64u), requestedCells));
    const uint64_t slots = uint64_t(cellCapacity) * mReGIRLightsPerCell;
    const uint64_t candidateCapacity = (budgetBytes / 2u) / sizeof(uint32_t);
    const uint32_t stableCapacity = reGIRCapacity(std::max(uint64_t(16u), uint64_t(mReGIRNextLightId)));
    FALCOR_CHECK(slots > 0u && slots <= uint64_t(65535u) * 256u && slots <= std::numeric_limits<uint32_t>::max(),
        "ReGIR RIS capacity exceeds the dispatch or 32-bit buffer range.");
    FALCOR_CHECK(candidateCapacity > 0u && candidateCapacity <= std::numeric_limits<uint32_t>::max(),
        "ReGIR candidate ID pool exceeds its 32-bit buffer range.");
    FALCOR_CHECK(uint64_t(stableCapacity) <= uint64_t(65535u) * 256u,
        "ReGIR stable light capacity exceeds the compute dispatch range.");
    const uint64_t cellBytes = uint64_t(cellCapacity) * (sizeof(uint64_t) + sizeof(uint4) + 3u * sizeof(uint32_t));
    const uint64_t lightBytes = uint64_t(stableCapacity) * (2u * kReGIRDescriptorBytes + 2u * sizeof(uint32_t));
    const uint64_t totalBytes = cellBytes + slots * sizeof(uint2) + candidateCapacity * sizeof(uint32_t) +
        lightBytes + kReGIRStateCount * sizeof(uint32_t);
    FALCOR_CHECK(totalBytes <= budgetBytes,
        "ReGIR cell lists need {} bytes, exceeding their {} MiB budget; no global sampling fallback is allowed.",
        totalBytes, mReGIRBudgetMB);

    const bool firstAllocation = !mpReGIRRIS;
    const bool growLightIds = !mpReGIRIdToCatalog || mReGIRLightIdCapacity < stableCapacity;
    const bool catalogueChanged = mReGIRCatalogGeneration != mDICatalogGeneration;
    const auto lightUpdates = IScene::UpdateFlags::LightsMoved | IScene::UpdateFlags::LightIntensityChanged |
        IScene::UpdateFlags::LightPropertiesChanged | IScene::UpdateFlags::LightCountChanged |
        IScene::UpdateFlags::GeometryMoved | IScene::UpdateFlags::GeometryChanged | IScene::UpdateFlags::MeshesChanged |
        IScene::UpdateFlags::MaterialsChanged | IScene::UpdateFlags::EmissiveMaterialsChanged;
    const bool descriptorsChanged = firstAllocation || growLightIds || catalogueChanged ||
        (mpScene->getUpdates() & lightUpdates) != IScene::UpdateFlags::None ||
        (mReGIRFreeze && is_set(mpScene->getUpdates(), IScene::UpdateFlags::LightCollectionChanged));
    if (firstAllocation)
    {
        mReGIRCellCapacity = cellCapacity;
        mReGIRSlotCount = uint32_t(slots);
        mReGIRPoolCapacity = uint32_t(candidateCapacity);
        mpReGIRRIS = mpDevice->createStructuredBuffer(sizeof(uint2), mReGIRSlotCount);
        mpReGIRCells = mpDevice->createStructuredBuffer(sizeof(uint64_t), mReGIRCellCapacity);
        mpReGIRCellMeta = mpDevice->createStructuredBuffer(sizeof(uint4), mReGIRCellCapacity);
        mpReGIRCellEpoch = mpDevice->createStructuredBuffer(sizeof(uint32_t), mReGIRCellCapacity);
        mpReGIRCellRISFrame = mpDevice->createStructuredBuffer(sizeof(uint32_t), mReGIRCellCapacity);
        mpReGIRCellLastUsed = mpDevice->createStructuredBuffer(sizeof(uint32_t), mReGIRCellCapacity);
        mpReGIRCandidateIds = mpDevice->createStructuredBuffer(sizeof(uint32_t), mReGIRPoolCapacity);
        mpReGIRState = mpDevice->createStructuredBuffer(sizeof(uint32_t), kReGIRStateCount);
        for (const auto& buffer : {mpReGIRRIS, mpReGIRCells, mpReGIRCellMeta, mpReGIRCellEpoch, mpReGIRCellRISFrame, mpReGIRCellLastUsed, mpReGIRState})
        {
            pRenderContext->clearUAV(buffer->getUAV().get(), uint4(0u));
            pRenderContext->uavBarrier(buffer.get());
        }
    }
    FALCOR_CHECK(mReGIRCellCapacity == cellCapacity && mReGIRSlotCount == uint32_t(slots) &&
        mReGIRPoolCapacity == uint32_t(candidateCapacity), "ReGIR resource options changed without cache invalidation.");

    if (growLightIds)
    {
        const auto previousCurrent = mpReGIRLightDescriptors;
        auto current = mpDevice->createStructuredBuffer(kReGIRDescriptorBytes, stableCapacity);
        auto previous = mpDevice->createStructuredBuffer(kReGIRDescriptorBytes, stableCapacity);
        pRenderContext->clearUAV(current->getUAV().get(), uint4(0u));
        pRenderContext->clearUAV(previous->getUAV().get(), uint4(0u));
        pRenderContext->uavBarrier(current.get());
        pRenderContext->uavBarrier(previous.get());
        if (previousCurrent)
        {
            pRenderContext->uavBarrier(previousCurrent.get());
            pRenderContext->copyBufferRegion(current.get(), 0u, previousCurrent.get(), 0u, previousCurrent->getSize());
        }
        mpReGIRLightDescriptors = current;
        mpReGIRPreviousLightDescriptors = previous;
        mpReGIRIdToCatalog = mpDevice->createStructuredBuffer(sizeof(uint32_t), stableCapacity);
        mpReGIRDirtyLights = mpDevice->createStructuredBuffer(sizeof(uint32_t), stableCapacity);
        mReGIRLightIdCapacity = stableCapacity;
    }
    if (growLightIds || catalogueChanged)
    {
        std::vector<uint32_t> mapping(mReGIRLightIdCapacity, std::numeric_limits<uint32_t>::max());
        FALCOR_CHECK(mReGIRIdToCatalogData.size() <= mapping.size(), "ReGIR stable-ID mapping exceeds its allocation.");
        std::copy(mReGIRIdToCatalogData.begin(), mReGIRIdToCatalogData.end(), mapping.begin());
        pRenderContext->updateBuffer(mpReGIRIdToCatalog.get(), mapping.data(), 0u, mapping.size() * sizeof(uint32_t));
        pRenderContext->uavBarrier(mpReGIRIdToCatalog.get());
    }

    if (!mpReGIRBuild || !mpReGIRUpdateLights || !mpReGIRUpdateCells || catalogueChanged)
    {
        auto defines = mpStageComputePass->getProgram()->getDefines();
        defines.add("RTPT_REGIR_ENABLED", "1");
        auto createPass = [&](const char* path, const char* entry)
        {
            ProgramDesc desc;
            desc.addShaderModules(mpScene->getShaderModules());
            desc.addTypeConformances(mpScene->getTypeConformances());
            desc.addShaderLibrary(path).csEntry(entry);
            desc.setShaderModel(ShaderModel::SM6_6);
            desc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
            return ComputePass::create(mpDevice, desc, defines, true);
        };
        mpReGIRUpdateLights = createPass("RenderPasses/RTPT/ReGIR/RTPTReGIRUpdate.cs.slang", "updateLights");
        mpReGIRUpdateCells = createPass("RenderPasses/RTPT/ReGIR/RTPTReGIRUpdate.cs.slang", "updateCells");
        mpReGIRBuild = createPass("RenderPasses/RTPT/ReGIR/RTPTReGIRBuild.cs.slang", "main");
        mReGIRCatalogGeneration = mDICatalogGeneration;
    }

    // Consumer dispatches can publish new cells inline. Make their persistent
    // keys and completed lists visible before this frame's maintenance passes.
    for (const auto& buffer : {mpReGIRCells, mpReGIRCellMeta, mpReGIRCellEpoch, mpReGIRCellRISFrame, mpReGIRCellLastUsed, mpReGIRCandidateIds})
        pRenderContext->uavBarrier(buffer.get());

    const float3 cameraPosition = mpScene->getCamera()->getPosition();
    if (mReGIRFreeze && mReGIRPrepared && !descriptorsChanged && all(cameraPosition == mReGIRBuildCameraPosition))
    {
        mReGIRActive = true;
        return true;
    }

    // Previous descriptors retain removed lights long enough to remove their
    // membership from old cells. Stable IDs and the candidate allocator persist.
    if (descriptorsChanged) std::swap(mpReGIRLightDescriptors, mpReGIRPreviousLightDescriptors);
    const uint32_t zero = 0u;
    pRenderContext->updateBuffer(mpReGIRState.get(), &zero, 6u * sizeof(uint32_t), sizeof(uint32_t));
    pRenderContext->uavBarrier(mpReGIRState.get());
    mReGIRBuildFrameStamp = uint32_t(mReGIRBuildCount + 1u);
    if (mReGIRBuildFrameStamp == 0u) mReGIRBuildFrameStamp = 1u;
    mReGIRPrepared = mReGIRActive = true;

    auto bind = [&](const ref<ComputePass>& pass)
    {
        const auto var = pass->getRootVar();
        if (var.hasMember("gScene")) mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        mpSampleGenerator->bindShaderData(var);
        if (var.hasMember("gDISettings"))
        {
            bindDISettings(var);
            var["gDISettings"]["frameStamp"] = mReGIRBuildFrameStamp;
        }
        if (var.hasMember("gDILightCatalog")) var["gDILightCatalog"] = mpDILightCatalog;
        bindReGIRInitial(var);
    };
    if (descriptorsChanged)
    {
        FALCOR_PROFILE(pRenderContext, "ReGIRUpdateLights");
        bind(mpReGIRUpdateLights);
        mpReGIRUpdateLights->execute(pRenderContext, uint3(std::max(1u, mReGIRNextLightId), 1u, 1u));
    }
    pRenderContext->uavBarrier(mpReGIRLightDescriptors.get());
    pRenderContext->uavBarrier(mpReGIRDirtyLights.get());
    pRenderContext->uavBarrier(mpReGIRState.get());
    {
        FALCOR_PROFILE(pRenderContext, "ReGIRUpdateCells");
        bind(mpReGIRUpdateCells);
        mpReGIRUpdateCells->execute(pRenderContext, uint3(mReGIRCellCapacity, 1u, 1u));
    }
    for (const auto& buffer : {mpReGIRCells, mpReGIRCellMeta, mpReGIRCellEpoch, mpReGIRCellRISFrame, mpReGIRCellLastUsed, mpReGIRCandidateIds, mpReGIRState})
        pRenderContext->uavBarrier(buffer.get());
    {
        FALCOR_PROFILE(pRenderContext, "ReGIRBuild");
        bind(mpReGIRBuild);
        mpReGIRBuild->execute(pRenderContext, uint3(mReGIRSlotCount, 1u, 1u));
    }
    pRenderContext->uavBarrier(mpReGIRRIS.get());
    pRenderContext->uavBarrier(mpReGIRCellRISFrame.get());
    ++mReGIRBuildCount;
    mReGIRBuildCameraPosition = cameraPosition;
    mReGIRFallbackReason.clear();
    return true;
}

void RTPT::bindReGIRInitial(const ShaderVar& var) const
{
    if (var.hasMember("gReGIRSettings"))
    {
        auto settings = var["gReGIRSettings"];
        settings["cameraPosition"] = mpScene->getCamera()->getPosition();
        settings["baseCellSize"] = mReGIRCellSize;
        settings["coarsenCellDistance"] = mReGIRCoarsenCellDistance;
        settings["brightnessThreshold"] = mReGIRBrightnessThreshold;
        settings["cellCapacity"] = mReGIRCellCapacity;
        settings["lightsPerCell"] = mReGIRLightsPerCell;
        settings["slotCount"] = mReGIRSlotCount;
        settings["buildSamples"] = mReGIRBuildSamples;
        settings["samplingJitter"] = mReGIRSamplingJitter;
        settings["active"] = mReGIRActive ? 1u : 0u;
        settings["lightCount"] = mDILightCount;
        settings["cullingEnabled"] = mReGIRCullingEnabled ? 1u : 0u;
        settings["generation"] = mDICatalogGeneration;
        settings["coverageMask"] = mDICoverageMask;
        settings["uncoveredAnalyticCount"] = mDIUncoveredAnalyticCount;
        settings["secondaryEnabled"] = mReGIRSecondaryEnabled ? 1u : 0u;
        settings["trainingEnabled"] = mReGIRTrainingEnabled ? 1u : 0u;
        settings["stableIdCount"] = mReGIRNextLightId;
        settings["candidateCapacity"] = mReGIRPoolCapacity;
        settings["listEpoch"] = 1u;
        settings["frameStamp"] = mReGIRBuildFrameStamp;
        settings["freezeSnapshot"] = mReGIRFreeze ? 1u : 0u;
    }
    if (var.hasMember("gReGIRCells")) var["gReGIRCells"] = mpReGIRCells;
    if (var.hasMember("gReGIRCellMeta")) var["gReGIRCellMeta"] = mpReGIRCellMeta;
    if (var.hasMember("gReGIRCellEpoch")) var["gReGIRCellEpoch"] = mpReGIRCellEpoch;
    if (var.hasMember("gReGIRCellRISFrame")) var["gReGIRCellRISFrame"] = mpReGIRCellRISFrame;
    if (var.hasMember("gReGIRCellLastUsed")) var["gReGIRCellLastUsed"] = mpReGIRCellLastUsed;
    if (var.hasMember("gReGIRCandidateIDs")) var["gReGIRCandidateIDs"] = mpReGIRCandidateIds;
    if (var.hasMember("gReGIRState")) var["gReGIRState"] = mpReGIRState;
    if (var.hasMember("gReGIRIdToCatalog")) var["gReGIRIdToCatalog"] = mpReGIRIdToCatalog;
    if (var.hasMember("gReGIRCatalog")) var["gReGIRCatalog"] = mpDILightCatalog;
    if (var.hasMember("gReGIRLightDescriptors")) var["gReGIRLightDescriptors"] = mpReGIRLightDescriptors;
    if (var.hasMember("gReGIRPreviousLightDescriptors")) var["gReGIRPreviousLightDescriptors"] = mpReGIRPreviousLightDescriptors;
    if (var.hasMember("gReGIRDirtyLightIDs")) var["gReGIRDirtyLightIDs"] = mpReGIRDirtyLights;
    if (var.hasMember("gReGIRRIS")) var["gReGIRRIS"] = mpReGIRRIS;
}

void RTPT::bindReGIRTransport(const ShaderVar& var) const
{
    bindReGIRInitial(var);
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
    props["mode"] = std::string("CellOnlyLodLists");
    props["globalSamplingEnabled"] = false;
    props["cellCapacity"] = mReGIRCellCapacity;
    props["baseCellSize"] = mReGIRCellSize;
    props["coarsenCellDistance"] = mReGIRCoarsenCellDistance;
    props["brightnessThreshold"] = mReGIRBrightnessThreshold;
    props["lightCullingEnabled"] = mReGIRCullingEnabled;
    props["stableLightIdCount"] = mReGIRNextLightId;
    props["stableIdCount"] = mReGIRNextLightId;
    props["stableLightIdCapacity"] = mReGIRLightIdCapacity;
    props["candidateCapacity"] = mReGIRPoolCapacity;
    props["slotCount"] = mReGIRSlotCount;
    props["risBufferOffset"] = 0u;
    props["risElementCount"] = mpReGIRRIS ? mpReGIRRIS->getElementCount() : 0u;
    const uint64_t risBytes = reGIRBufferBytes(mpReGIRRIS);
    const uint64_t hashBytes = reGIRBufferBytes(mpReGIRCells) + reGIRBufferBytes(mpReGIRCellMeta) +
        reGIRBufferBytes(mpReGIRCellEpoch) + reGIRBufferBytes(mpReGIRCellRISFrame) + reGIRBufferBytes(mpReGIRCellLastUsed);
    const uint64_t candidateBytes = reGIRBufferBytes(mpReGIRCandidateIds);
    const uint64_t descriptorBytes = reGIRBufferBytes(mpReGIRLightDescriptors) + reGIRBufferBytes(mpReGIRPreviousLightDescriptors);
    const uint64_t auxiliaryBytes = reGIRBufferBytes(mpReGIRState) + reGIRBufferBytes(mpReGIRIdToCatalog) + reGIRBufferBytes(mpReGIRDirtyLights);
    props["risBytes"] = risBytes;
    props["hashBytes"] = hashBytes;
    props["candidateBytes"] = candidateBytes;
    props["descriptorBytes"] = descriptorBytes;
    props["auxiliaryBytes"] = auxiliaryBytes;
    props["bytes"] = risBytes + hashBytes + candidateBytes + descriptorBytes + auxiliaryBytes;
    props["budgetBytes"] = uint64_t(mReGIRBudgetMB) << 20u;
    props["buildFrameStamp"] = mReGIRBuildFrameStamp;
    props["buildCount"] = mReGIRBuildCount;
    props["freeze"] = mReGIRFreeze;
    props["buildSamples"] = mReGIRBuildSamples;
    props["lightsPerCell"] = mReGIRLightsPerCell;
    props["gridSize"] = mReGIRGridSize;
    props["gridCenter"] = mpScene ? mpScene->getCamera()->getPosition() : float3(0.f);
    props["secondaryActive"] = mReGIRActive && mUseNEE && mReGIRSecondaryEnabled;
    props["trainingActive"] = mReGIRActive && mUseNEE && mReGIRTrainingEnabled &&
        ((mEnablePG && mPGSettings.enabled && mPGSettings.trainingEnabled) || (mEnableSHARC && mSHARCEnabled && !mSHARCFreeze));
    props["fallbackReason"] = mReGIRFallbackReason;
    if (mpReGIRState)
    {
        // Statistics explicitly requested by the caller may synchronize. This
        // readback is not part of normal per-frame candidate maintenance.
        const auto state = mpReGIRState->getElements<uint32_t>(0u, kReGIRStateCount);
        props["candidatePoolUsed"] = state[0];
        props["proceduralViews"] = state[1];
        props["listBuilds"] = state[2];
        props["listReuses"] = state[3];
        props["poolOverflows"] = state[4];
        props["hashOverflows"] = state[5];
        props["dirtyLights"] = state[6];
        props["dirtyCellBuilds"] = state[7];
        props["inlineBuilds"] = state[8];
        props["evictions"] = state[9];
    }
    std::vector<uint32_t> catalogueIds(mDILightCount, std::numeric_limits<uint32_t>::max());
    for (uint32_t stableId = 0u; stableId < mReGIRIdToCatalogData.size(); ++stableId)
    {
        const uint32_t rank = mReGIRIdToCatalogData[stableId];
        if (rank < catalogueIds.size()) catalogueIds[rank] = stableId;
    }
    // Properties' scalar setter is explicitly instantiated, so attach the
    // diagnostic arrays through its supported JSON constructor instead.
    auto json = props.toJson();
    json["catalogStableIds"] = catalogueIds;
    json["activeStableIds"] = catalogueIds;
    return Properties(std::move(json));
}
