#pragma once

// The represented sample keeps both surface hits and the terminal coordinates
// fixed. Only the edge from the evaluation pixel's primary hit changes.
GrisDualTailValue rtptGrisEvaluateFixedX1Tail(PackedHitInfo ownerPrimaryHit, float3 camera, GrisSpatialRecord tail,
    float3 deepIncident, inout SampleGenerator rng, bool nativeConnection = false,
    GrisDualReplayDomain domain = {}, float deepLightPdf = 0.f, bool knownLightVisible = false)
{
    GrisDualTailValue result = {};
    const bool shortNee = (tail.candidate.terminalKind & kGrisFixedX1Nee) != 0u;
    const bool deep = rtptGrisIsDeepTail(tail);
    const float lightProbability = rtptGrisDualLightProbability(tail);
    if (!(lightProbability > 0.f) || (shortNee && deep)) return result;
    if (deep && (gParams.maxBounces < 3u || !all(isfinite(deepIncident)) || !any(deepIncident > 0.f)))
        return result;

    // The current TLAS can certify an old path only if its endpoint geometry
    // is unchanged and neither connection crosses potentially moved geometry.
    uint movedBoundsCount = 0u;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (domain.previousGeometry)
    {
        movedBoundsCount = domain.movedBoundsCount;
        if (movedBoundsCount == 0u || !rtptGrisReplayStaticSurface(ownerPrimaryHit) ||
            !rtptGrisReplayStaticSurface(tail.sourceX1) ||
            (!shortNee && !rtptGrisReplayStaticSurface(tail.reconnectHit))) return result;
    }
#endif
    ShadingData primary;
    float3 firstPosition;
    if (!rtptGrisRefPrimary(ownerPrimaryHit, camera, primary) ||
        !rtptGrisRefPosition(tail.sourceX1, firstPosition)) return result;

    float3 firstDirection;
    float firstDistanceSquared;
    ShadingData first;
    if (!rtptGrisPrefixDirection(primary.computeRayOrigin(), firstPosition, firstDirection, firstDistanceSquared) ||
        !rtptGrisRefLoad(tail.sourceX1, -firstDirection, first)) return result;
    const IMaterialInstance firstMaterial = gScene.materials.getMaterialInstance(first, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(first, firstMaterial.getLobeTypes(first))) return result;

    const float firstGeometry = abs(dot(first.faceN, firstDirection)) / firstDistanceSquared;
    if (!(firstGeometry > 0.f) || !isfinite(firstGeometry)) return result;
    const bool mustCheckConnections = !nativeConnection || movedBoundsCount != 0u;
    if (mustCheckConnections && !rtptGrisRefVisible(primary, first, movedBoundsCount)) return result;

    // A known-visible terminal certifies only its light ray. In particular it
    // never certifies the new edge between the target primary surface and x1.
    const bool skipLightVisibility = knownLightVisible && movedBoundsCount == 0u && !domain.previousLights;
    float3 incident;
    bool shadowClear;
    if (shortNee)
    {
        incident = rtptGrisEvaluateDualLight(first, first, firstMaterial, tail, lightProbability, rng,
            domain.previousLights, shadowClear, movedBoundsCount, skipLightVisibility);
        if (movedBoundsCount != 0u && !shadowClear) return result;
    }
    else
    {
        float3 reconnectPosition;
        float3 connectionDirection;
        float connectionDistanceSquared;
        ShadingData reconnect;
        if (!rtptGrisRefPosition(tail.reconnectHit, reconnectPosition) ||
            !rtptGrisPrefixDirection(first.computeRayOrigin(), reconnectPosition, connectionDirection, connectionDistanceSquared) ||
            !rtptGrisRefLoad(tail.reconnectHit, -connectionDirection, reconnect)) return result;
        const IMaterialInstance reconnectMaterial =
            gScene.materials.getMaterialInstance(reconnect, ExplicitLodTextureSampler(0.f));
        if (!rtptGRISSupportsSurface(reconnect, reconnectMaterial.getLobeTypes(reconnect))) return result;
        if (mustCheckConnections && !rtptGrisRefVisible(first, reconnect, movedBoundsCount)) return result;

        const float connectionGeometry = abs(dot(reconnect.faceN, connectionDirection)) / connectionDistanceSquared;
        const float connectionPdf = firstMaterial.evalPdf(first, connectionDirection);
        if (!(connectionGeometry > 0.f) || !isfinite(connectionGeometry) ||
            !(connectionPdf > 0.f) || !isfinite(connectionPdf)) return result;

        if (deep)
        {
            const float directionPdf =
                rtptContinuationPdf(reconnect, reconnectMaterial, rtptBSDFSamplingContext(), tail.suffixDirection);
            if (!(directionPdf > 0.f) || !isfinite(directionPdf)) return result;
            const float mis = deepLightPdf > 0.f ? rtptPowerHeuristic(directionPdf, deepLightPdf) : 1.f;
            // Replay already compensates for draws after the fixed x2 direction.
            incident = reconnectMaterial.eval(reconnect, tail.suffixDirection, rng) * deepIncident * mis;
        }
        else
        {
            incident = rtptGrisEvaluateDualLight(reconnect, reconnect, reconnectMaterial, tail, lightProbability, rng,
                domain.previousLights, shadowClear, movedBoundsCount, skipLightVisibility);
            if (movedBoundsCount != 0u && !shadowClear) return result;
        }
        incident *= firstMaterial.eval(first, connectionDirection, rng) * connectionGeometry;
    }

    // The first-edge area density belongs to the Fresh proposal. The physical
    // target here contains only the geometry conversion, with no PG or PDF factor.
    const float3 common = incident * firstGeometry;
    if (!all(isfinite(common)) || !any(common > 0.f)) return result;
    const IMaterialInstance rootMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    const uint lobes = rootMaterial.getLobeTypes(primary);
    const uint diffuse = uint(LobeType::DiffuseReflection);
    const uint specular = uint(LobeType::SpecularReflection);
    if (rtptGRISSupportsSurface(primary, lobes & diffuse))
    {
        primary.mtl.setActiveLobes(diffuse);
        const float3 value = rootMaterial.eval(primary, firstDirection, rng) * common;
        if (all(isfinite(value))) result.diffuse = value;
    }
    if (rtptGRISSupportsSurface(primary, lobes & specular))
    {
        primary.mtl.setActiveLobes(specular);
        const float3 value = rootMaterial.eval(primary, firstDirection, rng) * common;
        if (all(isfinite(value))) result.specular = value;
    }
    return result;
}
