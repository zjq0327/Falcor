// Standalone: compile together with ../SDTree.cpp using any C++17 compiler.
#include "../SDTree.h"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace Falcor::PG;
namespace
{
constexpr double kPi = 3.14159265358979323846;
uint32_t gChecks = 0;
void require(bool condition, const char* message)
{
    ++gChecks;
    if (!condition) throw std::runtime_error(message);
}
bool near(float a, float b, float tolerance = 2e-5f)
{
    return std::abs(a - b) <= tolerance * std::max(1.f, std::max(std::abs(a), std::abs(b)));
}
std::array<float, 3> direction(float u, float v)
{
    const double z = 2. * u - 1.;
    const double r = std::sqrt(std::max(0., 1. - z * z));
    return {float(r * std::cos(2. * kPi * v)), float(r * std::sin(2. * kPi * v)), float(z)};
}
void checkDistribution(const TreeData& data, uint32_t root, const char* label)
{
    constexpr uint32_t n = 256;
    double integral = 0.;
    for (uint32_t y = 0; y < n; ++y)
        for (uint32_t x = 0; x < n; ++x)
        {
            const std::array<float, 2> random = {(float(x) + .314159f) / n, (float(y) + .271828f) / n};
            integral += SDTree::directionalPdf(data, root, direction(random[0], random[1]));
            const auto sample = SDTree::sampleDirectional(data, root, random);
            require(sample.pdf > 0.f && std::isfinite(sample.pdf), "sample PDF must be finite and positive");
            require(near(sample.pdf, SDTree::directionalPdf(data, root, sample.direction)), "sample/PDF mismatch");
            double norm = 0.;
            for (float value : sample.direction) norm += double(value) * value;
            require(std::abs(norm - 1.) < 1e-5, "sample direction is not unit length");
        }
    integral *= 4. * kPi / double(n * n);
    require(std::abs(integral - 1.) < 2e-5, "PDF integral is not one");
    std::cout << label << ": integral=" << integral << ", 65536 sample/pdf pairs passed\n";
}
void testDistributions()
{
    TreeData data{{SpatialNode{}}, {DirectionalNode{}}};
    checkDistribution(data, 0, "empty fallback");
    data.directional[0].weights = {1.f, 1.f, 1.f, 1.f};
    checkDistribution(data, 0, "uniform");
    data.directional[0].weights = {0.f, 0.f, 17.f, 0.f};
    checkDistribution(data, 0, "single bright quadrant");
    for (const auto& random : {std::array<float, 2>{0.f, 0.f}, {1.f, 1.f}, {.5f, .5f}})
    {
        const auto sample = SDTree::sampleDirectional(data, 0, random);
        require(std::isfinite(sample.pdf) && sample.pdf > 0.f, "boundary random input failed");
    }
    data.directional[0].weights = {1.f, 2.f, 3.f, 4.f};
    checkDistribution(data, 0, "four unequal quadrants");
    std::array<uint32_t, 4> histogram{};
    constexpr uint32_t n = 400;
    for (uint32_t y = 0; y < n; ++y)
        for (uint32_t x = 0; x < n; ++x)
        {
            const auto sample = SDTree::sampleDirectional(data, 0, {(x + .5f) / n, (y + .5f) / n});
            const uint32_t slot = SDTree::lookupDirectionalSlot(data, 0, sample.direction);
            ++histogram[slot];
        }
    for (uint32_t q = 0; q < 4; ++q)
        require(std::abs(double(histogram[q]) / double(n * n) - .1 * (q + 1)) < .003, "quadrant frequency mismatch");
    data.directional[0].weights = {1.f, 0.f, 0.f, 3.f};
    data.directional[0].children[0] = 1;
    data.directional.emplace_back();
    data.directional[1].weights = {.1f, .2f, .3f, .4f};
    data.spatial[0].directionalEnd = 2;
    checkDistribution(data, 0, "adaptive two-level distribution");
}

// Reference only the discrete CDF decisions, not the world-space round trip.
// A repaired endpoint must stay in this sampled leaf, including zero-weight
// neighbors and the maximum supported directional depth.
uint32_t selectedLeaf(const TreeData& data, std::array<float, 2> u)
{
    const float oneBelow = std::nextafter(1.f, 0.f);
    const auto unit = [=](float value) { return std::clamp(value, 0.f, oneBelow); };
    u = {unit(u[0]), unit(u[1])};
    uint32_t index = 0;
    for (uint32_t depth = 0; depth < 17; ++depth)
    {
        const auto& node = data.directional[index];
        const float total = (node.weights[0] + node.weights[1]) + (node.weights[2] + node.weights[3]);
        const float left = node.weights[0] + node.weights[2];
        const float leftProbability = left / total;
        const uint32_t x = u[0] < leftProbability ? 0u : 1u;
        u[0] = unit(x == 0u ? u[0] / leftProbability : (u[0] - leftProbability) / (1.f - leftProbability));
        const float column = x == 0u ? left : node.weights[1] + node.weights[3];
        const float bottomProbability = node.weights[x] / column;
        const uint32_t y = u[1] < bottomProbability ? 0u : 1u;
        u[1] = unit(y == 0u ? u[1] / bottomProbability : (u[1] - bottomProbability) / (1.f - bottomProbability));
        const uint32_t q = x + 2u * y;
        if (node.children[q] == kInvalidNode) return 4u * index + q;
        index = node.children[q];
    }
    throw std::runtime_error("Reference endpoint traversal exceeded maximum depth");
}

void checkEndpointGrid(const TreeData& data, const char* label)
{
    std::vector<float> inputs;
    for (float base : {0.f, .00001f, .01f, .125f, .25f, 1.f / 3.f, .4f, .5f, .625f, .75f, .875f, .99f, 1.f})
    {
        inputs.push_back(base);
        if (base > 0.f) inputs.push_back(std::nextafter(base, 0.f));
        if (base < 1.f) inputs.push_back(std::nextafter(base, 1.f));
    }
    std::sort(inputs.begin(), inputs.end());
    inputs.erase(std::unique(inputs.begin(), inputs.end()), inputs.end());
    float maximumRelativeError = 0.f;
    for (float x : inputs)
        for (float y : inputs)
        {
            const std::array<float, 2> random = {x, y};
            const auto sample = SDTree::sampleDirectional(data, 0, random);
            const float evaluated = SDTree::directionalPdf(data, 0, sample.direction);
            require(sample.pdf > 0.f && std::isfinite(sample.pdf), "endpoint sample PDF is not finite and positive");
            require(sample.pdf == evaluated, "endpoint sample/PDF must match for the actual float3");
            maximumRelativeError = std::max(maximumRelativeError, std::abs(sample.pdf - evaluated) / evaluated);
            require(SDTree::lookupDirectionalSlot(data, 0, sample.direction) == selectedLeaf(data, random),
                    "world-space endpoint escaped its selected directional leaf");
            double norm = 0.;
            for (float value : sample.direction) norm += double(value) * value;
            require(std::abs(norm - 1.) < 1e-5, "endpoint direction is not unit length");
        }
    std::cout << label << ": " << inputs.size() * inputs.size()
              << " endpoint pairs, max relative sample/pdf error=" << maximumRelativeError << '\n';
}

TreeData narrowDistribution(uint32_t depth, uint32_t firstQuadrant, uint32_t subsequentQuadrant)
{
    TreeData data{{SpatialNode{}}, std::vector<DirectionalNode>(depth)};
    for (uint32_t i = 0; i + 1 < depth; ++i)
    {
        const uint32_t q = i == 0 ? firstQuadrant : subsequentQuadrant;
        data.directional[i].weights[q] = 10.f;
        data.directional[i].children[q] = i + 1;
    }
    data.directional.back().weights = {1.f, 2.f, 3.f, 4.f};
    data.spatial[0].directionalEnd = depth;
    return data;
}

void testEndpointRoundTrips()
{
    TreeData data{{SpatialNode{}}, {DirectionalNode{}}};
    data.directional[0].weights = {1.f, 2.f, 3.f, 4.f};
    const auto seam = SDTree::sampleDirectional(data, 0, {.5f, std::nextafter(1.f, 0.f)});
    require(SDTree::lookupDirectionalSlot(data, 0, seam.direction) == 3u, "upper azimuth rounded through the global seam");
    require(seam.pdf == SDTree::directionalPdf(data, 0, seam.direction), "known seam regression remains");
    checkEndpointGrid(data, "asymmetric root boundaries");
    data.directional[0].weights = {0.f, 0.f, 17.f, 0.f};
    checkEndpointGrid(data, "root with zero-mass neighbors");
    data.directional[0].weights = {1.f, 0.f, 0.f, 3.f};
    data.directional[0].children[0] = 1;
    data.directional[0].children[3] = 2;
    data.directional.resize(3);
    data.directional[1].weights = {0.f, .1f, .2f, .7f};
    data.directional[2].weights = {2.f, 1.f, 0.f, 0.f};
    data.spatial[0].directionalEnd = 3;
    checkEndpointGrid(data, "subdivided asymmetric boundaries");
    for (uint32_t depth : {10u, 16u})
    {
        checkEndpointGrid(narrowDistribution(depth, 0, 0), "deep south-pole leaf");
        checkEndpointGrid(narrowDistribution(depth, 3, 3), "deep north-pole/azimuth-seam leaf");
        checkEndpointGrid(narrowDistribution(depth, 0, 3), "deep internal equator boundary");
    }
}

void testLifecycle()
{
    SDTree tree;
    Config config;
    config.spatialThreshold = 10;
    config.directionalThreshold = .2f;
    tree.reset({}, config);
    require(tree.validate(), "bootstrap tree invalid");
    require(!tree.statistics().hasDistribution, "bootstrap must have no learned distribution");
    require(!tree.finalizeEpoch({0.f, 0.f, 0.f, 0.f}, {0u}, 0), "empty epoch must not publish");
    require(tree.statistics().generation == 0, "empty epoch changed generation");
    require(tree.finalizeEpoch({100.f, 0.f, 0.f, 0.f}, {100u}, 0), "nonempty epoch did not publish");
    require(tree.statistics().generation == 1, "generation did not increase");
    require(tree.statistics().spatialLeaves == 1 && tree.statistics().buildSpatialLeaves == 2,
            "read/build spatial topology must differ after refinement");
    require(tree.statistics().directionalNodes == 1 && tree.statistics().buildDirectionalNodes == 4,
            "directional split/duplication mismatch");
    require(tree.statistics().spatialSplits == 1 && tree.statistics().directionalSplits == 1,
            "split statistics mismatch");
    for (const auto& node : tree.buildTree().directional)
        for (float value : node.weights) require(value == 0.f, "next epoch contains old weights");
    const uint32_t low = SDTree::lookupSpatial(tree.buildTree(), tree.bounds(), {-.5f, 0.f, 0.f});
    const uint32_t high = SDTree::lookupSpatial(tree.buildTree(), tree.bounds(), {.5f, 0.f, 0.f});
    require(low != high && low == 1u && high == 2u, "midpoint spatial lookup failed");
    require(SDTree::lookupSpatial(tree.buildTree(), tree.bounds(), {0.f, 0.f, 0.f}) == high,
            "spatial boundary must choose upper child");
    const float previousPdf = SDTree::directionalPdf(tree.readTree(), 0, direction(.25f, .25f));
    std::vector<float> weights(tree.buildTree().directional.size() * 4u, 0.f);
    std::vector<uint32_t> counts(tree.buildTree().spatial.size(), 0u);
    for (size_t i = 0; i < tree.buildTree().spatial.size(); ++i)
    {
        const auto& leaf = tree.buildTree().spatial[i];
        if (leaf.childBase != kInvalidNode) continue;
        counts[i] = 80;
        for (uint32_t d = leaf.directionalRoot; d < leaf.directionalEnd; ++d)
            for (uint32_t q = 0; q < 4; ++q)
                if (tree.buildTree().directional[d].children[q] == kInvalidNode)
                    weights[4u * d + q] = float((q + 1u) * (d + 1u));
    }
    require(near(previousPdf, SDTree::directionalPdf(tree.readTree(), 0, direction(.25f, .25f))),
            "record accumulation must not mutate read tree");
    require(tree.finalizeEpoch(weights, counts, 1), "second epoch not published");
    require(tree.statistics().generation == 2 && tree.statistics().spatialLeaves == 2 &&
            tree.statistics().buildSpatialLeaves == 4, "second spatial epoch did not split");
    require(tree.validate(), "refined tree invalid");
    for (const auto& leaf : tree.readTree().spatial)
        if (leaf.childBase == kInvalidNode) checkDistribution(tree.readTree(), leaf.directionalRoot, "trained spatial leaf");
    const uint32_t before = tree.statistics().generation;
    require(!tree.finalizeEpoch(std::vector<float>(tree.buildTree().directional.size() * 4u, 0.f),
                               std::vector<uint32_t>(tree.buildTree().spatial.size(), 0u), 2),
            "empty refined epoch unexpectedly published");
    require(tree.statistics().generation == before && tree.statistics().hasDistribution,
            "empty epoch discarded last learned tree");
    tree.reset({}, config);
    require(tree.finalizeEpoch({0.f, 0.f, 0.f, 0.f}, {4u}, 0, false), "black but valid samples were discarded");
    require(tree.statistics().samples == 4u && !tree.statistics().hasDistribution, "zero contribution count/fallback wrong");
    require(tree.validate(), "frozen black tree invalid");
}

void testRobustness()
{
    SDTree tree;
    Config config;
    config.memoryBudgetBytes = 232;
    config.spatialThreshold = 1;
    tree.reset({}, config);
    tree.finalizeEpoch({1.f, 1.f, 1.f, 1.f}, {100u}, 0);
    require(tree.statistics().budgetLimited && tree.statistics().memoryBytes <= 232u, "budget cap failed");
    require(tree.statistics().hasDistribution && tree.validate(), "budget cap discarded usable tree");
    tree.reset({});
    tree.finalizeEpoch({std::numeric_limits<float>::max(), std::numeric_limits<float>::max(), 0.f, 0.f}, {2u}, 0, false);
    require(tree.validate() && near(tree.readTree().directional[0].weights[0], .5f), "large weights overflowed normalization");
    tree.reset({});
    tree.finalizeEpoch({std::numeric_limits<float>::quiet_NaN(), -1.f, std::numeric_limits<float>::infinity(), 1.f}, {4u}, 0, false);
    require(tree.statistics().invalidWeights == 3 && tree.validate(), "invalid training weights were not rejected");
    require(tree.readTree().directional[0].weights[3] == 1.f, "valid weight lost during rejection");
    bool rejected = false;
    try { tree.finalizeEpoch({}, {}, 0); }
    catch (const std::invalid_argument&) { rejected = true; }
    require(rejected, "mismatched readback sizes accepted");
    tree.reset(Bounds{{0.f, 0.f, 0.f}, {0.f, 0.f, 0.f}});
    require(tree.bounds().min[0] < tree.bounds().max[0], "flat scene bounds were not padded");
    std::cout << "epoch lifecycle, adaptive topology, zero/invalid samples, overflow, budget and bounds passed\n";
}
} // namespace

int main()
{
    try
    {
        testDistributions();
        testEndpointRoundTrips();
        testLifecycle();
        testRobustness();
        std::cout << "PASS: " << gChecks << " checks\n";
        return 0;
    }
    catch (const std::exception& e)
    {
        std::cerr << "FAIL after " << gChecks << " checks: " << e.what() << '\n';
        return 1;
    }
}
