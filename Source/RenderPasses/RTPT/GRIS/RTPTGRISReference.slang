#pragma once

#include "RTPTGRISReuse.slang"

#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
#include "RTPTGRISSuffixReplay.slang"
#endif

#ifndef RTPT_GRIS_REFERENCE_REUSE
#define RTPT_GRIS_REFERENCE_REUSE 1
#endif

#if RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)

// R = Q_owner / sigma_reference. Stored F and W map to F*R and W/R.
// Prefix coordinates are surface hits, and BSDF tails use a fixed direction
// measure at x2. A rigid transform preserves surface area on both hits.
struct GrisReferencePrefix
{
    PackedHitInfo x1;
    uint rootLobe;
    bool valid;
};

float rtptGrisRefTarget(float3 value)
{
    return dot(abs(value), float3(0.2126f, 0.7152f, 0.0722f));
}

uint rtptGrisRefRootMask(uint rootLobe)
{
    if (rootLobe == uint(GrisRootComponent::GrisDiffuse)) return uint(LobeType::DiffuseReflection);
    if (rootLobe == uint(GrisRootComponent::GrisSpecular)) return uint(LobeType::SpecularReflection);
    return 0u;
}

float rtptGrisRefRootProbability(ShadingData primary, uint rootLobe)
{
    primary.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance material = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    const uint lobes = material.getLobeTypes(primary);
    if (!rtptGRISSupportsSurface(primary, lobes & rtptGrisRefRootMask(rootLobe))) return 0.f;
    const bool diffuse = (lobes & uint(LobeType::DiffuseReflection)) != 0u;
    const bool specular = (lobes & uint(LobeType::SpecularReflection)) != 0u;
    if ((rootLobe == uint(GrisRootComponent::GrisDiffuse) && !diffuse) ||
        (rootLobe == uint(GrisRootComponent::GrisSpecular) && !specular) ||
        rtptGrisRefRootMask(rootLobe) == 0u) return 0.f;
    return diffuse && specular ? 0.5f : 1.f;
}

bool rtptGrisRefVisible(ShadingData from, ShadingData to, uint movedBoundsCount = 0u)
{
    const float3 origin = from.computeRayOrigin();
    const float3 displacement = to.computeRayOrigin() - origin;
    const float distanceSquared = dot(displacement, displacement);
    if (!(distanceSquared > 0.f) || !isfinite(distanceSquared)) return false;
    const float distance = sqrt(distanceSquared);
    const Ray ray = Ray(origin, displacement / distance, 0.f, distance);
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (movedBoundsCount != 0u && !rtptGrisReplayRayClear(ray, movedBoundsCount)) return false;
#endif
    SceneRayQuery<true> query;
    return query.traceVisibilityRay(ray);
}

GrisReferencePrefix rtptGrisRefRecordPrefix(GrisSpatialRecord record)
{
    GrisReferencePrefix result = {};
    result.x1 = record.sourceX1;
    result.rootLobe = record.candidate.rootLobe;
    result.valid = HitInfo(result.x1).getType() == HitType::Triangle;
    return result;
}

bool rtptGrisRefKindSupported(GrisSpatialRecord record)
{
    const uint kind = rtptGrisTerminalKind(record.candidate.terminalKind);
    return kind == uint(GrisTerminalKind::GrisNee) || kind == uint(GrisTerminalKind::GrisEmitter) ||
        kind == uint(GrisTerminalKind::GrisEnvironment)
#if RTPT_GRIS_CACHE_TAIL
        || (kind == uint(GrisTerminalKind::GrisSharcTail) && rtptGrisIsDeepTail(record))
#endif
        ;
}

bool rtptGrisRefDomainValid(GrisSpatialRecord record)
{
    // A realized zero draw does not erase this owner's proposal domain or M.
    return record.candidate.prepared && record.candidate.M > 0.f && isfinite(record.candidate.M) &&
        HitInfo(record.ownerPrimaryHit).getType() == HitType::Triangle;
}

bool rtptGrisRefSampleValid(GrisSpatialRecord record)
{
    return rtptGrisRefDomainValid(record) && record.candidate.hasWinner && rtptGrisRefKindSupported(record) &&
        record.areaPdf > 0.f && isfinite(record.areaPdf) && record.candidate.W > 0.f &&
        isfinite(record.candidate.W) && all(isfinite(record.candidate.F)) &&
        HitInfo(record.sourceX1).getType() == HitType::Triangle &&
        HitInfo(record.reconnectHit).getType() == HitType::Triangle;
}

#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
struct GrisSuffixReplaySettings
{
    uint historyIndex;
    bool lightChanged;
    bool geometryChanged;
    uint movedInstanceBits;
    bool validateUnchanged;
#if RTPT_GRIS_SHARC_REPLAY
    uint sharcChanges; // Bit 0: cache contents. Bit 1: lookup anchor.
#endif
};

bool rtptGrisReplayStoredTail(GrisSpatialRecord source, GrisSuffixReplaySettings replay,
    bool previous, out GrisSpatialRecord result)
{
    result = source;
    if (!rtptGrisRefSampleValid(source)) return true;
    const uint kind = rtptGrisTerminalKind(source.candidate.terminalKind);
    const bool pointChanged = replay.lightChanged && rtptGrisIsPointNee(source);
    const bool replayable = rtptGrisHasReplayableNee(source) ||
        kind == uint(GrisTerminalKind::GrisEmitter) || kind == uint(GrisTerminalKind::GrisEnvironment);

    if (previous)
    {
        if (pointChanged) return rtptGrisReplaySuffix(source, true, false, result, true);
        if (!replay.geometryChanged) return true;
        if ((source.suffixInstanceMask & replay.movedInstanceBits) != 0u) return false;
        if (source.terminalBounce == 2u && !rtptGrisReplayStaticSurface(source.reconnectHit))
            return rtptGrisReplayDirectNeeInPreviousGeometry(source, result);
        // Deeper suffixes use the current-frame tail as an approximation of
        // the old support. The cross evaluation still uses the old prefix.
        return true;
    }

    if (replay.geometryChanged)
    {
        if ((source.suffixInstanceMask & replay.movedInstanceBits) != 0u) return false;
        return rtptGrisReplaySuffix(source, false, true, result);
    }
#if RTPT_GRIS_SHARC_REPLAY
    if (rtptGrisIsSharcTail(source))
    {
        if ((replay.sharcChanges & 2u) != 0u || replay.validateUnchanged)
            return rtptGrisReplaySuffix(source, false, false, result);
        return (replay.sharcChanges & 1u) == 0u || rtptGrisRefreshSharcTail(result);
    }
#endif
    if (pointChanged || (replay.validateUnchanged && replayable))
        return rtptGrisReplaySuffix(source, false, false, result, pointChanged);
    return true;
}

