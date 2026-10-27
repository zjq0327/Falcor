#pragma once
#include "RTPTVXPG.h"
#include <map>
#include <vector>

namespace RTPTVXPG::Diagnostics
{
// CPU-owned values only. No buffer handles or deferred reads may enter a snapshot.
struct Metadata
{
    Settings requested;
    Settings configured;
    RuntimeContext runtime;
    bool modelSubmitted = false;
    bool modelDiagnostics = false;
    uint32_t generation = 0;
    uint32_t geometryGeneration = 0;
    uint32_t geometryRebuilds = 0;
    uint32_t geometryCapacity = 0;
    uint32_t hashCapacity = 0;
    uint32_t lodLevels = 0;
    uint32_t modelDiagnosticsFrameIndex = 0;
    uint64_t estimatedBytes = 0;
    uint64_t payloadBytes = 0;
    uint64_t discoveryRecordCount = 0;
    Falcor::float3 gridMin = Falcor::float3(0.f);
    Falcor::float3 lodCamera = Falcor::float3(0.f);
    Falcor::float3 sortMin = Falcor::float3(0.f);
    Falcor::float3 sortExtent = Falcor::float3(0.f);
    float cellSize = 0.f;
    std::string fallbackReason;
};

struct ObservationStatistics
{
    bool available = false;
    uint64_t count = 0;
    double perActive = 0.;
    uint32_t p10 = 0;
    double median = 0.;
    double singleFraction = 0.;
    double lowCountFraction = 0.;
    double lowCountMassFraction = 0.;
};
using ObservationLevels = std::array<ObservationStatistics, 64>;

// Preserve the distinct explicit read sets of the Python API and UI button.
enum class StatisticsRequest
{
    Properties,
    Text
};
struct StatisticsSnapshot
{
    Metadata metadata;
    std::array<uint32_t, RTPT_VXPG_STATE_WORDS> state = {};
    std::array<uint32_t, RTPT_VXPG_CLUSTER_WORDS> cluster = {};
    std::array<uint32_t, RTPT_VXPG_GRID_WORDS> grid = {};
    std::array<uint32_t, RTPT_VXPG_TREE_WORDS> tree = {};
    std::array<uint32_t, RTPT_VXPG_HISTORY_WORDS> history = {};
    std::array<uint32_t, RTPT_VXPG_QUERY_WORDS> queries = {};
    std::array<uint32_t, 128> lods = {};
    std::array<uint32_t, 32> sharedObservations = {};
    ObservationLevels observations = {};
};

struct TreeNode
{
    Falcor::float3 lo;
    float mass;
    Falcor::float3 hi;
    uint32_t compact;
};
static_assert(sizeof(TreeNode) == 32);
struct TreeLeaf
{
    uint32_t compact, cell, cluster, morton;
    float mass;
    Falcor::float3 worldMin, worldMax;
    Falcor::int4 cellKey;
    Falcor::uint4 boundMinBits, boundMaxBits;
    uint32_t sortedRank, depth;
};
struct DepthStatistics
{
    std::map<uint32_t, uint32_t> histogram;
    double mean = 0.;
    uint32_t p95 = 0;
    uint32_t max = 0;
};
struct MortonStatistics
{
    DepthStatistics depth;
    uint32_t cluster = 0, count = 0, uniqueMorton = 0;
    uint32_t duplicateGroups = 0, duplicateLeaves = 0, duplicateExcess = 0, maxDuplicateRun = 0;
    double duplicateLeafFraction = 0., duplicateExcessFraction = 0.;
    std::map<uint32_t, uint32_t> duplicateRuns;
};
struct TreeContext
{
    uint32_t row;
    Falcor::float3 origin, normal;
    float sourceSize;
    std::array<float, 32> weights;
};
struct TreeSnapshot
{
    Metadata metadata;
    bool available = false;
    std::string status = "model_unavailable";
    uint32_t count = 0, geometryCount = 0, rows = 0;
    std::vector<Falcor::uint2> sorted;
    std::vector<uint32_t> compact, clusters, leafMap;
    std::vector<float> mass;
    std::vector<Falcor::uint4> infos, loBits, hiBits;
    std::vector<TreeNode> nodes;
    std::vector<Falcor::int4> keys;
    std::vector<Falcor::float4> positions, normals;
    std::vector<float> top;
    std::vector<uint32_t> sortedCompact;
    std::vector<TreeLeaf> leaves;
    std::vector<MortonStatistics> clusterStatistics;
    MortonStatistics totals;
    size_t validContextRows = 0;
    std::vector<TreeContext> contexts;
};

// Pure CPU interpretation. Tree structure validation precedes context readback.
std::array<uint32_t, 32> countSharedObservations(const std::vector<Falcor::float4>& records, uint32_t depth);
std::array<uint32_t, 128> countLods(
    const std::vector<Falcor::int4>& keys,
    const std::vector<Falcor::uint4>& bounds,
    const std::vector<uint32_t>& active
);
ObservationLevels summarizeObservations(
    const std::vector<uint32_t>& observations,
    const std::vector<uint32_t>& active,
    const std::vector<float>& mass,
    const std::vector<Falcor::int4>& keys
);
bool analyzeTreeStructure(TreeSnapshot& snapshot);
bool analyzeTreeContexts(TreeSnapshot& snapshot);

// Presentation consumes captured values only; no Manager or GPU access.
Falcor::Properties statisticsProperties(const StatisticsSnapshot& snapshot);
std::string statisticsText(const StatisticsSnapshot& snapshot);
Falcor::Properties treeProperties(const TreeSnapshot& snapshot);
std::string treeText(const TreeSnapshot& snapshot);
} // namespace RTPTVXPG::Diagnostics
