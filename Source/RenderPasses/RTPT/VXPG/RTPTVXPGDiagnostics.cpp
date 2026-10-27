#include "RTPTVXPGDiagnosticData.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <numeric>

using namespace Falcor;
namespace RTPTVXPG::Diagnostics
{
namespace
{
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

DepthStatistics depthStatistics(const std::vector<uint32_t>& depths)
{
    std::map<uint32_t, uint32_t> histogram;
    for (uint32_t value : depths)
        ++histogram[value];
    DepthStatistics result;
    result.histogram = std::move(histogram);
    result.mean = depths.empty() ? 0. : double(std::accumulate(depths.begin(), depths.end(), uint64_t(0))) / depths.size();
    std::vector<uint32_t> sorted = depths;
    std::sort(sorted.begin(), sorted.end());
    result.p95 = sorted.empty() ? 0u : sorted[(95ull * sorted.size() + 99ull) / 100ull - 1ull];
    result.max = sorted.empty() ? 0u : sorted.back();
    return result;
}
} // namespace

std::array<uint32_t, 32> countSharedObservations(const std::vector<float4>& records, uint32_t depth)
{
    std::array<uint32_t, 32> counts = {};
    for (size_t i = 0; i < records.size() / 3; ++i)
        if (records[i * 3].w != 0.f)
            ++counts[i % depth];
    return counts;
}

std::array<uint32_t, 128> countLods(const std::vector<int4>& keys, const std::vector<uint4>& bounds, const std::vector<uint32_t>& active)
{
    std::array<uint32_t, 128> counts = {};
    for (size_t i = 0; i < keys.size(); ++i)
        if ((bounds.empty() || bounds[i].w != 0) && keys[i].w > 0 && keys[i].w < 64)
            ++counts[keys[i].w];
    for (auto cell : active)
        if (cell < keys.size() && keys[cell].w > 0 && keys[cell].w < 64)
            ++counts[64 + keys[cell].w];
    return counts;
}

ObservationLevels summarizeObservations(
    const std::vector<uint32_t>& observations,
    const std::vector<uint32_t>& active,
    const std::vector<float>& mass,
    const std::vector<int4>& keys
)
{
    ObservationLevels levels = {};
    const uint32_t cells = uint32_t(observations.size()), activeCount = uint32_t(active.size());
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
        auto& result = levels[level];
        result.available = true;
        result.count = total;
        result.perActive = double(total) / counts.size();
        result.p10 = counts[(counts.size() - 1) / 10];
        result.median = .5 * (double(counts[(counts.size() - 1) / 2]) + counts[counts.size() / 2]);
        result.singleFraction = double(single) / counts.size();
        result.lowCountFraction = double(low) / counts.size();
        result.lowCountMassFraction = totalMass > 0. ? lowMass / totalMass : 0.;
    }
    return levels;
}