#endif

// Evaluate one complete path in the reference-tail domain for any source/target
// owner. All interface BSDFs, both prefix edges and their visibility are reevaluated.
// The returned ratio is a BSDF-only owner representation, not an additional
// importance correction. The actual root-PG ratio is captured at generation.
float3 rtptGrisRefEvaluate(PackedHitInfo primaryHit, float3 cameraPosition,
    GrisReferencePrefix prefix, GrisSpatialRecord tail, inout SampleGenerator rng,
    out float ownerRatio, out float firstDistance, bool recheckVisibility = false, bool previousGeometry = false)
{
    ownerRatio = 0.f;
    firstDistance = kRTPTNRDMissDistance;
    if (!prefix.valid || !rtptGrisRefKindSupported(tail)) return 0.f;
    ShadingData primary;
    float3 x1Position, x2Position;
    if (!rtptGrisRefPrimary(primaryHit, cameraPosition, primary, previousGeometry) ||
        !rtptGrisRefPosition(prefix.x1, x1Position, previousGeometry) ||
        !rtptGrisRefPosition(tail.reconnectHit, x2Position, previousGeometry)) return 0.f;
    const float rootProbability = rtptGrisRefRootProbability(primary, prefix.rootLobe);
    if (!(rootProbability > 0.f)) return 0.f;
    primary.mtl.setActiveLobes(rtptGrisRefRootMask(prefix.rootLobe));
    const IMaterialInstance rootMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float3 firstDirection;
    float rootDistanceSquared;
    if (!rtptGrisPrefixDirection(primary.computeRayOrigin(), x1Position, firstDirection, rootDistanceSquared)) return 0.f;
    firstDistance = sqrt(rootDistanceSquared);
    ShadingData first;
    if (!rtptGrisRefLoad(prefix.x1, -firstDirection, first, previousGeometry)) return 0.f;
    const IMaterialInstance firstMaterial = gScene.materials.getMaterialInstance(first, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(first, firstMaterial.getLobeTypes(first))) return 0.f;
    const float rootGeometry = abs(dot(first.faceN, firstDirection)) / rootDistanceSquared;
    float3 connectionDirection;
    float connectionDistanceSquared;
    if (!rtptGrisPrefixDirection(first.computeRayOrigin(), x2Position, connectionDirection, connectionDistanceSquared)) return 0.f;
    ShadingData reconnect;
    if (!rtptGrisRefLoad(tail.reconnectHit, -connectionDirection, reconnect, previousGeometry)) return 0.f;
    const IMaterialInstance reconnectMaterial = gScene.materials.getMaterialInstance(reconnect, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(reconnect, reconnectMaterial.getLobeTypes(reconnect))) return 0.f;
    const float connectionGeometry = abs(dot(reconnect.faceN, connectionDirection)) / connectionDistanceSquared;
    const float rootPdf = rootMaterial.evalPdf(primary, firstDirection);
    const float firstPdf = firstMaterial.evalPdf(first, connectionDirection);
    if (!(rootPdf > 0.f) || !(firstPdf > 0.f) || !isfinite(rootPdf) || !isfinite(firstPdf)) return 0.f;
    // Both root strata are traced once. This representation is conditional on
    // the root; auxiliary prefix proposals retain their own root probabilities.
    ownerRatio = rootPdf * rootGeometry * firstPdf * connectionGeometry;
    if (!(ownerRatio > 0.f) || !isfinite(ownerRatio)) { ownerRatio = 0.f; return 0.f; }
    const float3 prefixFactor = rootMaterial.eval(primary, firstDirection, rng) * rootGeometry *
        firstMaterial.eval(first, connectionDirection, rng) * connectionGeometry;
    if (!all(isfinite(prefixFactor)) || !any(prefixFactor > 0.f)) return 0.f;
    // The record already witnesses both native edges: they were first-hit rays
    // at generation, or visibility-tested connections when this owner won.
    // Retracing the identical packed path with two offset endpoints can
    // spuriously self-occlude. Geometry changes invalidate that witness.
    const bool nativePrefix = !recheckVisibility && all(primaryHit == tail.ownerPrimaryHit) &&
        all(prefix.x1 == tail.sourceX1);
    if (!nativePrefix)
    {
        ShadingData visibilityPrimary = primary;
        ShadingData visibilityFirst = first;
        ShadingData visibilityReconnect = reconnect;
        if (previousGeometry)
        {
            // No previous TLAS. Use current surface endpoints for both rays.
            float3 currentX1, currentX2;
            if (!rtptGrisRefPrimary(primaryHit, cameraPosition, visibilityPrimary) ||
                !rtptGrisRefPosition(prefix.x1, currentX1) || !rtptGrisRefPosition(tail.reconnectHit, currentX2) ||
                !rtptGrisRefLoad(prefix.x1, visibilityPrimary.posW - currentX1, visibilityFirst) ||
                !rtptGrisRefLoad(tail.reconnectHit, currentX1 - currentX2, visibilityReconnect)) return 0.f;
        }
        if (!rtptGrisRefVisible(visibilityPrimary, visibilityFirst) ||
            !rtptGrisRefVisible(visibilityFirst, visibilityReconnect)) return 0.f;
    }
    const float3 scatter = reconnectMaterial.eval(reconnect, tail.suffixDirection, rng);
    const float scatterPdf = reconnectMaterial.evalPdf(reconnect, tail.suffixDirection);
    if (!all(isfinite(scatter)) || !isfinite(scatterPdf) || !any(scatter > 0.f)) return 0.f;
    float3 endpoint = tail.suffixLight;
    const uint kind = rtptGrisTerminalKind(tail.candidate.terminalKind);
    if (!rtptGrisIsDeepTail(tail) && kind == uint(GrisTerminalKind::GrisNee))
    {
        const float lightPdf = asfloat(tail.lightPdfOrIndex);
        if (!tail.lightIsAnalytic && 2u < gParams.maxBounces)
            endpoint *= rtptPowerHeuristic(lightPdf, scatterPdf);
    }
    else
    {
        if (!(scatterPdf > 0.f)) return 0.f;
        ownerRatio *= scatterPdf / kGrisReferenceDirectionPdf;
        endpoint /= kGrisReferenceDirectionPdf;
        if (!rtptGrisIsDeepTail(tail) && gParams.useNEE != 0u && !tail.lightIsAnalytic)
            endpoint *= rtptPowerHeuristic(scatterPdf, asfloat(tail.lightPdfOrIndex));
    }
    const float3 value = prefixFactor * scatter * endpoint;
    if (!(ownerRatio > 0.f) || !isfinite(ownerRatio) || !all(isfinite(value))) { ownerRatio = 0.f; return 0.f; }
    return value;
}

