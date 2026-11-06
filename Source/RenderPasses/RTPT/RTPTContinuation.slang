#pragma once

#include "RTPTFirstHit.slangh"

#if RTPT_GRIS_GENERATE || RTPT_USE_GRIS
#include "GRIS/RTPTGRISSupport.slang"
#endif
#if RTPT_GRIS_GENERATE
#if RTPT_GRIS_SPATIAL
#include "GRIS/RTPTGRISCapture.slang"
#else
#include "GRIS/RTPTGRISTerminalPicker.slang"
#endif
#endif

/** Trace the selected component on the primary surface.
    The ordinary callers select their component with probability one. Generate
    passes its explicit root-selection probability and captures the candidate event.
    Later vertices use the mixed reflection estimator.
*/
float3 rtptTraceContinuation(
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
        rtptGRISCapturePrefix(bounce, sd, mi, hit, ray.dir, throughput, prefix);
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
            if (rtptGRISCaptureCacheTerminal(bounce, sd, mi, hit, ray, previousContinuationPdf,
                contribution, prefix, suffix)) break;
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
                contribution = rtptGRISCaptureDirectTerminal(sd, mi, sampling, hit, ray,
                    previousContinuationPdf, throughput, query, sg, suffix
#if RTPT_REGIR_TRANSPORT
                    , previousReGIRCoverage
#endif
                );
            }
            else
#endif
            {
#if RTPT_GRIS_GENERATE && RTPT_GRIS_ALTERNATING
                const bool continues = generateSuffix && bounce == 1u;
                contribution = throughput * rtptEstimateDirect(sd, mi, sampling, sg, continues);
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
float3 rtptTraceContinuation(
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
    return rtptTraceContinuation(primarySD, primaryMI, primaryLobes, primarySampling, sg,
        firstHitDistance, firstHitDistanceState, sharcStats, 0u);
}

// Keep the original continuation interface for the inline fallback and delta
// residual. Its unobserved event-state output is removed by shader compilation.
float3 rtptTraceContinuation(
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
    return rtptTraceContinuation(primarySD, primaryMI, primaryLobes, primarySampling, sg,
        firstHitDistance, unusedDistanceState, sharcStats);
}
#endif // !RTPT_GRIS_GENERATE
