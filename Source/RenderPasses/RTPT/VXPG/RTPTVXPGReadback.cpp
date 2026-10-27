#include "RTPTVXPGDiagnosticData.h"
#include <algorithm>

using namespace Falcor;
namespace RTPTVXPG
{
namespace
{
template<typename T>
std::vector<T> snapshotRead(const ref<Buffer>& buffer, uint32_t count)
{
    FALCOR_CHECK(buffer && uint64_t(count) * sizeof(T) <= buffer->getSize(), "VXPG snapshot buffer range is invalid.");
    std::vector<T> result(count);
    if (count)
        buffer->getBlob(result.data(), 0, uint64_t(count) * sizeof(T));
    return result;
}
} // namespace

Diagnostics::Metadata Manager::captureDiagnosticMetadata(const Settings& requested, const RuntimeContext& runtime) const
{
    Diagnostics::Metadata metadata;
    metadata.requested = requested;
    metadata.configured = mSettings;
    metadata.runtime = runtime;
    metadata.modelSubmitted = hasSubmittedModel();
    metadata.modelDiagnostics = hasModelDiagnostics();
    metadata.generation = getGeneration();
    metadata.geometryGeneration = getGeometryGeneration();
    metadata.geometryRebuilds = getGeometryRebuilds();
    metadata.geometryCapacity = getGeometryCapacity();
    metadata.hashCapacity = getHashCapacity();
    metadata.lodLevels = getLodLevels();
    metadata.modelDiagnosticsFrameIndex = getModelDiagnosticsFrameIndex();
    metadata.estimatedBytes = getEstimatedBytes();
    metadata.payloadBytes = getPayloadBytes();
    metadata.discoveryRecordCount = getDiscoveryRecordCount();
    metadata.gridMin = getGridOrigin();
    metadata.cellSize = getCellSize();
    metadata.fallbackReason = getFallbackReason();
    metadata.lodCamera = mLodCamera;
    if (mpScene)
    {
        metadata.sortMin = mpScene->getSceneBounds().minPoint;
        metadata.sortExtent = mpScene->getSceneBounds().extent();
    }
    return metadata;
}

std::array<uint32_t, RTPT_VXPG_HISTORY_WORDS> Manager::readHistoryCounters() const
{
    std::array<uint32_t, RTPT_VXPG_HISTORY_WORDS> result = {};
    if (mLighting.pHistoryStats && !mResetHistory)
        mLighting.pHistoryStats->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, RTPT_VXPG_QUERY_WORDS> Manager::readQueryCounters() const
{
    std::array<uint32_t, RTPT_VXPG_QUERY_WORDS> result = {};
    if (mSettings.detailedDiagnostics && mProposal.pQueryStats)
        mProposal.pQueryStats->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, RTPT_VXPG_GRID_WORDS> Manager::readGridCounters() const
{
    std::array<uint32_t, RTPT_VXPG_GRID_WORDS> result = {};
    if (mGrid.pGridState)
        mGrid.pGridState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, RTPT_VXPG_TREE_WORDS> Manager::readTreeCounters() const
{
    std::array<uint32_t, RTPT_VXPG_TREE_WORDS> result = {};
    if (mProposal.pTreeState && mDistributionValid)
        mProposal.pTreeState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, RTPT_VXPG_CLUSTER_WORDS> Manager::readClusterCounters() const
{
    std::array<uint32_t, RTPT_VXPG_CLUSTER_WORDS> result = {};
    if (mProposal.pClusterState)
        mProposal.pClusterState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, RTPT_VXPG_STATE_WORDS> Manager::readCounters() const
{
    std::array<uint32_t, RTPT_VXPG_STATE_WORDS> result = {};
    if (mProposal.pState)
        mProposal.pState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, 32> Manager::readSharedObservationCounts() const
{
    std::array<uint32_t, 32> counts = {};
    if (!mGrid.pDiscovery || !hasModelDiagnostics())
        return counts;
    // Explicit statistics readback only; never part of frame scheduling.
    const uint32_t depth = mSharedTrainingBounces;
    std::vector<float4> records(size_t(getDiscoveryRecordCount()) * 3);
    mGrid.pDiscovery->getBlob(records.data(), 0, records.size() * sizeof(float4));
    return Diagnostics::countSharedObservations(records, depth);
}

std::array<uint32_t, 128> Manager::readLodCounts(uint32_t geometryCount, uint32_t activeCount) const
{
    std::array<uint32_t, 128> counts = {};
    if (!mGrid.pCellKeys || !mProposal.pCompactIndices)
        return counts;
    geometryCount = std::min(geometryCount, cellCapacity());
    activeCount = std::min(activeCount, mSettings.maxVoxels);
    std::vector<int4> keys(geometryCount);
    std::vector<uint32_t> active(activeCount);
    std::vector<uint4> bounds;
    if (geometryCount)
        mGrid.pCellKeys->getBlob(keys.data(), 0, keys.size() * sizeof(int4));
    if (geometryCount)
    {
        bounds.resize(geometryCount);
        mGrid.pBoundMin->getBlob(bounds.data(), 0, bounds.size() * sizeof(uint4));
    }
    if (activeCount)
        mProposal.pCompactIndices->getBlob(active.data(), 0, active.size() * sizeof(uint32_t));
    return Diagnostics::countLods(keys, bounds, active);
}

Diagnostics::ObservationLevels Manager::readObservationStatistics(uint32_t geometryCount, uint32_t activeCount) const
{
    if (!hasModelDiagnostics() || !mLighting.pCount || !mProposal.pCompactIndices || !mProposal.pMass)
        return {};
    const uint32_t cells = std::min(geometryCount, cellCapacity());
    activeCount = std::min(activeCount, mSettings.maxVoxels);
    if (!cells || !activeCount)
        return {};
    // Explicit statistics read only; never invoked by normal render dispatch.
    std::vector<uint32_t> observations(cells), active(activeCount);
    std::vector<float> mass(activeCount);
    mLighting.pCount->getBlob(observations.data(), 0, observations.size() * sizeof(uint32_t));
    mProposal.pCompactIndices->getBlob(active.data(), 0, active.size() * sizeof(uint32_t));
    mProposal.pMass->getBlob(mass.data(), 0, mass.size() * sizeof(float));
    std::vector<int4> keys;
    {
        keys.resize(cells);
        mGrid.pCellKeys->getBlob(keys.data(), 0, keys.size() * sizeof(int4));
    }
    return Diagnostics::summarizeObservations(observations, active, mass, keys);
}

Diagnostics::StatisticsSnapshot Manager::readStatisticsSnapshot(
    const Settings& requested,
    const RuntimeContext& runtime,
    Diagnostics::StatisticsRequest request
) const
{
    Diagnostics::StatisticsSnapshot snapshot;
    snapshot.metadata = captureDiagnosticMetadata(requested, runtime);
    const bool selectedEnabled = runtime.enabled && runtime.guidingMode == GuidingMode::VXPG && requested.enabled;
    const bool activityAvailable =
        requested.detailedDiagnostics && runtime.diagnosticFrameAvailable && runtime.diagnosticGeneration == getGeneration();
    auto validModel = [&]()
    {
        return snapshot.state[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] == 0 && snapshot.state[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] == 0 &&
               snapshot.state[RTPT_VXPG_STATE_READY] == getGeneration();
    };
    auto readLevels = [&]()
    { snapshot.lods = readLodCounts(snapshot.state[RTPT_VXPG_STATE_OCCUPIED], snapshot.state[RTPT_VXPG_STATE_ACTIVE]); };
    auto readObservations = [&]()
    {
        snapshot.observations = readObservationStatistics(snapshot.state[RTPT_VXPG_STATE_OCCUPIED], snapshot.state[RTPT_VXPG_STATE_ACTIVE]);
    };
    if (request == Diagnostics::StatisticsRequest::Text)
    {
        snapshot.state = readCounters();
        snapshot.cluster = readClusterCounters();
        snapshot.grid = readGridCounters();
        snapshot.tree = readTreeCounters();
        snapshot.history = readHistoryCounters();
        if (validModel())
            readLevels();
        if (activityAvailable && hasModelDiagnostics() && validModel())
            readObservations();
    }
    else
    {
        snapshot.tree = readTreeCounters();
        snapshot.grid = readGridCounters();
        snapshot.history = readHistoryCounters();
        if (selectedEnabled && hasSubmittedModel())
            snapshot.state = readCounters();
        if (validModel())
            readLevels();
        const bool diagnosticsAvailable = selectedEnabled && activityAvailable;
        const bool modelDiagnosticsAvailable = diagnosticsAvailable && hasModelDiagnostics();
        if (modelDiagnosticsAvailable && runtime.sharedTraining)
            snapshot.sharedObservations = readSharedObservationCounts();
        if (diagnosticsAvailable)
            snapshot.queries = readQueryCounters();
        if (modelDiagnosticsAvailable && validModel())
            readObservations();
        if (selectedEnabled && hasSubmittedModel())
            snapshot.cluster = readClusterCounters();
    }
    return snapshot;
}

Diagnostics::TreeSnapshot Manager::readTreeSnapshot(const Settings& requested, const RuntimeContext& runtime) const
{
    Diagnostics::TreeSnapshot snapshot;
    snapshot.metadata = captureDiagnosticMetadata(requested, runtime);
    auto unavailable = [&](const char* status)
    {
        snapshot.status = status;
        return snapshot;
    };
    if (!runtime.enabled || runtime.guidingMode != GuidingMode::VXPG || !requested.enabled)
        return unavailable("VXPG is not enabled and selected");
    // This explicit API is opt-in under the existing Diagnostics switch. In
    // particular, a disabled request does not perform even a counter readback.
    if (!requested.detailedDiagnostics || !mSettings.detailedDiagnostics)
        return unavailable("diagnostics_disabled");
    if (!requested.enabled || !mSettings.enabled)
        return unavailable("clustered_vxpg_disabled");
    if (!mModelSubmitted || !mDistributionValid || !mpScene || !mProposal.pState || !mProposal.pClusterState || !mProposal.pSortA ||
        !mProposal.pCompactIndices || !mProposal.pMass || !mProposal.pCluster || !mProposal.pClusterInfo || !mProposal.pForest ||
        !mProposal.pCompactToLeaf || !mGrid.pCellKeys || !mGrid.pBoundMin || !mGrid.pBoundMax || !mView.pSuperpixelPosition ||
        !mView.pSuperpixelNormal || !mView.pTopTree)
        return unavailable("model_unavailable");
    const auto state = snapshotRead<uint32_t>(mProposal.pState, RTPT_VXPG_STATE_WORDS);
    const auto clusterState = snapshotRead<uint32_t>(mProposal.pClusterState, RTPT_VXPG_CLUSTER_WORDS);
    if (state[RTPT_VXPG_STATE_READY] != mGeneration || clusterState[RTPT_VXPG_CLUSTER_READY] != mGeneration)
        return unavailable("model_not_published");
    if (state[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] || state[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] || state[RTPT_VXPG_STATE_INVALID])
        return unavailable("model_invalid");
    const uint32_t count = state[RTPT_VXPG_STATE_ACTIVE], geometryCount = std::min(state[RTPT_VXPG_STATE_OCCUPIED], cellCapacity()),
                   nodeCount = clusterState[RTPT_VXPG_CLUSTER_FOREST_NODES];
    if (count > mSettings.maxVoxels || count > geometryCount || nodeCount > 4ull * mSettings.maxVoxels + 64ull)
        return unavailable("model_range_invalid");
    snapshot.sorted = snapshotRead<uint2>(mProposal.pSortA, count);
    snapshot.compact = snapshotRead<uint32_t>(mProposal.pCompactIndices, count);
    snapshot.mass = snapshotRead<float>(mProposal.pMass, count);
    snapshot.clusters = snapshotRead<uint32_t>(mProposal.pCluster, count);
    snapshot.infos = snapshotRead<uint4>(mProposal.pClusterInfo, 32);
    snapshot.nodes = snapshotRead<Diagnostics::TreeNode>(mProposal.pForest, nodeCount);
    snapshot.leafMap = snapshotRead<uint32_t>(mProposal.pCompactToLeaf, count);
    snapshot.keys = snapshotRead<int4>(mGrid.pCellKeys, geometryCount);
    snapshot.loBits = snapshotRead<uint4>(mGrid.pBoundMin, geometryCount);
    snapshot.hiBits = snapshotRead<uint4>(mGrid.pBoundMax, geometryCount);
    snapshot.count = count;
    snapshot.geometryCount = geometryCount;
    if (!Diagnostics::analyzeTreeStructure(snapshot))
        return snapshot;
    const uint2 superpixelDim = (mFrameDim + mSettings.superpixelSize - 1u) / mSettings.superpixelSize;
    const uint32_t rows = superpixelDim.x * superpixelDim.y;
    snapshot.positions = snapshotRead<float4>(mView.pSuperpixelPosition, rows);
    snapshot.normals = snapshotRead<float4>(mView.pSuperpixelNormal, rows);
    snapshot.top = snapshotRead<float>(mView.pTopTree, rows * 64);
    snapshot.rows = rows;
    if (!Diagnostics::analyzeTreeContexts(snapshot))
        return snapshot;
    snapshot.available = true;
    snapshot.status = "published_snapshot";
    return snapshot;
}
} // namespace RTPTVXPG