void rtptGrisNormalizeGenerated(inout GrisSpatialRecord record, GrisLocalPrefix prefix, inout SampleGenerator rng)
{
    record.sourceX1 = prefix.x1Hit;
    // Capture assembled R from the PDFs used by the actual root/x1/x2 draws.
    // Reconstructing a direction and querying PG again can cross a guide leaf
    // boundary, so the generated proposal must not be evaluated a second time.
    const float ratio = record.areaPdf;
    record.areaPdf = 0.f;
    if (!record.candidate.hasWinner || !rtptGrisRefKindSupported(record) ||
        !(ratio > 0.f) || !isfinite(ratio)) return;
    if (HitInfo(record.ownerPrimaryHit).getType() != HitType::Triangle ||
        HitInfo(record.sourceX1).getType() != HitType::Triangle ||
        HitInfo(record.reconnectHit).getType() != HitType::Triangle) return;
    const float3 cameraPosition = gScene.camera.getPosition();
    ShadingData primary;
    if (!rtptGrisRefPrimary(record.ownerPrimaryHit, cameraPosition, primary)) return;
    const float rootProbability = rtptGrisRefRootProbability(primary, record.candidate.rootLobe);
    if (!(rootProbability > 0.f)) return;
    if (ratio > 0.f && isfinite(ratio)) record.areaPdf = ratio;
}

#if defined(RTPT_GRIS_STORED_PREFIX_REUSE)
GrisSpatialRecord rtptGrisMergeStoredPrefix(GrisSpatialRecord canonical, GrisSpatialRecord inputs[kGrisMaxReuseInputs],
    float3 sourceCameras[kGrisMaxReuseInputs],
    uint inputCount, inout SampleGenerator rng
#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
    , GrisSuffixReplaySettings replay
#endif
    )
{
    if (gParams.useRussianRoulette != 0u || !rtptGrisRefDomainValid(canonical) ||
        (canonical.candidate.hasWinner && !rtptGrisRefSampleValid(canonical))) return canonical;

    const float3 targetCamera = gScene.camera.getPosition();
    bool domainValid[kGrisMaxReuseInputs];
#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
    GrisSpatialRecord historyInCurrent = {};
    GrisSpatialRecord canonicalInHistory = {};
    bool historyWinnerSupported = false;
    bool canonicalInHistorySupported = false;
#endif
    float totalM = canonical.candidate.M;
    uint acceptedCount = 0u;
    for (uint j = 0u; j < inputCount; ++j)
    {
        domainValid[j] = rtptGrisRefDomainValid(inputs[j]) &&
            (!inputs[j].candidate.hasWinner || rtptGrisRefSampleValid(inputs[j]));
#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
        if (domainValid[j] && j == replay.historyIndex)
        {
            // Primary reprojection still requires a stationary owner. The two
            // saved prefix vertices can move independently of that owner.
            if (replay.geometryChanged && (!rtptGrisReplayStaticSurface(canonical.ownerPrimaryHit) ||
                !rtptGrisReplayStaticSurface(inputs[j].ownerPrimaryHit)))
            {
                domainValid[j] = false;
                continue;
            }
            historyWinnerSupported = rtptGrisReplayStoredTail(inputs[j], replay, false, historyInCurrent);
            canonicalInHistorySupported = rtptGrisReplayStoredTail(canonical, replay, true, canonicalInHistory);
            // An unavailable previous point-light proposal invalidates the
            // history domain. A geometrically blocked candidate is only zero.
            if (replay.lightChanged || (replay.validateUnchanged && !RTPT_GRIS_SHARC_REPLAY))
                domainValid[j] = historyWinnerSupported && canonicalInHistorySupported;
        }
#endif
        if (domainValid[j])
        {
            totalM += inputs[j].candidate.M;
            ++acceptedCount;
        }
    }
    if (acceptedCount == 0u) return canonical;

    GrisSpatialRecord winner = canonical;
    float3 winnerValue = 0.f;
    float winnerRatio = 0.f;
    float weightSum = 0.f;
    // The last slot is the center. Each candidate retains its own surface
    // coordinates and its native F/R/W. Tail replay supplies cross-domain F.
    for (uint i = 0u; i <= inputCount; ++i)
    {
        const bool center = i == inputCount;
        GrisSpatialRecord candidate = canonical;
        if (!center)
        {
            if (!domainValid[i]) continue;
            candidate = inputs[i];
        }
        if (!candidate.candidate.hasWinner) continue;

        const float3 ownValue = candidate.candidate.F * candidate.areaPdf;
        const float ownTarget = rtptGrisRefTarget(ownValue);
        if (!(ownTarget > 0.f)) continue;
        const GrisReferencePrefix prefix = rtptGrisRefRecordPrefix(candidate);
        float targetRatio = candidate.areaPdf;
        float firstDistance = candidate.candidate.firstHit.hitT;
        float3 targetValue = ownValue;
        GrisSpatialRecord targetTail = candidate;
        bool geometryForward = false;
#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
        if (!center && i == replay.historyIndex)
        {
            if (!historyWinnerSupported) continue;
            targetTail = historyInCurrent;
            geometryForward = replay.geometryChanged;
        }
#endif
        if (!center)
            targetValue = rtptGrisRefEvaluate(canonical.ownerPrimaryHit, targetCamera, prefix, targetTail, rng,
                targetRatio, firstDistance, geometryForward);
        const float target = rtptGrisRefTarget(targetValue);
        if (!(target > 0.f) || !(targetRatio > 0.f)) continue;

        float misWeight;
        if (center)
        {
            // Spatial starts with the center's standalone share. Temporal
            // starts at one in case the reverse shift has no support.
            misWeight = 1.f;
            for (uint j = 0u; j < inputCount; ++j)
            {
                // An accepted empty reservoir can still support this path.
                if (!domainValid[j]) continue;
                GrisSpatialRecord crossTail = targetTail;
                bool previousGeometry = false;
#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
                if (j == replay.historyIndex)
                {
                    if (!canonicalInHistorySupported) continue;
                    crossTail = canonicalInHistory;
                    previousGeometry = replay.geometryChanged;
                }
#endif
                float crossRatio, crossDistance;
                const float3 cross = rtptGrisRefEvaluate(inputs[j].ownerPrimaryHit, sourceCameras[j], prefix, crossTail,
                    rng, crossRatio, crossDistance, previousGeometry, previousGeometry);
#if RTPT_GRIS_SPATIAL_REUSE
                misWeight += rtptGrisPairwiseCenterWeight(target, canonical.candidate.M,
                    rtptGrisRefTarget(cross), inputs[j].candidate.M);
#else
                misWeight = rtptGrisTalbotWeight(target, canonical.candidate.M, rtptGrisRefTarget(cross), inputs[j].candidate.M);
#endif
            }
        }
        else
        {
#if RTPT_GRIS_SPATIAL_REUSE
            misWeight = rtptGrisPairwiseNeighborWeight(target, canonical.candidate.M, ownTarget, candidate.candidate.M);
#else
            misWeight = rtptGrisTalbotWeight(ownTarget, candidate.candidate.M, target, canonical.candidate.M);
#endif
        }

        const float sourceWeight = candidate.candidate.W / candidate.areaPdf;
        const float weight = target * misWeight * sourceWeight;
        if (!(weight > 0.f) || !isfinite(weight)) continue;
        weightSum += weight;
        if (!isfinite(weightSum)) return canonical;
        if (sampleNext1D(rng) * weightSum < weight)
        {
            winner = targetTail;
            if (!center)
            {
                winner.candidate.firstHit.hitT = min(kRTPTNRDMissDistance, max(1e-5f, firstDistance));
                winner.candidate.firstHit.distanceState = kRTPTDistanceHit;
            }
            winnerValue = targetValue;
            winnerRatio = targetRatio;
        }
    }

    if (!(weightSum > 0.f))
    {
        canonical.candidate.F = 0.f;
        canonical.candidate.W = 0.f;
        canonical.candidate.M = totalM;
        canonical.candidate.hasWinner = false;
        return canonical;
    }

#if RTPT_GRIS_SPATIAL_REUSE
    weightSum /= float(acceptedCount) + 1.f;
#endif
    const float3 F = winnerValue / winnerRatio;
    const float W = winnerRatio * (weightSum / rtptGrisRefTarget(winnerValue));
    if (!(W > 0.f) || !isfinite(W) || !all(isfinite(F * W))) return canonical;
    winner.ownerPrimaryHit = canonical.ownerPrimaryHit;
    winner.areaPdf = winnerRatio;
    winner.candidate.F = F;
    winner.candidate.W = W;
    winner.candidate.M = totalM;
    return winner;
}
#endif

