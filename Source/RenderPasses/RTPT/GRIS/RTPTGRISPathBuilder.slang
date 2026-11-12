#pragma once

// Per-invocation state only. Persistent records keep just the selected term.
struct GrisPathBuilder
{
    PackedHitInfo reconnectHit;
    float areaPdf; // Active walk's actual prefix proposal/reference product.
    float3 rcWi;
    float3 tailThroughput;
    float sumH;
    float winnerH;
    bool hasInterface;
    bool hasTail;
#if RTPT_GRIS_SUFFIX_REPLAY
    uint suffixInstanceMask;
    uint4 postX2RngState;
#endif
};

void rtptGRISBeginWalk(inout GrisPathBuilder builder)
{
    // Reset transport state only. Both root walks share the same terminal
    // weight sum, selected weight and persistent winner payload.
    builder.reconnectHit = makeInvalidHit().pack();
    builder.areaPdf = 0.f;
    builder.rcWi = 0.f;
    builder.tailThroughput = 0.f;
    builder.hasInterface = false;
    builder.hasTail = false;
#if RTPT_GRIS_SUFFIX_REPLAY
    builder.suffixInstanceMask = 0u;
    builder.postX2RngState = 0u;
#endif
}

void rtptGRISBeginInterface(uint bounce, ShadingData sd, IMaterialInstance mi, HitInfo hit,
    Ray ray, float previousContinuationPdf, bool previousDelta, GrisLocalPrefix prefix,
    inout GrisPathBuilder builder, inout GrisSpatialRecord suffix)
{
    if (!rtptGRISPathReuseEnabled() || bounce != 2u || previousDelta || !HitInfo(prefix.x1Hit).isValid() ||
        !rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd))) return;
    const float areaPdf = rtptGRISAreaPdf(sd, ray, previousContinuationPdf);
    if (!(areaPdf > 0.f) || !isfinite(areaPdf)) return;
    // areaPdf already holds the actual sampled root-edge area density.
    // Capture the second edge before any selected terminal copies its R.
    const float prefixRatio = builder.areaPdf * areaPdf;
    if (!(prefixRatio > 0.f) || !isfinite(prefixRatio)) return;
    builder.hasInterface = true;
    builder.reconnectHit = hit.pack();
    builder.areaPdf = prefixRatio;
    // A new walk's interface must not overwrite a previously selected term.
}

void rtptGRISAddPathTerminalPayload(inout GrisPathBuilder builder, inout SampleGenerator terminalRng,
    uint currentRoot, PackedHitInfo currentX1,
    float3 contribution, uint kind, bool deepTail, float3 direction, float3 incident,
    uint lightPayload, bool analytic, uint terminalBounce, inout GrisSpatialRecord suffix
#if RTPT_GRIS_SUFFIX_REPLAY
    , uint4 directNeeRngState = 0u
#endif
#if RTPT_GRIS_REGIR_REPLAY
    , float innerRISWeight = 0.f
#endif
#if RTPT_GRIS_SHARC_REPLAY
    , uint2 sharcKey = 0u, float3 sharcGain = 0.f
#endif
    )
{
    const float h = dot(abs(contribution), float3(0.2126f, 0.7152f, 0.0722f));
    if (!(h > 0.f) || !isfinite(h) || !all(isfinite(incident))) return;
    builder.sumH += h;
    if (sampleNext1D(terminalRng) * builder.sumH >= h) return;
    builder.winnerH = h;
    suffix.candidate.rootLobe = currentRoot;
    suffix.sourceX1 = currentX1;
    suffix.reconnectHit = builder.reconnectHit;
    suffix.areaPdf = builder.areaPdf;
    suffix.suffixDirection = direction;
    suffix.suffixLight = incident;
    suffix.lightPdfOrStableID = lightPayload;
    suffix.lightIsAnalytic = analytic;
    suffix.candidate.F = contribution;
    suffix.candidate.terminalKind = kind | (deepTail ? kGrisDeepTail : 0u);
#if RTPT_GRIS_SUFFIX_REPLAY
    suffix.suffixInstanceMask = builder.suffixInstanceMask;
    suffix.terminalBounce = terminalBounce;
    suffix.postX2RngState = terminalBounce == 2u ? directNeeRngState : builder.postX2RngState;
#endif
#if RTPT_GRIS_SHARC_REPLAY
    suffix.sharcKey = sharcKey;
    suffix.sharcGain = sharcGain;
#if RTPT_GRIS_REGIR_REPLAY
    if (rtptGrisTerminalKind(kind) == uint(GrisTerminalKind::GrisReGIRPath))
        suffix.sharcGain.x = innerRISWeight;
#endif
#elif RTPT_GRIS_REGIR_REPLAY
    suffix.innerRISWeight = innerRISWeight;
#endif
}

void rtptGRISAddPathTerminal(inout GrisPathBuilder builder, inout SampleGenerator terminalRng,
    uint currentRoot, PackedHitInfo currentX1,
    float3 contribution, uint kind, bool deepTail, float3 direction, float3 incident,
    float lightPdf, bool analytic, uint terminalBounce, inout GrisSpatialRecord suffix
#if RTPT_GRIS_SHARC_REPLAY
    , uint2 sharcKey = 0u, float3 sharcGain = 0.f
#endif
    )
{
    rtptGRISAddPathTerminalPayload(builder, terminalRng, currentRoot, currentX1, contribution,
        kind, deepTail, direction, incident, asuint(lightPdf), analytic, terminalBounce, suffix
#if RTPT_GRIS_SHARC_REPLAY
#if RTPT_GRIS_SUFFIX_REPLAY
        , 0u
#endif
#if RTPT_GRIS_REGIR_REPLAY
        , 0.f
#endif
        , sharcKey, sharcGain
#endif
        );
}

