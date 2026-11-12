#pragma once

#if RTPT_GRIS_SUFFIX_REPLAY && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)

StructuredBuffer<uint> gGRISReplayMovedInstances;

bool rtptGrisReplayStaticSurface(PackedHitInfo packed)
{
    const HitInfo hit = HitInfo(packed);
    if (hit.getType() != HitType::Triangle) return false;
    return gGRISReplayMovedInstances[hit.getTriangleHit().instanceID.index] == 0u;
}

enum GrisNeeReplayStatus { GrisReplayInvalid, GrisReplayZero, GrisReplayCached, GrisReplaySampled };

#if RTPT_GRIS_SHARC_REPLAY
bool rtptGrisIsSharcTail(GrisSpatialRecord record)
{
    return rtptGrisTerminalKind(record.candidate.terminalKind) == uint(GrisTerminalKind::GrisSharcTail);
}

bool rtptGrisRefreshSharcTail(inout GrisSpatialRecord tail)
{
    float3 rawRadiance;
    if (!rtptReadSharcTailRadiance(tail.sharcKey, rawRadiance)) return false;
    const float3 incident = tail.sharcGain * rawRadiance;
    if (!all(isfinite(incident)) || any(incident < 0.f)) return false;
    if (any(incident != tail.suffixLight)) tail.suffixLight = incident;
    return true;
}
#endif

GrisNeeReplayStatus rtptGrisSampleReplayNee(GrisSpatialRecord source, ShadingData sd,
    bool previousLight, bool pointLightChanged, inout SampleGenerator rng, out RTPTLightSample light)
{
    light = {};
#if RTPT_GRIS_REGIR_REPLAY
    if (rtptGrisTerminalKind(source.candidate.terminalKind) == uint(GrisTerminalKind::GrisReGIRPath))
    {
        const float innerRISWeight = rtptGrisGetInnerRISWeight(source);
        if (previousLight || !(innerRISWeight > 0.f) || !isfinite(innerRISWeight))
            return GrisNeeReplayStatus::GrisReplayInvalid;
        SampleGenerator unusedCellRng;
        const float2 uv = rtptGrisSplitReGIRReplayRng(rng, source.terminalBounce, unusedCellRng);
        return rtptReGIRRebuildTransportSample(sd, source.lightPdfOrStableID, uv, innerRISWeight, light)
            ? GrisNeeReplayStatus::GrisReplaySampled : GrisNeeReplayStatus::GrisReplayZero;
    }
#endif
    const bool environmentNee = rtptGrisIsEnvironmentNee(source);
    if (environmentNee || rtptGrisIsEmissiveNee(source))
    {
        // Rigid occluder motion preserves the emissive and environment proposals.
        if (previousLight) return GrisNeeReplayStatus::GrisReplayInvalid;
        const RTPTReplayLightType expected = environmentNee ?
            RTPTReplayLightType::Environment : RTPTReplayLightType::Emissive;
        const bool sampled = rtptSampleLight(sd, rng, light);
        if (environmentNee && light.replayType != expected) return GrisNeeReplayStatus::GrisReplayInvalid;
        return sampled && light.replayType == expected ?
            GrisNeeReplayStatus::GrisReplaySampled : GrisNeeReplayStatus::GrisReplayZero;
    }

    // Decode the identity before testing intensity or visibility. Both frame
    // snapshots share the ordered point-light proposal.
    const uint lightIndex = rtptReplayPointLightIndex(rng);
    if (lightIndex == kRTPTInvalidReplayLightID) return GrisNeeReplayStatus::GrisReplayInvalid;
    if (pointLightChanged && !rtptReplayPointLightChanged(lightIndex)) return GrisNeeReplayStatus::GrisReplayCached;
    return rtptReplayPointLight(sd, lightIndex, previousLight, rng, light) ?
        GrisNeeReplayStatus::GrisReplaySampled : GrisNeeReplayStatus::GrisReplayZero;
}

