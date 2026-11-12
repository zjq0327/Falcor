#pragma once

#include "RTPTGRISTypes.slang"
#include "RTPTGRISSupport.slang"

[ForceInline]
void rtptGRISCapturePrefix(
    uint bounce,
    ShadingData sd,
    IMaterialInstance mi,
    HitInfo hit,
    float3 direction,
    float3 throughput,
    inout GrisLocalPrefix prefix
)
{
    // New fixed-x2 generation uses full-BSDF / marginal-PDF continuation at
    // both continuous interfaces. The legacy alternating path keeps its
    // original single-diffuse support contract.
#if RTPT_GRIS_ALTERNATING
    const bool supported = rtptGRISSupportsFirstVertex(sd, mi.getLobeTypes(sd));
#else
    const bool supported = rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd));
#endif
    if (bounce == 1 && supported)
    {
        prefix.x1Hit = hit.pack();
        prefix.firstDirW = direction;
        prefix.throughputToX1 = throughput;
    }
}

float rtptGRISAreaPdf(ShadingData sd, Ray ray, float continuationPdf)
{
#if !RTPT_GRIS_ALTERNATING
    // q is the actual sampled density. Only its geometric Jacobian uses the
    // same represented edge as the physical numerator and cross evaluation.
    float3 direction;
    float distanceSquared;
    if (!rtptGrisPrefixDirection(ray.origin, sd.posW, direction, distanceSquared)) return 0.f;
    return continuationPdf * abs(dot(sd.faceN, direction)) / distanceSquared;
#else
    const float3 edge = sd.posW - ray.origin;
    return continuationPdf * abs(dot(sd.faceN, ray.dir)) / dot(edge, edge);
#endif
}

#if ENABLE_SHARC && SHARC_QUERY
// A recorded cache terminal owns this contribution and ends the local path.
[ForceInline]
bool rtptGRISCaptureCacheTerminal(
    uint bounce,
    ShadingData sd,
    IMaterialInstance mi,
    HitInfo hit,
    Ray ray,
    float previousContinuationPdf,
    float3 contribution,
    inout GrisLocalPrefix prefix,
    inout GrisSpatialRecord suffix
)
{
    if (bounce == 1u) prefix.x1Hit = makeInvalidHit().pack();
    if (bounce == 2u && HitInfo(prefix.x1Hit).isValid() && rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd)))
    {
        const float areaPdf = rtptGRISAreaPdf(sd, ray, previousContinuationPdf);
        if (areaPdf > 0.f && isfinite(areaPdf) && all(isfinite(contribution)))
        {
            suffix.reconnectHit = hit.pack();
            suffix.areaPdf = areaPdf;
            suffix.candidate.terminalKind = uint(GrisTerminalKind::GrisCacheTerminal);
            suffix.candidate.F = contribution;
            return true;
        }
    }
    return false;
}
#endif

struct GrisDirectLightSample
{
    RTPTLightSample light;
    bool reusable;
#if RTPT_REGIR_TRANSPORT
    bool fromReGIR;
    uint stableID;
    float2 uv;
    float risWeight;
    float inverseDomainProbability;
#endif
};

bool rtptGRISSampleDirectLight(ShadingData sd, inout SampleGenerator sg, out GrisDirectLightSample sample)
{
    sample = {};
#if RTPT_REGIR_TRANSPORT
    const uint coverage = rtptReGIRTransportCoverage(false);
    sample.fromReGIR = coverage != 0u;
    sample.inverseDomainProbability = 1.f;
#if !RTPT_REGIR_ONLY
    if (sample.fromReGIR && any(rtptLightCategoryProbabilitiesForCoverage(coverage) > 0.f))
    {
        // The light domains are disjoint. The selection probability is common
        // to all prefixes that reconnect to this fixed x2 vertex.
        sample.fromReGIR = sampleNext1D(sg) < 0.5f;
        sample.inverseDomainProbability = 2.f;
    }
#endif
    bool sampledLight = false;
    if (sample.fromReGIR)
        sampledLight = rtptReGIRSampleTransportLight(sd, sg, sample.light, sample.stableID, sample.uv, sample.risWeight);
#if !RTPT_REGIR_ONLY
    else
        sampledLight = rtptSampleLightForCoverage(sd, coverage, sg, sample.light);
#endif
    if (!sampledLight) return false;
    sample.light.LiOverPdf *= sample.inverseDomainProbability;
    // At fixed, front-facing x2 the complementary environment ray retains
    // its direction and visibility when reconnected.
    sample.reusable = coverage != 0u;
#else
    if (!rtptSampleLight(sd, sg, sample.light)) return false;
#endif
    sample.reusable = sample.reusable || sample.light.analytic || sample.light.visibilityRay.tMax < FLT_MAX;
    return true;
}

void rtptGRISStoreDirectTerminal(GrisDirectLightSample sample, inout GrisSpatialRecord suffix)
{
#if RTPT_REGIR_TRANSPORT
    if (sample.fromReGIR)
    {
        // Legacy terminal reconstruction only. Complete fixed-x2 paths use
        // GrisReGIRPath and keep real direction/weighted incident factors.
        suffix.candidate.terminalKind = uint(GrisTerminalKind::GrisReGIR);
        suffix.lightPdfOrStableID = sample.stableID;
        suffix.suffixDirection = float3(sample.uv, 0.f);
        suffix.suffixLight = float3(sample.risWeight, sample.inverseDomainProbability, 0.f);
        return;
    }
#endif
    suffix.candidate.terminalKind = uint(GrisTerminalKind::GrisNee);
    suffix.suffixDirection = sample.light.dir;
    suffix.suffixLight = sample.light.LiOverPdf;
    suffix.lightPdfOrStableID = asuint(sample.light.pdf);
    suffix.lightIsAnalytic = sample.light.analytic;
}

// Record a reusable x2 light event or return its contribution to the local path.
[ForceInline]
float3 rtptGRISCaptureDirectTerminal(
    ShadingData sd,
    IMaterialInstance mi,
    RTPTSamplingContext sampling,
    HitInfo hit,
    Ray ray,
    float previousContinuationPdf,
    float3 throughput,
    SceneRayQuery<true> query,
    inout SampleGenerator sg,
    inout GrisSpatialRecord suffix
)
{
    GrisDirectLightSample sample;
    if (!rtptGRISSampleDirectLight(sd, sg, sample)) return float3(0.f);

    bool hasBSDFCompetitor = RTPT_GRIS_ALTERNATING == 0;
#if RTPT_REGIR_TRANSPORT
    hasBSDFCompetitor = hasBSDFCompetitor && !sample.fromReGIR;
#endif
    const float3 contribution = throughput * rtptEvaluateLightSample(sd, mi, sampling, sample.light, sg, hasBSDFCompetitor);
    const float areaPdf = rtptGRISAreaPdf(sd, ray, previousContinuationPdf);
    const bool canReuse = sample.reusable && areaPdf > 0.f && isfinite(areaPdf) && all(isfinite(contribution));
    const bool positive = all(isfinite(contribution)) && any(contribution > 0.f);
    if (!(canReuse || positive) || !query.traceVisibilityRay(sample.light.visibilityRay)) return float3(0.f);
    if (!canReuse) return contribution;

    // Keep a visible proposal even if its source BSDF gives zero.
    suffix.reconnectHit = hit.pack();
    suffix.areaPdf = areaPdf;
    rtptGRISStoreDirectTerminal(sample, suffix);
    suffix.candidate.F = positive ? contribution : float3(0.f);
    return float3(0.f);
}

#if !RTPT_GRIS_ALTERNATING
#include "RTPTGRISPathBuilder.slang"
#endif