#if RTPT_GRIS_DUAL_FIRST_HIT
#include "RTPTGRISDualExplicitPath.slang"
// Direct and deep events have separate measures. Both use dA(x2) and the
// light ID (plus unit-square coordinates for a triangle). Deep events also
// use solid angle for the shared direction leaving x2.
// The generated x1 and its actual sampling density condition this domain.
struct GrisDualTailValue
{
    float3 diffuse;
    float3 specular;

    float target() { return rtptGrisRefTarget(diffuse + specular); }
};

struct GrisDualReplayDomain
{
    bool previousLights;
    bool previousGeometry;
    uint movedBoundsCount;
#if RTPT_GRIS_DUAL_SHARC && defined(RTPT_GRIS_TEMPORAL_REUSE)
    uint previousSharcMode;
#endif
};

float rtptGrisDualLightProbability(GrisSpatialRecord tail)
{
    const uint kind = rtptGrisTerminalKind(tail.candidate.terminalKind);
    if (kind == uint(GrisTerminalKind::GrisDualEmitter) || kind == uint(GrisTerminalKind::GrisDualEnvironmentMiss))
        return 1.f;
#if RTPT_GRIS_DUAL_SHARC
    // Both routes share the x3 draw when they use the same x2 and outgoing direction.
    // Its selected-lobe proposal compensation is folded into the incident.
    if (kind == uint(GrisTerminalKind::GrisDualSharcTail)) return 1.f;
#endif
    const float3 categories = rtptLightCategoryProbabilities();
#if USE_ENV_LIGHT
    if (kind == uint(GrisTerminalKind::GrisDualEnvironmentNee)) return categories.x;
#endif
#if USE_ANALYTIC_LIGHTS
    if (kind == uint(GrisTerminalKind::GrisDualPointNee) &&
        tail.lightPdfOrIndex < gScene.getLightCount())
        return categories.z / float(gScene.getLightCount());
#endif
#if USE_EMISSIVE_LIGHTS
    if (kind == uint(GrisTerminalKind::GrisDualEmissiveNee) &&
        categories.y > 0.f && tail.lightPdfOrIndex < gScene.lightCollection.getTriangleCount() &&
        gScene.lightCollection.getActiveTriangleIndex(tail.lightPdfOrIndex) != LightCollection::kInvalidIndex)
        return categories.y / float(gScene.lightCollection.getActiveTriangleCount());
#endif
    return 0.f;
}

