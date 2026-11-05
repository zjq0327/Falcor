#pragma once

#include "Signal/RTPTSignalResolve.slang"

#if RTPT_USE_GRIS || RTPT_GRIS_GENERATE
#include "GRIS/RTPTGRISTypes.slang"
#include "GRIS/RTPTGRISSupport.slang"
#endif

#if RTPT_USE_GRIS
#if RTPT_GRIS_ALTERNATING
StructuredBuffer<GrisDualShadedIndirect> gGRISShadedIndirect;
#else
StructuredBuffer<GrisShadedIndirect> gGRISShadedIndirect;

GrisFirstHit rtptResolveGrisFirstHit(GrisShadedIndirect gris, uint rootLobe, ShadingData sd,
    IMaterialInstance mi, bool traceMissing, inout SampleGenerator rng)
{
    GrisFirstHit result = {};
    result.distanceState = kRTPTDistanceNotSelected;
    if (gris.state != uint(GrisRecordState::GrisUnprepared) && gris.rootLobe == rootLobe)
    {
        result = gris.firstHit;
        if (result.distanceState == kRTPTDistanceHit || result.distanceState == kRTPTDistanceMiss) return result;
    }
    if (!traceMissing) return result;

    // The caller has enabled only this lobe. Probe geometry independently of
    // the radiance sample, including valid rays with a black BSDF weight.
    // Retry rejected directions before issuing the single ray. RELAX 3.1
    // cannot reconstruct a missing specular distance on its own.
    for (uint attempt = 0; attempt < 4; ++attempt)
    {
        BSDFSample bs = {};
        if (!mi.sample(sd, rng, bs) || !(bs.pdf > 0.f) || !isfinite(bs.pdf) ||
            !all(isfinite(bs.wo)) || bs.isLobe(LobeType::Delta) || bs.isLobe(LobeType::Transmission))
            continue;

        SceneRayQuery<true> query;
        float hitT;
        const HitInfo hit = query.traceRay(Ray(sd.computeRayOrigin(), bs.wo), hitT);
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        if (hit.getType() == HitType::Triangle)
            hitT = length(gScene.getVertexData(hit.getTriangleHit()).posW - sd.posW);
#endif
        result.hitT = hit.isValid() ? min(kRTPTNRDMissDistance, max(1e-5f, hitT)) : kRTPTNRDMissDistance;
        result.distanceState = hit.isValid() ? kRTPTDistanceHit : kRTPTDistanceMiss;
        return result;
    }

    result.hitT = 0.f;
    result.distanceState = kRTPTDistanceSampleRejected;
    return result;
}
#endif
#endif

#ifndef RTPT_SEPARATE_SIGNAL_RESOLVE
#define RTPT_SEPARATE_SIGNAL_RESOLVE 0
#endif

#if RTPT_SEPARATE_SIGNAL_RESOLVE
RWStructuredBuffer<RTPTSignalRecord> gSignalRecords;

void rtptStoreSignalRecord(
    uint2 pixel,
    RTPTNRDSignals directAndGuides,
    float3 indirectDiffuse,
    float3 indirectSpecular,
    uint diffuseDistanceState,
    uint specularDistanceState
)
{
    RTPTSignalRecord record = {};
    record.directDiffuse = directAndGuides.diffuse;
    record.directSpecular = directAndGuides.specular;
    record.indirectDiffuse = indirectDiffuse;
    record.indirectSpecular = indirectSpecular;
    record.emission = directAndGuides.emission;
    record.residual = directAndGuides.residual;
    record.diffuseReflectance = directAndGuides.diffuseReflectance;
    record.specularReflectance = directAndGuides.specularReflectance;
    record.diffuseHitDistance = directAndGuides.diffuseHitDistance;
    record.specularHitDistance = directAndGuides.specularHitDistance;
    record.diffuseDistanceState = diffuseDistanceState;
    record.specularDistanceState = specularDistanceState;
    record.normalRoughness = directAndGuides.normalRoughness;
    record.viewZ = directAndGuides.viewZ;
    record.motionW = directAndGuides.motionW;
    gSignalRecords[pixel.y * gParams.frameDim.x + pixel.x] = record;
}
#endif

