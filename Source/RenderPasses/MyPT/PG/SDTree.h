/***************************************************************************
 # Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
 # SPDX-License-Identifier: BSD-3-Clause
 ***************************************************************************/
#pragma once

// Deliberately independent of Falcor/graphics headers for numerical tests.
#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace Falcor::PG
{
constexpr uint32_t kInvalidNode = 0xffffffffu;

struct SpatialNode
{
    uint32_t childBase = kInvalidNode; // Binary children are childBase and childBase + 1.
    uint32_t axis = 0;                // Split at the midpoint of this node's cell.
    uint32_t directionalRoot = 0;
    uint32_t directionalEnd = 1;      // Exclusive; each leaf's directional tree is contiguous.
};

struct DirectionalNode
{
    std::array<uint32_t, 4> children = {kInvalidNode, kInvalidNode, kInvalidNode, kInvalidNode};
    std::array<float, 4> weights = {}; // Integrated mass of each quadrant, NOT density.
};
static_assert(sizeof(SpatialNode) == 16);
static_assert(sizeof(DirectionalNode) == 32);

struct Bounds
{
    std::array<float, 3> min = {-1.f, -1.f, -1.f};
    std::array<float, 3> max = {1.f, 1.f, 1.f};
};

struct TreeData
{
    std::vector<SpatialNode> spatial;
    std::vector<DirectionalNode> directional;
    uint64_t nodeBytes() const;
    uint64_t statisticsBytes() const; // uint count per spatial node + four float bits per directional node.
};

struct Config
{
    uint64_t memoryBudgetBytes = 64ull * 1024 * 1024;
    uint32_t spatialThreshold = 12000;
    uint32_t maxSpatialDepth = 20;
    uint32_t maxDirectionalDepth = 10; // Quadrant depth; root quadrants have depth 1.
    float directionalThreshold = 0.01f;
};

struct Statistics
{
    uint32_t generation = 0;
    uint32_t spatialLeaves = 1;
    uint32_t directionalNodes = 1;
    uint32_t buildSpatialLeaves = 1;
    uint32_t buildDirectionalNodes = 1;
    uint32_t spatialSplits = 0;
    uint32_t directionalSplits = 0;
    uint64_t samples = 0;
    uint64_t invalidWeights = 0;
    uint64_t memoryBytes = 0; // Conservative GPU read/build + stats + upload/readback staging budget.
    bool budgetLimited = false;
    bool hasDistribution = false;
};

struct DirectionSample
{
    std::array<float, 3> direction = {0.f, 0.f, 1.f};
    float pdf = 0.f;
};

class SDTree
{
public:
    SDTree();
    void reset(const Bounds& bounds, const Config& config = {});
    const Bounds& bounds() const { return mBounds; }
    const Config& config() const { return mConfig; }
    const TreeData& readTree() const { return mRead; }
    const TreeData& buildTree() const { return mBuild; }
    const Statistics& statistics() const { return mStatistics; }

    // Inputs are one value per build quadrant/spatial node. Only leaf quadrant
    // weights are authoritative; internal sums are rebuilt even after GPU reduction.
    // Publishes a nonempty epoch, then constructs ZEROED next-epoch topology.
    // An epoch with no valid samples preserves the last published distribution.
    bool finalizeEpoch(const std::vector<float>& quadrantWeights, const std::vector<uint32_t>& spatialCounts,
                       uint32_t epoch, bool continueTraining = true);
    void clearBuildStatistics();
    bool validate(std::string* error = nullptr) const;

    // CPU equivalents of GPU routines, used by standalone tests and diagnostics.
    static uint32_t lookupSpatial(const TreeData& tree, const Bounds& bounds, const std::array<float, 3>& position);
    static uint32_t lookupDirectionalSlot(const TreeData& tree, uint32_t root, const std::array<float, 3>& direction);
    static float directionalMass(const TreeData& tree, uint32_t root);
    static float directionalPdf(const TreeData& tree, uint32_t root, const std::array<float, 3>& direction);
    static DirectionSample sampleDirectional(const TreeData& tree, uint32_t root, const std::array<float, 2>& random);

private:
    void updateStatistics();
    void makeNextBuild(const std::vector<uint32_t>& spatialCounts, uint32_t epoch);
    Bounds mBounds;
    Config mConfig;
    TreeData mRead;
    TreeData mBuild;
    Statistics mStatistics;
};
} // namespace Falcor::PG
