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
    if (bounce == 1 && rtptGRISSupportsFirstVertex(sd, mi.getLobeTypes(sd)))
    {
        prefix.x1Hit = hit.pack();
        prefix.firstDirW = direction;
        prefix.throughputToX1 = throughput;
    }
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
        const float3 edge = sd.posW - ray.origin;
        const float areaPdf = previousContinuationPdf * abs(dot(sd.faceN, ray.dir)) / dot(edge, edge);
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
#if RTPT_REGIR_TRANSPORT
    , uint coverage
#endif
)
{
    RTPTLightSample light;
#if RTPT_REGIR_TRANSPORT
    uint lightStableID = 0u;
    float2 lightUV = 0.f;
    float risWeight = 0.f;
    bool sampleReGIR = coverage != 0u;
    float inverseDomainProbability = 1.f;
#if !RTPT_REGIR_ONLY
    if (sampleReGIR && any(rtptLightCategoryProbabilitiesForCoverage(coverage) > 0.f))
    {
        // The light domains are disjoint. The selection probability is common
        // to all prefixes that reconnect to this fixed x2 vertex.
        sampleReGIR = sampleNext1D(sg) < 0.5f;
        inverseDomainProbability = 2.f;
    }
#endif
    bool sampledLight = false;
    if (sampleReGIR)
        sampledLight = rtptReGIRSampleTransportLight(sd, sg, light, lightStableID, lightUV, risWeight);
#if !RTPT_REGIR_ONLY
    else
        sampledLight = rtptSampleLightForCoverage(sd, coverage, sg, light);
#endif
#else
    const bool sampledLight = rtptSampleLight(sd, sg, light);
#endif
    if (!sampledLight) return float3(0.f);

    bool hasBSDFCompetitor = RTPT_GRIS_ALTERNATING == 0;
    bool reusableLight = light.analytic || light.visibilityRay.tMax < FLT_MAX;
#if RTPT_REGIR_TRANSPORT
    hasBSDFCompetitor = hasBSDFCompetitor && !sampleReGIR;
    light.LiOverPdf *= inverseDomainProbability;
    // At this fixed, front-facing x2 the complementary environment ray
    // also retains its direction and its visibility result when reconnected.
    reusableLight = reusableLight || coverage != 0u;
#endif
    const float3 contribution = throughput * rtptEvaluateLightSample(sd, mi, sampling, light, sg, hasBSDFCompetitor);
    const float3 edge = sd.posW - ray.origin;
    const float areaPdf = previousContinuationPdf * abs(dot(sd.faceN, ray.dir)) / dot(edge, edge);
    const bool canReuse = reusableLight && areaPdf > 0.f && isfinite(areaPdf) && all(isfinite(contribution));
    const bool positive = all(isfinite(contribution)) && any(contribution > 0.f);
    if (!(canReuse || positive) || !query.traceVisibilityRay(light.visibilityRay)) return float3(0.f);
    if (!canReuse) return contribution;

    // Keep a visible proposal even if its source BSDF gives zero.
    suffix.reconnectHit = hit.pack();
    suffix.areaPdf = areaPdf;
#if RTPT_REGIR_TRANSPORT
    if (sampleReGIR)
    {
        suffix.candidate.terminalKind = uint(GrisTerminalKind::GrisReGIR);
        suffix.lightPdfOrStableID = lightStableID;
        suffix.suffixDirection = float3(lightUV, 0.f);
        suffix.suffixLight = float3(risWeight, inverseDomainProbability, 0.f);
    }
    else
#endif
    {
        suffix.candidate.terminalKind = uint(GrisTerminalKind::GrisNee);
        suffix.suffixDirection = light.dir;
        suffix.suffixLight = light.LiOverPdf;
        suffix.lightPdfOrStableID = asuint(light.pdf);
        suffix.lightIsAnalytic = light.analytic;
    }
    suffix.candidate.F = positive ? contribution : float3(0.f);
    return float3(0.f);
}