// Replay a selected tail in the common fixed-x2 domain. The caller retains the
// original reservoir, including its prefix proposal ratio and selection weight.
// The walk always uses the current TLAS. When geometry changes, only static
// surface vertices can participate in reuse. Previous light data is optional.
bool rtptGrisReplaySuffix(GrisSpatialRecord source, bool previousLight, bool geometryChanged,
    out GrisSpatialRecord result, bool pointLightChanged = false)
{
    result = source;
    result.suffixLight = 0.f;
    if (geometryChanged) result.suffixInstanceMask = 0u;

    const uint kind = rtptGrisTerminalKind(source.candidate.terminalKind);
    const bool regir = RTPT_GRIS_REGIR_REPLAY && kind == uint(GrisTerminalKind::GrisReGIRPath);
    const bool nee = regir || kind == uint(GrisTerminalKind::GrisNee);
    const bool emitter = kind == uint(GrisTerminalKind::GrisEmitter);
    const bool environment = kind == uint(GrisTerminalKind::GrisEnvironment);
#if RTPT_GRIS_SHARC_REPLAY
    const bool sharc = rtptGrisIsSharcTail(source);
#else
    const bool sharc = false;
#endif
    const uint terminalBounce = source.terminalBounce;
    const bool deep = rtptGrisIsDeepTail(source);
    if (!(nee || emitter || environment || sharc) ||
        terminalBounce < (nee ? 2u : 3u) || terminalBounce > gParams.maxBounces ||
        deep != (terminalBounce > (nee ? 2u : 3u)) ||
        (sharc && (previousLight || terminalBounce < 4u || terminalBounce == gParams.maxBounces)) ||
        (nee && (terminalBounce == gParams.maxBounces || (!regir && !rtptGrisHasReplayableNee(source)))) ||
        ((nee || terminalBounce > 3u) && all(source.postX2RngState == 0u)))
        return false;

    if (geometryChanged && !rtptGrisReplayStaticSurface(source.reconnectHit)) return !regir;

    ShadingData reconnect;
    // The saved reflection direction is on the same side of x2 as the source
    // view. Use that side to reconstruct the ray origin. The reference
    // evaluator computes the x2 BSDF and PDF using the actual shifted prefix.
    if (!rtptGrisRefLoad(source.reconnectHit, source.suffixDirection, reconnect) || !reconnect.frontFacing) return false;

    SceneRayQuery<true> query;
    if (terminalBounce == 2u)
    {
        SampleGenerator neeRng = rtptGrisRestoreReplayRng(source.postX2RngState);
        RTPTLightSample light;
        const GrisNeeReplayStatus status = rtptGrisSampleReplayNee(source, reconnect, previousLight,
            pointLightChanged, neeRng, light);
        if (status == GrisNeeReplayStatus::GrisReplayInvalid) return false;
        if (status == GrisNeeReplayStatus::GrisReplayCached) result = source;
        if (status == GrisNeeReplayStatus::GrisReplaySampled)
        {
            result.suffixDirection = light.dir;
            if (!regir) result.lightPdfOrStableID = asuint(light.pdf);
            if (query.traceVisibilityRay(light.visibilityRay)) result.suffixLight = light.LiOverPdf;
        }
        return true;
    }

    // NEE needs the original terminal stream even at x3.
    SampleGenerator rng = SampleGenerator(uint2(0u, terminalBounce), 0u);
    if (nee || terminalBounce > 3u) rng = rtptGrisRestoreReplayRng(source.postX2RngState);
    const RTPTSamplingContext sampling = rtptBSDFSamplingContext();
    float3 throughput = 1.f;
    float3 previousPosition = reconnect.posW;
    float3 previousNormal = reconnect.getOrientedFaceNormal();
    float previousPdf = 0.f;
    bool previousDelta = false;
#if RTPT_GRIS_SHARC_REPLAY
    bool previousDiffuse = false;
    bool previousGuideSelected = false;
    float previousRoughness = 0.f;
#endif
    // Every generated reconnect surface has a continuous reflection lobe.
    bool previousUsedNEE = gParams.useNEE != 0u;
    Ray ray = Ray(reconnect.computeRayOrigin(), source.suffixDirection);

    // A valid replay can have zero contribution. Keep the terminal metadata
    // for that case so the source proposal remains available to cross MIS.
    for (uint bounce = 3u; bounce <= terminalBounce; ++bounce)
    {
        float hitT;
        const HitInfo hit = query.traceRay(ray, hitT);
#if RTPT_REGIR_ONLY
        // Generate assigns the explicit BSDF terminals full weight in the
        // cell-only light domain.
        const bool hasNeeCompetitor = false;
#else
        const bool hasNeeCompetitor = previousUsedNEE && !previousDelta;
#endif
        if (!hit.isValid())
        {
            if (pointLightChanged || regir) return false;
#if USE_ENV_LIGHT
            if (environment && bounce == terminalBounce)
            {
                const float pdf = hasNeeCompetitor ? rtptEnvironmentLightPdf(ray.dir) : 0.f;
                const float3 emission = gScene.envMap.eval(ray.dir);
                const float mis = deep && hasNeeCompetitor ? rtptPowerHeuristic(previousPdf, pdf) : 1.f;
                const float3 value = throughput * emission * mis;
                if (all(isfinite(value))) result.suffixLight = value;
                result.lightPdfOrStableID = asuint(pdf);
            }
#endif
            return true;
        }
        if (hit.getType() != HitType::Triangle) return !(pointLightChanged || regir);

        const TriangleHit triangleHit = hit.getTriangleHit();
        if (geometryChanged)
        {
            const uint instance = triangleHit.instanceID.index;
            if (gGRISReplayMovedInstances[instance] != 0u) return !regir;
            result.suffixInstanceMask |= rtptGrisSuffixInstanceBit(instance);
        }
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(gScene.getVertexData(triangleHit), materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance material = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        const bool usesNEE = gParams.useNEE != 0u &&
            (material.getLobeTypes(sd) & uint(LobeType::NonDeltaReflection)) != 0u;

        if (bounce == terminalBounce)
        {
#if RTPT_GRIS_SHARC_REPLAY
            if (sharc)
            {
                const BSDFProperties properties = material.getProperties(sd);
                RTPTSharcStats stats = {};
                float3 cachedRadiance;
                RTPTSharcTailQuery tailQuery;
                if (!rtptTrySharcQueryOnEdge(sd, material, properties, bounce, previousDelta,
                    previousGuideSelected, previousDiffuse, previousRoughness, length(sd.posW - previousPosition),
                    sampling, ray.dir, stats, cachedRadiance, tailQuery)) return true;

                const float3 gain = throughput * tailQuery.materialFactor;
                const float3 incident = gain * tailQuery.rawRadiance;
                if (all(isfinite(gain)) && all(isfinite(incident)) && all(incident >= 0.f))
                {
                    result.sharcKey = tailQuery.key;
                    result.sharcGain = gain;
                    result.suffixLight = incident;
                }
                else
                {
                    const float3 legacyIncident = throughput * cachedRadiance;
                    if (all(isfinite(legacyIncident))) result.suffixLight = legacyIncident;
                    result.sharcKey = 0u;
                    result.sharcGain = 0.f;
                }
                return true;
            }
#endif
            if (nee)
            {
                if (!usesNEE) return !(pointLightChanged || regir);
                SampleGenerator neeRng = rtptGrisForkReplayNEERng(rng, bounce);
                RTPTLightSample light;
                const GrisNeeReplayStatus status = rtptGrisSampleReplayNee(source, sd, previousLight,
                    pointLightChanged, neeRng, light);
                if (status == GrisNeeReplayStatus::GrisReplayInvalid) return false;
                if (status == GrisNeeReplayStatus::GrisReplayCached) result = source;
                if (status == GrisNeeReplayStatus::GrisReplaySampled)
                {
                    const float3 value = throughput * rtptEvaluateLightSample(sd, material, sampling, light, neeRng, !regir);
                    if (!regir) result.lightPdfOrStableID = asuint(light.pdf);
                    if (all(isfinite(value)) && query.traceVisibilityRay(light.visibilityRay))
                        result.suffixLight = value;
                }
                return true;
            }
#if USE_EMISSIVE_LIGHTS
            if (emitter)
            {
                float3 emission = material.getProperties(sd).emission;
                if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
                    emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
                const float pdf = hasNeeCompetitor ?
                    rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd) : 0.f;
                const float mis = deep && hasNeeCompetitor ? rtptPowerHeuristic(previousPdf, pdf) : 1.f;
                const float3 value = throughput * emission * mis;
                if (all(isfinite(value))) result.suffixLight = value;
                result.lightPdfOrStableID = asuint(pdf);
            }
#endif
            return true;
        }

        // Match Generate's BSDF stream. Intermediate NEE events are not part
        // of the selected tail, so only the main stream's fork is needed.
        if (usesNEE) rtptGrisForkReplayNEERng(rng, bounce);
        BSDFSample scatter;
        bool guideSelected;
        if (!rtptSampleContinuation(sd, material, sampling, rng, scatter, guideSelected) ||
            scatter.isLobe(LobeType::Transmission) ||
            !all(isfinite(scatter.wo)) || !all(isfinite(scatter.weight))) return !(pointLightChanged || regir);
        previousDelta = scatter.isLobe(LobeType::Delta);
#if RTPT_GRIS_SHARC_REPLAY
        if (sharc)
        {
            previousDiffuse = !guideSelected && scatter.isLobe(LobeType::DiffuseReflection);
            previousGuideSelected = guideSelected;
            previousRoughness = material.getProperties(sd).roughness;
        }
#endif
        if (!previousDelta && (!(scatter.pdf > 0.f) || !isfinite(scatter.pdf))) return !(pointLightChanged || regir);
        throughput *= scatter.weight;
        if (!all(isfinite(throughput)) || !any(throughput > 0.f)) return !(pointLightChanged || regir);

        previousUsedNEE = usesNEE;
        previousPdf = scatter.pdf;
        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        ray = Ray(sd.computeRayOrigin(), scatter.wo);
    }
    return true;
}
#endif
