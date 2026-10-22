#pragma once
#include "RTPTVXPGTypes.slang"

// Geometry-only bound used identically during traversal and reverse evaluation.
// The positive floor is proposal regularization, never a radiance clamp.
float rtptVXPGNodeImportance(RTPTVXPGNode node, float3 origin, float3 normal)
{
    if (!(node.mass > 0.f)) return 0.f;
    const float3 delta = 0.5f * (node.lo + node.hi) - origin;
    const float distance2 = dot(delta, delta);
    const float radius = 0.5f * length(node.hi - node.lo);
    const float distance = sqrt(max(1.e-20f, distance2));
    const float cosineBound = saturate(dot(normal, delta) / distance + radius / distance);
    const float cell2 = gVXPGParams.cellSize * gVXPGParams.cellSize;
    return node.mass * max(0.01f, cosineBound) / max(cell2, distance2);
}
float rtptVXPGLeftProbability(RTPTVXPGNode left, RTPTVXPGNode right, float3 origin, float3 normal)
{
    const float l = rtptVXPGNodeImportance(left, origin, normal);
    const float r = rtptVXPGNodeImportance(right, origin, normal);
    const float sum = l + r;
    if (sum > 0.f && isfinite(sum)) return l / sum;
    const float mass = left.mass + right.mass;
    return mass > 0.f ? left.mass / mass : 0.5f;
}
float rtptVXPGClusterDistance(uint4 a, uint4 b, float intensityA, float intensityB)
{
    const uint4 bits = countbits(a ^ b);
    // Fixed reference path uses position weight 0 and intensity weight 1.
    return float(bits.x + bits.y + bits.z + bits.w) + abs(intensityA - intensityB);
}