/** Establish domain ownership before sampling the original NEE/continuations.
    Prepared is independent of whether the final reservoir is empty, black or
    occluded. No brightness or winner-validity test may select the estimator.
*/
uint rtptLoadPrimaryDICoverage(uint2 pixel, uint sampleIndex, out float3 diffuse, out float3 specular)
{
    diffuse = specular = 0.f;
#if RTPT_USE_RESTIR_DI
    if (gParams.useNEE == 0u) return 0u;
    if (gDISettings.prepared == 0u) return 0u;
    if (any(gDISettings.frameDim != gParams.frameDim)) return 0u;
#if RTPT_USE_PRIMARY_SURFACE
    if (gDISettings.frameStamp != gPrimarySettings.frameStamp) return 0u;
#endif
    if (any(pixel >= gDISettings.frameDim)) return 0u;
    if (sampleIndex != gDISettings.sampleIndex) return 0u;
    uint count, stride;
    gDIResults.GetDimensions(count, stride);
    const uint index = pixel.y * gDISettings.frameDim.x + pixel.x;
    if (index >= count) return 0u;
    const RTPTDIResult result = gDIResults[index];
    if ((result.flags & kRTPTDIResultPrepared) == 0u) return 0u;
    if (result.generation != gDISettings.generation) return 0u;
    if (result.sampleIndex != sampleIndex) return 0u;
    if (result.frameStamp != gDISettings.frameStamp) return 0u;
    if (result.coverageMask != gDISettings.coverageMask) return 0u;
    diffuse = result.diffuse;
    specular = result.specular;
    return result.coverageMask;
#else
    return 0u;
#endif
}

/** NRD uses regular octahedral normals, not equal-area environment coordinates.
    Preserve the projected components before folding; avoid overlapping swizzles.
*/
float2 rtptNRDPackNormal(float3 normal)
{
    const float3 n = normal / max(1e-20f, abs(normal.x) + abs(normal.y) + abs(normal.z));
    const float x = n.z < 0.f ? (1.f - abs(n.y)) * (n.x >= 0.f ? 1.f : -1.f) : n.x;
    const float y = n.z < 0.f ? (1.f - abs(n.x)) * (n.y >= 0.f ? 1.f : -1.f) : n.y;
    return float2(x, y) * 0.5f + 0.5f;
}

#if RTPT_GRIS_GENERATE && !RTPT_GRIS_SPATIAL
#include "GRIS/RTPTGRISTerminalPicker.slang"
#endif

/** Trace the selected component on the primary surface.
    The ordinary callers select their component with probability one. Generate
    passes its explicit root-selection probability and captures the candidate event.
    Later vertices use the mixed reflection estimator.
*/
float3 rtptTraceNRDContinuation(
    ShadingData primarySD,
    IMaterialInstance primaryMI,
    uint primaryLobes,
    RTPTSamplingContext primarySampling,
    inout SampleGenerator sg,
    out float firstHitDistance,
    out uint firstHitDistanceState,
    inout RTPTSharcStats sharcStats,
    uint rootCoverage
#if RTPT_GRIS_GENERATE
    , float rootProbability
#if RTPT_GRIS_SPATIAL
    , inout GrisLocalPrefix prefix
    , inout GrisSpatialRecord suffix
#if RTPT_GRIS_ALTERNATING
    , bool generateSuffix
#endif
#else
    , inout TerminalPicker terminalPicker
    , inout SampleGenerator terminalRng
#endif
#endif
)
{
    firstHitDistance = kRTPTNRDMissDistance;
    firstHitDistanceState = kRTPTDistanceSampleRejected;
    primarySD.mtl.setActiveLobes(primaryLobes);
    BSDFSample bs = {};
    bool previousGuideSelected = false;
    const bool sampled = rtptSampleContinuation(primarySD, primaryMI, primarySampling, sg, bs, previousGuideSelected);
    if (!sampled) return float3(0.f);
    if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) return float3(0.f);

    bool previousDelta = bs.isLobe(LobeType::Delta);
    if (!previousDelta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))) return float3(0.f);
    float3 throughput = bs.weight;
#if RTPT_GRIS_GENERATE
    throughput /= rootProbability;
#endif
#if !(RTPT_GRIS_GENERATE && RTPT_GRIS_ALTERNATING)
    if (!any(throughput > 0.f)) return float3(0.f);
#endif
    float3 radiance = 0.f;
    float3 previousPosition = primarySD.posW;
    float3 previousNormal = primarySD.getOrientedFaceNormal();
    float previousContinuationPdf = bs.pdf;
    bool previousUsedNEE = gParams.useNEE != 0 && !previousDelta;
