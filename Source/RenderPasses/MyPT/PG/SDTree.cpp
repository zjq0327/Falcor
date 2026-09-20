/***************************************************************************
 # Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
 # SPDX-License-Identifier: BSD-3-Clause
 ***************************************************************************/
#include "SDTree.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <stdexcept>

namespace Falcor::PG
{
namespace
{
constexpr float kPi = 3.14159265358979323846f;
constexpr float kInvFourPi = 1.f / (4.f * kPi);
constexpr float kOneBelow = 0.999999940395355224609375f;

float unit(float value) { return std::clamp(value, 0.f, kOneBelow); }
std::array<float, 2> canonical(const std::array<float, 3>& direction)
{
    float phi = std::atan2(direction[1], direction[0]) / (2.f * kPi);
    if (phi < 0.f) phi += 1.f;
    return {unit((direction[2] + 1.f) * .5f), unit(phi)};
}
std::array<float, 3> fromCanonical(const std::array<float, 2>& uv)
{
    const float z = 2.f * uv[0] - 1.f;
    const float r = std::sqrt(std::max(0.f, 1.f - z * z));
    const float phi = 2.f * kPi * uv[1];
    return {r * std::cos(phi), r * std::sin(phi), z};
}
uint32_t quadrant(std::array<float, 2>& uv)
{
    const uint32_t x = uv[0] >= .5f ? 1u : 0u;
    const uint32_t y = uv[1] >= .5f ? 1u : 0u;
    uv = {unit(2.f * uv[0] - float(x)), unit(2.f * uv[1] - float(y))};
    return x + 2u * y;
}
float mass(const DirectionalNode& node)
{
    return (node.weights[0] + node.weights[1]) + (node.weights[2] + node.weights[3]);
}
uint64_t budgetBytes(const TreeData& read, const TreeData& build)
{
    // One GPU allocation and one conservatively sized upload/readback counterpart.
    // Host std::vectors are deliberately not reported as GPU memory.
    return 2u * (read.nodeBytes() + build.nodeBytes() + build.statisticsBytes());
}
uint32_t leafCount(const TreeData& tree)
{
    return uint32_t(std::count_if(tree.spatial.begin(), tree.spatial.end(),
        [](const SpatialNode& n) { return n.childBase == kInvalidNode; }));
}
} // namespace

uint64_t TreeData::nodeBytes() const
{
    return spatial.size() * sizeof(SpatialNode) + directional.size() * sizeof(DirectionalNode);
}
uint64_t TreeData::statisticsBytes() const
{
    return spatial.size() * sizeof(uint32_t) + directional.size() * 4u * sizeof(float);
}

SDTree::SDTree() { reset({}); }

void SDTree::reset(const Bounds& bounds, const Config& config)
{
    mBounds = bounds;
    for (uint32_t axis = 0; axis < 3; ++axis)
    {
        if (!std::isfinite(bounds.min[axis]) || !std::isfinite(bounds.max[axis]))
            throw std::invalid_argument("PG scene bounds must be finite");
        if (!(mBounds.max[axis] > mBounds.min[axis]))
        {
            const float midpoint = .5f * mBounds.min[axis] + .5f * mBounds.max[axis];
            const float extent = std::max(1e-4f, std::abs(midpoint) * 1e-5f);
            mBounds.min[axis] = midpoint - extent;
            mBounds.max[axis] = midpoint + extent;
        }
    }
    mConfig = config;
    mConfig.maxSpatialDepth = std::clamp(config.maxSpatialDepth, 1u, 30u);
    // float sphere coordinates cannot reliably address indefinitely small bins.
    mConfig.maxDirectionalDepth = std::clamp(config.maxDirectionalDepth, 1u, 16u);
    if (!std::isfinite(mConfig.directionalThreshold) || mConfig.directionalThreshold <= 0.f)
        throw std::invalid_argument("PG directional threshold must be finite and positive");
    mConfig.directionalThreshold = std::min(mConfig.directionalThreshold, 1.f);
    mConfig.spatialThreshold = std::max(1u, mConfig.spatialThreshold);
    mRead = TreeData{{SpatialNode{}}, {DirectionalNode{}}};
    mBuild = mRead;
    mStatistics = {};
    if (budgetBytes(mRead, mBuild) > mConfig.memoryBudgetBytes)
        throw std::invalid_argument("PG tree memory budget is smaller than bootstrap storage");
    updateStatistics();
}

bool SDTree::finalizeEpoch(const std::vector<float>& quadrantWeights, const std::vector<uint32_t>& spatialCounts,
                          uint32_t epoch, bool continueTraining)
{
    if (quadrantWeights.size() != mBuild.directional.size() * 4u || spatialCounts.size() != mBuild.spatial.size())
        throw std::invalid_argument("PG epoch readback sizes do not match build topology");
    mStatistics.spatialSplits = 0;
    mStatistics.directionalSplits = 0;
    mStatistics.budgetLimited = false;
    uint64_t epochSamples = 0;
    for (size_t i = 0; i < spatialCounts.size(); ++i)
        if (mBuild.spatial[i].childBase == kInvalidNode) epochSamples += spatialCounts[i];
    mStatistics.samples += epochSamples;
    if (epochSamples == 0)
    {
        clearBuildStatistics();
        updateStatistics();
        return false;
    }

    // Double-precision temporary masses prevent overflow while normalizing a
    // tree containing several individually finite, large training samples.
    // GPU parent sums are not trusted as leaf samples and cannot poison this.
    std::vector<std::array<double, 4>> sums(mBuild.directional.size());
    for (const auto& spatial : mBuild.spatial)
    {
        if (spatial.childBase != kInvalidNode) continue;
        for (uint32_t i = spatial.directionalEnd; i-- > spatial.directionalRoot;)
        {
            for (uint32_t q = 0; q < 4; ++q)
            {
                const uint32_t child = mBuild.directional[i].children[q];
                if (child != kInvalidNode)
                {
                    for (double value : sums[child]) sums[i][q] += value;
                }
                else
                {
                    const float value = quadrantWeights[4u * i + q];
                    if (std::isfinite(value) && value >= 0.f) sums[i][q] = value;
                    else ++mStatistics.invalidWeights;
                }
            }
        }
        double total = 0.;
        for (double value : sums[spatial.directionalRoot]) total += value;
        for (uint32_t i = spatial.directionalRoot; i < spatial.directionalEnd; ++i)
            for (uint32_t q = 0; q < 4; ++q)
                mBuild.directional[i].weights[q] = total > 0. ? float(sums[i][q] / total) : 0.f;
    }
    // Publishing this immutable snapshot and initializing the next build are
    // separate operations. The host uploads and switches generations safely.
    mRead = mBuild;
    ++mStatistics.generation;
    if (continueTraining) makeNextBuild(spatialCounts, epoch);
    else clearBuildStatistics();
    updateStatistics();
    std::string error;
    if (!validate(&error)) throw std::runtime_error("Invalid PG SD-tree: " + error);
    return true;
}

void SDTree::makeNextBuild(const std::vector<uint32_t>& spatialCounts, uint32_t epoch)
{
    // Reserve the existing topology before allowing any growth: every source
    // leaf still fits even when earlier leaves consume the remaining budget.
    uint64_t reservedBytes = budgetBytes(mRead, mRead);
    mBuild.spatial = mRead.spatial;
    mBuild.directional.clear();
    const auto reserve = [&](uint64_t bytes) {
        if (reservedBytes > mConfig.memoryBudgetBytes || bytes > mConfig.memoryBudgetBytes - reservedBytes)
        {
            mStatistics.budgetLimited = true;
            return false;
        }
        reservedBytes += bytes;
        return true;
    };
    std::vector<uint32_t> depths(mRead.spatial.size(), 0u);
    for (uint32_t i = 0; i < uint32_t(mRead.spatial.size()); ++i)
    {
        const SpatialNode source = mRead.spatial[i];
        if (source.childBase != kInvalidNode)
        {
            depths[source.childBase] = depths[i] + 1u;
            depths[source.childBase + 1u] = depths[i] + 1u;
            continue;
        }
        const float total = directionalMass(mRead, source.directionalRoot);
        std::function<uint32_t(uint32_t, uint32_t)> clone = [&](uint32_t sourceIndex, uint32_t depth) {
            const uint32_t result = uint32_t(mBuild.directional.size());
            mBuild.directional.emplace_back();
            const DirectionalNode original = mRead.directional[sourceIndex];
            for (uint32_t q = 0; q < 4; ++q)
            {
                const bool energetic = total > 0.f && original.weights[q] > total * mConfig.directionalThreshold;
                if (original.children[q] != kInvalidNode)
                {
                    // Coarsen weak regions. ReadTree keeps the learned detail;
                    // this topology determines resolution of the NEXT epoch.
                    if (energetic && depth < mConfig.maxDirectionalDepth)
                    {
                        const uint32_t child = clone(original.children[q], depth + 1u);
                        mBuild.directional[result].children[q] = child;
                    }
                }
                else if (energetic && depth < mConfig.maxDirectionalDepth && reserve(96u))
                {
                    // At most one additional directional level per epoch.
                    const uint32_t child = uint32_t(mBuild.directional.size());
                    mBuild.directional.emplace_back();
                    mBuild.directional[result].children[q] = child;
                    ++mStatistics.directionalSplits;
                }
            }
            return result;
        };
        const uint32_t root = clone(source.directionalRoot, 1u);
        const uint32_t end = uint32_t(mBuild.directional.size());
        mBuild.spatial[i].directionalRoot = root;
        mBuild.spatial[i].directionalEnd = end;
        // The increasing threshold limits spatial growth as training doubles.
        const double threshold = double(mConfig.spatialThreshold) * std::exp2(.5 * double(std::min(epoch, 60u)));
        if (double(spatialCounts[i]) > threshold && depths[i] < mConfig.maxSpatialDepth)
        {
            const uint32_t nodeCount = end - root;
            // Two spatial nodes (2 * (16+4) * 2 bytes) and a duplicate tree.
            if (!reserve(80u + uint64_t(nodeCount) * 96u)) continue;
            const uint32_t childBase = uint32_t(mBuild.spatial.size());
            const uint32_t otherRoot = uint32_t(mBuild.directional.size());
            // Copy by value before appending: vector growth invalidates references.
            for (uint32_t j = root; j < end; ++j)
            {
                DirectionalNode copy = mBuild.directional[j];
                for (auto& child : copy.children)
                    if (child != kInvalidNode) child += otherRoot - root;
                mBuild.directional.push_back(copy);
            }
            mBuild.spatial[i].childBase = childBase;
            const uint32_t nextAxis = (source.axis + 1u) % 3u;
            mBuild.spatial.push_back({kInvalidNode, nextAxis, root, end});
            mBuild.spatial.push_back({kInvalidNode, nextAxis, otherRoot, otherRoot + nodeCount});
            ++mStatistics.spatialSplits;
        }
    }
    clearBuildStatistics();
    // A larger build becomes the next read. Reserve that future publication
    // peak too, so a legal build can never grow into an over-budget read tree.
    // If necessary retain the known-fitting topology, with fresh statistics.
    if (budgetBytes(mBuild, mBuild) > mConfig.memoryBudgetBytes)
    {
        mBuild = mRead;
        clearBuildStatistics();
        mStatistics.spatialSplits = 0;
        mStatistics.directionalSplits = 0;
        mStatistics.budgetLimited = true;
    }
}

void SDTree::clearBuildStatistics()
{
    for (auto& node : mBuild.directional) node.weights.fill(0.f);
}

void SDTree::updateStatistics()
{
    mStatistics.spatialLeaves = leafCount(mRead);
    mStatistics.directionalNodes = uint32_t(mRead.directional.size());
    mStatistics.buildSpatialLeaves = leafCount(mBuild);
    mStatistics.buildDirectionalNodes = uint32_t(mBuild.directional.size());
    mStatistics.memoryBytes = budgetBytes(mRead, mBuild);
    mStatistics.hasDistribution = false;
    for (const auto& node : mRead.spatial)
        if (node.childBase == kInvalidNode && directionalMass(mRead, node.directionalRoot) > 0.f)
            mStatistics.hasDistribution = true;
}

uint32_t SDTree::lookupSpatial(const TreeData& tree, const Bounds& bounds, const std::array<float, 3>& position)
{
    auto lo = bounds.min;
    auto hi = bounds.max;
    uint32_t index = 0;
    for (uint32_t depth = 0; depth < 32u; ++depth)
    {
        const SpatialNode& node = tree.spatial.at(index);
        if (node.childBase == kInvalidNode) return index;
        const float midpoint = .5f * lo[node.axis] + .5f * hi[node.axis];
        const bool upper = position[node.axis] >= midpoint;
        if (upper) lo[node.axis] = midpoint;
        else hi[node.axis] = midpoint;
        index = node.childBase + uint32_t(upper);
    }
    return kInvalidNode;
}

uint32_t SDTree::lookupDirectionalSlot(const TreeData& tree, uint32_t root, const std::array<float, 3>& direction)
{
    auto uv = canonical(direction);
    uint32_t index = root;
    for (uint32_t depth = 0; depth < 17u; ++depth)
    {
        const uint32_t q = quadrant(uv);
        const uint32_t child = tree.directional.at(index).children[q];
        if (child == kInvalidNode) return 4u * index + q;
        index = child;
    }
    return kInvalidNode;
}

float SDTree::directionalMass(const TreeData& tree, uint32_t root) { return mass(tree.directional.at(root)); }

float SDTree::directionalPdf(const TreeData& tree, uint32_t root, const std::array<float, 3>& direction)
{
    auto uv = canonical(direction);
    uint32_t index = root;
    float pdf = kInvFourPi;
    for (uint32_t depth = 0; depth < 17u; ++depth)
    {
        const DirectionalNode& node = tree.directional.at(index);
        const float total = mass(node);
        if (!(total > 0.f)) return index == root ? kInvFourPi : 0.f;
        const uint32_t q = quadrant(uv);
        pdf *= 4.f * node.weights[q] / total;
        if (!(pdf > 0.f) || node.children[q] == kInvalidNode) return pdf;
        index = node.children[q];
    }
    return 0.f;
}

DirectionSample SDTree::sampleDirectional(const TreeData& tree, uint32_t root, const std::array<float, 2>& random)
{
    std::array<float, 2> u = {unit(random[0]), unit(random[1])};
    std::array<float, 2> lower = {0.f, 0.f};
    float size = 1.f;
    uint32_t index = root;
    for (uint32_t depth = 0; depth < 17u; ++depth)
    {
        const DirectionalNode& node = tree.directional.at(index);
        const float total = mass(node);
        if (!(total > 0.f)) break; // Empty root samples a uniform sphere.
        const float left = node.weights[0] + node.weights[2];
        const float probLeft = left / total;
        const uint32_t x = u[0] < probLeft ? 0u : 1u;
        u[0] = unit(x == 0u ? u[0] / probLeft : (u[0] - probLeft) / (1.f - probLeft));
        const float column = x == 0u ? left : node.weights[1] + node.weights[3];
        const float probBottom = node.weights[x] / column;
        const uint32_t y = u[1] < probBottom ? 0u : 1u;
        u[1] = unit(y == 0u ? u[1] / probBottom : (u[1] - probBottom) / (1.f - probBottom));
        const uint32_t q = x + 2u * y;
        size *= .5f;
        lower[0] += size * float(x);
        lower[1] += size * float(y);
        if (node.children[q] == kInvalidNode) break;
        index = node.children[q];
    }
    // Floating-point reconstruction may round lower + size*u to 1 (the
    // azimuth seam), or trig/inverse-trig may place a boundary sample into a
    // neighboring leaf. Always report the PDF of the ACTUAL returned float3.
    // This costs a second traversal, but keeps scatter and NEE PDFs consistent.
    auto result = fromCanonical({unit(lower[0] + size * u[0]), unit(lower[1] + size * u[1])});
    auto actual = canonical(result);
    float pdf = directionalPdf(tree, root, result);
    const bool crossedBoundary = actual[0] < lower[0] || actual[0] >= lower[0] + size ||
                                 actual[1] < lower[1] || actual[1] >= lower[1] + size;
    if (crossedBoundary || !(pdf > 0.f) || !std::isfinite(pdf))
    {
        // Only a numerically unrepresentable/crossed boundary is remapped.
        // Do not clamp every sample into a large interior margin: at depth 16
        // that would distort a significant portion of each small cell.
        result = fromCanonical({lower[0] + .5f * size, lower[1] + .5f * size});
        pdf = directionalPdf(tree, root, result);
    }
    return {result, pdf};
}

bool SDTree::validate(std::string* error) const
{
    const auto fail = [&](const std::string& message) { if (error) *error = message; return false; };
    for (const TreeData* tree : {&mRead, &mBuild})
    {
        if (tree->spatial.empty() || tree->directional.empty()) return fail("empty node arrays");
        std::vector<uint32_t> spatialReferences(tree->spatial.size(), 0u);
        std::vector<uint32_t> directionalReferences(tree->directional.size(), 0u);
        spatialReferences[0] = 1;
        for (uint32_t i = 0; i < uint32_t(tree->spatial.size()); ++i)
        {
            const SpatialNode& node = tree->spatial[i];
            if (node.axis >= 3u) return fail("invalid spatial axis");
            if (node.childBase != kInvalidNode)
            {
                if (node.childBase <= i || uint64_t(node.childBase) + 1u >= tree->spatial.size())
                    return fail("invalid spatial child");
                ++spatialReferences[node.childBase];
                ++spatialReferences[node.childBase + 1u];
                continue;
            }
            if (node.directionalRoot >= node.directionalEnd || node.directionalEnd > tree->directional.size())
                return fail("invalid directional range");
            ++directionalReferences[node.directionalRoot];
            for (uint32_t d = node.directionalRoot; d < node.directionalEnd; ++d)
            {
                for (uint32_t q = 0; q < 4u; ++q)
                {
                    const auto& directional = tree->directional[d];
                    const float weight = directional.weights[q];
                    if (!std::isfinite(weight) || weight < 0.f) return fail("invalid weight");
                    const uint32_t child = directional.children[q];
                    if (child == kInvalidNode) continue;
                    if (child <= d || child >= node.directionalEnd) return fail("invalid directional child");
                    ++directionalReferences[child];
                    if (std::abs(weight - mass(tree->directional[child])) > 1e-5f * std::max(1.f, weight))
                        return fail("inconsistent parent mass");
                }
            }
        }
        for (uint32_t count : spatialReferences) if (count != 1u) return fail("shared or unreachable spatial node");
        for (uint32_t count : directionalReferences) if (count != 1u) return fail("shared or unreachable directional node");
    }
    if (budgetBytes(mRead, mBuild) > mConfig.memoryBudgetBytes) return fail("tree budget exceeded");
    return true;
}
} // namespace Falcor::PG
