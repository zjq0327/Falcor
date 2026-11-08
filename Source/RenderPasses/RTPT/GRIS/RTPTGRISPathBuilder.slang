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
}

bool rtptGRISPathReuseEnabled()
{
#if RTPT_REGIR_TRANSPORT
    return false;
#else
#if ENABLE_SHARC && SHARC_QUERY
    if (gSharcSettings.useCache != 0u) return false;
#endif
    return true;
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

void rtptGRISAddPathTerminal(inout GrisPathBuilder builder, inout SampleGenerator terminalRng,
    uint currentRoot, PackedHitInfo currentX1,
    float3 contribution, uint kind, bool deepTail, float3 direction, float3 incident,
    float lightPdf, bool analytic, inout GrisSpatialRecord suffix)
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
    suffix.lightPdfOrStableID = asuint(lightPdf);
    suffix.lightIsAnalytic = analytic;
    suffix.candidate.F = contribution;
    suffix.candidate.terminalKind = kind | (deepTail ? kGrisDeepTail : 0u);
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
    // Preserve the existing complete, disjoint ReGIR/light domains locally.
    return throughput * rtptEstimateDirect(sd, mi, sampling, sg);
#else
    if (!rtptGRISPathReuseEnabled()) return throughput * rtptEstimateDirect(sd, mi, sampling, sg);
    RTPTLightSample light;
    if (!rtptSampleLight(sd, sg, light)) return float3(0.f);
    const float3 value = rtptEvaluateLightSample(sd, mi, sampling, light, sg, true);
    const float3 contribution = throughput * value;
    if (!all(isfinite(contribution)) || !query.traceVisibilityRay(light.visibilityRay)) return float3(0.f);
    if (!builder.hasInterface) return contribution;
    const bool deepTail = bounce > 2u;
    const float3 incident = deepTail ? builder.tailThroughput * value : light.LiOverPdf;
    const float3 direction = deepTail ? builder.rcWi : light.dir;
    rtptGRISAddPathTerminal(builder, terminalRng, currentRoot, currentX1, contribution, uint(GrisTerminalKind::GrisNee),
        deepTail, direction, incident, light.pdf, light.analytic, suffix);
    return float3(0.f);
#endif
}