#if RTPT_REGIR_TRANSPORT
    uint previousReGIRCoverage = 0u;
#endif
#if ENABLE_SHARC && SHARC_QUERY
    bool previousDiffuse = !previousGuideSelected && bs.isLobe(LobeType::DiffuseReflection);
    float previousRoughness = primaryMI.getProperties(primarySD).roughness;
#if RTPT_GRIS_GENERATE
    RTPTSamplingContext previousSharcSampling = primaryLobes == uint(LobeType::DiffuseReflection)
        ? primarySampling : rtptBSDFSamplingContext();
#endif
#endif
    Ray ray = Ray(primarySD.computeRayOrigin(), bs.wo);
    SceneRayQuery<true> query;
    firstHitDistanceState = kRTPTDistanceUntraced;

    // Always trace the first component ray before roulette so the distance is
    // available even when the radiance estimator later terminates.
    for (uint bounce = 1; bounce <= gParams.maxBounces; ++bounce)
    {
        float hitT;
#if ENABLE_SHARC && SHARC_QUERY
        ++sharcStats.radianceRays;
#endif
        const HitInfo hit = query.traceRay(ray, hitT);
        if (bounce == 1)
            firstHitDistanceState = hit.isValid() ? kRTPTDistanceHit : kRTPTDistanceMiss;
        if (bounce == 1 && hit.isValid())
            firstHitDistance = min(kRTPTNRDMissDistance, max(1e-5f, hitT));

        if (!hit.isValid())
        {
#if USE_ENV_LIGHT
#if RTPT_REGIR_ONLY
            const float misWeight = 1.f;
#elif RTPT_REGIR_TRANSPORT
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousContinuationPdf,
                    rtptEnvironmentLightPdfForCoverage(ray.dir, bounce == 1u ? rootCoverage : previousReGIRCoverage))
                : 1.f;
#elif RTPT_USE_RESTIR_DI
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousContinuationPdf,
                    bounce == 1u ? rtptEnvironmentLightPdfForCoverage(ray.dir, rootCoverage) : rtptEnvironmentLightPdf(ray.dir))
                : 1.f;
#else
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousContinuationPdf, rtptEnvironmentLightPdf(ray.dir))
                : 1.f;
#endif
            const float3 contribution = throughput * gScene.envMap.eval(ray.dir) * misWeight;
            if (all(isfinite(contribution)))
            {
#if RTPT_GRIS_GENERATE && !RTPT_GRIS_SPATIAL
                rtptSelectGrisTerminal(terminalPicker, terminalRng, contribution, GrisTerminalKind::GrisEnvironment);
#endif
                radiance += contribution;
            }
#endif
            break;
        }
        if (hit.getType() != HitType::Triangle) break;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const TriangleHit triangleHit = hit.getTriangleHit();
        const VertexData vertex = gScene.getVertexData(triangleHit);
        if (bounce == 1)
            firstHitDistance = min(kRTPTNRDMissDistance, max(1e-5f, length(vertex.posW - primarySD.posW)));
#if RTPT_GRIS_GENERATE && RTPT_GRIS_ALTERNATING
        if (!any(throughput > 0.f)) break;
#endif
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL
        if (bounce == 1 && rtptGRISSupportsFirstVertex(sd, mi.getLobeTypes(sd)))
        {
            prefix.x1Hit = hit.pack();
            prefix.firstDirW = ray.dir;
            prefix.throughputToX1 = throughput;
        }
#endif

#if ENABLE_SHARC && SHARC_QUERY
        const BSDFProperties sharcProperties = mi.getProperties(sd);
        float3 cachedRadiance;
#if RTPT_GRIS_GENERATE
        // The guided and BSDF techniques share one continuation on the supported diffuse edges.
        const bool sharedDiffuse = previousSharcSampling.alpha > 0.f;
        if (rtptTrySharcQueryOnEdge(sd, mi, sharcProperties, bounce, previousDelta,
            previousGuideSelected && !sharedDiffuse, previousDiffuse || sharedDiffuse, previousRoughness,
            length(sd.posW - previousPosition), previousSharcSampling, ray.dir, sharcStats, cachedRadiance))
#else
        if (rtptTrySharcQuery(sd, mi, sharcProperties, bounce, previousDelta, previousGuideSelected, previousDiffuse, previousRoughness,
            length(sd.posW - previousPosition), sharcStats, cachedRadiance))
#endif
        {
            const float3 contribution = throughput * cachedRadiance;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL
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
                    break;
                }
            }