void rtptGRISFinalizePath(GrisPathBuilder builder, inout GrisSpatialRecord suffix)
{
    suffix.candidate.M = 1.f;
    if (!(builder.winnerH > 0.f)) return;
    const float weight = builder.sumH / builder.winnerH;
    if (!isfinite(weight) || !all(isfinite(suffix.candidate.F * weight))) return;
    suffix.candidate.W = weight;
    suffix.candidate.hasWinner = true;
}

// The selected x2 -> light sample is stored before x2 scattering and its MIS.
// Deeper terms retain their own endpoint scattering/MIS in tailIncident.
float3 rtptGRISCapturePathNEE(uint bounce, ShadingData sd, IMaterialInstance mi,
    RTPTSamplingContext sampling, float3 throughput, SceneRayQuery<true> query,
    uint currentRoot, PackedHitInfo currentX1,
    inout SampleGenerator sg, inout SampleGenerator terminalRng,
    inout GrisPathBuilder builder, inout GrisSpatialRecord suffix)
{
#if RTPT_REGIR_TRANSPORT
    // The explicit-path adapter currently supports the cell-only domain.
    // Mixed remaining-light domains retain the complete local estimator.
#if !RTPT_REGIR_ONLY
    return throughput * rtptEstimateDirect(sd, mi, sampling, sg);
#else
    if (!rtptGRISPathReuseEnabled()) return throughput * rtptEstimateDirect(sd, mi, sampling, sg);
    if (rtptReGIRTransportCoverage(false) == 0u) return float3(0.f);
    RTPTLightSample light;
    uint stableID;
    float2 lightUV;
    float innerRISWeight;
#if RTPT_GRIS_REGIR_REPLAY
    const uint4 directRngState = bounce == 2u ? rtptGrisCaptureReplayRng(sg) : 0u;
    SampleGenerator cellRng;
    lightUV = rtptGrisSplitReGIRReplayRng(sg, bounce, cellRng);
    RTPTDILightInfo lightInfo;
    if (!rtptReGIRSelectTransportLight(sd, cellRng, lightInfo, innerRISWeight)) return float3(0.f);
    stableID = lightInfo.pad0;
    if (!rtptReGIRBuildTransportSample(sd, lightInfo, lightUV, innerRISWeight, light)) return float3(0.f);
#else
    if (!rtptReGIRSampleTransportLight(sd, sg, light, stableID, lightUV, innerRISWeight)) return float3(0.f);
#endif
    // LiOverPdf already contains the cell/RIS and conditional-light sampling
    // compensation. ReGIR owns this non-delta direct-light domain, so there
    // is no ordinary light/BSDF MIS or usable marginal light PDF here.
    const float3 value = rtptEvaluateLightSample(sd, mi, sampling, light, sg, false);
    const float3 contribution = throughput * value;
    if (!all(isfinite(contribution)) || !query.traceVisibilityRay(light.visibilityRay)) return float3(0.f);
    if (!builder.hasInterface) return contribution;
    const bool deepTail = bounce > 2u;
    const float3 incident = deepTail ? builder.tailThroughput * value : light.LiOverPdf;
    const float3 direction = deepTail ? builder.rcWi : light.dir;
    // Identity changes with the selected terminal, including deep-tail terms.
    // The historical RIS compensation remains inside incident; current table
    // weights must never replace it when an unrelated light changes.
    rtptGRISAddPathTerminalPayload(builder, terminalRng, currentRoot, currentX1, contribution,
        uint(GrisTerminalKind::GrisReGIRPath), deepTail, direction, incident, stableID, light.analytic,
#if RTPT_GRIS_REGIR_REPLAY
        bounce, suffix, directRngState, innerRISWeight);
#else
        0u, suffix);
#endif
    return float3(0.f);
#endif
#else
    if (!rtptGRISPathReuseEnabled()) return throughput * rtptEstimateDirect(sd, mi, sampling, sg);
#if RTPT_GRIS_SUFFIX_REPLAY
    // A direct NEE winner needs the state before the light category draw.
    const uint4 directNeeRngState = bounce == 2u && builder.hasInterface ? rtptGrisCaptureReplayRng(sg) : 0u;
#endif
    RTPTLightSample light;
    if (!rtptSampleLight(sd, sg, light)) return float3(0.f);
    const float3 value = rtptEvaluateLightSample(sd, mi, sampling, light, sg, true);
    const float3 contribution = throughput * value;
    if (!all(isfinite(contribution)) || !query.traceVisibilityRay(light.visibilityRay)) return float3(0.f);
    if (!builder.hasInterface) return contribution;
    const bool deepTail = bounce > 2u;
    const float3 incident = deepTail ? builder.tailThroughput * value : light.LiOverPdf;
    const float3 direction = deepTail ? builder.rcWi : light.dir;
    uint kind = uint(GrisTerminalKind::GrisNee);
#if RTPT_GRIS_SUFFIX_REPLAY
    if (light.replayType == RTPTReplayLightType::Emissive) kind |= kGrisEmissiveNee;
    if (light.replayType == RTPTReplayLightType::Point) kind |= kGrisPointNee;
    if (light.replayType == RTPTReplayLightType::Environment) kind |= kGrisEnvironmentNee;
#endif
    rtptGRISAddPathTerminalPayload(builder, terminalRng, currentRoot, currentX1, contribution,
        kind, deepTail, direction, incident, asuint(light.pdf), light.analytic, bounce, suffix
#if RTPT_GRIS_SUFFIX_REPLAY
        , light.replayType != RTPTReplayLightType::None ? directNeeRngState : 0u
#endif
        );
    return float3(0.f);
#endif
}
