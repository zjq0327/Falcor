#include "RTPTVXPG.h"
#include "Utils/Timing/Profiler.h"
#include <limits>

using namespace Falcor;
namespace RTPTVXPG
{
void Manager::configure(const Settings& settings, uint2 frameDim, uint32_t sharedStride, uint32_t sharedBounces)
{
    validate(settings);
    FALCOR_CHECK(sharedStride >= 1 && sharedStride <= 32 && sharedBounces >= 1 && sharedBounces <= 32, "Invalid shared training layout.");
    const auto changes = compareSettings(mSettings, settings);
    // Apply the strongest effect once; weaker effects are included by scope.
    const bool resourcesChanged = changes.resources() || any(frameDim != mFrameDim);
    if (resourcesChanged)
        invalidate(Invalidation::Resources);
    else if (changes.history || sharedStride != mSharedTrainingStride || sharedBounces != mSharedTrainingBounces)
        invalidate(Invalidation::LightingHistory);
    else if (changes.topologyInterval)
        invalidate(Invalidation::Proposal, "Topology refresh interval changed");
    else if (changes.spatialLifetime)
        invalidate(Invalidation::Proposal, "Spatial lifetime changed");
    if (changes.diagnostics)
    {
        // Change only instrumentation variants; published data and histories
        // remain usable, including a frozen proposal and its debug view.
        const char* enabled = settings.detailedDiagnostics ? "1" : "0";
        for (const auto& pass : {mView.pPrimary, mProposal.pRowVisibility, mView.pTopLeaves})
            if (pass)
                pass->addDefine("RTPT_VXPG_DETAILED_DIAGNOSTICS", enabled, true);
        invalidateDiagnosticSnapshot();
    }
    updateScreenAllocation(frameDim);
    mSettings = settings;
    mFrameDim = frameDim;
    mSharedTrainingStride = sharedStride;
    mSharedTrainingBounces = sharedBounces;
    mEstimatedBytes = estimateModelBytes();
    if (mEstimatedBytes > uint64_t(getBudgetMiB()) * 1024ull * 1024ull)
    {
        invalidate(Invalidation::Resources, "Resource estimate exceeds VXPG budget");
    }
}

uint64_t Manager::primaryDiscoveryCount() const
{
    const uint32_t stride = mSettings.discoveryStride;
    return uint64_t((mFrameDim.x + stride - 1) / stride) * ((mFrameDim.y + stride - 1) / stride);
}

uint64_t Manager::getDiscoveryRecordCount() const
{
    const uint32_t stride = mSharedTrainingStride;
    return uint64_t((mFrameDim.x + stride - 1) / stride) * ((mFrameDim.y + stride - 1) / stride) * mSharedTrainingBounces;
}

void Manager::advanceGeneration(uint32_t& generation)
{
    if (generation == std::numeric_limits<uint32_t>::max())
    {
        // No queued consumer may retain the identity when it is reused.
        mpDevice->wait();
        generation = 1;
    }
    else
        ++generation;
}

void Manager::invalidate(Invalidation scope, const std::string& reason)
{
    // Retire an identity only once. Further requests may still discard history,
    // the grid or allocations while the proposal is already invalid.
    if (mReady || mDistributionValid || mLightingPrepared)
        advanceGeneration(mGeneration);
    beginFrame();
    invalidateDiagnosticSnapshot();
    mReady = mDistributionValid = false;
    if (scope >= Invalidation::LightingHistory)
        mResetHistory = true;
    if (scope >= Invalidation::Grid)
    {
        mGeometryValid = false;
        mLightingFrameIndex = 0;
    }
    if (scope == Invalidation::Resources)
        releaseModelResources();
    if (!reason.empty())
        mFallbackReason = reason;
    else if (scope >= Invalidation::Grid)
        mFallbackReason = "Voxel proposal has not been built";
    else if (scope == Invalidation::LightingHistory)
        mFallbackReason = "Lighting history needs rebuilding";
    else
        mFallbackReason = "View-dependent proposal needs rebuilding";
}

void Manager::cameraChanged(bool projectionChanged, bool freezeUpdates)
{
    // Ordinary motion refreshes screen data during the update. Frozen data
    // cannot do that; projection changes always require a new proposal.
    if (projectionChanged)
        invalidate(Invalidation::Proposal, "Camera projection changed; rebuild the VXPG proposal");
    else if (freezeUpdates)
        invalidate(Invalidation::Proposal);
}

void Manager::lightingChanged()
{
    invalidate(Invalidation::LightingHistory, "Lighting configuration needs rebuilding");
    mView.pPrimary = nullptr;
}

void Manager::setScene(const ref<Scene>& scene)
{
    mpScene = scene;
    mView.pDebug = nullptr;
    mLighting.pClearFrame = mView.pPrimary = mProposal.pGlobalLeaves = mProposal.pGlobalLevel = mProposal.pPublish = nullptr;
    resetClusterPasses();
    invalidate();
}

void Manager::buildIncrementalGeometry(RenderContext* context)
{
    const float3 camera = mpScene->getCamera()->getPosition();
    if (any(camera != mLodCamera))
        cameraChanged(false, mSettings.freezeUpdates);
    if (mSettings.freezeUpdates)
        return;
    mLodCamera = camera;
    mEstimatedBytes = estimateModelBytes();
    if (mEstimatedBytes > uint64_t(getBudgetMiB()) * 1024ull * 1024ull)
    {
        invalidate(Invalidation::Grid, "Incremental grid exceeds VXPG budget");
        return;
    }
    const auto* animation = mpScene->getAnimationController();
    if (animation && (animation->hasSkinnedMeshes() || animation->hasAnimatedMeshCaches()))
    {
        invalidate(Invalidation::Grid, "Skinned/vertex-cache geometry is not validated for VXPG");
        return;
    }
    if (mGeometryValid)
        return;
    FALCOR_PROFILE(context, "VXPGIncrementalGridReset");
    const uint32_t cells = cellCapacity();
    ensureGridResources();
    mGridMin = float3(-1.e-4f);
    mCellSize = 2.f / mSettings.lodSceneScale;
    mLodLevels = 63u;
    for (const auto& b :
         {mGrid.pHash,
          mProposal.pState,
          mGrid.pBoundMin,
          mGrid.pBoundMax,
          mProposal.pInverse,
          mGrid.pCellKeys,
          mGrid.pCellLifetime,
          mGrid.pGridState})
        if (b)
            context->uavBarrier(b.get());
    dispatchUpdate(context, mGrid.pGridClear, uint3(std::max(cells, getHashCapacity()), 1, 1));
    for (const auto& b :
         {mGrid.pHash,
          mProposal.pState,
          mGrid.pBoundMin,
          mGrid.pBoundMax,
          mProposal.pInverse,
          mGrid.pCellKeys,
          mGrid.pCellLifetime,
          mGrid.pGridState})
        if (b)
            context->uavBarrier(b.get());
    mResetHistory = true;
    mDistributionValid = false;
    mGeometryValid = true;
    mReady = false;
    advanceGeneration(mGeometryGeneration);
    ++mGeometryRebuilds;
}

void Manager::prepareIncrementalGrid(RenderContext* context)
{
    FALCOR_PROFILE(context, "VXPGIncrementalMaintenance");
    // Resize only observation scratch when training depth/stride changes. Keep
    // the persistent spatial map, including while its proposal is frozen.
    ensureObservationResources();
    const uint32_t records = uint32_t(getDiscoveryRecordCount());
    for (const auto& b :
         {mGrid.pPendingHash, mGrid.pDiscovery, mGrid.pGridState, mGrid.pCellLifetime, mGrid.pRetiredCells, mGrid.pHash, mGrid.pBoundMin})
        if (b)
            context->uavBarrier(b.get());
    dispatchUpdate(context, mGrid.pGridBegin, uint3(std::max(records, getHashCapacity()), 1, 1));
    context->uavBarrier(mGrid.pGridState.get());
    context->uavBarrier(mGrid.pPendingHash.get());
    context->uavBarrier(mGrid.pDiscovery.get());
    dispatchUpdate(context, mGrid.pGridEvict, uint3(cellCapacity(), 1, 1));
    for (const auto& b : {mGrid.pHash, mGrid.pBoundMin, mGrid.pGridState, mGrid.pRetiredCells, mLighting.pHistory})
        if (b)
            context->uavBarrier(b.get());
}

void Manager::finishIncrementalGrid(RenderContext* context)
{
    FALCOR_PROFILE(context, "VXPGIncrementalInsert");
    const uint32_t requests = uint32_t(discoveryRequestCount());
    auto barriers = [&]()
    {
        for (const auto& b :
             {mGrid.pHash,
              mGrid.pCellKeys,
              mProposal.pState,
              mGrid.pBoundMin,
              mGrid.pBoundMax,
              mProposal.pInverse,
              mGrid.pGridState,
              mGrid.pCellLifetime,
              mGrid.pFreeCells,
              mGrid.pPendingHash,
              mGrid.pPendingSlots,
              mGrid.pDiscovery,
              mLighting.pCount,
              mLighting.pFlux,
              mLighting.pHistory,
              mLighting.pRepresentativePosition,
              mLighting.pRepresentativeNormal})
            if (b)
                context->uavBarrier(b.get());
    };
    auto run = [&](const ref<ComputePass>& pass, uint32_t count)
    {
        dispatchUpdate(context, pass, uint3(count, 1, 1));
        barriers();
    };
    barriers();
    run(mGrid.pGridDiscover, requests);
    run(mGrid.pGridInsert, uint32_t(std::min<uint64_t>(requests, getHashCapacity())));
    run(mGrid.pGridReplay, uint32_t(getDiscoveryRecordCount()));
    dispatchUpdate(context, mProposal.pGeometryWork, uint3(1));
    context->uavBarrier(mProposal.pWorkArgs.get());
    context->copyResource(mProposal.pWorkDispatch.get(), mProposal.pWorkArgs.get());
}

void Manager::buildGeometry(RenderContext* context)
{
    if (!mpScene || !mSettings.enabled)
        return;
    buildIncrementalGeometry(context);
}

void Manager::prepareLighting(RenderContext* context)
{
    beginFrame();
    // Construction observations describe one actual update, never a frozen
    // frame or an old update from before diagnostics were enabled.
    invalidateDiagnosticSnapshot();
    if (!mGeometryValid || !mSettings.enabled)
        return;
    if (mSettings.freezeUpdates)
    {
        if (!mDistributionValid)
            mFallbackReason = "Frozen proposal is invalid; unfreeze to rebuild";
        else
        {
            if (!mProposal.pClearDiagnostics)
                mProposal.pClearDiagnostics = createPass("RTPTVXPGPrepare.cs.slang", "clearDiagnostics");
            context->uavBarrier(mProposal.pState.get());
            context->uavBarrier(mProposal.pQueryStats.get());
            dispatchUpdate(context, mProposal.pClearDiagnostics, uint3(32, 1, 1));
            context->uavBarrier(mProposal.pQueryStats.get());
            context->uavBarrier(mProposal.pState.get());
        }
        return;
    }
    ensureLightingResources(context);
    advanceGeneration(mGeneration);
    {
        FALCOR_PROFILE(context, "VXPGClear");
        {
            if (mGeneration == 1)
                context->clearUAV(mProposal.pDirtyNodes->getUAV().get(), uint4(0));
            context->uavBarrier(mProposal.pTreeState.get());
            dispatchUpdate(context, mProposal.pBeginLocal, uint3(1));
            context->uavBarrier(mProposal.pTreeState.get());
        }
        context->uavBarrier(mProposal.pState.get());
        context->uavBarrier(mProposal.pGlobalTree.get());
        context->uavBarrier(mProposal.pMass.get());
        context->uavBarrier(mProposal.pCompactIndices.get());
        context->uavBarrier(mProposal.pInverse.get());
        context->uavBarrier(mLighting.pFlux.get());
        context->uavBarrier(mLighting.pCount.get());
        context->uavBarrier(mGrid.pBoundMax.get());
        context->uavBarrier(mLighting.pHistoryStats.get());
        context->uavBarrier(mProposal.pQueryStats.get());
        if (mLighting.pHistory)
            context->uavBarrier(mLighting.pHistory.get());
        {
            context->uavBarrier(mProposal.pWorkArgs.get());
            dispatchUpdate(context, mProposal.pGeometryWork, uint3(1));
            context->uavBarrier(mProposal.pWorkArgs.get());
            context->copyResource(mProposal.pWorkDispatch.get(), mProposal.pWorkArgs.get());
            dispatchIndirectUpdate(context, mLighting.pClearFrame, mProposal.pWorkDispatch, 4 * sizeof(uint32_t));
        }
        context->uavBarrier(mProposal.pQueryStats.get());
        context->uavBarrier(mProposal.pState.get());
        context->uavBarrier(mLighting.pFlux.get());
        context->uavBarrier(mLighting.pCount.get());
        context->uavBarrier(mGrid.pBoundMax.get());
        context->uavBarrier(mProposal.pInverse.get());
    }
    prepareIncrementalGrid(context);
    if (mLighting.pHistoryPrevious)
    {
        context->copyResource(mLighting.pHistoryPrevious.get(), mLighting.pHistory.get());
        context->copyResource(mLighting.pNormalPrevious.get(), mLighting.pRepresentativeNormal.get());
    }
    context->uavBarrier(mLighting.pRepresentativePosition.get());
    context->uavBarrier(mLighting.pRepresentativeNormal.get());
    if (mLighting.pHistory)
        context->uavBarrier(mLighting.pHistory.get());
    context->uavBarrier(mLighting.pHistoryStats.get());
    mResetHistory = false;
    mLightingPrepared = true;
}

void Manager::barrierInjection(RenderContext* context) const
{
    for (const auto& buffer :
         {mLighting.pFlux,
          mLighting.pCount,
          mProposal.pState,
          mGrid.pBoundMax,
          mLighting.pRepresentativePosition,
          mLighting.pRepresentativeNormal})
        if (buffer)
            context->uavBarrier(buffer.get());
}

// Bind only common inputs here. Entry constants, sampler data and all GPU
// synchronization remain explicit at the stage call sites.
void Manager::bindUpdatePass(RenderContext* context, const ref<ComputePass>& pass) const
{
    auto root = pass->getRootVar();
    bind(root, mLightingFrameIndex, true);
    auto scene = root.findMember("gScene");
    if (scene.isValid())
        mpScene->bindShaderDataForRaytracing(context, scene);
}

void Manager::dispatchUpdate(RenderContext* context, const ref<ComputePass>& pass, uint3 size)
{
    bindUpdatePass(context, pass);
    pass->execute(context, size);
}

void Manager::dispatchIndirectUpdate(
    RenderContext* context,
    const ref<ComputePass>& pass,
    const ref<Buffer>& arguments,
    uint64_t byteOffset
)
{
    bindUpdatePass(context, pass);
    pass->executeIndirect(context, arguments.get(), byteOffset);
}

void Manager::updateLighting(RenderContext* context, uint32_t seed, uint32_t sampleOffset, bool useNRD)
{
    if (!mLightingPrepared)
        return;
    mLightingPrepared = false;

    // Shared training has already written observations between prepare/update.
    updatePrimaryData(context, seed, sampleOffset, useNRD);
    finishIncrementalGrid(context);
    resolveHistoryAndBuildGlobalTree(context);
    updateLocalTrees(context);
    updateVisibility(context);
    // Old cell IDs remain unavailable until the new proposal is published.
    publishAndRetire(context);
}

void Manager::updatePrimaryData(RenderContext* context, uint32_t seed, uint32_t sampleOffset, bool useNRD)
{
    FALCOR_PROFILE(context, "VXPGPrimary");
    context->uavBarrier(mView.pPrimaryPosition.get());
    context->uavBarrier(mView.pPrimaryNormal.get());
    context->uavBarrier(mView.pPrimaryHit.get());
    context->uavBarrier(mLighting.pRepresentativePosition.get());
    context->uavBarrier(mLighting.pRepresentativeNormal.get());
    auto root = mView.pPrimary->getRootVar();
    mpSampleGenerator->bindShaderData(root);
    root["gParams"]["seed"] = seed;
    root["gParams"]["sampleOffset"] = sampleOffset;
    root["gParams"]["useNRD"] = useNRD ? 1u : 0u;
    dispatchUpdate(context, mView.pPrimary, uint3(mFrameDim, 1));
    context->uavBarrier(mLighting.pFlux.get());
    context->uavBarrier(mLighting.pCount.get());
    context->uavBarrier(mProposal.pState.get());
    context->uavBarrier(mGrid.pBoundMax.get());
    context->uavBarrier(mLighting.pRepresentativePosition.get());
    context->uavBarrier(mLighting.pRepresentativeNormal.get());
    context->uavBarrier(mView.pPrimaryPosition.get());
    context->uavBarrier(mView.pPrimaryNormal.get());
    context->uavBarrier(mView.pPrimaryHit.get());
}

void Manager::resolveHistoryAndBuildGlobalTree(RenderContext* context)
{
    FALCOR_PROFILE(context, "VXPGCompactAndTree");
    {
        context->uavBarrier(mProposal.pCellMass.get());
        context->uavBarrier(mProposal.pDirtyLeaves.get());
        dispatchIndirectUpdate(context, mProposal.pResolveLocal, mProposal.pWorkDispatch, 4 * sizeof(uint32_t));
        context->uavBarrier(mProposal.pCellMass.get());
        context->uavBarrier(mProposal.pTreeState.get());
        context->uavBarrier(mProposal.pState.get());
        dispatchUpdate(context, mProposal.pSelectLocal, uint3(1));
        context->uavBarrier(mProposal.pTreeState.get());
        context->uavBarrier(mProposal.pState.get());
        dispatchIndirectUpdate(context, mProposal.pCompactLocal, mProposal.pWorkDispatch, 4 * sizeof(uint32_t));
        context->uavBarrier(mProposal.pDirtyLeaves.get());
        context->uavBarrier(mProposal.pTreeState.get());
    }
    context->uavBarrier(mProposal.pMass.get());
    context->uavBarrier(mProposal.pCompactIndices.get());
    context->uavBarrier(mProposal.pInverse.get());
    context->uavBarrier(mProposal.pState.get());
    if (mLighting.pHistory)
        context->uavBarrier(mLighting.pHistory.get());
    context->uavBarrier(mLighting.pHistoryStats.get());
    context->uavBarrier(mProposal.pQueryStats.get());
    {
        context->uavBarrier(mProposal.pWorkArgs.get());
        dispatchUpdate(context, mProposal.pActiveWork, uint3(1));
        context->uavBarrier(mProposal.pWorkArgs.get());
        context->copyResource(mProposal.pWorkDispatch.get(), mProposal.pWorkArgs.get());
    }
    mProposal.pGlobalLeaves->getRootVar()["VXPGTreeLevel"]["leafCapacity"] = mProposal.leafCapacity;
    dispatchIndirectUpdate(context, mProposal.pGlobalLeaves, mProposal.pWorkDispatch, 12 * sizeof(uint32_t));
    context->uavBarrier(mProposal.pGlobalTree.get());
    for (uint32_t offset = mProposal.leafCapacity / 2, level = 1; offset > 0; offset /= 2, ++level)
    {
        auto root = mProposal.pGlobalLevel->getRootVar();
        root["VXPGTreeLevel"]["nodeOffset"] = level;
        root["VXPGTreeLevel"]["nodeCount"] = offset;
        dispatchIndirectUpdate(context, mProposal.pGlobalLevel, mProposal.pWorkDispatch, (32 + (level - 1) * 3) * sizeof(uint32_t));
        context->uavBarrier(mProposal.pGlobalTree.get());
    }
}

void Manager::updateLocalTrees(RenderContext* context)
{
    FALCOR_PROFILE(context, "VXPGLocalTreeUpdate");
    context->uavBarrier(mProposal.pLocalArgs.get());
    dispatchUpdate(context, mProposal.pLocalWork, uint3(1));
    context->uavBarrier(mProposal.pLocalArgs.get());
    context->copyResource(mProposal.pLocalDispatch.get(), mProposal.pLocalArgs.get());
    auto localDispatch = [&](const ref<ComputePass>& pass)
    {
        dispatchIndirectUpdate(context, pass, mProposal.pLocalDispatch);
        context->uavBarrier(mProposal.pGlobalTree.get());
        if (mProposal.pForest)
            context->uavBarrier(mProposal.pForest.get());
        context->uavBarrier(mProposal.pDirtyNodes.get());
        context->uavBarrier(mProposal.pTreeState.get());
    };
    if (mProposal.pForest)
        context->uavBarrier(mProposal.pForest.get());
    localDispatch(mProposal.pLocalLeaves);
    for (uint32_t level = 1; (mProposal.leafCapacity >> level) > 0; ++level)
    {
        mProposal.pLocalLevel->getRootVar()["VXPGLocalLevel"]["localTreeLevel"] = level;
        localDispatch(mProposal.pLocalLevel);
    }
}

void Manager::publishAndRetire(RenderContext* context)
{
    {
        context->uavBarrier(mProposal.pState.get());
        dispatchUpdate(context, mProposal.pPublish, uint3(1));
        context->uavBarrier(mProposal.pState.get());
        if (mProposal.pTreeState)
            context->uavBarrier(mProposal.pTreeState.get());
    }
    {
        dispatchUpdate(context, mGrid.pGridRetire, uint3(cellCapacity(), 1, 1));
        context->uavBarrier(mGrid.pFreeCells.get());
        context->uavBarrier(mGrid.pGridState.get());
        context->uavBarrier(mProposal.pInverse.get());
    }
    mDistributionValid = true;
    mReady = true;
    mFallbackReason.clear();
    mModelDiagnosticsAvailable = mSettings.detailedDiagnostics;
    mModelDiagnosticsFrameIndex = mLightingFrameIndex;
    mPreviousLodCamera = mLodCamera;
    ++mLightingFrameIndex;
}

void Manager::updateVisibility(RenderContext* context)
{
    const uint32_t rows = ((mFrameDim.x + mSettings.superpixelSize - 1) / mSettings.superpixelSize) *
                          ((mFrameDim.y + mSettings.superpixelSize - 1) / mSettings.superpixelSize);
    ensureVisibilityResources(rows);
    updateVisibilityClusters(context);
    const auto sorted = sortClusterVoxels(context);
    buildClusterForest(context, sorted);
    updateScreenDistribution(context, rows);
}

void Manager::updateVisibilityClusters(RenderContext* context)
{
    FALCOR_PROFILE(context, "VXPGVisibilityClusters");
    for (const auto& buffer :
         {mProposal.pClusterInfo,
          mProposal.pClusterState,
          mView.pRowPosition,
          mView.pRowNormal,
          mProposal.pVisibility,
          mProposal.pSeeds,
          mProposal.pCluster})
        context->uavBarrier(buffer.get());
    dispatchUpdate(context, mProposal.pPrepareClusters, uint3(64, 1, 1));
    context->uavBarrier(mProposal.pClusterArgs.get());
    context->uavBarrier(mProposal.pClusterState.get());
    context->uavBarrier(mProposal.pClusterInfo.get());
    dispatchUpdate(context, mProposal.pRows, uint3(128, 1, 1));
    context->uavBarrier(mView.pRowPosition.get());
    context->uavBarrier(mView.pRowNormal.get());
    dispatchIndirectUpdate(context, mProposal.pRowVisibility, mProposal.pClusterArgs);
    context->uavBarrier(mProposal.pVisibility.get());
    context->uavBarrier(mProposal.pClusterState.get());
    dispatchUpdate(context, mProposal.pSeedsPass, uint3(256, 1, 1));
    context->uavBarrier(mProposal.pSeeds.get());
    dispatchIndirectUpdate(context, mProposal.pAssignClusters, mProposal.pWorkDispatch, 8 * sizeof(uint32_t));
    context->uavBarrier(mProposal.pCluster.get());
    context->uavBarrier(mProposal.pClusterInfo.get());
}

ref<Buffer> Manager::sortClusterVoxels(RenderContext* context)
{
    ref<Buffer> sorted = mProposal.pSortA, scratch = mProposal.pSortB;
    FALCOR_PROFILE(context, "VXPGMortonSort");
    context->uavBarrier(mProposal.pSortA.get());
    context->uavBarrier(mProposal.pSortB.get());
    auto constants = [&](const ShaderVar& root, uint32_t shift)
    {
        auto cb = root["VXPGClusterBuild"];
        cb["sortCapacity"] = mProposal.leafCapacity;
        cb["sortGroups"] = (mProposal.leafCapacity + 255) / 256;
        cb["sortShift"] = shift;
    };
    auto root = mProposal.pEncode->getRootVar();
    constants(root, 0);
    root["gVXPGSortOutput"] = sorted;
    dispatchIndirectUpdate(context, mProposal.pEncode, mProposal.pWorkDispatch, 16 * sizeof(uint32_t));
    context->uavBarrier(sorted.get());
    for (uint32_t shift = 0; shift < 32; shift += 8)
    {
        root = mProposal.pHistogramPass->getRootVar();
        constants(root, shift);
        root["gVXPGSortInput"] = sorted;
        root["gVXPGHistogram"] = mProposal.pHistogram;
        dispatchIndirectUpdate(context, mProposal.pHistogramPass, mProposal.pWorkDispatch, 16 * sizeof(uint32_t));
        context->uavBarrier(mProposal.pHistogram.get());
        root = mProposal.pPrefixPass->getRootVar();
        constants(root, shift);
        root["gVXPGHistogram"] = mProposal.pHistogram;
        root["gVXPGBinOffsets"] = mProposal.pBinOffsets;
        dispatchUpdate(context, mProposal.pPrefixPass, uint3(256, 1, 1));
        context->uavBarrier(mProposal.pHistogram.get());
        context->uavBarrier(mProposal.pBinOffsets.get());
        root = mProposal.pScatter->getRootVar();
        constants(root, shift);
        root["gVXPGSortInput"] = sorted;
        root["gVXPGSortOutput"] = scratch;
        root["gVXPGHistogram"] = mProposal.pHistogram;
        root["gVXPGBinOffsets"] = mProposal.pBinOffsets;
        dispatchIndirectUpdate(context, mProposal.pScatter, mProposal.pWorkDispatch, 16 * sizeof(uint32_t));
        context->uavBarrier(scratch.get());
        context->uavBarrier(sorted.get());
        context->uavBarrier(mProposal.pHistogram.get());
        context->uavBarrier(mProposal.pBinOffsets.get());
        std::swap(sorted, scratch);
    }
    return sorted;
}

void Manager::buildClusterForest(RenderContext* context, const ref<Buffer>& sorted)
{
    FALCOR_PROFILE(context, "VXPGClusterForest");
    context->uavBarrier(mProposal.pForest.get());
    dispatchUpdate(context, mProposal.pAllocateForest, uint3(1));
    context->uavBarrier(mProposal.pClusterInfo.get());
    context->uavBarrier(mProposal.pClusterState.get());
    {
        context->uavBarrier(mProposal.pWorkArgs.get());
        dispatchUpdate(context, mProposal.pForestWork, uint3(1));
        context->uavBarrier(mProposal.pWorkArgs.get());
        context->copyResource(mProposal.pWorkDispatch.get(), mProposal.pWorkArgs.get());
        dispatchIndirectUpdate(context, mProposal.pInitializeForest, mProposal.pWorkDispatch, 20 * sizeof(uint32_t));
    }
    context->uavBarrier(mProposal.pForest.get());
    auto root = mProposal.pForestLeaves->getRootVar();
    context->uavBarrier(mProposal.pCompactToLeaf.get());
    root["gVXPGSortInput"] = sorted;
    dispatchIndirectUpdate(context, mProposal.pForestLeaves, mProposal.pWorkDispatch, 8 * sizeof(uint32_t));
    context->uavBarrier(mProposal.pForest.get());
    context->uavBarrier(mProposal.pCompactToLeaf.get());
    for (uint32_t level = 1; (mProposal.leafCapacity >> level) > 0; ++level)
    {
        root = mProposal.pForestLevel->getRootVar();
        root["VXPGClusterBuild"]["treeLevel"] = level;
        dispatchIndirectUpdate(context, mProposal.pForestLevel, mProposal.pWorkDispatch, (96 + (level - 1) * 3) * sizeof(uint32_t));
        context->uavBarrier(mProposal.pForest.get());
    }
    dispatchUpdate(context, mProposal.pPublishClusters, uint3(1));
    // Publication converts the remaining AABB roots to query geometry.
    context->uavBarrier(mProposal.pForest.get());
    context->uavBarrier(mProposal.pClusterState.get());
    context->uavBarrier(mProposal.pState.get());
}

void Manager::updateScreenDistribution(RenderContext* context, uint32_t rows)
{
    FALCOR_PROFILE(context, "VXPGSuperpixelTopTree");
    context->uavBarrier(mView.pSuperpixelPosition.get());
    context->uavBarrier(mView.pSuperpixelNormal.get());
    context->uavBarrier(mView.pSuperpixelCount.get());
    dispatchUpdate(context, mView.pCenters, uint3(rows, 1, 1));
    context->uavBarrier(mView.pSuperpixelPosition.get());
    context->uavBarrier(mView.pSuperpixelNormal.get());
    context->uavBarrier(mView.pSuperpixelCount.get());
    context->uavBarrier(mView.pFuzzyIds.get());
    context->uavBarrier(mView.pFuzzyWeights.get());
    dispatchUpdate(context, mView.pAssociate, uint3(mFrameDim, 1));
    context->uavBarrier(mView.pFuzzyIds.get());
    context->uavBarrier(mView.pFuzzyWeights.get());
    context->uavBarrier(mView.pSuperpixelCount.get());
    context->uavBarrier(mView.pSuperpixelRange.get());
    context->uavBarrier(mView.pSuperpixelBlocks.get());
    dispatchUpdate(context, mView.pSuperpixelPrefix, uint3(rows, 1, 1));
    context->uavBarrier(mView.pSuperpixelRange.get());
    context->uavBarrier(mView.pSuperpixelBlocks.get());
    context->uavBarrier(mView.pSuperpixelCount.get());
    dispatchUpdate(context, mView.pSuperpixelBlockPrefix, uint3(1));
    context->uavBarrier(mView.pSuperpixelBlocks.get());
    dispatchUpdate(context, mView.pSuperpixelRanges, uint3(rows, 1, 1));
    context->uavBarrier(mView.pSuperpixelRange.get());
    context->uavBarrier(mView.pSuperpixelPoints.get());
    dispatchUpdate(context, mView.pSuperpixelScatter, uint3(mFrameDim, 1));
    context->uavBarrier(mView.pSuperpixelPoints.get());
    context->uavBarrier(mView.pSuperpixelCount.get());
    context->uavBarrier(mView.pTopTree.get());
    const uint32_t pairs = rows * 32;
    dispatchUpdate(context, mView.pTopLeaves, uint3(std::min(1024u, pairs) * 32, (pairs + 1023) / 1024, 1));
    context->uavBarrier(mView.pTopTree.get());
    dispatchUpdate(context, mView.pTopParents, uint3(rows, 1, 1));
    context->uavBarrier(mView.pTopTree.get());
    context->uavBarrier(mProposal.pClusterState.get());
}

void Manager::renderDebug(RenderContext* context, const ref<Texture>& output)
{
    if (mSettings.debugEnabled && mGeometryValid && output && (mSettings.debugMode == 0 || mSettings.debugMode == 4))
    {
        if (!mView.pDebug)
            mView.pDebug = createPass("RTPTVXPGDebug.cs.slang", "debugGeometry", PassScene::SceneOnly);
        auto root = mView.pDebug->getRootVar();
        root["gVXPGDebug"] = output;
        dispatchUpdate(context, mView.pDebug, uint3(mFrameDim, 1));
        return;
    }
    if (!mSettings.debugEnabled || mSettings.debugMode == 0 || mSettings.debugMode == 4 || !mDistributionValid || !mView.pDistributionDebug)
        return;
    auto root = mView.pDistributionDebug->getRootVar();
    root["gVXPGDebug"] = output;
    dispatchUpdate(context, mView.pDistributionDebug, uint3(mFrameDim, 1));
}
} // namespace RTPTVXPG
