#pragma once

#ifdef RTPT_GRIS_DELTA_REUSE
struct GrisDeltaPrefix
{
    PackedHitInfo x1;
    float3 direction;
    float3 throughput;
};

bool rtptGrisSupportsDeltaRoot(ShadingData primary, uint lobes)
{
    return primary.frontFacing && primary.mtl.getMaterialType() == MaterialType::Standard &&
        (lobes & uint(LobeType::DeltaReflection)) != 0u &&
        (lobes & (uint(LobeType::SpecularReflection) | uint(LobeType::Transmission))) == 0u;
}

bool rtptGrisOwnerHasDeltaRoot(PackedHitInfo owner, float3 camera)
{
    ShadingData primary;
    if (!rtptGrisRefPrimary(owner, camera, primary)) return false;
    const IMaterialInstance material = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    return rtptGrisSupportsDeltaRoot(primary, material.getLobeTypes(primary));
}

// The restricted StandardMaterial reflection is deterministic. Reconstruct
// the owner's anchor even when its shared reservoir selected a diffuse path.
bool rtptGrisReplayDeltaPrefix(ShadingData primary, SampleGenerator rng, out GrisDeltaPrefix prefix)
{
    prefix = {};
    const IMaterialInstance material = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    if (!rtptGrisSupportsDeltaRoot(primary, material.getLobeTypes(primary))) return false;
    primary.mtl.setActiveLobes(uint(LobeType::DeltaReflection));
    BSDFSample bs = {};
    if (!material.sample(primary, rng, bs) || !bs.isLobe(LobeType::DeltaReflection) ||
        !all(isfinite(bs.wo)) || !all(isfinite(bs.weight)) || !any(bs.weight > 0.f)) return false;
    SceneRayQuery<true> query;
    float distance;
    const HitInfo hit = query.traceRay(Ray(primary.computeRayOrigin(), bs.wo), distance);
    if (hit.getType() != HitType::Triangle) return false;
    prefix.x1 = hit.pack();
    prefix.direction = bs.wo;
    prefix.throughput = bs.weight;
    return true;
}
#endif

// Continuous roots keep the represented x1. Singular roots reconstruct the
// evaluation pixel's mirror hit. Both use the same suffix coordinates.
GrisDualTailValue rtptGrisEvaluateFixedX1Tail(PackedHitInfo ownerPrimaryHit, float3 camera, GrisSpatialRecord tail,
    float3 deepIncident, inout SampleGenerator rng, bool nativeConnection = false,
    GrisDualReplayDomain domain = {}, float deepLightPdf = 0.f, bool knownLightVisible = false
#ifdef RTPT_GRIS_DELTA_REUSE
    , GrisDeltaPrefix deltaPrefix = {}
#endif
    )
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
    if (!rtptGrisRefPrimary(ownerPrimaryHit, camera, primary)) return result;
    float3 firstDirection = 0.f;
    float firstGeometry = 1.f;
    ShadingData first;
    const bool mustCheckConnections = !nativeConnection || movedBoundsCount != 0u;
#ifdef RTPT_GRIS_DELTA_REUSE
    const bool deltaRoot = (tail.candidate.terminalKind & kGrisDeltaRoot) != 0u;
    if (deltaRoot)
    {
        // The old deterministic edge cannot be recovered from the current TLAS.
        if (domain.previousGeometry ||
            (!nativeConnection && !rtptGrisReplayDeltaPrefix(primary, rng, deltaPrefix)) ||
            !rtptGrisRefLoad(deltaPrefix.x1, -deltaPrefix.direction, first)) return result;
    }
    else
#endif
    {
        float3 firstPosition;
        float firstDistanceSquared;
        if (!rtptGrisRefPosition(tail.sourceX1, firstPosition) ||
            !rtptGrisPrefixDirection(primary.computeRayOrigin(), firstPosition, firstDirection, firstDistanceSquared) ||
            !rtptGrisRefLoad(tail.sourceX1, -firstDirection, first)) return result;
        firstGeometry = abs(dot(first.faceN, firstDirection)) / firstDistanceSquared;
        if (!(firstGeometry > 0.f) || !isfinite(firstGeometry)) return result;
    }
    const IMaterialInstance firstMaterial = gScene.materials.getMaterialInstance(first, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(first, firstMaterial.getLobeTypes(first))) return result;
#ifdef RTPT_GRIS_DELTA_REUSE
    if (!deltaRoot)
#endif
        if (mustCheckConnections && !rtptGrisRefVisible(primary, first, movedBoundsCount)) return result;

    // A known-visible terminal certifies only its light ray. In particular it
    // never certifies the new edge between the target primary surface and x1.
    const bool skipLightVisibility = knownLightVisible && movedBoundsCount == 0u && !domain.previousLights
#ifdef RTPT_GRIS_DELTA_REUSE
        && !(deltaRoot && shortNee)
#endif
        ;
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

#ifdef RTPT_GRIS_DELTA_REUSE
    if (deltaRoot)
    {
        const float3 value = deltaPrefix.throughput * incident;
        if (all(isfinite(value))) result.specular = value;
        return result;
    }
#endif

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