#endif
            if (all(isfinite(contribution)))
            {
#if RTPT_GRIS_GENERATE && !RTPT_GRIS_SPATIAL
                rtptSelectGrisTerminal(terminalPicker, terminalRng, contribution, GrisTerminalKind::GrisCacheTerminal);
#endif
                radiance += contribution;
            }
            break;
        }
#endif

#if USE_EMISSIVE_LIGHTS
        float3 emission = mi.getProperties(sd).emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (any(emission > 0.f))
        {
            bool coveredRootEvent = false;
#if RTPT_REGIR_TRANSPORT
            if (!previousDelta)
                coveredRootEvent = rtptDICoversEmissiveHit(triangleHit, bounce == 1u ? rootCoverage : previousReGIRCoverage);
#elif RTPT_USE_RESTIR_DI
            if (bounce == 1u && !previousDelta)
                coveredRootEvent = rtptDICoversEmissiveHit(triangleHit, rootCoverage);
#endif
            if (!coveredRootEvent)
            {
#if RTPT_REGIR_ONLY
                const bool hasNeeCompetitor = false;
                const float lightPdf = 0.f;
#else
                const bool hasNeeCompetitor = previousUsedNEE && !previousDelta;
                const float lightPdf = hasNeeCompetitor ?
#if RTPT_REGIR_TRANSPORT
                        rtptEmissiveLightPdfForCoverage(previousPosition, previousNormal, triangleHit, sd,
                            bounce == 1u ? rootCoverage : previousReGIRCoverage)
#elif RTPT_USE_RESTIR_DI
                        bounce == 1u ? rtptEmissiveLightPdfForCoverage(previousPosition, previousNormal, triangleHit, sd, rootCoverage)
                                     : rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd)
#else
                        rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd)
#endif
                    : 0.f;
#endif
                const float misWeight = hasNeeCompetitor ? rtptPowerHeuristic(previousContinuationPdf, lightPdf) : 1.f;
                const float3 contribution = throughput * emission * misWeight;
                if (all(isfinite(contribution)))
                {
#if RTPT_GRIS_GENERATE && !RTPT_GRIS_SPATIAL
                    rtptSelectGrisTerminal(terminalPicker, terminalRng, contribution, GrisTerminalKind::GrisEmitter);
#endif
                    radiance += contribution;
                }
            }
            // The covered emission is one event; the hit's reflected indirect
            // transport below remains eligible for NEE, guiding and SHaRC.
        }
#endif
        if (bounce == gParams.maxBounces) break;
#if ENABLE_PG && (RTPT_GRIS_GENERATE || RTPT_USE_GRIS)
        const RTPTSamplingContext sampling = bounce == 1 && rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd))
            ? rtptMakeSamplingContext(sd, mi) : rtptBSDFSamplingContext();
#else
        const RTPTSamplingContext sampling = rtptMakeSamplingContext(sd, mi);
#endif

        const bool hasNonDeltaLobes = (mi.getLobeTypes(sd) & uint(LobeType::NonDeltaReflection)) != 0;
        previousUsedNEE = gParams.useNEE != 0 && hasNonDeltaLobes;
#if RTPT_REGIR_TRANSPORT
        previousReGIRCoverage = previousUsedNEE ? rtptReGIRTransportCoverage(false) : 0u;
