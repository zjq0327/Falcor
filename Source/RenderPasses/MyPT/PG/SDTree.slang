/***************************************************************************
 # Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
 # SPDX-License-Identifier: BSD-3-Clause
 ***************************************************************************/
#ifndef MYPT_PG_SDTREE_SLANG
#define MYPT_PG_SDTREE_SLANG

// Byte-for-byte counterparts of PG::SpatialNode/DirectionalNode in SDTree.h.
// Resource bindings live in Params.slang; these routines have explicit inputs.
struct PGSpatialNode
{
    uint childBase;
    uint axis;
    uint directionalRoot;
    uint directionalEnd;
};

struct PGDirectionalNode
{
    uint4 children;
    float4 weights;
};

static const uint kPGInvalidNode = 0xffffffffu;
static const float kPGPi = 3.14159265358979323846f;
static const float kPGInvFourPi = 0.07957747154594766788f;
static const float kPGOneBelow = 0.999999940395355224609375f;

float2 pgDirectionToCanonical(float3 direction)
{
    float phi = atan2(direction.y, direction.x) / (2.f * kPGPi);
    if (phi < 0.f) phi += 1.f;
    return clamp(float2(.5f * (direction.z + 1.f), phi), 0.f, kPGOneBelow);
}

float3 pgCanonicalToDirection(float2 uv)
{
    float z = 2.f * uv.x - 1.f;
    float radius = sqrt(max(0.f, 1.f - z * z));
    float phi = 2.f * kPGPi * uv.y;
    return float3(radius * cos(phi), radius * sin(phi), z);
}

uint pgCanonicalQuadrant(inout float2 uv)
{
    uint2 side = uint2(uv.x >= .5f ? 1u : 0u, uv.y >= .5f ? 1u : 0u);
    uv = clamp(2.f * uv - float2(side), 0.f, kPGOneBelow);
    return side.x + 2u * side.y;
}

uint pgLookupSpatial(StructuredBuffer<PGSpatialNode> nodes, float3 boundsMin, float3 boundsMax, float3 position)
{
    uint index = 0u;
    [loop]
    for (uint depth = 0u; depth < 32u; ++depth)
    {
        PGSpatialNode node = nodes[index];
        if (node.childBase == kPGInvalidNode) return index;
        float midpoint = .5f * boundsMin[node.axis] + .5f * boundsMax[node.axis];
        bool upper = position[node.axis] >= midpoint;
        if (upper) boundsMin[node.axis] = midpoint;
        else boundsMax[node.axis] = midpoint;
        index = node.childBase + (upper ? 1u : 0u);
    }
    return kPGInvalidNode;
}

float pgDirectionalMass(StructuredBuffer<PGDirectionalNode> nodes, uint root)
{
    float4 w = nodes[root].weights;
    return (w.x + w.y) + (w.z + w.w);
}

uint pgLookupDirectionalSlot(StructuredBuffer<PGDirectionalNode> nodes, uint root, float3 direction)
{
    float2 uv = pgDirectionToCanonical(direction);
    uint index = root;
    [loop]
    for (uint depth = 0u; depth < 17u; ++depth)
    {
        uint q = pgCanonicalQuadrant(uv);
        uint child = nodes[index].children[q];
        if (child == kPGInvalidNode) return 4u * index + q;
        index = child;
    }
    return kPGInvalidNode;
}

float pgDirectionalPdf(StructuredBuffer<PGDirectionalNode> nodes, uint root, float3 direction)
{
    float2 uv = pgDirectionToCanonical(direction);
    uint index = root;
    float pdf = kPGInvFourPi;
    [loop]
    for (uint depth = 0u; depth < 17u; ++depth)
    {
        PGDirectionalNode node = nodes[index];
        float total = (node.weights.x + node.weights.y) + (node.weights.z + node.weights.w);
        if (!(total > 0.f)) return index == root ? kPGInvFourPi : 0.f;
        uint q = pgCanonicalQuadrant(uv);
        pdf *= 4.f * node.weights[q] / total;
        if (!(pdf > 0.f) || node.children[q] == kPGInvalidNode) return pdf;
        index = node.children[q];
    }
    return 0.f;
}

void pgSampleDirectional(StructuredBuffer<PGDirectionalNode> nodes, uint root, float2 random,
                         out float3 direction, out float pdf)
{
    float2 u = clamp(random, 0.f, kPGOneBelow);
    float2 lower = 0.f;
    float size = 1.f;
    pdf = kPGInvFourPi;
    uint index = root;
    [loop]
    for (uint depth = 0u; depth < 17u; ++depth)
    {
        PGDirectionalNode node = nodes[index];
        float total = (node.weights.x + node.weights.y) + (node.weights.z + node.weights.w);
        if (!(total > 0.f)) break;
        float left = node.weights.x + node.weights.z;
        float probLeft = left / total;
        uint x = u.x < probLeft ? 0u : 1u;
        u.x = clamp(x == 0u ? u.x / probLeft : (u.x - probLeft) / (1.f - probLeft), 0.f, kPGOneBelow);
        float column = x == 0u ? left : node.weights.y + node.weights.w;
        float probBottom = node.weights[x] / column;
        uint y = u.y < probBottom ? 0u : 1u;
        u.y = clamp(y == 0u ? u.y / probBottom : (u.y - probBottom) / (1.f - probBottom), 0.f, kPGOneBelow);
        uint q = x + 2u * y;
        size *= .5f;
        lower += size * float2(x, y);
        if (node.children[q] == kPGInvalidNode) break;
        index = node.children[q];
    }
    // A float addition can round the reconstructed azimuth to 1, even though
    // each random input is below 1. Trig round trips can also cross internal
    // leaf boundaries. Evaluate the same returned float3 used by NEE/MIS,
    // accepting one extra directional traversal for numerical consistency.
    direction = pgCanonicalToDirection(clamp(lower + size * u, 0.f, kPGOneBelow));
    float2 actual = pgDirectionToCanonical(direction);
    pdf = pgDirectionalPdf(nodes, root, direction);
    bool crossedBoundary = any(actual < lower) || any(actual >= lower + size);
    if (crossedBoundary || !(pdf > 0.f) || !isfinite(pdf))
    {
        // Rare boundary-only repair, not a broad interior clamp or rejection
        // sampler. No additional random numbers are consumed. Float quantized
        // sampling still approximates the ideal continuous distribution.
        direction = pgCanonicalToDirection(lower + .5f * size);
        pdf = pgDirectionalPdf(nodes, root, direction);
    }
}

// uint CAS operates on float BIT PATTERNS; integer InterlockedAdd is incorrect.
// Never writes NaN/Inf and reports overflow so training can count the rejection.
bool pgAtomicAddWeight(RWStructuredBuffer<uint> weights, uint slot, float weight)
{
    if (!isfinite(weight) || weight < 0.f) return false;
    if (weight == 0.f) return true;
    uint expected;
    InterlockedOr(weights[slot], 0u, expected);
    [allow_uav_condition]
    [loop]
    while (true)
    {
        float sum = asfloat(expected) + weight;
        if (!isfinite(sum)) return false;
        uint observed;
        InterlockedCompareExchange(weights[slot], expected, asuint(sum), observed);
        if (observed == expected) return true;
        expected = observed;
    }
}
#endif // MYPT_PG_SDTREE_SLANG
