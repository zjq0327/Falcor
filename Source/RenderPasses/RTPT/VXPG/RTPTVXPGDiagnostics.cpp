#include "RTPTVXPG.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <numeric>
#include <vector>

using namespace Falcor;
namespace RTPTVXPG
{
namespace
{
using Json = Properties::json;
constexpr uint32_t kInvalid = 0xffffffffu;
struct SnapshotNode
{
    float3 lo;
    float mass;
    float3 hi;
    uint32_t compact;
};
static_assert(sizeof(SnapshotNode) == 32);

Json vectorJson(float3 v)
{
    return Json::array({v.x, v.y, v.z});
}
Json vectorJson(uint4 v)
{
    return Json::array({v.x, v.y, v.z, v.w});
}
Json vectorJson(int4 v)
{
    return Json::array({v.x, v.y, v.z, v.w});
}
float3 xyz(float4 v)
{
    return float3(v.x, v.y, v.z);
}
bool finite3(float3 v)
{
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}
float fromBits(uint32_t bits)
{
    float value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

template<typename T>
std::vector<T> snapshotRead(const ref<Buffer>& buffer, uint32_t count)
{
    FALCOR_CHECK(buffer && uint64_t(count) * sizeof(T) <= buffer->getSize(), "VXPG snapshot buffer range is invalid.");
    std::vector<T> result(count);
    if (count)
        buffer->getBlob(result.data(), 0, uint64_t(count) * sizeof(T));
    return result;
}

Json histogramJson(const std::map<uint32_t, uint32_t>& values)
{
    Json result = Json::array();
    for (const auto& [value, count] : values)
        result.push_back(Json::array({value, count}));
    return result;
}

Json depthStatistics(const std::vector<uint32_t>& depths)
{
    std::map<uint32_t, uint32_t> histogram;
    for (uint32_t value : depths)
        ++histogram[value];
    Json result;
    result["depthHistogram"] = histogramJson(histogram);
    result["meanDepth"] = depths.empty() ? 0. : double(std::accumulate(depths.begin(), depths.end(), uint64_t(0))) / depths.size();
    std::vector<uint32_t> sorted = depths;
    std::sort(sorted.begin(), sorted.end());
    result["p95Depth"] = sorted.empty() ? 0u : sorted[(95ull * sorted.size() + 99ull) / 100ull - 1ull];
    result["maxDepth"] = sorted.empty() ? 0u : sorted.back();
    return result;
}
} // namespace

Properties Manager::readTreeSnapshot(const Settings& requested) const
{
    auto unavailable = [](const char* status)
    {
        Json result = {{"version", 2}, {"available", false}, {"status", status}};
        return Properties(std::move(result));
    };
    // This explicit API is opt-in under the existing Diagnostics switch. In
    // particular, a disabled request does not perform even a counter readback.
    if (!requested.detailedDiagnostics || !mSettings.detailedDiagnostics)
        return unavailable("diagnostics_disabled");
    if (!requested.enabled || !mSettings.enabled)
        return unavailable("clustered_vxpg_disabled");
    if (!mReady || !mDistributionValid || !mpScene || !mProposal.pState || !mProposal.pClusterState || !mProposal.pSortA ||
        !mProposal.pCompactIndices || !mProposal.pMass || !mProposal.pCluster || !mProposal.pClusterInfo || !mProposal.pForest ||
        !mProposal.pCompactToLeaf || !mGrid.pCellKeys || !mGrid.pBoundMin || !mGrid.pBoundMax || !mView.pSuperpixelPosition ||
        !mView.pSuperpixelNormal || !mView.pTopTree)
        return unavailable("model_unavailable");
    const auto state = snapshotRead<uint32_t>(mProposal.pState, 32);
    const auto clusterState = snapshotRead<uint32_t>(mProposal.pClusterState, 8);
    if (state[5] != mGeneration || clusterState[6] != mGeneration)
        return unavailable("model_not_published");
    if (state[1] || state[4] || state[11])
        return unavailable("model_invalid");
    const uint32_t count = state[3], geometryCount = std::min(state[2], cellCapacity()), nodeCount = clusterState[4];
    if (count > mSettings.maxVoxels || count > geometryCount || nodeCount > 4ull * mSettings.maxVoxels + 64ull)
        return unavailable("model_range_invalid");
    const auto sorted = snapshotRead<uint2>(mProposal.pSortA, count);
    const auto compact = snapshotRead<uint32_t>(mProposal.pCompactIndices, count);
    const auto mass = snapshotRead<float>(mProposal.pMass, count);
    const auto clusters = snapshotRead<uint32_t>(mProposal.pCluster, count);
    const auto infos = snapshotRead<uint4>(mProposal.pClusterInfo, 32);
    const auto nodes = snapshotRead<SnapshotNode>(mProposal.pForest, nodeCount);
    const auto leafMap = snapshotRead<uint32_t>(mProposal.pCompactToLeaf, count);
    const auto keys = snapshotRead<int4>(mGrid.pCellKeys, geometryCount);
    const auto loBits = snapshotRead<uint4>(mGrid.pBoundMin, geometryCount);
    const auto hiBits = snapshotRead<uint4>(mGrid.pBoundMax, geometryCount);
    std::vector<uint32_t> morton(count), sortedRank(count), depths(count), seen(count, 0);
    Json sortedCompact = Json::array(), sortedKeys = Json::array();
    uint64_t previous = 0;
    for (uint32_t rank = 0; rank < count; ++rank)
    {
        const uint2 code = sorted[rank];
        const uint32_t c = code.x >> 21;
        const uint32_t index = code.y;
        const uint32_t position = code.x & 0x1fffffu;
        if (index >= count || c >= mSettings.clusterCount || seen[index]++ || clusters[index] != c || position > 0x1fffffu)
            return unavailable("sort_mapping_invalid");
        // Stable Radix preserves active-list order for equal combined keys.
        const uint64_t compare = (uint64_t(code.x) << 32) | index;
        if (rank && compare < previous)
            return unavailable("sort_order_invalid");
        previous = compare;
        const uint4 info = infos[c];
        if (rank < info.x || rank - info.x >= info.y)
            return unavailable("cluster_range_invalid");
        morton[index] = position;
        sortedRank[index] = rank;
        sortedCompact.push_back(index);
        sortedKeys.push_back(Json::array({code.x, code.y}));
    }
    Json leaves = Json::array();
    std::vector<std::vector<uint32_t>> clusterDepths(32);
    for (uint32_t index = 0; index < count; ++index)
    {
        const uint32_t cell = compact[index], c = clusters[index];
        if (cell >= geometryCount || c >= mSettings.clusterCount || loBits[cell].w == 0 || keys[cell].w <= 0 || keys[cell].w > 511 ||
            !(mass[index] > 0.f) || !std::isfinite(mass[index]))
            return unavailable("leaf_data_invalid");
        const uint4 info = infos[c];
        const uint32_t leaf = leafMap[index];
        if (info.y == 0 || leaf < info.w || leaf - info.w >= info.y || uint64_t(info.z) + leaf >= nodes.size() ||
            nodes[info.z + leaf].compact != index || sortedRank[index] != info.x + leaf - info.w ||
            nodes[info.z + leaf].mass != mass[index])
            return unavailable("leaf_mapping_invalid");
        uint32_t node = leaf, depth = 0;
        while (node > 1)
        {
            node /= 2;
            ++depth;
        }
        if (node != 1 || depth > 64)
            return unavailable("heap_depth_invalid");
        depths[index] = depth;
        clusterDepths[c].push_back(depth);
        const float size = std::exp2(float(keys[cell].w)) / mSettings.lodSceneScale;
        const float3 localLo(fromBits(loBits[cell].x), fromBits(loBits[cell].y), fromBits(loBits[cell].z));
        const float3 localHi(fromBits(hiBits[cell].x), fromBits(hiBits[cell].y), fromBits(hiBits[cell].z));
        const float3 key(float(keys[cell].x), float(keys[cell].y), float(keys[cell].z));
        const float3 worldLo = mGridMin + (key + localLo) * size, worldHi = mGridMin + (key + localHi) * size;
        if (!finite3(worldLo) || !finite3(worldHi) || worldHi.x <= worldLo.x || worldHi.y <= worldLo.y || worldHi.z <= worldLo.z)
            return unavailable("leaf_bounds_invalid");
        leaves.push_back(
            {{"compact", index},
             {"cell", cell},
             {"cluster", c},
             {"morton", morton[index]},
             {"mass", mass[index]},
             {"worldMin", vectorJson(worldLo)},
             {"worldMax", vectorJson(worldHi)},
             {"cellKey", vectorJson(keys[cell])},
             {"boundMinBits", vectorJson(loBits[cell])},
             {"boundMaxBits", vectorJson(hiBits[cell])},
             {"sortedRank", sortedRank[index]},
             {"depth", depth}}
        );
    }
    Json clusterResults = Json::array();
    std::map<uint32_t, uint32_t> totalDuplicateRuns;
    uint32_t totalUnique = 0, totalDuplicateGroups = 0, totalDuplicateLeaves = 0, totalDuplicateExcess = 0, maxDuplicateRun = 0;
    uint32_t totalClusterLeaves = 0;
    for (uint32_t c = 0; c < mSettings.clusterCount; ++c)
    {
        const uint4 info = infos[c];
        if (uint64_t(info.x) + info.y > count || info.y != clusterDepths[c].size())
            return unavailable("cluster_count_invalid");
        totalClusterLeaves += info.y;
        std::map<uint32_t, uint32_t> duplicates;
        uint32_t unique = 0, duplicateGroups = 0, duplicateLeaves = 0, duplicateExcess = 0, maxRun = 0;
        for (uint32_t first = info.x; first < info.x + info.y;)
        {
            const uint32_t index = sortedCompact[first].get<uint32_t>();
            const uint32_t position = morton[index];
            uint32_t end = first + 1;
            while (end < info.x + info.y && morton[sortedCompact[end].get<uint32_t>()] == position)
                ++end;
            ++unique;
            const uint32_t run = end - first;
            if (run > 1)
            {
                ++duplicates[run];
                ++totalDuplicateRuns[run];
                ++duplicateGroups;
                duplicateLeaves += run;
                duplicateExcess += run - 1;
                maxRun = std::max(maxRun, run);
            }
            first = end;
        }
        Json record = depthStatistics(clusterDepths[c]);
        record["cluster"] = c;
        record["count"] = info.y;
        record["uniqueMorton"] = unique;
        record["duplicateGroups"] = duplicateGroups;
        record["duplicateLeaves"] = duplicateLeaves;
        record["duplicateExcess"] = duplicateExcess;
        record["maxDuplicateRun"] = maxRun;
        record["duplicateRunHistogram"] = histogramJson(duplicates);
        clusterResults.push_back(std::move(record));
        totalUnique += unique;
        totalDuplicateGroups += duplicateGroups;
        totalDuplicateLeaves += duplicateLeaves;
        totalDuplicateExcess += duplicateExcess;
        maxDuplicateRun = std::max(maxDuplicateRun, maxRun);
    }
    if (totalClusterLeaves != count)
        return unavailable("cluster_total_invalid");
    Json totals = depthStatistics(depths);
    totals["count"] = count;
    totals["uniqueMorton"] = totalUnique;
    totals["duplicateGroups"] = totalDuplicateGroups;
    totals["duplicateLeaves"] = totalDuplicateLeaves;
    totals["duplicateExcess"] = totalDuplicateExcess;
    totals["maxDuplicateRun"] = maxDuplicateRun;
    totals["duplicateLeafFraction"] = count ? double(totalDuplicateLeaves) / count : 0.;
    totals["duplicateExcessFraction"] = count ? double(totalDuplicateExcess) / count : 0.;
    totals["duplicateRunHistogram"] = histogramJson(totalDuplicateRuns);
    Json nodeJson = Json::array(), infoJson = Json::array();
    for (const auto& node : nodes)
        nodeJson.push_back({{"lo", vectorJson(node.lo)}, {"mass", node.mass}, {"hi", vectorJson(node.hi)}, {"compact", node.compact}});
    for (uint4 info : infos)
        infoJson.push_back(vectorJson(info));

    const uint2 superpixelDim = (mFrameDim + mSettings.superpixelSize - 1u) / mSettings.superpixelSize;
    const uint32_t rows = superpixelDim.x * superpixelDim.y;
    const auto positions = snapshotRead<float4>(mView.pSuperpixelPosition, rows);
    const auto normals = snapshotRead<float4>(mView.pSuperpixelNormal, rows);
    const auto top = snapshotRead<float>(mView.pTopTree, rows * 64);
    std::vector<uint32_t> validRows;
    for (uint32_t row = 0; row < rows; ++row)
        if (positions[row].w != 0.f && finite3(xyz(positions[row])) && finite3(xyz(normals[row])) && top[row * 64 + 1] > 0.f &&
            std::isfinite(top[row * 64 + 1]))
            validRows.push_back(row);
    Json contexts = Json::array();
    const uint32_t contextCount = uint32_t(std::min<size_t>(64, validRows.size()));
    for (uint32_t i = 0; i < contextCount; ++i)
    {
        const uint32_t row = validRows[(uint64_t(2 * i + 1) * validRows.size()) / (2 * contextCount)];
        const float3 origin = xyz(positions[row]);
        const float3 delta = mLodCamera - (origin + float3(1.e-4f));
        const float distance2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
        const uint32_t level = uint32_t(std::clamp(.5f * std::log2(std::max(distance2, 1.e-10f)), 1.f, 511.f));
        const float sourceSize = std::exp2(float(level)) / mSettings.lodSceneScale;
        if (!(sourceSize > 0.f) || !std::isfinite(sourceSize))
            return unavailable("context_size_invalid");
        Json weights = Json::array();
        for (uint32_t c = 0; c < 32; ++c)
        {
            const float weight = top[row * 64 + 32 + c];
            if (!std::isfinite(weight) || weight < 0.f)
                return unavailable("context_weight_invalid");
            weights.push_back(weight);
        }
        contexts.push_back(
            {{"row", row},
             {"origin", vectorJson(origin)},
             {"normal", vectorJson(xyz(normals[row]))},
             {"sourceSize", sourceSize},
             {"topWeights", std::move(weights)}}
        );
    }
    Json result = {
        {"version", 2},
        {"available", true},
        {"status", "published_snapshot"},
        {"treeType", "Heap"},
        {"sortBackend", "Radix"},
        {"generation", mGeneration},
        {"geometryGeneration", mGeometryGeneration},
        {"activeCount", count},
        {"activeCapacity", mSettings.maxVoxels},
        {"geometryCapacity", cellCapacity()},
        {"clusterCount", mSettings.clusterCount},
        {"gridMin", vectorJson(mGridMin)},
        {"lodCamera", vectorJson(mLodCamera)},
        {"lodSceneScale", mSettings.lodSceneScale},
        {"sortMin", vectorJson(mpScene->getSceneBounds().minPoint)},
        {"sortExtent", vectorJson(mpScene->getSceneBounds().extent())},
        {"leaves", std::move(leaves)},
        {"sortedCompact", std::move(sortedCompact)},
        {"sortedKeys", std::move(sortedKeys)},
        {"tree", {{"nodes", std::move(nodeJson)}, {"clusterInfo", std::move(infoJson)}}},
        {"clusters", std::move(clusterResults)},
        {"totals", std::move(totals)},
        {"contexts", std::move(contexts)},
        {"validContextRows", validRows.size()},
        {"definitions",
         {{"mortonGrouping", "Within each Cluster; equal Morton in different Clusters is not a collision for this tree."},
          {"duplicateLeaves", "All leaves in Morton runs of length >= 2."},
          {"duplicateExcess", "Sum(runLength-1) over duplicate runs."},
          {"depth", "Root-to-real-leaf edges; uniform over leaves, not weighted by queries."},
          {"nodeGeometry", "Published center in lo and radius in hi.x; not raw AABBs."},
          {"bounds", "CPU-expanded production formula; raw cellKey and local bound bits retained for exact GPU replay."},
          {"contexts", "At most 64 evenly spaced valid SPixel rows; sourceSize follows production distance-LOD formula."}}}};
    return Properties(std::move(result));
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
    for (size_t i = 0; i < records.size() / 3; ++i)
        if (records[i * 3].w != 0.f)
            ++counts[i % depth];
    return counts;
}

std::array<uint32_t, 8> Manager::readHistoryCounters() const
{
    std::array<uint32_t, 8> result = {};
    if (mLighting.pHistoryStats && !mResetHistory)
        mLighting.pHistoryStats->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, 8> Manager::readQueryCounters() const
{
    std::array<uint32_t, 8> result = {};
    if (mSettings.detailedDiagnostics && mProposal.pQueryStats)
        mProposal.pQueryStats->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, 16> Manager::readGridCounters() const
{
    std::array<uint32_t, 16> result = {};
    if (mGrid.pGridState)
        mGrid.pGridState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, 16> Manager::readTreeCounters() const
{
    std::array<uint32_t, 16> result = {};
    if (mProposal.pTreeState && mDistributionValid)
        mProposal.pTreeState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, 8> Manager::readClusterCounters() const
{
    std::array<uint32_t, 8> result = {};
    if (mProposal.pClusterState)
        mProposal.pClusterState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t, 32> Manager::readCounters() const
{
    std::array<uint32_t, 32> result = {};
    if (mProposal.pState)
        mProposal.pState->getBlob(result.data(), 0, sizeof(result));
    return result;
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
    for (size_t i = 0; i < keys.size(); ++i)
        if ((bounds.empty() || bounds[i].w != 0) && keys[i].w > 0 && keys[i].w < 64)
            ++counts[keys[i].w];
    for (auto cell : active)
        if (cell < keys.size() && keys[cell].w > 0 && keys[cell].w < 64)
            ++counts[64 + keys[cell].w];
    return counts;
}

void Manager::appendObservationStatistics(Properties& props, uint32_t geometryCount, uint32_t activeCount) const
{
    if (!hasModelDiagnostics() || !mLighting.pCount || !mProposal.pCompactIndices || !mProposal.pMass)
        return;
    const uint32_t cells = std::min(geometryCount, cellCapacity());
    activeCount = std::min(activeCount, mSettings.maxVoxels);
    if (!cells || !activeCount)
        return;
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
    for (uint32_t level = 0; level < 64u; ++level)
    {
        std::vector<uint32_t> counts;
        uint64_t total = 0;
        uint32_t single = 0, low = 0;
        double totalMass = 0., lowMass = 0.;
        for (uint32_t i = 0; i < activeCount; ++i)
        {
            const uint32_t cell = active[i];
            if (cell >= cells || (level != 0 && keys[cell].w != int(level)))
                continue;
            const uint32_t n = observations[cell];
            counts.push_back(n);
            total += n;
            single += n == 1;
            low += n <= 4;
            totalMass += mass[i];
            if (n <= 4)
                lowMass += mass[i];
        }
        if (counts.empty())
            continue;
        std::sort(counts.begin(), counts.end());
        const std::string prefix = level == 0 ? "observation" : "lod" + std::to_string(level) + "Observation";
        props[prefix + "Count"] = total;
        props[prefix + "PerActive"] = double(total) / counts.size();
        props[prefix + "P10"] = counts[(counts.size() - 1) / 10];
        props[prefix + "Median"] = .5 * (double(counts[(counts.size() - 1) / 2]) + counts[counts.size() / 2]);
        props[prefix + "SingleFraction"] = double(single) / counts.size();
        props[prefix + "LowCountFraction"] = double(low) / counts.size();
        props[prefix + "LowCountMassFraction"] = totalMass > 0. ? lowMass / totalMass : 0.;
    }
}

Properties Manager::getTreeSnapshot(const Settings& settings, const RuntimeContext& runtime) const
{
    if (!runtime.enabled || runtime.guidingMode != RTPTVXPG::GuidingMode::VXPG || !settings.enabled)
    {
        Properties result;
        result["version"] = 2u;
        result["available"] = false;
        result["status"] = "VXPG is not enabled and selected";
        return result;
    }
    return readTreeSnapshot(settings);
}

Properties Manager::getStatistics(const Settings& settings, const RuntimeContext& runtime) const
{
    Properties props;
    props["localTreeUpdateEnabled"] = true;
    const auto tree = readTreeCounters();
    props["treeFullBuild"] = tree[0] != 0;
    props["treeDirtyLeaves"] = tree[2];
    props["treeFullBuilds"] = tree[3];
    props["treeLocalUpdates"] = tree[4];
    props["treeGlobalNodesUpdated"] = tree[5];
    props["treeForestNodesUpdated"] = tree[6];
    props["treeTopologyAge"] = tree[7];
    props["treeTopologyValid"] = tree[8] != 0;
    props["treeMembershipChanges"] = tree[9];
    props["treeRebuildReason"] = tree[10];
    props["cameraReuseEnabled"] = true; // Read-only capability; no configurable switch.
    const auto grid = readGridCounters();
    props["historyConfidenceEnabled"] = true;
    props["lodHistoryReuseEnabled"] = true;
    props["incrementalGridEnabled"] = true;
    props["incrementalGridActive"] = true;
    props["gridFreeCells"] = grid[0];
    props["gridInsertedCells"] = grid[3];
    props["gridEvictedCells"] = grid[4];
    props["gridCapacityRejects"] = grid[5];
    props["gridLiveCells"] = grid[6];
    props["gridReusedCellSlots"] = grid[7];
    props["gridDiscoveryRejects"] = grid[8];
    props["lightingHistoryEnabled"] = true; // Read-only capability; no configurable switch.
    const auto history = readHistoryCounters();
    props["lodHistoryBorrowedCells"] = history[4];
    props["lodHistoryBorrowedTotal"] = history[6];
    props["lodHistoryNormalRejects"] = history[5];
    props["historyValidCells"] = history[0];
    props["historyCarriedCells"] = history[1];
    props["historyExpiredCells"] = history[2];
    props["historyUpdatedCells"] = history[3];
    props["selected"] = runtime.guidingMode == RTPTVXPG::GuidingMode::VXPG;
    props["enabled"] = runtime.enabled && settings.enabled;
    props["ready"] = isReady();
    props["generation"] = getGeneration();
    props["estimatedBytes"] = getEstimatedBytes();
    props["allocatedPayloadBytes"] = getPayloadBytes();
    props["sparseGridEnabled"] = true;
    props["effectiveGridOrigin"] = getGridOrigin();
    props["effectiveCellSize"] = getCellSize();
    props["hashCapacity"] = getHashCapacity();
    props["geometryCapacity"] = getGeometryCapacity();
    props["multiLodEnabled"] = true;
    props["multiLodActive"] = true;
    props["effectiveGridMode"] = "Incremental sparse distance LOD";
    props["geometryGeneration"] = getGeometryGeneration();
    props["geometryRebuilds"] = getGeometryRebuilds();
    props["lodLevelLimit"] = getLodLevels();
    props["effectiveBudgetMB"] = getBudgetMiB();
    props["fallbackReason"] = getFallbackReason();
    const bool selectedEnabled = runtime.enabled && runtime.guidingMode == RTPTVXPG::GuidingMode::VXPG && settings.enabled;
    const auto counters = selectedEnabled && isReady() ? readCounters() : std::array<uint32_t, 32>{};
    props["ready"] = runtime.enabled && runtime.guidingMode == RTPTVXPG::GuidingMode::VXPG && settings.enabled && settings.useGuiding &&
                     isReady() && counters[5] == getGeneration();
    if (isReady() && counters[5] == 0)
        props["fallbackReason"] = "No valid voxel distribution; using BSDF";
    if (counters[1] != 0)
        props["fallbackReason"] = "Invalid spatial grid; using BSDF";
    else if (counters[4] != 0)
    {
        if (counters[4] & 16u)
            props["fallbackReason"] = "Superpixel count/scatter mismatch; using BSDF";
        else if (counters[4] & 8u)
            props["fallbackReason"] = "Superpixel prefix exceeds screen capacity; using BSDF";
        else if (counters[4] & 6u)
            props["fallbackReason"] = "Voxel observation statistics overflow; using BSDF";
        else
            props["fallbackReason"] = "Active voxel capacity exceeded; using BSDF";
    }
    else if (counters[11] != 0)
        props["fallbackReason"] = "Invalid/non-finite proposal data; using BSDF";
    props["pairedCacheBytes"] = runtime.pairedCacheBytes;
    props["sharcFrameIndex"] = runtime.sharcFrameIndex;
    props["geometryOverflow"] = counters[1];
    props["occupiedCells"] = grid[6];
    props["geometrySlotSpan"] = counters[2];
    props["activeVoxels"] = counters[3];
    props["distributionOverflow"] = counters[4];
    props["gpuReady"] = counters[5];
    props["invalidSamples"] = counters[11];
    props["gatheredShadingPoints"] = counters[26];
    if (counters[1] == 0 && counters[4] == 0 && counters[5] == getGeneration())
    {
        // Explicit diagnostics query only: never read keys back in the render loop.
        const auto levels = readLodCounts(counters[2], counters[3]);
        uint32_t used = 0;
        for (uint32_t level = 1; level < 64; ++level)
            if (levels[level])
            {
                ++used;
                props["lod" + std::to_string(level) + "Geometry"] = levels[level];
                props["lod" + std::to_string(level) + "Active"] = levels[64 + level];
            }
        props["lodLevelsUsed"] = used;
    }
    props["sharedInjectionActive"] = runtime.sharedTraining;
    props["sharedWithSHARC"] = runtime.sharedWithSHARC;
    props["sharedInjectionStride"] = runtime.trainingStride;
    props["sharedInjectionMaxBounce"] = runtime.sharedTraining ? runtime.trainingBounces : 0u;
    props["discoveryRecordCapacity"] = getDiscoveryRecordCount();
    const bool diagnosticsAvailable = selectedEnabled && settings.detailedDiagnostics && runtime.diagnosticFrameAvailable &&
                                      runtime.diagnosticGeneration == getGeneration();
    const bool modelDiagnosticsAvailable = diagnosticsAvailable && hasModelDiagnostics();
    if (modelDiagnosticsAvailable && runtime.sharedTraining)
    {
        const auto counts = readSharedObservationCounts();
        uint32_t total = 0;
        for (uint32_t bounce = 0; bounce < 32; ++bounce)
        {
            if (bounce < runtime.trainingBounces)
                props["sharedObservationsBounce" + std::to_string(bounce + 1)] = counts[bounce];
            total += counts[bounce];
        }
        props["sharedRecordedObservations"] = total;
    }
    props["detailedDiagnostics"] = settings.detailedDiagnostics;
    props["diagnosticsAvailable"] = diagnosticsAvailable;
    props["diagnosticsStatus"] = !settings.detailedDiagnostics ? "disabled" : diagnosticsAvailable ? "current_frame" : "unavailable";
    props["modelDiagnosticsAvailable"] = modelDiagnosticsAvailable;
    props["modelDiagnosticsStatus"] = !settings.detailedDiagnostics ? "disabled"
                                      : modelDiagnosticsAvailable   ? "current_update"
                                                                    : "unavailable";
    // Missing activity fields mean unavailable, not zero rays/cache hits.
    // Structural and error fields above remain readable in every mode.
    if (diagnosticsAvailable)
    {
        props["diagnosticsFrameCount"] = 1u;
        props["diagnosticsFrameSampleOffset"] = runtime.diagnosticSampleOffset;
        props["diagnosticsFrameSamplesPerPixel"] = runtime.diagnosticSamplesPerPixel;
        props["diagnosticsGeneration"] = runtime.diagnosticGeneration;
        props["guideAttempts"] = counters[6];
        props["guideAccepted"] = counters[7];
        props["guideRejected"] = counters[8];
        props["hypotheticalPGCacheChecks"] = counters[13];
        props["primaryGuideAttempts"] = counters[14];
        props["secondGuideAttempts"] = counters[15];
        props["actualGuideRays"] = counters[19];
        props["brdfRays"] = counters[20];
        props["primaryRays"] = counters[21];
        props["sharedInjectionPaths"] = counters[28];
        props["mainShadowRays"] = counters[23];
        props["brdfCacheHits"] = counters[24];
        // Owner counters span training and rendering in this frame. Full
        // branch steps count both forward sampling and reverse PDF traversal.
        props["guideSelfRejected"] = counters[9];
        props["ownerQueries"] = counters[29];
        props["ownerProbes"] = counters[30];
        props["ownerMaxProbes"] = counters[27];
        props["fullBranchSteps"] = counters[31];
        const auto queries = readQueryCounters();
        props["forwardQueries"] = queries[0];
        props["forwardSteps"] = queries[1];
        props["reverseQueries"] = queries[2];
        props["reverseSteps"] = queries[3];
        props["forwardMaxDepth"] = queries[5];
        props["reverseMaxDepth"] = queries[6];
    }
    if (modelDiagnosticsAvailable)
    {
        props["modelDiagnosticsGeneration"] = getGeneration();
        props["modelDiagnosticsFrameIndex"] = getModelDiagnosticsFrameIndex();
        props["modelDiagnosticsFrameCount"] = 1u;
        props["injectedObservations"] = counters[12];
        props["injectionShadowRays"] = counters[16];
        props["injectionPrimaryRays"] = counters[17];
        props["injectionSecondaryRays"] = counters[18];
        props["positiveThroughputPairs"] = counters[25];
        if (counters[1] == 0 && counters[4] == 0 && counters[5] == getGeneration())
            appendObservationStatistics(props, counters[2], counters[3]);
    }
    const auto cluster = selectedEnabled && isReady() ? readClusterCounters() : std::array<uint32_t, 8>{};
    props["validSuperpixels"] = cluster[0];
    props["nonemptyClusters"] = cluster[1];
    if (modelDiagnosticsAvailable)
    {
        props["visibilityRays"] = cluster[2];
        props["visiblePairs"] = cluster[3];
    }
    props["forestNodes"] = cluster[4];
    props["topRows"] = cluster[5];
    props["clusterReady"] = cluster[6] == getGeneration();
    return props;
}

void Manager::renderDiagnosticsUI(Gui::Widgets& vx, const Settings& settings, const RuntimeContext& runtime, UIState& ui) const
{
    if (runtime.guidingMode != RTPTVXPG::GuidingMode::VXPG)
        vx.text("Not selected; settings preserved.");
    else if (!settings.enabled)
        vx.text("Disabled; using BSDF.");
    else if (!settings.useGuiding)
        vx.text("Sampling disabled; using BSDF.");
    else if (!isReady())
        vx.text("Using BSDF: " + getFallbackReason());
    else
        vx.text("VXPG selected; GPU-valid proposals are used, otherwise BSDF.");
    if (vx.button("Read GPU statistics"))
    {
        const auto s = readCounters();
        const auto c = readClusterCounters();
        ui.statisticsText = "Snapshot generation " + std::to_string(getGeneration()) + ": " +
                            (s[5] == getGeneration() ? "ready" : "BSDF fallback") + ", voxels " + std::to_string(s[3]) + ", clusters " +
                            std::to_string(c[1]) + ", geometry overflow " + std::to_string(s[1]) + ", distribution error flags " +
                            std::to_string(s[4]) + ", invalid " + std::to_string(s[11]);
        if (s[4] & 16u)
            ui.statisticsText += "\nSuperpixel count/scatter mismatch.";
        else if (s[4] & 8u)
            ui.statisticsText += "\nSuperpixel prefix exceeds screen capacity.";
        else if (s[4] & 6u)
            ui.statisticsText += "\nVoxel observation statistics overflow.";
        else if (s[4] & 1u)
            ui.statisticsText += "\nActive voxel capacity exceeded.";
        {
            const auto grid = readGridCounters();
            ui.statisticsText += "\nGrid live/slot span: " + std::to_string(grid[6]) + "/" + std::to_string(s[2]) +
                                 "; inserted/evicted/recycled: " + std::to_string(grid[3]) + "/" + std::to_string(grid[4]) + "/" +
                                 std::to_string(grid[7]) + "; capacity/discovery rejects: " + std::to_string(grid[5]) + "/" +
                                 std::to_string(grid[8]);
        }
        {
            const auto tree = readTreeCounters();
            ui.statisticsText += "\nTree full/local updates: " + std::to_string(tree[3]) + "/" + std::to_string(tree[4]) +
                                 "; dirty leaves/global nodes/forest nodes: " + std::to_string(tree[2]) + "/" + std::to_string(tree[5]) +
                                 "/" + std::to_string(tree[6]);
        }
        {
            const auto history = readHistoryCounters();
            ui.statisticsText += "\nHistory valid/carried/expired/updated: " + std::to_string(history[0]) + "/" +
                                 std::to_string(history[1]) + "/" + std::to_string(history[2]) + "/" + std::to_string(history[3]);
        }
        const bool activityAvailable =
            settings.detailedDiagnostics && runtime.diagnosticFrameAvailable && runtime.diagnosticGeneration == getGeneration();
        if (activityAvailable)
        {
            ui.statisticsText += ", accepted " + std::to_string(s[7]) + "/" + std::to_string(s[6]) + " (one frame, sample offset " +
                                 std::to_string(runtime.diagnosticSampleOffset) + ", spp " +
                                 std::to_string(runtime.diagnosticSamplesPerPixel) + ")";
            ui.statisticsText += "\nSelf rejects " + std::to_string(s[9]) + ", Full branch steps " + std::to_string(s[31]) +
                                 ", owner queries/probes/max " + std::to_string(s[29]) + "/" + std::to_string(s[30]) + "/" +
                                 std::to_string(s[27]);
        }
        else
            ui.statisticsText += ", activity unavailable";
        if (!hasModelDiagnostics())
            ui.statisticsText += ", model activity unavailable";
        if (s[1] == 0 && s[4] == 0 && s[5] == getGeneration())
        {
            const auto levels = readLodCounts(s[2], s[3]);
            for (uint32_t level = 1; level < 64; ++level)
                if (levels[level])
                    ui.statisticsText += "\nLOD " + std::to_string(level) + ": geometry " + std::to_string(levels[level]) + ", active " +
                                         std::to_string(levels[64 + level]);
        }
        if (activityAvailable && hasModelDiagnostics() && s[1] == 0 && s[4] == 0 && s[5] == getGeneration())
        {
            Properties observations;
            appendObservationStatistics(observations, s[2], s[3]);
            if (observations.has("observationMedian"))
                ui.statisticsText += "\nPositive observations per active cell: mean " +
                                     std::to_string(double(observations["observationPerActive"])) + ", median " +
                                     std::to_string(double(observations["observationMedian"])) + ", mass fraction with <=4 observations " +
                                     std::to_string(double(observations["observationLowCountMassFraction"]));
        }
    }
    if (!settings.detailedDiagnostics)
        vx.text("Detailed activity unavailable (disabled); error counters remain enabled.");
    if (!ui.statisticsText.empty())
        vx.text(ui.statisticsText);
    vx.text("Estimated resource MiB: " + std::to_string(double(getEstimatedBytes()) / (1024. * 1024.)));
    if (runtime.pairedCacheBytes != 0)
        vx.text("Paired SHaRC extra MiB: " + std::to_string(double(runtime.pairedCacheBytes) / (1024. * 1024.)));
}

} // namespace RTPTVXPG