#endif
        if (previousUsedNEE)
        {
            float3 contribution = 0.f;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL
            if (bounce == 2 && HitInfo(prefix.x1Hit).isValid() && rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd)))
            {
                RTPTLightSample light;
#if RTPT_REGIR_ONLY
                uint lightStableID;
                float2 lightUV;
                float risWeight;
                bool sampledLight = false;
                if (previousReGIRCoverage != 0u)
                    sampledLight = rtptReGIRSampleTransportLight(sd, sg, light, lightStableID, lightUV, risWeight);
#else
                const bool sampledLight = rtptSampleLight(sd, sg, light);
#endif
                if (sampledLight)
                {
#if RTPT_REGIR_ONLY
                    contribution = throughput * (mi.eval(sd, light.dir, sg) * light.LiOverPdf);
                    const bool finiteLight = true;
#else
                    contribution = throughput * rtptEvaluateLightSample(sd, mi, sampling, light, sg, RTPT_GRIS_ALTERNATING == 0);
                    const bool finiteLight = light.analytic || light.visibilityRay.tMax < FLT_MAX;
#endif
                    const float3 edge = sd.posW - ray.origin;
                    const float areaPdf = previousContinuationPdf * abs(dot(sd.faceN, ray.dir)) / dot(edge, edge);
                    const bool canReuse = finiteLight && areaPdf > 0.f && isfinite(areaPdf) && all(isfinite(contribution));
                    const bool positive = all(isfinite(contribution)) && any(contribution > 0.f);
                    if ((canReuse || positive) && query.traceVisibilityRay(light.visibilityRay))
                    {
                        if (canReuse)
                        {
                            // Keep a visible proposal even if its source BSDF gives zero.
                            suffix.reconnectHit = hit.pack();
                            suffix.areaPdf = areaPdf;
#if RTPT_REGIR_ONLY
                            suffix.candidate.terminalKind = uint(GrisTerminalKind::GrisReGIR);
                            suffix.lightStableID = lightStableID;
                            suffix.suffixDirection = float3(lightUV, 0.f);
                            suffix.suffixLight = float3(risWeight, 0.f, 0.f);
#else
                            suffix.candidate.terminalKind = uint(GrisTerminalKind::GrisNee);
                            suffix.suffixDirection = light.dir;
                            suffix.suffixLight = light.LiOverPdf;
                            suffix.lightPdf = light.pdf;
                            suffix.lightIsAnalytic = light.analytic;
#endif
                            suffix.candidate.F = positive ? contribution : float3(0.f);
                            contribution = 0.f;
                        }
                    }
                    else contribution = 0.f;
                }
            }
            else
#endif
            {
#if RTPT_GRIS_GENERATE && RTPT_GRIS_ALTERNATING && !RTPT_REGIR_ONLY
                RTPTLightSample light;
                const bool continues = generateSuffix && bounce == 1u;
                contribution = throughput * rtptEstimateDirectSample(sd, mi, sampling, sg, light, continues);
#else
                contribution = throughput * rtptEstimateDirect(sd, mi, sampling, sg);
#endif
            }
            if (all(isfinite(contribution)))
            {
#if RTPT_GRIS_GENERATE && !RTPT_GRIS_SPATIAL
#if RTPT_REGIR_ONLY
                rtptSelectGrisTerminal(terminalPicker, terminalRng, contribution, GrisTerminalKind::GrisReGIR);
#else
                rtptSelectGrisTerminal(terminalPicker, terminalRng, contribution, GrisTerminalKind::GrisNee);
#endif
#endif
                radiance += contribution;
            }
        }

#if RTPT_GRIS_GENERATE && RTPT_GRIS_ALTERNATING
        // Only the scheduled component samples x1 -> x2. At x2 the suffix
        // ends with NEE, so there is no competing BSDF sample at that vertex.
        if (!generateSuffix || bounce == 2u) break;
#endif
        bs = {};
        if (!rtptSampleContinuation(sd, mi, sampling, sg, bs, previousGuideSelected)) break;
        if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) break;
        previousDelta = bs.isLobe(LobeType::Delta);
#if ENABLE_SHARC && SHARC_QUERY
        previousDiffuse = !previousGuideSelected && bs.isLobe(LobeType::DiffuseReflection);
        previousRoughness = sharcProperties.roughness;
#if RTPT_GRIS_GENERATE
        previousSharcSampling = bounce == 1u && rtptGRISSupportsFirstVertex(sd, mi.getLobeTypes(sd))
            ? sampling : rtptBSDFSamplingContext();
#endif
#endif
        if (!previousDelta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))) break;
        throughput *= bs.weight;
        if (!all(isfinite(throughput)) || !any(throughput > 0.f)) break;
        if (gParams.useRussianRoulette != 0 && bounce + 1 >= gParams.rrStartBounce)
        {
            const float survival = min(0.95f, max(throughput.x, max(throughput.y, throughput.z)));
            if (sampleNext1D(sg) >= survival) break;
            throughput /= survival;
        }

        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        previousContinuationPdf = bs.pdf;
        ray = Ray(sd.computeRayOrigin(), bs.wo);
#else
        break;
#endif
    }
    return all(isfinite(radiance)) ? radiance : float3(0.f);
}

