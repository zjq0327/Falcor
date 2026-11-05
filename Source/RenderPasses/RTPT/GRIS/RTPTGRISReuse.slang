#pragma once
#include "RTPTGRISTypes.slang"
#include "RTPTGRISSupport.slang"

#ifndef RTPT_GRIS_ALTERNATING_SPATIAL
#define RTPT_GRIS_ALTERNATING_SPATIAL 0
#endif

#if RTPT_GRIS_ALTERNATING
StructuredBuffer<GrisAlternatingFresh> gGRISFresh;
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
struct GrisConnection
{
    ShadingData x2;
    float3 scatterArea; // x1 BSDF times cosine and the solid-angle-to-area factor.
    float areaPdf;
#if ENABLE_SHARC && SHARC_QUERY
    float3 cachedRadiance;
#endif
#if RTPT_REGIR_ONLY
    RTPTLightSample light;
#endif
};

bool rtptGrisConnect(GrisLocalPrefix prefix, GrisSpatialRecord suffix, inout SampleGenerator rng, out GrisConnection connection)
{
    connection = {};
    const HitInfo x1 = HitInfo(prefix.x1Hit);
    const HitInfo x2 = HitInfo(suffix.reconnectHit);
    if (!(suffix.areaPdf > 0.f) || x1.getType() != HitType::Triangle || x2.getType() != HitType::Triangle) return false;

    const TriangleHit x1Triangle = x1.getTriangleHit();
    const TriangleHit x2Triangle = x2.getTriangleHit();
    ShadingData first = gScene.materials.prepareShadingData(gScene.getVertexData(x1Triangle),
        gScene.getMaterialID(x1Triangle.instanceID), -prefix.firstDirW);
    first.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance firstMaterial = gScene.materials.getMaterialInstance(first, ExplicitLodTextureSampler(0.f));

    const VertexData vertex = gScene.getVertexData(x2Triangle);
    const float3 origin = first.computeRayOrigin();
    const float3 edge = vertex.posW - origin;
    const float distanceSquared = dot(edge, edge);
    if (!(distanceSquared > 0.f)) return false;
    const float3 direction = edge * rsqrt(distanceSquared);
    connection.x2 = gScene.materials.prepareShadingData(vertex, gScene.getMaterialID(x2Triangle.instanceID), -direction);
    connection.x2.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance secondMaterial = gScene.materials.getMaterialInstance(connection.x2, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(connection.x2, secondMaterial.getLobeTypes(connection.x2))) return false;

    const float3 scatter = firstMaterial.eval(first, direction, rng);
    if (!all(isfinite(scatter)) || !any(scatter > 0.f)) return false;
    const float geometry = abs(dot(connection.x2.faceN, direction)) / distanceSquared;
    const RTPTSamplingContext sampling = rtptMakeSamplingContext(first, firstMaterial);
    connection.areaPdf = rtptContinuationPdf(first, firstMaterial, sampling, direction) * geometry;
    if (!(connection.areaPdf > 0.f) || !isfinite(connection.areaPdf)) return false;
    connection.scatterArea = scatter * geometry;

    const float3 visibilityEdge = connection.x2.computeRayOrigin() - origin;
    const float visibilityLength = length(visibilityEdge);
    if (!(visibilityLength > 0.f)) return false;
    SceneRayQuery<true> query;
    if (!query.traceVisibilityRay(Ray(origin, visibilityEdge / visibilityLength, 0.f, visibilityLength))) return false;
#if ENABLE_SHARC && SHARC_QUERY
    RTPTSharcStats stats = {};
    const bool terminates = rtptTrySharcQueryOnEdge(connection.x2, secondMaterial, secondMaterial.getProperties(connection.x2),
        2u, false, false, true, firstMaterial.getProperties(first).roughness, length(vertex.posW - first.posW),
        sampling, direction, stats, connection.cachedRadiance);
    const bool cacheSuffix = suffix.candidate.terminalKind == uint(GrisTerminalKind::GrisCacheTerminal);
    if (terminates || cacheSuffix) return terminates && cacheSuffix;
#endif
#if RTPT_REGIR_ONLY
    if (suffix.candidate.terminalKind != uint(GrisTerminalKind::GrisReGIR) || rtptReGIRTransportCoverage(false) == 0u)
        return false;
    // Rebuilding checks the current catalogue and receiver cutoff in both MIS
    // directions. The front-facing x2 and its recorded light ray stay fixed.
    return rtptReGIRRebuildTransportSample(connection.x2, suffix.lightStableID,
        suffix.suffixDirection.xy, suffix.suffixLight.x, connection.light);
#else
    return suffix.candidate.terminalKind == uint(GrisTerminalKind::GrisNee);
#endif
}