float3 rtptGrisEvaluateDualLight(ShadingData surface, ShadingData visibilitySurface, IMaterialInstance material,
    GrisSpatialRecord tail, float lightProbability, inout SampleGenerator rng, bool previousLights,
    out bool shadowClear, uint movedBoundsCount = 0u, bool knownVisible = false)
{
    shadowClear = false;
    SceneRayQuery<true> query;
    const uint kind = rtptGrisTerminalKind(tail.candidate.terminalKind);
#if USE_ENV_LIGHT
    if (kind == uint(GrisTerminalKind::GrisDualEnvironmentNee))
    {
        const float2 uv = rtptGrisIsDeepTail(tail) ? tail.suffixLight.xy : tail.suffixDirection.xy;
        EnvMapSample sample;
        if (!gEnvMapSampler.sample(uv, sample) || !(sample.pdf > 0.f) || !isfinite(sample.pdf) ||
            !all(isfinite(sample.dir)) || !all(isfinite(sample.Le)) || !any(sample.Le > 0.f) ||
            dot(surface.getOrientedFaceNormal(), sample.dir) <= 0.f) return 0.f;

        const Ray shadow = Ray(visibilitySurface.computeRayOrigin(), sample.dir);
        if (!knownVisible && !query.traceVisibilityRay(shadow)) return 0.f;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
        if (movedBoundsCount != 0u) shadowClear = rtptGrisDualExplicitInfiniteRayClear(shadow, movedBoundsCount);
#endif

        const float bsdfPdf = rtptContinuationPdf(surface, material, rtptBSDFSamplingContext(), sample.dir);
        if (!isfinite(bsdfPdf)) return 0.f;
        const float mis = rtptPowerHeuristic(lightProbability * sample.pdf, bsdfPdf);
        // The outer proposal accounts for the environment category probability.
        return material.eval(surface, sample.dir, rng) * sample.Le * (mis / sample.pdf);
    }
#endif
#if USE_ANALYTIC_LIGHTS
    if (kind == uint(GrisTerminalKind::GrisDualPointNee))
    {
        const uint lightIndex = tail.lightPdfOrIndex;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
        const LightData light = previousLights ? gGRISReplayPreviousLights[lightIndex] : gScene.getLight(lightIndex);
#else
        const LightData light = gScene.getLight(lightIndex);
#endif
        AnalyticLightSample sample;
        if (!samplePointLight(surface.posW, light, sample) ||
            dot(surface.getOrientedFaceNormal(), sample.dir) <= 0.f ||
            !all(isfinite(sample.Li)) || !any(sample.Li > 0.f)) return 0.f;
        AnalyticLightSample visibilitySample = sample;
        if (any(surface.posW != visibilitySurface.posW) &&
            !samplePointLight(visibilitySurface.posW, light, visibilitySample)) return 0.f;
        const Ray shadow = Ray(visibilitySurface.computeRayOrigin(), visibilitySample.dir, 0.f, visibilitySample.distance);
        if (!knownVisible && !query.traceVisibilityRay(shadow)) return 0.f;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
        if (movedBoundsCount != 0u) shadowClear = rtptGrisReplayRayClear(shadow, movedBoundsCount);
#endif
        return material.eval(surface, sample.dir, rng) * sample.Li;
    }
#endif
#if USE_EMISSIVE_LIGHTS
    if (kind == uint(GrisTerminalKind::GrisDualEmissiveNee))
    {
        const uint lightIndex = tail.lightPdfOrIndex;
        const float2 uv = rtptGrisIsDeepTail(tail) ? tail.suffixLight.xy : tail.suffixDirection.xy;
        TriangleLightSample sample;
        if (!sampleTriangle(surface.posW, lightIndex, uv, sample) ||
            dot(surface.getOrientedFaceNormal(), sample.dir) <= 0.f || !(sample.pdf > 0.f) || !isfinite(sample.pdf)) return 0.f;

        const EmissiveTriangle triangle = gScene.lightCollection.getTriangle(lightIndex);
        VertexData lightVertex = {};
        lightVertex.posW = sample.posW;
        lightVertex.texC = triangle.getTexCoord(sample_triangle(uv));
        if (gScene.materials.alphaTest(lightVertex, triangle.materialID, 0.f)) return 0.f;
        const float3 origin = visibilitySurface.computeRayOrigin();
        const float3 edge = computeRayOrigin(sample.posW, sample.normalW) - origin;
        const float distance = length(edge);
        if (!(distance > 0.f) || !isfinite(distance)) return 0.f;
        const Ray shadow = Ray(origin, edge / distance, 0.f, distance);
        if (!knownVisible && !query.traceVisibilityRay(shadow)) return 0.f;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
        if (movedBoundsCount != 0u) shadowClear = rtptGrisReplayRayClear(shadow, movedBoundsCount);
#endif

        const float lightPdf = lightProbability * sample.pdf;
        const float bsdfPdf = rtptContinuationPdf(surface, material, rtptBSDFSamplingContext(), sample.dir);
        if (!isfinite(lightPdf) || !isfinite(bsdfPdf)) return 0.f;
        const float mis = rtptPowerHeuristic(lightPdf, bsdfPdf);
        // sample.pdf converts unit-square light coordinates to solid angle.
        return material.eval(surface, sample.dir, rng) * sample.Le * (mis / sample.pdf);
    }
#endif
    return 0.f;
}

float3 rtptGrisEvaluateDualDeep(GrisSpatialRecord tail, TriangleHit triangle, float lightProbability,
    inout SampleGenerator rng, out bool shadowClear, bool previousLights = false, uint movedBoundsCount = 0u)
{
    shadowClear = false;
    ShadingData surface = gScene.materials.prepareShadingData(gScene.getVertexData(triangle),
        gScene.getMaterialID(triangle.instanceID), -tail.suffixDirection);
    surface.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
    if ((material.getLobeTypes(surface) & uint(LobeType::NonDeltaReflection)) == 0u) return 0.f;
    return rtptGrisEvaluateDualLight(surface, surface, material, tail, lightProbability, rng,
        previousLights, shadowClear, movedBoundsCount);
}

struct GrisDualDeepIncident
{
    float3 current;
    float3 previous;
    float lightPdf; // Competing NEE density for x3 BSDF terminals.
};

#if RTPT_GRIS_DUAL_SHARC && defined(RTPT_GRIS_TEMPORAL_REUSE)
ParameterBlock<SharcParameters> gGRISPreviousSharc;
#endif

GrisDualDeepIncident rtptGrisTraceDualDeep(GrisSpatialRecord tail, inout SampleGenerator rng,
    GrisDualReplayDomain domain, bool evaluatePrevious)
{
    GrisDualDeepIncident result = {};
    const float3 direction = tail.suffixDirection;
    if (!all(isfinite(direction)) || !(dot(direction, direction) > 0.f)) return result;
    const float lightProbability = rtptGrisDualLightProbability(tail);
    if (!(lightProbability > 0.f)) return result;

    // Both eligible routes see the front of x2. The same offset origin and
    // outgoing direction therefore give the same x3 and NEE evaluation.
    const TriangleHit reconnect = HitInfo(tail.reconnectHit).getTriangleHit();
    const VertexData vertex = rtptGrisPrefixVertex(reconnect);
    SceneRayQuery<true> query;
    float hitT;
    const Ray ray = Ray(computeRayOrigin(vertex.posW, vertex.faceNormalW), direction);
    const HitInfo hit = query.traceRay(ray, hitT);
    if (hit.getType() != HitType::Triangle) return result;

    uint shadowBoundsCount = 0u;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (evaluatePrevious && domain.previousGeometry && rtptGrisReplayStaticSurface(tail.reconnectHit) &&
        rtptGrisReplayStaticSurface(hit.pack()) &&
        rtptGrisReplayRayClear(Ray(ray.origin, ray.dir, ray.tMin, hitT), domain.movedBoundsCount))
        shadowBoundsCount = domain.movedBoundsCount;
#endif
    bool shadowClear;
    result.current = rtptGrisEvaluateDualDeep(tail, hit.getTriangleHit(), lightProbability, rng,
        shadowClear, false, shadowBoundsCount);
    result.previous = result.current;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (domain.previousGeometry)
        result.previous = shadowClear ? result.current : float3(0.f);
    else if (evaluatePrevious && domain.previousLights &&
        rtptGrisTerminalKind(tail.candidate.terminalKind) == uint(GrisTerminalKind::GrisDualPointNee))
        result.previous = rtptGrisEvaluateDualDeep(tail, hit.getTriangleHit(), lightProbability, rng, shadowClear, true);
#endif
    return result;
}