#if !RTPT_GRIS_GENERATE
// Existing callers, including the delta residual, retain the complete old
// contribution domain. Only the root non-delta D/S calls pass DI ownership.
float3 rtptTraceNRDContinuation(
    ShadingData primarySD,
    IMaterialInstance primaryMI,
    uint primaryLobes,
    RTPTSamplingContext primarySampling,
    inout SampleGenerator sg,
    out float firstHitDistance,
    out uint firstHitDistanceState,
    inout RTPTSharcStats sharcStats
)
{
    return rtptTraceNRDContinuation(primarySD, primaryMI, primaryLobes, primarySampling, sg,
        firstHitDistance, firstHitDistanceState, sharcStats, 0u);
}

// Keep the original continuation interface for the inline fallback and delta
// residual. Its unobserved event-state output is removed by shader compilation.
float3 rtptTraceNRDContinuation(
    ShadingData primarySD,
    IMaterialInstance primaryMI,
    uint primaryLobes,
    RTPTSamplingContext primarySampling,
    inout SampleGenerator sg,
    out float firstHitDistance,
    inout RTPTSharcStats sharcStats
)
{
    uint unusedDistanceState;
    return rtptTraceNRDContinuation(primarySD, primaryMI, primaryLobes, primarySampling, sg,
        firstHitDistance, unusedDistanceState, sharcStats);
}

float3 rtptTraceNRD(uint2 pixel, uint sampleIndex, inout SampleGenerator sg, inout RTPTSharcStats sharcStats)
{
    RTPTNRDSignals signals = {};
    signals.diffuseReflectance = 1.f;
    signals.specularReflectance = 1.f;
    signals.normalRoughness = float4(0.5f, 0.5f, 0.f, 0.f);
    signals.viewZ = kRTPTNRDMissDistance;
#if RTPT_SEPARATE_SIGNAL_RESOLVE
    float3 indirectDiffuse = 0.f;
    float3 indirectSpecular = 0.f;
    uint diffuseDistanceState = kRTPTDistanceNoLobe;
    uint specularDistanceState = kRTPTDistanceNoLobe;
#endif

    SceneRayQuery<true> query;
    HitInfo hit;
    float3 rayDirection;
#if ENABLE_SHARC && SHARC_QUERY
    ++sharcStats.radianceRays;
#endif
#if RTPT_USE_PRIMARY_SURFACE
    RTPTPrimarySurface primarySurface;
    const bool primaryLoaded = rtptTryLoadPrimary(pixel, sampleIndex, primarySurface);
    if (primaryLoaded)
    {
        hit = HitInfo(primarySurface.packedHit);
        rayDirection = primarySurface.rayDirection;
    }
    else
#endif
    {
        const Ray ray = rtptGenerateCameraRay(pixel, sg);
        float hitT;
        hit = query.traceRay(ray, hitT);
        rayDirection = ray.dir;
    }
    if (!hit.isValid())
    {
#if USE_ENV_BACKGROUND
        const float3 background = gScene.envMap.eval(rayDirection);
        signals.emission = all(isfinite(background)) ? background : float3(0.f);
#endif
#if RTPT_SEPARATE_SIGNAL_RESOLVE
        rtptStoreSignalRecord(pixel, signals, indirectDiffuse, indirectSpecular, diffuseDistanceState, specularDistanceState);
        return 0.f;
#else
        rtptWriteNRDSignals(pixel, signals);
        return signals.emission;
#endif
    }

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        const VertexData vertex = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -rayDirection);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        const BSDFProperties properties = mi.getProperties(sd);
#if ENABLE_SHARC && SHARC_QUERY
        rtptCaptureSharcPrimary(sd, properties, sharcStats);
#endif
        signals.emission = properties.emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            signals.emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (!all(isfinite(signals.emission))) signals.emission = 0.f;

        signals.diffuseReflectance = max(kNRDMinReflectance, properties.diffuseReflectionAlbedo);
        const float NdotV = saturate(dot(properties.guideNormal, sd.V));
        const float alpha = properties.roughness * properties.roughness;
        signals.specularReflectance = max(kNRDMinReflectance, approxSpecularIntegralGGX(properties.specularReflectionAlbedo, alpha, NdotV));
        // Reconstruct NRD guides from this same primary hit in the original
        // shading context. Reusing separately compiled fast-math guides can
        // change viewZ/motion by one ULP and perturb denoiser history.
        signals.normalRoughness = float4(rtptNRDPackNormal(properties.guideNormal), properties.roughness, 0.f);
        signals.viewZ = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1.f)).w;
        signals.motionW = gScene.getPrevPosW(triangleHit) - sd.posW;

        const uint lobes = mi.getLobeTypes(sd);
        const bool hasDiffuse = (lobes & uint(LobeType::DiffuseReflection)) != 0;
        const bool hasSpecular = (lobes & uint(LobeType::SpecularReflection)) != 0;
        const bool hasDeltaSpecular = (lobes & uint(LobeType::DeltaReflection)) != 0;
        ShadingData diffuseSD = sd;
        diffuseSD.mtl.setActiveLobes(uint(LobeType::DiffuseReflection));
        ShadingData specularSD = sd;
        specularSD.mtl.setActiveLobes(uint(LobeType::SpecularReflection));
        RTPTSamplingContext diffuseSampling = rtptBSDFSamplingContext();
        RTPTSamplingContext specularSampling = rtptBSDFSamplingContext();
        if (hasDiffuse) diffuseSampling = rtptMakeSamplingContext(diffuseSD, mi);
        // Keep primary specular NEE and continuation on the BSDF-only density.
        // Later vertices build their own context and remain eligible for PG.

        uint rootCoverage = 0u;
