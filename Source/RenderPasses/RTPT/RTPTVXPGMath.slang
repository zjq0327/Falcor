#pragma once

// The input densities use the same solid-angle measure, conditional on the
// same material component. The guide density includes rejected/null events;
// it is never renormalized after a target-voxel or cache test.
struct RTPTVXPGMISWeights
{
    float brdfLocal;
    float guideLocal;
    float brdfSuffix;
    float guideSuffix;
};

float2 rtptVXPGPartition(float p, float q)
{
    const float scale = max(p, q);
    if (!(scale > 0.f) || !isfinite(p) || !isfinite(q) || p < 0.f || q < 0.f) return float2(0.f);
    if (q == 0.f) return float2(1.f, 0.f);
    if (p == 0.f) return float2(0.f, 1.f);
    if (p == q) return float2(0.5f);
    // Dividing by a near-FLT_MAX scale can lower to an underflowing GPU rcp.
    // Keep both denominator and its reciprocal in the normal float range.
    float2 scaled = float2(p, q);
    if (scale > 1.e20f) scaled *= 1.e-20f;
    else if (scale < 1.e-20f) scaled *= 1.e20f;
    return scaled / (scaled.x + scaled.y);
}

RTPTVXPGMISWeights rtptVXPGWeights(float p, float q, bool guideUsesCache)
{
    const float2 local = rtptVXPGPartition(p, q);
    const float2 suffix = rtptVXPGPartition(p, guideUsesCache ? q : 0.f);
    RTPTVXPGMISWeights result;
    result.brdfLocal = local.x;
    result.guideLocal = local.y;
    result.brdfSuffix = suffix.x;
    result.guideSuffix = suffix.y;
    return result;
}