float3 rtptGrisEvaluateSuffix(GrisSpatialRecord suffix, GrisConnection connection, inout SampleGenerator rng)
{
#if ENABLE_SHARC && SHARC_QUERY
    if (suffix.candidate.terminalKind == uint(GrisTerminalKind::GrisCacheTerminal)) return connection.cachedRadiance;
#endif
    const IMaterialInstance material = gScene.materials.getMaterialInstance(connection.x2, ExplicitLodTextureSampler(0.f));
#if RTPT_REGIR_ONLY
    return material.eval(connection.x2, connection.light.dir, rng) * connection.light.LiOverPdf;
#else
    RTPTLightSample light = {};
    light.dir = suffix.suffixDirection;
    light.LiOverPdf = suffix.suffixLight;
    light.pdf = suffix.lightPdf;
    light.analytic = suffix.lightIsAnalytic;
    return rtptEvaluateLightSample(connection.x2, material, rtptBSDFSamplingContext(), light, rng, RTPT_GRIS_ALTERNATING == 0);
#endif
}

float rtptGrisTarget(float3 F)
{
    return dot(abs(F), float3(0.2126f, 0.7152f, 0.0722f));
}

#if RTPT_GRIS_ALTERNATING
struct GrisAlternatingProposal
{
    GrisSpatialRecord raw;
    GrisLocalPrefix prefix;
};

#if RTPT_GRIS_ALTERNATING_SPATIAL
static const uint kGrisAlternatingProposalCount = 3u;

GrisAlternatingProposal rtptGrisReadNeighbor(uint2 pixel)
{
    GrisAlternatingProposal proposal = {};
    const uint neighborX = pixel.x ^ 1u;
    if (neighborX < gParams.frameDim.x)
    {
        const GrisAlternatingFresh neighbor = gGRISFresh[pixel.y * gParams.frameDim.x + neighborX];
        proposal.raw = neighbor.raw;
        proposal.prefix = neighbor.prefix[rtptGrisSourceSlot(neighbor.raw.candidate.rootLobe)];
    }
    return proposal;
}
#else
static const uint kGrisAlternatingProposalCount = 2u;
#endif

float3 rtptGrisEvaluateConnected(GrisLocalPrefix prefix, GrisSpatialRecord suffix, GrisConnection connection,
    float proposalSum, inout SampleGenerator rng)
{
    const float3 radiance = rtptGrisEvaluateSuffix(suffix, connection, rng);
    const float3 contribution = prefix.throughputToX1 * connection.scatterArea * radiance / proposalSum;
    return all(isfinite(contribution)) ? contribution : float3(0.f);
}

GrisDualWinner rtptGrisEvaluateDual(GrisAlternatingFresh fresh,
    GrisAlternatingProposal proposals[kGrisAlternatingProposalCount], uint candidateIndex, inout SampleGenerator rng)
{
    GrisDualWinner result = {};
    const GrisSpatialRecord suffix = proposals[candidateIndex].raw;
    if (!(suffix.areaPdf > 0.f)) return result;

    const uint sourceSlot = rtptGrisSourceSlot(fresh.raw.candidate.rootLobe);
    GrisConnection diffuse, specular;
    const bool nativeD = candidateIndex == 0u && sourceSlot == 0u;
    const bool nativeS = candidateIndex == 0u && sourceSlot == 1u;
    bool connectD = false;
    bool connectS = false;
    if (!nativeD) connectD = rtptGrisConnect(fresh.prefix[0], suffix, rng, diffuse);
    if (!nativeS) connectS = rtptGrisConnect(fresh.prefix[1], suffix, rng, specular);

    // The local source edge is also one of the two target edges. Reuse its
    // connection result. An empty draw can still have a valid source prefix.
    float proposalSum = suffix.areaPdf;
    if (candidateIndex != 0u)
    {
        if (sourceSlot == 0u && connectD) proposalSum += diffuse.areaPdf;
        if (sourceSlot == 1u && connectS) proposalSum += specular.areaPdf;
    }
    [unroll]
    for (uint source = 1u; source < kGrisAlternatingProposalCount; ++source)
    {
        if (source == candidateIndex) continue;
        GrisConnection reverse;
        if (rtptGrisConnect(proposals[source].prefix, suffix, rng, reverse)) proposalSum += reverse.areaPdf;
    }

    if (nativeD) result.F_D = suffix.candidate.F * (suffix.areaPdf / proposalSum);
    else if (connectD) result.F_D = rtptGrisEvaluateConnected(fresh.prefix[0], suffix, diffuse, proposalSum, rng);
    if (nativeS) result.F_S = suffix.candidate.F * (suffix.areaPdf / proposalSum);
    else if (connectS) result.F_S = rtptGrisEvaluateConnected(fresh.prefix[1], suffix, specular, proposalSum, rng);
    return result;
}