#if RTPT_USE_RESTIR_DI && RTPT_USE_PRIMARY_SURFACE
        float3 diDiffuse = 0.f;
        float3 diSpecular = 0.f;
        if (primaryLoaded)
            rootCoverage = rtptLoadPrimaryDICoverage(pixel, sampleIndex, diDiffuse, diSpecular);
        if (rootCoverage != 0u)
        {
            signals.diffuse = diDiffuse;
            signals.specular = diSpecular;
        }
#endif

#if RTPT_REGIR_TRANSPORT
        // A rejected/missing primary record requires a fresh traced surface,
        // not a global-light proposal. ReGIR retains the same local domain.
        if (rootCoverage == 0u && gParams.useNEE != 0u && (hasDiffuse || hasSpecular))
            rootCoverage = rtptEstimateReGIRRootDirect(sd, mi, sg, signals.diffuse, signals.specular);
#endif

#if !RTPT_REGIR_ONLY
        RTPTLightSample ls;
#if RTPT_USE_RESTIR_DI || RTPT_REGIR_TRANSPORT
        if (rootCoverage != 0u)
        {
            if (gParams.useNEE != 0 && (hasDiffuse || hasSpecular) && rtptSampleLightForCoverage(sd, rootCoverage, sg, ls))
            {
                if (query.traceVisibilityRay(ls.visibilityRay))
                {
                    if (hasDiffuse) signals.diffuse += rtptEvaluateDirectComponent(diffuseSD, mi, ls, diffuseSampling, sg);
                    if (hasSpecular) signals.specular += rtptEvaluateDirectComponent(specularSD, mi, ls, specularSampling, sg);
                }
            }
        }
        else
#endif
        {
            if (gParams.useNEE != 0 && (hasDiffuse || hasSpecular) && rtptSampleLight(sd, sg, ls))
            {
                if (query.traceVisibilityRay(ls.visibilityRay))
                {
                    if (hasDiffuse) signals.diffuse = rtptEvaluateDirectComponent(diffuseSD, mi, ls, diffuseSampling, sg);
                    if (hasSpecular) signals.specular = rtptEvaluateDirectComponent(specularSD, mi, ls, specularSampling, sg);
                }
            }
        }
#endif
#if RTPT_SEPARATE_SIGNAL_RESOLVE
#if RTPT_USE_GRIS && RTPT_GRIS_ALTERNATING
        GrisDualShadedIndirect gris = {};
        if (primaryLoaded) gris = gGRISShadedIndirect[pixel.y * gParams.frameDim.x + pixel.x];
        const bool grisDiffusePrepared = (gris.preparedMask & 1u) != 0u;
        const bool grisSpecularPrepared = (gris.preparedMask & 2u) != 0u;
        if (grisDiffusePrepared)
        {
            indirectDiffuse = gris.radiance[0];
            signals.diffuseHitDistance = gris.firstHit[0].hitT;
            diffuseDistanceState = gris.firstHit[0].distanceState;
        }
        if (grisSpecularPrepared)
        {
            indirectSpecular = gris.radiance[1];
            signals.specularHitDistance = gris.firstHit[1].hitT;
            specularDistanceState = gris.firstHit[1].distanceState;
        }
        if (hasDiffuse && !grisDiffusePrepared)
            indirectDiffuse = rtptTraceNRDContinuation(sd, mi, uint(LobeType::DiffuseReflection), diffuseSampling, sg,
                signals.diffuseHitDistance, diffuseDistanceState, sharcStats, rootCoverage);
        if (hasSpecular && !grisSpecularPrepared)
            indirectSpecular = rtptTraceNRDContinuation(sd, mi, uint(LobeType::SpecularReflection), specularSampling, sg,
                signals.specularHitDistance, specularDistanceState, sharcStats, rootCoverage);