#include "RTPTGRISDualExplicitReplay.slang"

#include "RTPTGRISFixedX1.slang"

GrisDualTailValue rtptGrisNativeDualTail(GrisSpatialRecord record)
{
    GrisDualTailValue result = {};
    result.diffuse = record.candidate.F;
    result.specular = record.candidate.dualF;
    return result;
}

bool rtptGrisDualTailValid(GrisSpatialRecord record)
{
    const uint kind = rtptGrisTerminalKind(record.candidate.terminalKind);
    if (HitInfo(record.sourceX1).getType() != HitType::Triangle) return false;
    if ((record.candidate.terminalKind & kGrisFixedX1Nee) != 0u)
        return record.candidate.hasWinner &&
            (kind == uint(GrisTerminalKind::GrisDualPointNee) || kind == uint(GrisTerminalKind::GrisDualEmissiveNee) ||
             kind == uint(GrisTerminalKind::GrisDualEnvironmentNee));
    return record.candidate.hasWinner &&
        (
#if RTPT_GRIS_DUAL_SHARC
#if RTPT_GRIS_GENERATE
            kind == uint(GrisTerminalKind::GrisDualSharcTail) ||
#else
            (kind == uint(GrisTerminalKind::GrisDualSharcTail) && record.dualExplicitBounce == 4u) ||
#endif
#endif
            kind == uint(GrisTerminalKind::GrisDualPointNee) || kind == uint(GrisTerminalKind::GrisDualEmissiveNee) ||
            kind == uint(GrisTerminalKind::GrisDualEnvironmentNee) || kind == uint(GrisTerminalKind::GrisDualEmitter) ||
            kind == uint(GrisTerminalKind::GrisDualEnvironmentMiss)) &&
        HitInfo(record.reconnectHit).getType() == HitType::Triangle;
}

bool rtptGrisAcceptDualDomain(GrisSpatialRecord canonical, GrisSpatialRecord source, GrisDualReplayDomain domain)
{
    if (!rtptGrisRefDomainValid(source)) return false;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (domain.previousGeometry && (!rtptGrisReplayStaticSurface(canonical.ownerPrimaryHit) ||
        !rtptGrisReplayStaticSurface(source.ownerPrimaryHit))) return false;
#endif
    return true;
}

bool rtptGrisUseNativeDualHistory(GrisSpatialRecord tail, GrisDualReplayDomain domain)
{
#if RTPT_GRIS_DUAL_SHARC && defined(RTPT_GRIS_TEMPORAL_REUSE)
    if (rtptGrisTerminalKind(tail.candidate.terminalKind) == uint(GrisTerminalKind::GrisDualSharcTail) &&
        domain.previousSharcMode == 0u) return false;
#endif
    return !domain.previousGeometry;
}

GrisDualDeepIncident rtptGrisTraceDualTail(GrisSpatialRecord tail, inout SampleGenerator rng,
    GrisDualReplayDomain domain, bool evaluatePrevious)
{
    if (tail.dualExplicitBounce != 0u) return rtptGrisTraceDualExplicit(tail, rng, domain);
    if (rtptGrisIsDeepTail(tail)) return rtptGrisTraceDualDeep(tail, rng, domain, evaluatePrevious);
    GrisDualDeepIncident incident = {};
    return incident;
}

#if defined(RTPT_GRIS_TEMPORAL_REUSE)
SampleGenerator rtptGrisDualTemporalEvaluationRng(uint2 pixel, bool fresh)
{
    return SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ (fresh ? 0x279b3d17u : 0x798ef035u));
}
#endif

GrisSpatialRecord rtptGrisFinalizeDualTail(GrisSpatialRecord center, GrisSpatialRecord winner,
    float sum, float winnerTarget, float count)
{
    const float W = winnerTarget > 0.f ? sum / winnerTarget : 0.f;
    if (W > 0.f && isfinite(W) && all(isfinite(winner.candidate.F * W)) && all(isfinite(winner.candidate.dualF * W)))
    {
        winner.ownerPrimaryHit = center.ownerPrimaryHit;
        winner.candidate.prepared = center.candidate.prepared;
        winner.candidate.W = W;
        winner.candidate.M = count;
        return winner;
    }
    center.candidate.hasWinner = false;
    center.candidate.W = 0.f;
    center.candidate.M = count;
    return center;
}

#if RTPT_GRIS_GENERATE
void rtptGrisApplyDualNeeTerminal(GrisDualNeeTerminal terminal, bool deep, inout GrisSpatialRecord record)
{
    record.candidate.terminalKind = terminal.terminalKind;
    record.candidate.hasWinner = terminal.hasWinner;
    record.lightPdfOrIndex = terminal.lightPdfOrIndex;
    record.lightIsAnalytic = terminal.lightIsAnalytic;
    if (deep) record.suffixLight = terminal.coordinates;
    else record.suffixDirection = terminal.coordinates;
}

static const uint kGrisFreshX2NeeEvent = 0u;
static const uint kGrisFreshX3NeeEvent = 1u;
static const uint kGrisFreshX3BsdfEvent = 2u;
static const uint kGrisFreshLateEvent = 3u;
static const uint kGrisFreshSharcEvent = 4u;
static const uint kGrisFixedX1NeeEvent = 5u;

bool rtptGrisFreshRootPdfValid(float nativePdf, float3 drawDirection)
{
    return nativePdf > 0.f && isfinite(nativePdf) && all(isfinite(drawDirection)) &&
        dot(drawDirection, drawDirection) > 0.f;
}

float rtptGrisFreshRootPdfSumAtVertex(float nativePdf, uint slot, uint attemptedMask, float3 drawDirection,
    float3 firstPosition, float3 firstFaceNormal, ShadingData primary, IMaterialInstance primaryMaterial,
    RTPTSamplingContext diffuseSampling, bool separateRootMeasures)
{
    if (separateRootMeasures) return nativePdf;
    if (!rtptGrisFreshRootPdfValid(nativePdf, drawDirection)) return 0.f;

    const uint otherSlot = slot ^ 1u;
    if ((attemptedMask & (1u << otherSlot)) == 0u) return nativePdf;

    float3 representedDirection;
    float distanceSquared;
    if (!rtptGrisPrefixDirection(primary.computeRayOrigin(), firstPosition, representedDirection, distanceSquared)) return 0.f;
    const float geometry = abs(dot(firstFaceNormal, representedDirection)) / distanceSquared;
    primary.mtl.setActiveLobes(otherSlot == 0u ? uint(LobeType::DiffuseReflection) : uint(LobeType::SpecularReflection));
    const RTPTSamplingContext sampling = otherSlot == 0u ? diffuseSampling : rtptBSDFSamplingContext();
    const float otherPdf = rtptContinuationPdf(primary, primaryMaterial, sampling, drawDirection);
    return otherPdf >= 0.f && isfinite(otherPdf) ? nativePdf + otherPdf * geometry : 0.f;
}

