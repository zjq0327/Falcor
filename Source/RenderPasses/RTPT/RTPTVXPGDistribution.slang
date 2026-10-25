#pragma once
#include "RTPTVXPGTypes.slang"

// Geometry-only bound used identically during traversal and reverse evaluation.
// The positive floor is proposal regularization, never a radiance clamp.
float rtptVXPGNodeImportance(RTPTVXPGNode node, float3 origin, float3 normal, float sourceSize)
{
    if (!(node.mass > 0.f)) return 0.f;
#if RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY
    const float3 delta = node.lo - origin;
    const float radius = node.hi.x;
#else
    const float3 delta = 0.5f * (node.lo + node.hi) - origin;
    const float radius = 0.5f * length(node.hi - node.lo);
#endif
    const float distance2 = dot(delta, delta);
    const float distance = sqrt(max(1.e-20f, distance2));
    const float cosineBound = saturate(dot(normal, delta) / distance + radius / distance);
    const float cell2 = sourceSize * sourceSize;
    return node.mass * max(0.01f, cosineBound) / max(cell2, distance2);
}
float rtptVXPGNodeImportance(RTPTVXPGNode node, float3 origin, float3 normal)
{
    return rtptVXPGNodeImportance(node,origin,normal,rtptVXPGSurfaceSize(origin));
}
float rtptVXPGLeftProbability(RTPTVXPGNode left, RTPTVXPGNode right, float3 origin, float3 normal, float sourceSize)
{
    rtptVXPGCount(RTPT_VXPG_STATE_FULL_BRANCH_STEPS);
    const float l = rtptVXPGNodeImportance(left, origin, normal,sourceSize);
    const float r = rtptVXPGNodeImportance(right, origin, normal,sourceSize);
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