#else
#if RTPT_USE_GRIS
        bool grisPrepared = false;
        if (primaryLoaded)
        {
            const GrisShadedIndirect gris = gGRISShadedIndirect[pixel.y * gParams.frameDim.x + pixel.x];
            grisPrepared = gris.state != uint(GrisRecordState::GrisUnprepared);
            if (grisPrepared)
            {
                if (gris.rootLobe == uint(GrisRootComponent::GrisDiffuse)) indirectDiffuse = gris.radiance;
                if (gris.rootLobe == uint(GrisRootComponent::GrisSpecular)) indirectSpecular = gris.radiance;

                // Keep distance-only probes out of the transport random stream.
                SampleGenerator distanceRng = SampleGenerator(pixel, sampleIndex ^ 0xe3723fd1u);
                const bool traceMissing = signals.viewZ < kNRDDepthRange;
                if (hasDiffuse)
                {
                    const GrisFirstHit firstHit = rtptResolveGrisFirstHit(gris, uint(GrisRootComponent::GrisDiffuse),
                        diffuseSD, mi, traceMissing, distanceRng);
                    signals.diffuseHitDistance = firstHit.hitT;
                    diffuseDistanceState = firstHit.distanceState;
                }
                if (hasSpecular)
                {
                    const GrisFirstHit firstHit = rtptResolveGrisFirstHit(gris, uint(GrisRootComponent::GrisSpecular),
                        specularSD, mi, traceMissing, distanceRng);
                    signals.specularHitDistance = firstHit.hitT;
                    specularDistanceState = firstHit.distanceState;
                }
            }
        }
        if (!grisPrepared)
        {
#endif
            if (hasDiffuse)
                indirectDiffuse = rtptTraceNRDContinuation(sd, mi, uint(LobeType::DiffuseReflection), diffuseSampling, sg,
                    signals.diffuseHitDistance, diffuseDistanceState, sharcStats, rootCoverage);
            if (hasSpecular)
                indirectSpecular = rtptTraceNRDContinuation(sd, mi, uint(LobeType::SpecularReflection), specularSampling, sg,
                    signals.specularHitDistance, specularDistanceState, sharcStats, rootCoverage);
#if RTPT_USE_GRIS
        }
#endif
#endif
#else
        uint unusedDiffuseState, unusedSpecularState;
        if (hasDiffuse)
            signals.diffuse += rtptTraceNRDContinuation(sd, mi, uint(LobeType::DiffuseReflection), diffuseSampling, sg,
                signals.diffuseHitDistance, unusedDiffuseState, sharcStats, rootCoverage);
        if (hasSpecular)
            signals.specular += rtptTraceNRDContinuation(sd, mi, uint(LobeType::SpecularReflection), specularSampling, sg,
                signals.specularHitDistance, unusedSpecularState, sharcStats, rootCoverage);
#endif
        if (hasDeltaSpecular)
        {
            float unusedDistance;
            signals.residual = rtptTraceNRDContinuation(sd, mi, uint(LobeType::DeltaReflection), rtptBSDFSamplingContext(), sg, unusedDistance, sharcStats);
        }
#if !RTPT_SEPARATE_SIGNAL_RESOLVE
        // NRD deliberately excludes surfaces outside its denoising range.
        // Preserve their energy through the unfiltered residual channel.
        if (signals.viewZ >= kNRDDepthRange)
        {
            signals.residual += signals.diffuse + signals.specular;
            signals.diffuse = 0.f;
            signals.specular = 0.f;
            signals.diffuseHitDistance = 0.f;
            signals.specularHitDistance = 0.f;
        }
#endif
    }
#endif

#if RTPT_SEPARATE_SIGNAL_RESOLVE
    rtptStoreSignalRecord(pixel, signals, indirectDiffuse, indirectSpecular, diffuseDistanceState, specularDistanceState);
    return 0.f;
#else
    rtptWriteNRDSignals(pixel, signals);
    return signals.emission + signals.diffuse + signals.specular + signals.residual;
#endif
}
#endif // !RTPT_GRIS_GENERATE