// Materialize only the candidate selected by the Fresh reservoir.
GrisSpatialRecord rtptGrisMakeDualFreshProposal(PackedHitInfo owner, PackedHitInfo firstHit,
    uint event, uint slot, GrisDualX2Sample x2, GrisDualExplicitTerminal terminal
#if RTPT_GRIS_DUAL_SHARC
    , GrisSpatialRecord cache
#endif
#ifdef RTPT_GRIS_DELTA_REUSE
    , bool deltaRoot
#endif
    )
{
#if RTPT_GRIS_DUAL_SHARC
    if (event == kGrisFreshSharcEvent)
    {
#ifdef RTPT_GRIS_DELTA_REUSE
        if (deltaRoot) cache.candidate.terminalKind |= kGrisDeltaRoot;
#endif
        return cache;
    }
#endif
    const bool deep = event != kGrisFreshX2NeeEvent;
    GrisSpatialRecord proposal = {};
    proposal.ownerPrimaryHit = owner;
    proposal.sourceX1 = firstHit;
    proposal.reconnectHit = x2.hit;
    proposal.candidate.rootLobe = slot == 0u ? uint(GrisRootComponent::GrisDiffuse) : uint(GrisRootComponent::GrisSpecular);
    if (event == kGrisFixedX1NeeEvent)
    {
        proposal.reconnectHit = makeInvalidHit().pack();
        proposal.areaPdf = 1.f;
        rtptGrisApplyDualNeeTerminal(x2.firstNee, false, proposal);
        proposal.candidate.terminalKind |= kGrisFixedX1Nee;
#ifdef RTPT_GRIS_DELTA_REUSE
        if (deltaRoot) proposal.candidate.terminalKind |= kGrisDeltaRoot;
#endif
        return proposal;
    }
    proposal.areaPdf = deep ? x2.deepPdf : x2.areaPdf;
    if (deep)
    {
        proposal.suffixDirection = x2.direction;
        proposal.dualExplicitRng = x2.replayRng;
    }
    const GrisDualNeeTerminal light = deep ? x2.deepLight : x2.directLight;
    rtptGrisApplyDualNeeTerminal(light, deep, proposal);
    if (event == kGrisFreshX3BsdfEvent || event == kGrisFreshLateEvent)
    {
        // Explicit events restore the terminal fields recorded at the original hit.
        proposal.suffixLight = terminal.suffixLight;
        proposal.dualExplicitPathID = terminal.dualExplicitPathID;
        proposal.dualExplicitBounce = terminal.dualExplicitBounce;
        proposal.candidate.terminalKind = terminal.terminalKind;
        proposal.candidate.hasWinner = terminal.dualExplicitBounce != 0u;
        proposal.lightPdfOrIndex = terminal.lightPdfOrIndex;
        proposal.lightIsAnalytic = terminal.lightIsAnalytic;
    }
#ifdef RTPT_GRIS_DELTA_REUSE
    if (deltaRoot) proposal.candidate.terminalKind |= kGrisDeltaRoot;
#endif
    return proposal;
}

struct GrisFreshSlotReservoir
{
    float weightSum;
    float winnerTarget;
    float3 winnerDiffuse;
    float3 winnerSpecular;
    uint winnerEvent;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
    float4 winnerDeepIncident;
#endif
};

void rtptGrisOfferFreshCandidate(inout GrisFreshSlotReservoir reservoir, uint event, GrisDualTailValue value,
    float proposalSum, float3 deepIncident, float deepLightPdf, inout SampleGenerator pickRng)
{
    if (!(proposalSum > 0.f) || !isfinite(proposalSum)) return;
    const float target = value.target();
    const float weight = target / proposalSum;
    if (!(weight > 0.f) || !isfinite(weight)) return;

    reservoir.weightSum += weight;
    if (sampleNext1D(pickRng) * reservoir.weightSum < weight)
    {
        reservoir.winnerTarget = target;
        reservoir.winnerDiffuse = value.diffuse;
        reservoir.winnerSpecular = value.specular;
        reservoir.winnerEvent = event;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
        reservoir.winnerDeepIncident = float4(deepIncident, deepLightPdf);
#endif
    }
}

uint rtptGrisChooseFreshSlot(GrisFreshSlotReservoir diffuse, GrisFreshSlotReservoir specular, inout SampleGenerator mergeRng)
{
    if (!(diffuse.weightSum > 0.f)) return 1u;
    if (!(specular.weightSum > 0.f)) return 0u;
    const float total = diffuse.weightSum + specular.weightSum;
    return sampleNext1D(mergeRng) * total < specular.weightSum ? 1u : 0u;
}
#endif

#if defined(RTPT_GRIS_TEMPORAL_REUSE) || RTPT_GRIS_SPATIAL_REUSE
struct GrisDualTemporalWinner
{
    uint inputIndex;
    float3 diffuse;
    float3 specular;
    float target;
    float sum;
    float count;
#if defined(RTPT_GRIS_TEMPORAL_REUSE) && RTPT_GRIS_SPATIAL_DEEP_INCIDENT
    float4 deepIncident;
#endif
};