GrisDualWinner rtptGrisMergeAlternating(uint2 pixel, GrisAlternatingFresh fresh, GrisAlternatingProposal history,
    inout SampleGenerator rng)
{
    if (fresh.preparedMask == 0u) return {};

    GrisAlternatingProposal proposals[kGrisAlternatingProposalCount];
    proposals[0].raw = fresh.raw;
    proposals[0].prefix = fresh.prefix[rtptGrisSourceSlot(fresh.raw.candidate.rootLobe)];
    proposals[1] = history;
#if RTPT_GRIS_ALTERNATING_SPATIAL
    proposals[2] = rtptGrisReadNeighbor(pixel);
#endif

    // Balance all actual proposals before selecting a single shared winner.
    // Keep the draw separate from evaluating material and light contributions.
    GrisDualWinner candidates[kGrisAlternatingProposalCount];
    float weights[kGrisAlternatingProposalCount];
    float total = 0.f;
    [unroll]
    for (uint i = 0u; i < kGrisAlternatingProposalCount; ++i)
    {
        candidates[i] = rtptGrisEvaluateDual(fresh, proposals, i, rng);
        weights[i] = rtptGrisTarget(candidates[i].F_D) + rtptGrisTarget(candidates[i].F_S);
        total += weights[i];
    }
    if (!(total > 0.f) || !isfinite(total)) return {};

    float draw = sampleNext1D(rng) * total;
    uint winnerIndex = 0u;
    // Retain the last positive bin if the draw rounds to the upper endpoint.
    [unroll]
    for (int i = int(kGrisAlternatingProposalCount) - 1; i >= 0; --i)
    {
        if (!(weights[i] > 0.f)) continue;
        winnerIndex = uint(i);
        if (draw < weights[i]) break;
        draw -= weights[i];
    }
    GrisDualWinner winner = candidates[winnerIndex];
    winner.W = total / weights[winnerIndex];
    if (!isfinite(winner.W) || !all(isfinite(winner.F_D * winner.W)) || !all(isfinite(winner.F_S * winner.W))) return {};
    winner.hasWinner = 1u;
    return winner;
}
#else
GrisCandidate rtptGrisMerge(GrisSpatialRecord canonical, GrisSpatialRecord other,
    GrisLocalPrefix targetPrefix, GrisLocalPrefix sourcePrefix, inout SampleGenerator rng)
{
    // One fresh sample per prefix. Both proposals must support the same
    // terminal event at x2, and share the light sampler when tracing continues.
    float3 local = canonical.candidate.F;
    GrisConnection reverse;
    if (rtptGrisConnect(sourcePrefix, canonical, rng, reverse))
        local *= canonical.areaPdf / (canonical.areaPdf + reverse.areaPdf);

    float3 shifted = 0.f;
    GrisConnection forward;
    if (rtptGrisConnect(targetPrefix, other, rng, forward))
    {
        const float3 radiance = rtptGrisEvaluateSuffix(other, forward, rng);
        if (all(isfinite(radiance)) && any(radiance > 0.f))
            shifted = targetPrefix.throughputToX1 * forward.scatterArea * radiance / (forward.areaPdf + other.areaPdf);
    }

    // Collapse the two balanced RGB contributions to one winner. Division
    // by its selection probability preserves the sum in expectation.
    GrisCandidate result = canonical.candidate;
    const float localWeight = rtptGrisTarget(local);
    const float shiftedWeight = rtptGrisTarget(shifted);
    const float total = localWeight + shiftedWeight;
    if (!isfinite(total)) return result;
    if (total > 0.f)
    {
        const bool selectShifted = sampleNext1D(rng) * total < shiftedWeight;
        result.F = selectShifted ? shifted : local;
        result.terminalKind = selectShifted ? other.candidate.terminalKind : canonical.candidate.terminalKind;
        result.W = total / (selectShifted ? shiftedWeight : localWeight);
        result.hasWinner = true;
        if (!isfinite(result.W) || !all(isfinite(result.F * result.W))) return canonical.candidate;
    }
    return result;
}
#endif
#endif