bool analyzeTreeStructure(TreeSnapshot& snapshot)
{
    const auto& metadata = snapshot.metadata;
    const uint32_t count = snapshot.count, geometryCount = snapshot.geometryCount;
    const auto& sorted = snapshot.sorted;
    const auto& compact = snapshot.compact;
    const auto& mass = snapshot.mass;
    const auto& clusters = snapshot.clusters;
    const auto& infos = snapshot.infos;
    const auto& nodes = snapshot.nodes;
    const auto& leafMap = snapshot.leafMap;
    const auto& keys = snapshot.keys;
    const auto& loBits = snapshot.loBits;
    const auto& hiBits = snapshot.hiBits;
    auto unavailable = [&](const char* status)
    {
        snapshot.status = status;
        return false;
    };
    std::vector<uint32_t> morton(count), sortedRank(count), depths(count), seen(count, 0);
    auto& sortedCompact = snapshot.sortedCompact;
    uint64_t previous = 0;
    for (uint32_t rank = 0; rank < count; ++rank)
    {
        const uint2 code = sorted[rank];
        const uint32_t c = code.x >> 21;
        const uint32_t index = code.y;
        const uint32_t position = code.x & 0x1fffffu;
        if (index >= count || c >= metadata.configured.clusterCount || seen[index]++ || clusters[index] != c || position > 0x1fffffu)
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
    }
    auto& leaves = snapshot.leaves;
    std::vector<std::vector<uint32_t>> clusterDepths(32);
    for (uint32_t index = 0; index < count; ++index)
    {
        const uint32_t cell = compact[index], c = clusters[index];
        if (cell >= geometryCount || c >= metadata.configured.clusterCount || loBits[cell].w == 0 || keys[cell].w <= 0 ||
            keys[cell].w > 511 || !(mass[index] > 0.f) || !std::isfinite(mass[index]))
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
        const float size = std::exp2(float(keys[cell].w)) / metadata.configured.lodSceneScale;
        const float3 localLo(fromBits(loBits[cell].x), fromBits(loBits[cell].y), fromBits(loBits[cell].z));
        const float3 localHi(fromBits(hiBits[cell].x), fromBits(hiBits[cell].y), fromBits(hiBits[cell].z));
        const float3 key(float(keys[cell].x), float(keys[cell].y), float(keys[cell].z));
        const float3 worldLo = metadata.gridMin + (key + localLo) * size, worldHi = metadata.gridMin + (key + localHi) * size;
        if (!finite3(worldLo) || !finite3(worldHi) || worldHi.x <= worldLo.x || worldHi.y <= worldLo.y || worldHi.z <= worldLo.z)
            return unavailable("leaf_bounds_invalid");
        leaves.push_back(
            {index, cell, c, morton[index], mass[index], worldLo, worldHi, keys[cell], loBits[cell], hiBits[cell], sortedRank[index], depth}
        );
    }
    auto& clusterResults = snapshot.clusterStatistics;
    std::map<uint32_t, uint32_t> totalDuplicateRuns;
    uint32_t totalUnique = 0, totalDuplicateGroups = 0, totalDuplicateLeaves = 0, totalDuplicateExcess = 0, maxDuplicateRun = 0;
    uint32_t totalClusterLeaves = 0;
    for (uint32_t c = 0; c < metadata.configured.clusterCount; ++c)
    {
        const uint4 info = infos[c];
        if (uint64_t(info.x) + info.y > count || info.y != clusterDepths[c].size())
            return unavailable("cluster_count_invalid");
        totalClusterLeaves += info.y;
        std::map<uint32_t, uint32_t> duplicates;
        uint32_t unique = 0, duplicateGroups = 0, duplicateLeaves = 0, duplicateExcess = 0, maxRun = 0;
        for (uint32_t first = info.x; first < info.x + info.y;)
        {
            const uint32_t index = sortedCompact[first];
            const uint32_t position = morton[index];
            uint32_t end = first + 1;
            while (end < info.x + info.y && morton[sortedCompact[end]] == position)
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
        MortonStatistics record;
        record.depth = depthStatistics(clusterDepths[c]);
        record.cluster = c;
        record.count = info.y;
        record.uniqueMorton = unique;
        record.duplicateGroups = duplicateGroups;
        record.duplicateLeaves = duplicateLeaves;
        record.duplicateExcess = duplicateExcess;
        record.maxDuplicateRun = maxRun;
        record.duplicateRuns = duplicates;
        clusterResults.push_back(std::move(record));
        totalUnique += unique;
        totalDuplicateGroups += duplicateGroups;
        totalDuplicateLeaves += duplicateLeaves;
        totalDuplicateExcess += duplicateExcess;
        maxDuplicateRun = std::max(maxDuplicateRun, maxRun);
    }
    if (totalClusterLeaves != count)
        return unavailable("cluster_total_invalid");
    auto& totals = snapshot.totals;
    totals.depth = depthStatistics(depths);
    totals.count = count;
    totals.uniqueMorton = totalUnique;
    totals.duplicateGroups = totalDuplicateGroups;
    totals.duplicateLeaves = totalDuplicateLeaves;
    totals.duplicateExcess = totalDuplicateExcess;
    totals.maxDuplicateRun = maxDuplicateRun;
    totals.duplicateLeafFraction = count ? double(totalDuplicateLeaves) / count : 0.;
    totals.duplicateExcessFraction = count ? double(totalDuplicateExcess) / count : 0.;
    totals.duplicateRuns = totalDuplicateRuns;
    return true;
}

bool analyzeTreeContexts(TreeSnapshot& snapshot)
{
    const auto& metadata = snapshot.metadata;
    const uint32_t rows = snapshot.rows;
    const auto& positions = snapshot.positions;
    const auto& normals = snapshot.normals;
    const auto& top = snapshot.top;
    auto unavailable = [&](const char* status)
    {
        snapshot.status = status;
        return false;
    };
    std::vector<uint32_t> validRows;
    for (uint32_t row = 0; row < rows; ++row)
        if (positions[row].w != 0.f && finite3(xyz(positions[row])) && finite3(xyz(normals[row])) && top[row * 64 + 1] > 0.f &&
            std::isfinite(top[row * 64 + 1]))
            validRows.push_back(row);
    auto& contexts = snapshot.contexts;
    const uint32_t contextCount = uint32_t(std::min<size_t>(64, validRows.size()));
    for (uint32_t i = 0; i < contextCount; ++i)
    {
        const uint32_t row = validRows[(uint64_t(2 * i + 1) * validRows.size()) / (2 * contextCount)];
        const float3 origin = xyz(positions[row]);
        const float3 delta = metadata.lodCamera - (origin + float3(1.e-4f));
        const float distance2 = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
        const uint32_t level = uint32_t(std::clamp(.5f * std::log2(std::max(distance2, 1.e-10f)), 1.f, 511.f));
        const float sourceSize = std::exp2(float(level)) / metadata.configured.lodSceneScale;
        if (!(sourceSize > 0.f) || !std::isfinite(sourceSize))
            return unavailable("context_size_invalid");
        std::array<float, 32> weights = {};
        for (uint32_t c = 0; c < 32; ++c)
        {
            const float weight = top[row * 64 + 32 + c];
            if (!std::isfinite(weight) || weight < 0.f)
                return unavailable("context_weight_invalid");
            weights[c] = weight;
        }
        contexts.push_back({row, origin, xyz(normals[row]), sourceSize, weights});
    }
    snapshot.validContextRows = validRows.size();
    return true;
}
} // namespace RTPTVXPG::Diagnostics