GrisDualTemporalWinner rtptGrisMergeDualTails(GrisSpatialRecord canonical,
#if RTPT_GRIS_SPATIAL_REUSE
    StructuredBuffer<GrisSpatialRecord> spatialInput, uint sourceIndices[kGrisMaxReuseInputs],
    uint inputCount, inout SampleGenerator rng
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
    , StructuredBuffer<float4> spatialDeepIncident, uint centerIndex
#endif
#else
    GrisSpatialRecord inputs[kGrisMaxReuseInputs],
    float3 sourceCameras[kGrisMaxReuseInputs], uint inputCount, inout SampleGenerator rng
#endif
#if defined(RTPT_GRIS_TEMPORAL_REUSE)
    , uint2 pixel
#endif
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    , bool previousLights, bool previousGeometry, uint movedBoundsCount
#endif
#if RTPT_GRIS_DUAL_SHARC && defined(RTPT_GRIS_TEMPORAL_REUSE)
    , uint previousSharcMode
#endif
    )
{
    const float3 camera = gScene.camera.getPosition();
    GrisDualReplayDomain sourceDomain = {};
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    sourceDomain.previousLights = previousLights;
    sourceDomain.previousGeometry = previousGeometry;
    sourceDomain.movedBoundsCount = movedBoundsCount;
#endif
#if RTPT_GRIS_DUAL_SHARC && defined(RTPT_GRIS_TEMPORAL_REUSE)
    sourceDomain.previousSharcMode = previousSharcMode;
#endif
    GrisDualTemporalWinner winner = {inputCount, canonical.candidate.F, canonical.candidate.dualF, 0.f, 0.f, canonical.candidate.M
#if defined(RTPT_GRIS_TEMPORAL_REUSE) && RTPT_GRIS_SPATIAL_DEEP_INCIDENT
        , float4(0.f)
#endif
    };
    bool accepted[kGrisMaxReuseInputs];
#if RTPT_GRIS_SPATIAL_REUSE
    PackedHitInfo sourcePrimaryHits[kGrisMaxReuseInputs];
    float sourceCounts[kGrisMaxReuseInputs];
    uint acceptedCount = 0u;
#endif
    [loop] for (uint j = 0u; j < inputCount; ++j)
    {
#if RTPT_GRIS_SPATIAL_REUSE
        const GrisSpatialRecord neighbor = spatialInput[sourceIndices[j]];
        sourcePrimaryHits[j] = neighbor.ownerPrimaryHit;
        sourceCounts[j] = neighbor.candidate.M;
#else
        const GrisSpatialRecord neighbor = inputs[j];
#endif
        accepted[j] = rtptGrisAcceptDualDomain(canonical, neighbor, sourceDomain);
        if (accepted[j])
        {
            winner.count += neighbor.candidate.M;
#if RTPT_GRIS_SPATIAL_REUSE
            ++acceptedCount;
#endif
        }
    }

    [loop] for (uint i = 0u; i <= inputCount; ++i)
    {
        const bool center = i == inputCount;
        GrisSpatialRecord proposal = canonical;
        if (!center)
        {
            if (!accepted[i]) continue;
#if RTPT_GRIS_SPATIAL_REUSE
            proposal = spatialInput[sourceIndices[i]];
#else
            proposal = inputs[i];
#endif
        }
        if (!rtptGrisDualTailValid(proposal) || !(proposal.candidate.W > 0.f)) continue;
#if RTPT_GRIS_SPATIAL_REUSE
        // Spatial reuses the current-frame direct shadow test. Short NEE
        // starts at the stored x1. Longer direct NEE starts at the stored x2.
        const bool knownVisible = !rtptGrisIsDeepTail(proposal);
#else
        const bool knownVisible = false;
#endif
#if defined(RTPT_GRIS_TEMPORAL_REUSE)
        // A skipped candidate cannot change the stream used by the other
        // candidate or by the reservoir lottery.
        SampleGenerator evaluationRng = rtptGrisDualTemporalEvaluationRng(pixel, center);
#else
#define evaluationRng rng
#endif
#if RTPT_GRIS_SPATIAL_REUSE && RTPT_GRIS_SPATIAL_DEEP_INCIDENT
        GrisDualDeepIncident deepIncident = {};
        if (!knownVisible)
        {
            const float4 incident = spatialDeepIncident[center ? centerIndex : sourceIndices[i]];
            deepIncident.current = deepIncident.previous = incident.xyz;
            deepIncident.lightPdf = incident.w;
        }
#else
        const GrisDualDeepIncident deepIncident = rtptGrisTraceDualTail(proposal, evaluationRng,
            sourceDomain, center || sourceDomain.previousGeometry);
#endif
        const GrisDualTailValue targetValue = center ? rtptGrisNativeDualTail(proposal) :
            rtptGrisEvaluateFixedX1Tail(canonical.ownerPrimaryHit, camera, proposal, deepIncident.current,
                evaluationRng, false, {}, deepIncident.lightPdf, knownVisible);
        const float target = targetValue.target();
        if (!(target > 0.f)) continue;

        float misWeight;
#if RTPT_GRIS_SPATIAL_REUSE
        if (center)
        {
            misWeight = 1.f;
            [loop] for (uint j = 0u; j < inputCount; ++j)
            {
                // An accepted empty reservoir can still support this path.
                if (!accepted[j]) continue;
                const float cross =
                    rtptGrisEvaluateFixedX1Tail(sourcePrimaryHits[j], camera, proposal, deepIncident.previous,
                        evaluationRng, false, sourceDomain, deepIncident.lightPdf, knownVisible).target();
                misWeight += rtptGrisPairwiseCenterWeight(target, canonical.candidate.M, cross, sourceCounts[j]);
            }
        }
        else
        {
            const float sourceTarget = rtptGrisNativeDualTail(proposal).target();
            misWeight = rtptGrisPairwiseNeighborWeight(target, canonical.candidate.M, sourceTarget, proposal.candidate.M);
        }
#else
        float historyTarget = 0.f;
        float historyCount = 0.f;
        if (inputCount != 0u && accepted[0])
        {
            // On motion, apply the same old-domain visibility rule to both
            // directions of MIS, including the old domain's own winner.
            const bool useNative = !center && rtptGrisUseNativeDualHistory(proposal, sourceDomain);
            historyTarget = useNative ? rtptGrisNativeDualTail(proposal).target() :
                rtptGrisEvaluateFixedX1Tail(inputs[0].ownerPrimaryHit, sourceCameras[0], proposal, deepIncident.previous,
                    evaluationRng, false, sourceDomain, deepIncident.lightPdf, knownVisible).target();
            historyCount = inputs[0].candidate.M;
        }
        misWeight = center
            ? rtptGrisTalbotWeight(target, canonical.candidate.M, historyTarget, historyCount)
            : rtptGrisTalbotWeight(historyTarget, historyCount, target, canonical.candidate.M);
#endif
        const float weight = target * misWeight * proposal.candidate.W;
        if (weight > 0.f && isfinite(weight))
        {
            winner.sum += weight;
            if (sampleNext1D(rng) * winner.sum < weight)
            {
                winner.inputIndex = i;
                winner.diffuse = targetValue.diffuse;
                winner.specular = targetValue.specular;
                winner.target = target;
#if defined(RTPT_GRIS_TEMPORAL_REUSE) && RTPT_GRIS_SPATIAL_DEEP_INCIDENT
                winner.deepIncident = float4(deepIncident.current, deepIncident.lightPdf);
#endif
            }
        }
    }
#if !defined(RTPT_GRIS_TEMPORAL_REUSE)
#undef evaluationRng
#endif
#if RTPT_GRIS_SPATIAL_REUSE
    // Every accepted pair and the standalone center share contribute once.
    winner.sum /= float(acceptedCount) + 1.f;
#endif
    return winner;
}
#endif
#endif

#endif
