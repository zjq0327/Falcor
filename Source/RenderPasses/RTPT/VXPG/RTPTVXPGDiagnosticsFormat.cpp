#include "RTPTVXPGDiagnosticData.h"
#include <nlohmann/json.hpp>

using namespace Falcor;
namespace RTPTVXPG::Diagnostics
{
namespace
{
using Json = Properties::json;
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
Json histogramJson(const std::map<uint32_t, uint32_t>& values)
{
    Json result = Json::array();
    for (const auto& [value, count] : values)
        result.push_back(Json::array({value, count}));
    return result;
}

Json depthJson(const DepthStatistics& stats)
{
    return {
        {"depthHistogram", histogramJson(stats.histogram)}, {"meanDepth", stats.mean}, {"p95Depth", stats.p95}, {"maxDepth", stats.max}
    };
}
void appendObservationProperties(Properties& props, const ObservationLevels& observations)
{
    for (uint32_t level = 0; level < observations.size(); ++level)
    {
        const auto& value = observations[level];
        if (!value.available)
            continue;
        const std::string prefix = level == 0 ? "observation" : "lod" + std::to_string(level) + "Observation";
        props[prefix + "Count"] = value.count;
        props[prefix + "PerActive"] = value.perActive;
        props[prefix + "P10"] = value.p10;
        props[prefix + "Median"] = value.median;
        props[prefix + "SingleFraction"] = value.singleFraction;
        props[prefix + "LowCountFraction"] = value.lowCountFraction;
        props[prefix + "LowCountMassFraction"] = value.lowCountMassFraction;
    }
}
} // namespace

Properties statisticsProperties(const StatisticsSnapshot& snapshot)
{
    const auto& metadata = snapshot.metadata;
    const auto& settings = metadata.requested;
    const auto& runtime = metadata.runtime;
    Properties props;
    props["localTreeUpdateEnabled"] = true;
    const auto tree = snapshot.tree;
    props["treeFullBuild"] = tree[RTPT_VXPG_TREE_FULL_BUILD] != 0;
    props["treeDirtyLeaves"] = tree[RTPT_VXPG_TREE_DIRTY_LEAVES];
    props["treeFullBuilds"] = tree[RTPT_VXPG_TREE_FULL_BUILDS];
    props["treeLocalUpdates"] = tree[RTPT_VXPG_TREE_LOCAL_UPDATES];
    props["treeGlobalNodesUpdated"] = tree[RTPT_VXPG_TREE_GLOBAL_NODES];
    props["treeForestNodesUpdated"] = tree[RTPT_VXPG_TREE_FOREST_NODES];
    props["treeTopologyAge"] = tree[RTPT_VXPG_TREE_TOPOLOGY_AGE];
    props["treeTopologyValid"] = tree[RTPT_VXPG_TREE_TOPOLOGY_VALID] != 0;
    props["treeMembershipChanges"] = tree[RTPT_VXPG_TREE_MEMBERSHIP_CHANGES];
    props["treeRebuildReason"] = tree[RTPT_VXPG_TREE_REBUILD_REASON];
    props["cameraReuseEnabled"] = true; // Read-only capability; no configurable switch.
    const auto grid = snapshot.grid;
    props["historyConfidenceEnabled"] = true;
    props["lodHistoryReuseEnabled"] = true;
    props["incrementalGridEnabled"] = true;
    props["incrementalGridActive"] = true;
    props["gridFreeCells"] = grid[RTPT_VXPG_GRID_FREE];
    props["gridInsertedCells"] = grid[RTPT_VXPG_GRID_INSERTED];
    props["gridEvictedCells"] = grid[RTPT_VXPG_GRID_EVICTED];
    props["gridCapacityRejects"] = grid[RTPT_VXPG_GRID_CAPACITY_REJECTS];
    props["gridLiveCells"] = grid[RTPT_VXPG_GRID_LIVE];
    props["gridReusedCellSlots"] = grid[RTPT_VXPG_GRID_REUSED];
    props["gridDiscoveryRejects"] = grid[RTPT_VXPG_GRID_DISCOVERY_REJECTS];
    props["lightingHistoryEnabled"] = true; // Read-only capability; no configurable switch.
    const auto history = snapshot.history;
    props["lodHistoryBorrowedCells"] = history[RTPT_VXPG_HISTORY_BORROWED];
    props["lodHistoryBorrowedTotal"] = history[RTPT_VXPG_HISTORY_BORROWED_TOTAL];
    props["lodHistoryNormalRejects"] = history[RTPT_VXPG_HISTORY_NORMAL_REJECTS];
    props["historyValidCells"] = history[RTPT_VXPG_HISTORY_VALID];
    props["historyCarriedCells"] = history[RTPT_VXPG_HISTORY_CARRIED];
    props["historyExpiredCells"] = history[RTPT_VXPG_HISTORY_EXPIRED];
    props["historyUpdatedCells"] = history[RTPT_VXPG_HISTORY_UPDATED];
    props["selected"] = runtime.guidingMode == RTPTVXPG::GuidingMode::VXPG;
    props["enabled"] = runtime.enabled && settings.enabled;
    props["ready"] = metadata.modelSubmitted;
    props["generation"] = metadata.generation;
    props["estimatedBytes"] = metadata.estimatedBytes;
    props["allocatedPayloadBytes"] = metadata.payloadBytes;
    props["sparseGridEnabled"] = true;
    props["effectiveGridOrigin"] = metadata.gridMin;
    props["effectiveCellSize"] = metadata.cellSize;
    props["hashCapacity"] = metadata.hashCapacity;
    props["geometryCapacity"] = metadata.geometryCapacity;
    props["multiLodEnabled"] = true;
    props["multiLodActive"] = true;
    props["effectiveGridMode"] = "Incremental sparse distance LOD";
    props["geometryGeneration"] = metadata.geometryGeneration;
    props["geometryRebuilds"] = metadata.geometryRebuilds;
    props["lodLevelLimit"] = metadata.lodLevels;
    props["effectiveBudgetMB"] = metadata.configured.lodBudgetMiB;
    props["fallbackReason"] = metadata.fallbackReason;
    const bool selectedEnabled = runtime.enabled && runtime.guidingMode == RTPTVXPG::GuidingMode::VXPG && settings.enabled;
    const auto counters = selectedEnabled && metadata.modelSubmitted ? snapshot.state : std::array<uint32_t, RTPT_VXPG_STATE_WORDS>{};
    props["ready"] = runtime.enabled && runtime.guidingMode == RTPTVXPG::GuidingMode::VXPG && settings.enabled && settings.useGuiding &&
                     metadata.modelSubmitted && counters[RTPT_VXPG_STATE_READY] == metadata.generation;
    if (metadata.modelSubmitted && counters[RTPT_VXPG_STATE_READY] == 0)
        props["fallbackReason"] = "No valid voxel distribution; using BSDF";
    if (counters[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0)
        props["fallbackReason"] = "Invalid spatial grid; using BSDF";
    else if (counters[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] != 0)
    {
        if (counters[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] & RTPT_VXPG_OVERFLOW_SCREEN_SCATTER)
            props["fallbackReason"] = "Superpixel count/scatter mismatch; using BSDF";
        else if (counters[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] & RTPT_VXPG_OVERFLOW_SCREEN_PREFIX)
            props["fallbackReason"] = "Superpixel prefix exceeds screen capacity; using BSDF";
        else if (counters[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] & RTPT_VXPG_OVERFLOW_OBSERVATION)
            props["fallbackReason"] = "Voxel observation statistics overflow; using BSDF";
        else
            props["fallbackReason"] = "Active voxel capacity exceeded; using BSDF";
    }
    else if (counters[RTPT_VXPG_STATE_INVALID] != 0)
        props["fallbackReason"] = "Invalid/non-finite proposal data; using BSDF";
    props["pairedCacheBytes"] = runtime.pairedCacheBytes;
    props["sharcFrameIndex"] = runtime.sharcFrameIndex;
    props["geometryOverflow"] = counters[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW];
    props["occupiedCells"] = grid[RTPT_VXPG_GRID_LIVE];
    props["geometrySlotSpan"] = counters[RTPT_VXPG_STATE_OCCUPIED];
    props["activeVoxels"] = counters[RTPT_VXPG_STATE_ACTIVE];
    props["distributionOverflow"] = counters[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW];
    props["gpuReady"] = counters[RTPT_VXPG_STATE_READY];
    props["invalidSamples"] = counters[RTPT_VXPG_STATE_INVALID];
    props["gatheredShadingPoints"] = counters[RTPT_VXPG_STATE_GATHERED_POINTS];
    if (counters[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] == 0 && counters[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] == 0 &&
        counters[RTPT_VXPG_STATE_READY] == metadata.generation)
    {
        // Explicit diagnostics query only: never read keys back in the render loop.
        const auto levels = snapshot.lods;
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
    props["discoveryRecordCapacity"] = metadata.discoveryRecordCount;
    const bool diagnosticsAvailable = selectedEnabled && settings.detailedDiagnostics && runtime.diagnosticFrameAvailable &&
                                      runtime.diagnosticGeneration == metadata.generation;
    const bool modelDiagnosticsAvailable = diagnosticsAvailable && metadata.modelDiagnostics;
    if (modelDiagnosticsAvailable && runtime.sharedTraining)
    {
        const auto counts = snapshot.sharedObservations;
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
        props["guideAttempts"] = counters[RTPT_VXPG_STATE_ATTEMPTS];
        props["guideAccepted"] = counters[RTPT_VXPG_STATE_ACCEPTED];
        props["guideRejected"] = counters[RTPT_VXPG_STATE_REJECTED];
        props["hypotheticalPGCacheChecks"] = counters[RTPT_VXPG_STATE_PG_CACHE_CHECKS];
        props["primaryGuideAttempts"] = counters[RTPT_VXPG_STATE_PRIMARY_ATTEMPTS];
        props["secondGuideAttempts"] = counters[RTPT_VXPG_STATE_SECOND_ATTEMPTS];
        props["actualGuideRays"] = counters[RTPT_VXPG_STATE_GUIDE_RAYS];
        props["brdfRays"] = counters[RTPT_VXPG_STATE_BRDF_RAYS];
        props["primaryRays"] = counters[RTPT_VXPG_STATE_PRIMARY_RAYS];
        props["sharedInjectionPaths"] = counters[RTPT_VXPG_STATE_SHARED_PATHS];
        props["mainShadowRays"] = counters[RTPT_VXPG_STATE_MAIN_SHADOW];
        props["brdfCacheHits"] = counters[RTPT_VXPG_STATE_BRDF_CACHE_HITS];
        // Owner counters span training and rendering in this frame. Full
        // branch steps count both forward sampling and reverse PDF traversal.
        props["guideSelfRejected"] = counters[RTPT_VXPG_STATE_SELF_REJECTED];
        props["ownerQueries"] = counters[RTPT_VXPG_STATE_OWNER_QUERIES];
        props["ownerProbes"] = counters[RTPT_VXPG_STATE_OWNER_PROBES];
        props["ownerMaxProbes"] = counters[RTPT_VXPG_STATE_OWNER_MAX_PROBES];
        props["fullBranchSteps"] = counters[RTPT_VXPG_STATE_FULL_BRANCH_STEPS];
        const auto queries = snapshot.queries;
        props["forwardQueries"] = queries[RTPT_VXPG_QUERY_FORWARD_COUNT];
        props["forwardSteps"] = queries[RTPT_VXPG_QUERY_FORWARD_STEPS];
        props["reverseQueries"] = queries[RTPT_VXPG_QUERY_REVERSE_COUNT];
        props["reverseSteps"] = queries[RTPT_VXPG_QUERY_REVERSE_STEPS];
        props["forwardMaxDepth"] = queries[RTPT_VXPG_QUERY_FORWARD_MAX_DEPTH];
        props["reverseMaxDepth"] = queries[RTPT_VXPG_QUERY_REVERSE_MAX_DEPTH];
    }
    if (modelDiagnosticsAvailable)
    {
        props["modelDiagnosticsGeneration"] = metadata.generation;
        props["modelDiagnosticsFrameIndex"] = metadata.modelDiagnosticsFrameIndex;
        props["modelDiagnosticsFrameCount"] = 1u;
        props["injectedObservations"] = counters[RTPT_VXPG_STATE_INJECTED];
        props["injectionShadowRays"] = counters[RTPT_VXPG_STATE_INJECT_SHADOW];
        props["injectionPrimaryRays"] = counters[RTPT_VXPG_STATE_INJECT_PRIMARY];
        props["injectionSecondaryRays"] = counters[RTPT_VXPG_STATE_INJECT_SECONDARY];
        props["positiveThroughputPairs"] = counters[RTPT_VXPG_STATE_POSITIVE_PAIRS];
        if (counters[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] == 0 && counters[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] == 0 &&
            counters[RTPT_VXPG_STATE_READY] == metadata.generation)
            appendObservationProperties(props, snapshot.observations);
    }
    const auto cluster = selectedEnabled && metadata.modelSubmitted ? snapshot.cluster : std::array<uint32_t, RTPT_VXPG_CLUSTER_WORDS>{};
    props["validSuperpixels"] = cluster[RTPT_VXPG_CLUSTER_VALID_SUPERPIXELS];
    props["nonemptyClusters"] = cluster[RTPT_VXPG_CLUSTER_NONEMPTY];
    if (modelDiagnosticsAvailable)
    {
        props["visibilityRays"] = cluster[RTPT_VXPG_CLUSTER_VISIBILITY_RAYS];
        props["visiblePairs"] = cluster[RTPT_VXPG_CLUSTER_VISIBLE_PAIRS];
    }
    props["forestNodes"] = cluster[RTPT_VXPG_CLUSTER_FOREST_NODES];
    props["topRows"] = cluster[RTPT_VXPG_CLUSTER_TOP_ROWS];
    props["clusterReady"] = cluster[RTPT_VXPG_CLUSTER_READY] == metadata.generation;
    return props;
}

std::string statisticsText(const StatisticsSnapshot& snapshot)
{
    const auto& metadata = snapshot.metadata;
    const auto& settings = metadata.requested;
    const auto& runtime = metadata.runtime;
    std::string text;
    const auto s = snapshot.state;
    const auto c = snapshot.cluster;
    text = "Snapshot generation " + std::to_string(metadata.generation) + ": " +
           (s[RTPT_VXPG_STATE_READY] == metadata.generation ? "ready" : "BSDF fallback") + ", voxels " +
           std::to_string(s[RTPT_VXPG_STATE_ACTIVE]) + ", clusters " + std::to_string(c[RTPT_VXPG_CLUSTER_NONEMPTY]) +
           ", geometry overflow " + std::to_string(s[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW]) + ", distribution error flags " +
           std::to_string(s[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW]) + ", invalid " + std::to_string(s[RTPT_VXPG_STATE_INVALID]);
    if (s[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] & RTPT_VXPG_OVERFLOW_SCREEN_SCATTER)
        text += "\nSuperpixel count/scatter mismatch.";
    else if (s[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] & RTPT_VXPG_OVERFLOW_SCREEN_PREFIX)
        text += "\nSuperpixel prefix exceeds screen capacity.";
    else if (s[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] & RTPT_VXPG_OVERFLOW_OBSERVATION)
        text += "\nVoxel observation statistics overflow.";
    else if (s[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] & RTPT_VXPG_OVERFLOW_ACTIVE_CAPACITY)
        text += "\nActive voxel capacity exceeded.";
    {
        const auto grid = snapshot.grid;
        text += "\nGrid live/slot span: " + std::to_string(grid[RTPT_VXPG_GRID_LIVE]) + "/" + std::to_string(s[RTPT_VXPG_STATE_OCCUPIED]) +
                "; inserted/evicted/recycled: " + std::to_string(grid[RTPT_VXPG_GRID_INSERTED]) + "/" +
                std::to_string(grid[RTPT_VXPG_GRID_EVICTED]) + "/" + std::to_string(grid[RTPT_VXPG_GRID_REUSED]) +
                "; capacity/discovery rejects: " + std::to_string(grid[RTPT_VXPG_GRID_CAPACITY_REJECTS]) + "/" +
                std::to_string(grid[RTPT_VXPG_GRID_DISCOVERY_REJECTS]);
    }
    {
        const auto tree = snapshot.tree;
        text += "\nTree full/local updates: " + std::to_string(tree[RTPT_VXPG_TREE_FULL_BUILDS]) + "/" +
                std::to_string(tree[RTPT_VXPG_TREE_LOCAL_UPDATES]) +
                "; dirty leaves/global nodes/forest nodes: " + std::to_string(tree[RTPT_VXPG_TREE_DIRTY_LEAVES]) + "/" +
                std::to_string(tree[RTPT_VXPG_TREE_GLOBAL_NODES]) + "/" + std::to_string(tree[RTPT_VXPG_TREE_FOREST_NODES]);
    }
    {
        const auto history = snapshot.history;
        text += "\nHistory valid/carried/expired/updated: " + std::to_string(history[RTPT_VXPG_HISTORY_VALID]) + "/" +
                std::to_string(history[RTPT_VXPG_HISTORY_CARRIED]) + "/" + std::to_string(history[RTPT_VXPG_HISTORY_EXPIRED]) + "/" +
                std::to_string(history[RTPT_VXPG_HISTORY_UPDATED]);
    }
    const bool activityAvailable =
        settings.detailedDiagnostics && runtime.diagnosticFrameAvailable && runtime.diagnosticGeneration == metadata.generation;
    if (activityAvailable)
    {
        text += ", accepted " + std::to_string(s[RTPT_VXPG_STATE_ACCEPTED]) + "/" + std::to_string(s[RTPT_VXPG_STATE_ATTEMPTS]) +
                " (one frame, sample offset " + std::to_string(runtime.diagnosticSampleOffset) + ", spp " +
                std::to_string(runtime.diagnosticSamplesPerPixel) + ")";
        text += "\nSelf rejects " + std::to_string(s[RTPT_VXPG_STATE_SELF_REJECTED]) + ", Full branch steps " +
                std::to_string(s[RTPT_VXPG_STATE_FULL_BRANCH_STEPS]) + ", owner queries/probes/max " +
                std::to_string(s[RTPT_VXPG_STATE_OWNER_QUERIES]) + "/" + std::to_string(s[RTPT_VXPG_STATE_OWNER_PROBES]) + "/" +
                std::to_string(s[RTPT_VXPG_STATE_OWNER_MAX_PROBES]);
    }
    else
        text += ", activity unavailable";
    if (!metadata.modelDiagnostics)
        text += ", model activity unavailable";
    if (s[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] == 0 && s[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] == 0 &&
        s[RTPT_VXPG_STATE_READY] == metadata.generation)
    {
        const auto levels = snapshot.lods;
        for (uint32_t level = 1; level < 64; ++level)
            if (levels[level])
                text += "\nLOD " + std::to_string(level) + ": geometry " + std::to_string(levels[level]) + ", active " +
                        std::to_string(levels[64 + level]);
    }
    if (activityAvailable && metadata.modelDiagnostics && s[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] == 0 &&
        s[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] == 0 && s[RTPT_VXPG_STATE_READY] == metadata.generation)
    {
        const auto& observation = snapshot.observations[0];
        if (observation.available)
            text += "\nPositive observations per active cell: mean " + std::to_string(observation.perActive) + ", median " +
                    std::to_string(observation.median) + ", mass fraction with <=4 observations " +
                    std::to_string(observation.lowCountMassFraction);
    }
    return text;
}

Properties treeProperties(const TreeSnapshot& snapshot)
{
    if (!snapshot.available)
    {
        if (snapshot.status == "VXPG is not enabled and selected")
        {
            Properties result;
            result["version"] = 2u;
            result["available"] = false;
            result["status"] = snapshot.status;
            return result;
        }
        return Properties(Json{{"version", 2}, {"available", false}, {"status", snapshot.status}});
    }
    const auto& metadata = snapshot.metadata;
    const uint32_t count = snapshot.count;
    Json sortedCompact = Json::array(), sortedKeys = Json::array(), leaves = Json::array(), clusterResults = Json::array(),
         contexts = Json::array();
    for (uint32_t index : snapshot.sortedCompact)
        sortedCompact.push_back(index);
    for (const auto code : snapshot.sorted)
        sortedKeys.push_back(Json::array({code.x, code.y}));
    for (const auto& leaf : snapshot.leaves)
        leaves.push_back(
            {{"compact", leaf.compact},
             {"cell", leaf.cell},
             {"cluster", leaf.cluster},
             {"morton", leaf.morton},
             {"mass", leaf.mass},
             {"worldMin", vectorJson(leaf.worldMin)},
             {"worldMax", vectorJson(leaf.worldMax)},
             {"cellKey", vectorJson(leaf.cellKey)},
             {"boundMinBits", vectorJson(leaf.boundMinBits)},
             {"boundMaxBits", vectorJson(leaf.boundMaxBits)},
             {"sortedRank", leaf.sortedRank},
             {"depth", leaf.depth}}
        );
    for (const auto& stats : snapshot.clusterStatistics)
    {
        Json record = depthJson(stats.depth);
        record["cluster"] = stats.cluster;
        record["count"] = stats.count;
        record["uniqueMorton"] = stats.uniqueMorton;
        record["duplicateGroups"] = stats.duplicateGroups;
        record["duplicateLeaves"] = stats.duplicateLeaves;
        record["duplicateExcess"] = stats.duplicateExcess;
        record["maxDuplicateRun"] = stats.maxDuplicateRun;
        record["duplicateRunHistogram"] = histogramJson(stats.duplicateRuns);
        clusterResults.push_back(std::move(record));
    }
    const auto& stats = snapshot.totals;
    Json totals = depthJson(stats.depth);
    totals["count"] = stats.count;
    totals["uniqueMorton"] = stats.uniqueMorton;
    totals["duplicateGroups"] = stats.duplicateGroups;
    totals["duplicateLeaves"] = stats.duplicateLeaves;
    totals["duplicateExcess"] = stats.duplicateExcess;
    totals["maxDuplicateRun"] = stats.maxDuplicateRun;
    totals["duplicateLeafFraction"] = stats.duplicateLeafFraction;
    totals["duplicateExcessFraction"] = stats.duplicateExcessFraction;
    totals["duplicateRunHistogram"] = histogramJson(stats.duplicateRuns);
    Json nodeJson = Json::array(), infoJson = Json::array();
    for (const auto& node : snapshot.nodes)
        nodeJson.push_back({{"lo", vectorJson(node.lo)}, {"mass", node.mass}, {"hi", vectorJson(node.hi)}, {"compact", node.compact}});
    for (uint4 info : snapshot.infos)
        infoJson.push_back(vectorJson(info));
    for (const auto& context : snapshot.contexts)
    {
        Json weights = Json::array();
        for (float weight : context.weights)
            weights.push_back(weight);
        contexts.push_back(
            {{"row", context.row},
             {"origin", vectorJson(context.origin)},
             {"normal", vectorJson(context.normal)},
             {"sourceSize", context.sourceSize},
             {"topWeights", std::move(weights)}}
        );
    }
    Json result = {
        {"version", 2},
        {"available", true},
        {"status", "published_snapshot"},
        {"treeType", "Heap"},
        {"sortBackend", "Radix"},
        {"generation", metadata.generation},
        {"geometryGeneration", metadata.geometryGeneration},
        {"activeCount", count},
        {"activeCapacity", metadata.configured.maxVoxels},
        {"geometryCapacity", metadata.geometryCapacity},
        {"clusterCount", metadata.configured.clusterCount},
        {"gridMin", vectorJson(metadata.gridMin)},
        {"lodCamera", vectorJson(metadata.lodCamera)},
        {"lodSceneScale", metadata.configured.lodSceneScale},
        {"sortMin", vectorJson(metadata.sortMin)},
        {"sortExtent", vectorJson(metadata.sortExtent)},
        {"leaves", std::move(leaves)},
        {"sortedCompact", std::move(sortedCompact)},
        {"sortedKeys", std::move(sortedKeys)},
        {"tree", {{"nodes", std::move(nodeJson)}, {"clusterInfo", std::move(infoJson)}}},
        {"clusters", std::move(clusterResults)},
        {"totals", std::move(totals)},
        {"contexts", std::move(contexts)},
        {"validContextRows", snapshot.validContextRows},
        {"definitions",
         {{"mortonGrouping", "Within each Cluster; equal Morton in different Clusters is not a collision for this tree."},
          {"duplicateLeaves", "All leaves in Morton runs of length >= 2."},
          {"duplicateExcess", "Sum(runLength-1) over duplicate runs."},
          {"depth", "Root-to-real-leaf edges; uniform over leaves, not weighted by queries."},
          {"nodeGeometry", "Published center in lo and radius in hi.x; not raw AABBs."},
          {"bounds", "CPU-expanded production formula; raw cellKey and local bound bits retained for exact GPU replay."},
          {"contexts", "At most 64 evenly spaced valid SPixel rows; sourceSize follows production distance-LOD formula."}}}
    };
    return Properties(std::move(result));
}

std::string treeText(const TreeSnapshot& snapshot)
{
    if (!snapshot.available)
        return "Tree snapshot unavailable: " + snapshot.status;
    const auto& totals = snapshot.totals;
    return "Snapshot generation " + std::to_string(snapshot.metadata.generation) + ": active " + std::to_string(snapshot.count) +
           ", leaves in duplicate Morton groups " + std::to_string(totals.duplicateLeaves) + ", excess duplicate keys " +
           std::to_string(totals.duplicateExcess) + "\nLeaf depth mean/p95/max: " + std::to_string(totals.depth.mean) + "/" +
           std::to_string(totals.depth.p95) + "/" + std::to_string(totals.depth.max);
}
} // namespace RTPTVXPG::Diagnostics
