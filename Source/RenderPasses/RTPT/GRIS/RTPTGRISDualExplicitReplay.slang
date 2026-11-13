#pragma once

#include "RTPTGRISDualExplicitPath.slang"

GrisDualDeepIncident rtptGrisTraceDualExplicit(GrisSpatialRecord tail, inout SampleGenerator rng, GrisDualReplayDomain domain)
{
    GrisDualDeepIncident result = {};
    const uint kind = rtptGrisTerminalKind(tail.candidate.terminalKind);
    const bool emitter = kind == uint(GrisTerminalKind::GrisDualEmitter);
    const bool environment = kind == uint(GrisTerminalKind::GrisDualEnvironmentMiss);
    const bool nee = !emitter && !environment;
    const uint terminalBounce = tail.dualExplicitBounce;
    if (terminalBounce < (nee ? 4u : 3u) || terminalBounce > gParams.maxBounces ||
        (nee && terminalBounce == gParams.maxBounces) || !all(isfinite(tail.suffixDirection)) ||
        !(dot(tail.suffixDirection, tail.suffixDirection) > 0.f) || all(tail.dualExplicitRng == 0u)) return result;

    const float terminalMultiplier = terminalBounce == 3u ? 1.f : float(rtptGrisDualExplicitLateCount(gParams.maxBounces));
    const TriangleHit reconnect = HitInfo(tail.reconnectHit).getTriangleHit();
    const VertexData x2 = rtptGrisPrefixVertex(reconnect);
    Ray ray = Ray(computeRayOrigin(x2.posW, x2.faceNormalW), tail.suffixDirection);
    SceneRayQuery<true> query;
    SampleGenerator pathRng = rtptGrisRestoreReplayRng(tail.dualExplicitRng);
    const RTPTSamplingContext sampling = rtptBSDFSamplingContext();
    uint2 pathID = rtptGrisDualExplicitBeginPath();
    float3 throughput = 1.f;
    float3 previousPosition = x2.posW;
    float3 previousNormal = x2.faceNormalW;
    float previousPdf = 0.f;
    bool previousDelta = false;
    bool previousUsedNEE = gParams.useNEE != 0u;
#if RTPT_REGIR_TRANSPORT
    uint previousCoverage = previousUsedNEE ? rtptReGIRTransportCoverage(false) : 0u;
#endif
    bool currentSupported = true;
    bool previousSupported = true;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (domain.previousGeometry) previousSupported = rtptGrisReplayStaticSurface(tail.reconnectHit);
#endif
#if RTPT_GRIS_DUAL_SHARC
    bool previousDiffuse = false;
    float previousRoughness = 0.f;
#if defined(RTPT_GRIS_TEMPORAL_REUSE)
    previousSupported = previousSupported && domain.previousSharcMode != 0u;
    const bool sameCache = domain.previousSharcMode == 1u &&
        all(gGRISPreviousSharc.hashGridParameters.cameraPosition == gSharc.hashGridParameters.cameraPosition);
#endif
#endif

    [loop] for (uint bounce = 3u; bounce <= terminalBounce; ++bounce)
    {
        float hitT;
        const HitInfo hit = query.traceRay(ray, hitT);
        const bool usesMis = !RTPT_REGIR_ONLY && previousUsedNEE && !previousDelta;
        if (!hit.isValid())
        {
#if USE_ENV_LIGHT
            if (environment && bounce == terminalBounce &&
                all(rtptGrisDualExplicitAppendMiss(pathID) == tail.dualExplicitPathID))
            {
                const float lightPdf = usesMis ? rtptEnvironmentLightPdf(ray.dir) : 0.f;
                // x3's preceding BSDF is the reconnected x2 BSDF. Its
                // route-dependent competitor weight is applied by the caller.
                const float mis = bounce > 3u && usesMis ? rtptPowerHeuristic(previousPdf, lightPdf) : 1.f;
                const float3 value = terminalMultiplier * throughput * gScene.envMap.eval(ray.dir) * mis;
                if (!all(isfinite(value)) || !isfinite(lightPdf)) return result;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
                if (previousSupported && domain.previousGeometry)
                    previousSupported = rtptGrisDualExplicitInfiniteRayClear(ray, domain.movedBoundsCount);
#endif
                result.lightPdf = bounce == 3u ? lightPdf : 0.f;
                result.current = currentSupported ? value : 0.f;
                result.previous = previousSupported ? value : 0.f;
            }
#endif
            return result;
        }
        if (hit.getType() != HitType::Triangle) return result;

        const PackedHitInfo packed = hit.pack();
        pathID = rtptGrisDualExplicitAppendHit(pathID, packed);
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
        if (previousSupported && domain.previousGeometry)
            previousSupported = rtptGrisReplayStaticSurface(packed) &&
                rtptGrisReplayRayClear(Ray(ray.origin, ray.dir, ray.tMin, hitT), domain.movedBoundsCount);
#endif
        const TriangleHit triangle = hit.getTriangleHit();
        const uint materialID = gScene.getMaterialID(triangle.instanceID);
        ShadingData surface = gScene.materials.prepareShadingData(gScene.getVertexData(triangle), materialID, -ray.dir);
        surface.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
        const bool usesNee = gParams.useNEE != 0u &&
            (material.getLobeTypes(surface) & uint(LobeType::NonDeltaReflection)) != 0u;
#if RTPT_GRIS_DUAL_SHARC
        // A successful cache query owns the remainder of its frame's path.
        // An explicit terminal can still be supported in the other frame.
        if (bounce >= 4u && previousDiffuse)
        {
            const BSDFProperties properties = material.getProperties(surface);
            const float distance = length(surface.posW - previousPosition);
            RTPTSharcStats stats = {};
            float3 cached;
            const bool currentHit = currentSupported && rtptTrySharcQueryOnEdgeFrom(gSharc, surface, material,
                properties, bounce, previousDelta, false, previousDiffuse, previousRoughness, distance,
                sampling, ray.dir, stats, cached);
            currentSupported = currentSupported && !currentHit;
#if defined(RTPT_GRIS_TEMPORAL_REUSE)
            if (previousSupported)
            {
                const bool previousHit = sameCache ? currentHit : rtptTrySharcQueryOnEdgeFrom(gGRISPreviousSharc,
                    surface, material, properties, bounce, previousDelta, false, previousDiffuse, previousRoughness,
                    distance, sampling, ray.dir, stats, cached);
                previousSupported = !previousHit;
            }
#else
            previousSupported = currentSupported;
#endif
        }
        if (!currentSupported && !previousSupported) return result;
#endif
        if (bounce == terminalBounce)
        {
            if (any(pathID != tail.dualExplicitPathID)) return result;
#if USE_EMISSIVE_LIGHTS
            if (emitter)
            {
#if RTPT_REGIR_TRANSPORT
                if (!previousDelta && rtptDICoversEmissiveHit(triangle, previousCoverage)) return result;
#endif
                float3 emission = material.getProperties(surface).emission;
                if (surface.frontFacing && gScene.materials.hasLightProfile(materialID))
                    emission *= gScene.materials.evalLightProfile(dot(surface.faceN, surface.V));
                const float lightPdf = usesMis ? rtptEmissiveLightPdf(previousPosition, previousNormal, triangle, surface) : 0.f;
                const float mis = bounce > 3u && usesMis ? rtptPowerHeuristic(previousPdf, lightPdf) : 1.f;
                const float3 value = terminalMultiplier * throughput * emission * mis;
                if (!all(isfinite(value)) || !isfinite(lightPdf)) return result;
                result.lightPdf = bounce == 3u ? lightPdf : 0.f;
                result.current = currentSupported ? value : 0.f;
                result.previous = previousSupported ? value : 0.f;
                return result;
            }
#endif
            if (!nee || !usesNee) return result;
            const float lightProbability = rtptGrisDualLightProbability(tail);
            if (!(lightProbability > 0.f)) return result;

            // Match the independent evaluation stream cloned in Generate.
            const SampleGenerator evalRng = rtptGrisForkReplayNEERng(pathRng, bounce);
            SampleGenerator currentRng = evalRng;
            bool shadowClear;
            uint boundsCount = 0u;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
            if (previousSupported && domain.previousGeometry) boundsCount = domain.movedBoundsCount;
#endif
            const float3 value = terminalMultiplier * throughput * rtptGrisEvaluateDualLight(surface, surface,
                material, tail, lightProbability, currentRng, false, shadowClear, boundsCount);
            if (currentSupported && all(isfinite(value))) result.current = value;
            if (previousSupported)
            {
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
#if !RTPT_GRIS_DUAL_REGIR
                if (domain.previousLights && kind == uint(GrisTerminalKind::GrisDualPointNee))
                {
                    SampleGenerator previousRng = evalRng;
                    const float3 oldValue = terminalMultiplier * throughput * rtptGrisEvaluateDualLight(surface,
                        surface, material, tail, lightProbability, previousRng, true, shadowClear, boundsCount);
                    if ((!domain.previousGeometry || shadowClear) && all(isfinite(oldValue)))
                        result.previous = oldValue;
                    return result;
                }
#endif
                if (domain.previousGeometry && !shadowClear) return result;
#endif
                if (all(isfinite(value))) result.previous = value;
            }
            return result;
        }

        if (usesNee) rtptGrisForkReplayNEERng(pathRng, bounce);
        BSDFSample scatter;
        bool guideSelected;
        if (!rtptSampleContinuation(surface, material, sampling, pathRng, scatter, guideSelected) ||
            scatter.isLobe(LobeType::Transmission) || !all(isfinite(scatter.wo)) ||
            !all(isfinite(scatter.weight))) return result;
        previousDelta = scatter.isLobe(LobeType::Delta);
        if (!previousDelta && (!(scatter.pdf > 0.f) || !isfinite(scatter.pdf))) return result;
        throughput *= scatter.weight;
        if (!all(isfinite(throughput)) || !any(throughput > 0.f)) return result;
#if RTPT_GRIS_DUAL_SHARC
        previousDiffuse = !guideSelected && scatter.isLobe(LobeType::DiffuseReflection);
        previousRoughness = material.getProperties(surface).roughness;
#endif
        previousUsedNEE = usesNee;
#if RTPT_REGIR_TRANSPORT
        previousCoverage = usesNee ? rtptReGIRTransportCoverage(false) : 0u;
#endif
        previousPdf = scatter.pdf;
        previousPosition = surface.posW;
        previousNormal = surface.getOrientedFaceNormal();
        ray = Ray(surface.computeRayOrigin(), scatter.wo);
    }
    return result;
}
