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

#if RTPT_REGIR_TRANSPORT && RTPT_REGIR_ONLY
struct GrisLightHistorySettings
{
    uint enabled;
    uint currentEpoch;
    uint historyEpoch;
    uint stableIdCount;
};
ConstantBuffer<GrisLightHistorySettings> gGRISLightHistorySettings;
// birth epoch, last physical change epoch, alive, light kind. Unlike the
// ReGIR culling descriptor this tracks RGB/spot changes, not only a proxy.
StructuredBuffer<uint4> gGRISLightHistoryMetadata;
#endif

uint rtptGrisCurrentLightEpoch()
{
#if RTPT_REGIR_TRANSPORT && RTPT_REGIR_ONLY
    return gGRISLightHistorySettings.currentEpoch;
#else
    return 0u;
#endif
}

uint rtptGrisPreviousLightEpoch()
{
#if RTPT_REGIR_TRANSPORT && RTPT_REGIR_ONLY
    return gGRISLightHistorySettings.historyEpoch;
#else
    return 0u;
#endif
}

bool rtptGrisSourceAllowsTail(GrisSpatialRecord tail, uint sourceLightEpoch)
{
#if RTPT_REGIR_TRANSPORT && RTPT_REGIR_ONLY
    if (gGRISLightHistorySettings.enabled == 0u || sourceLightEpoch == gGRISLightHistorySettings.currentEpoch)
        return true;
    // Phase one changes only analytic point/spot lights. Geometry, materials,
    // emissive sources and environment changes retain structural invalidation.
    if (rtptGrisTerminalKind(tail.candidate.terminalKind) != uint(GrisTerminalKind::GrisReGIRPath) ||
        !tail.lightIsAnalytic) return true;
    const uint stableID = tail.lightPdfOrStableID;
    if (sourceLightEpoch == 0u || sourceLightEpoch > gGRISLightHistorySettings.currentEpoch ||
        stableID >= gGRISLightHistorySettings.stableIdCount) return false;
    const uint4 state = gGRISLightHistoryMetadata[stableID];
    return state.z != 0u && state.w == kRTPTDILightPoint &&
        state.x <= sourceLightEpoch && state.y <= sourceLightEpoch;
#else
    return true;
#endif
}

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
#if RTPT_REGIR_TRANSPORT && RTPT_REGIR_ONLY
        || kind == uint(GrisTerminalKind::GrisReGIRPath)
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

bool rtptGrisIsReGIRReplayTail(GrisSpatialRecord tail)
{
    return RTPT_GRIS_REGIR_REPLAY &&
        rtptGrisTerminalKind(tail.candidate.terminalKind) == uint(GrisTerminalKind::GrisReGIRPath);
}

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
    if (rtptGrisIsReGIRReplayTail(source)) return rtptGrisReplaySuffix(source, false, false, result);
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
        const float lightPdf = asfloat(tail.lightPdfOrStableID);
        if (!tail.lightIsAnalytic && 2u < gParams.maxBounces)
            endpoint *= rtptPowerHeuristic(lightPdf, scatterPdf);
    }
    else if (!rtptGrisIsDeepTail(tail) && kind == uint(GrisTerminalKind::GrisReGIRPath))
    {
        // Direct x2 -> light: its inner RIS compensation is already in
        // endpoint, and the covered emission has no BSDF competitor. This
        // sample did not draw an x2 continuation, so do not add q2/q_ref.
    }
    else
    {
        if (!(scatterPdf > 0.f)) return 0.f;
        ownerRatio *= scatterPdf / kGrisReferenceDirectionPdf;
        endpoint /= kGrisReferenceDirectionPdf;
#if !RTPT_REGIR_ONLY
        if (!rtptGrisIsDeepTail(tail) && gParams.useNEE != 0u && !tail.lightIsAnalytic)
            endpoint *= rtptPowerHeuristic(scatterPdf, asfloat(tail.lightPdfOrStableID));
#endif
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
    float3 sourceCameras[kGrisMaxReuseInputs], uint sourceLightEpochs[kGrisMaxReuseInputs],
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
    bool hasSource = false;
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
            historyWinnerSupported = rtptGrisSourceAllowsTail(inputs[j], sourceLightEpochs[j]) &&
                rtptGrisReplayStoredTail(inputs[j], replay, false, historyInCurrent);
            canonicalInHistorySupported = rtptGrisReplayStoredTail(canonical, replay, true, canonicalInHistory);
            // An unavailable previous point-light proposal invalidates the
            // history domain. A geometrically blocked candidate is only zero.
            if (replay.lightChanged || (replay.validateUnchanged && !RTPT_GRIS_REGIR_REPLAY &&
                !RTPT_GRIS_SHARC_REPLAY))
                domainValid[j] = historyWinnerSupported && canonicalInHistorySupported;
        }
#endif
        if (domainValid[j])
        {
            totalM += inputs[j].candidate.M;
            hasSource = true;
        }
    }
    if (!hasSource) return canonical;

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
            if (!domainValid[i] || !rtptGrisSourceAllowsTail(inputs[i], sourceLightEpochs[i])) continue;
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

        // Equal domain coefficients. Even an empty source contributes a
        // cross term if it supports this candidate.
        float denominator = center ? ownTarget : ownTarget + target;
        for (uint j = 0u; j < inputCount; ++j)
        {
            if (!domainValid[j] || j == i) continue;
            GrisSpatialRecord crossTail = targetTail;
            bool previousGeometry = false;
#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
            if (j == replay.historyIndex)
            {
                if (center)
                {
                    if (!canonicalInHistorySupported) continue;
                    crossTail = canonicalInHistory;
                }
                previousGeometry = replay.geometryChanged;
            }
#endif
            if (!rtptGrisSourceAllowsTail(crossTail, sourceLightEpochs[j])) continue;
            float crossRatio, crossDistance;
            const float3 cross = rtptGrisRefEvaluate(inputs[j].ownerPrimaryHit, sourceCameras[j], prefix, crossTail,
                rng, crossRatio, crossDistance, previousGeometry, previousGeometry);
            denominator += rtptGrisRefTarget(cross);
        }

        const float sourceWeight = candidate.candidate.W / candidate.areaPdf;
        const float weight = (ownTarget / denominator) * target * sourceWeight;
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
    float2 proposalPdf;

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
    // At fixed x2 and outgoing direction, both routes share the x3 draw.
    // Its selected-lobe proposal compensation is folded into the incident.
    if (kind == uint(GrisTerminalKind::GrisDualSharcTail)) return 1.f;
#endif
#if RTPT_GRIS_DUAL_REGIR
    // The ReGIR draw is conditional on the shared receiver. Both routes
    // therefore use the same light proposal, including its inner RIS weight.
    if (kind == uint(GrisTerminalKind::GrisDualReGIRNee))
        return tail.suffixLight.z > 0.f && isfinite(tail.suffixLight.z) ? 1.f : 0.f;
#endif
    const float3 categories = rtptLightCategoryProbabilities();
#if USE_ENV_LIGHT
    if (kind == uint(GrisTerminalKind::GrisDualEnvironmentNee)) return categories.x;
#endif
#if USE_ANALYTIC_LIGHTS
    if (kind == uint(GrisTerminalKind::GrisDualPointNee) &&
        tail.lightPdfOrStableID < gScene.getLightCount())
        return categories.z / float(gScene.getLightCount());
#endif
#if USE_EMISSIVE_LIGHTS
    if (kind == uint(GrisTerminalKind::GrisDualEmissiveNee) &&
        categories.y > 0.f && tail.lightPdfOrStableID < gScene.lightCollection.getTriangleCount() &&
        gScene.lightCollection.getActiveTriangleIndex(tail.lightPdfOrStableID) != LightCollection::kInvalidIndex)
        return categories.y / float(gScene.lightCollection.getActiveTriangleCount());
#endif
    return 0.f;
}

float3 rtptGrisEvaluateDualLight(ShadingData surface, ShadingData visibilitySurface, IMaterialInstance material,
    GrisSpatialRecord tail, float lightProbability, inout SampleGenerator rng, bool previousLights,
    out bool shadowClear, uint movedBoundsCount = 0u)
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
        if (!query.traceVisibilityRay(shadow)) return 0.f;
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
#if RTPT_GRIS_DUAL_REGIR
    if (kind == uint(GrisTerminalKind::GrisDualReGIRNee))
    {
        RTPTLightSample light;
        if (!rtptReGIRRebuildTransportSample(surface, tail.lightPdfOrStableID, tail.suffixLight.xy,
            tail.suffixLight.z, light) || !query.traceVisibilityRay(light.visibilityRay)) return 0.f;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
        if (movedBoundsCount != 0u) shadowClear = rtptGrisReplayRayClear(light.visibilityRay, movedBoundsCount);
#endif
        // LiOverPdf already includes the inner weight. ReGIR owns the
        // covered NEE domain, with no competing ordinary BSDF light sample.
        return material.eval(surface, light.dir, rng) * light.LiOverPdf;
    }
#endif
#if USE_ANALYTIC_LIGHTS
    if (kind == uint(GrisTerminalKind::GrisDualPointNee))
    {
        const uint lightIndex = tail.lightPdfOrStableID;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY && !RTPT_GRIS_DUAL_REGIR
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
        if (!query.traceVisibilityRay(shadow)) return 0.f;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
        if (movedBoundsCount != 0u) shadowClear = rtptGrisReplayRayClear(shadow, movedBoundsCount);
#endif
        return material.eval(surface, sample.dir, rng) * sample.Li;
    }
#endif
#if USE_EMISSIVE_LIGHTS
    if (kind == uint(GrisTerminalKind::GrisDualEmissiveNee))
    {
        const uint lightIndex = tail.lightPdfOrStableID;
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
        if (!query.traceVisibilityRay(shadow)) return 0.f;
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

#if RTPT_GRIS_DUAL_SHARC
#if defined(RTPT_GRIS_TEMPORAL_REUSE)
ParameterBlock<SharcParameters> gGRISPreviousSharc;
#endif

GrisDualDeepIncident rtptGrisTraceDualSharc(GrisSpatialRecord tail, GrisDualReplayDomain domain)
{
    GrisDualDeepIncident result = {};
    if (!all(isfinite(tail.suffixDirection)) || !all(isfinite(tail.sharcDirection)) ||
        !(dot(tail.suffixDirection, tail.suffixDirection) > 0.f) ||
        !(dot(tail.sharcDirection, tail.sharcDirection) > 0.f) ||
        !all(isfinite(tail.suffixLight)) || !any(tail.suffixLight > 0.f)) return result;

    const TriangleHit reconnect = HitInfo(tail.reconnectHit).getTriangleHit();
    const VertexData x2 = rtptGrisPrefixVertex(reconnect);
    const Ray firstRay = Ray(computeRayOrigin(x2.posW, x2.faceNormalW), tail.suffixDirection);
    SceneRayQuery<true> query;
    float firstT;
    const HitInfo first = query.traceRay(firstRay, firstT);
    if (first.getType() != HitType::Triangle) return result;
    const TriangleHit x3 = first.getTriangleHit();
    ShadingData third = gScene.materials.prepareShadingData(gScene.getVertexData(x3),
        gScene.getMaterialID(x3.instanceID), -firstRay.dir);
    third.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance thirdMaterial = gScene.materials.getMaterialInstance(third, ExplicitLodTextureSampler(0.f));
    const float roughness = thirdMaterial.getProperties(third).roughness;
    const Ray secondRay = Ray(third.computeRayOrigin(), tail.sharcDirection);
    float secondT;
    const HitInfo second = query.traceRay(secondRay, secondT);
    if (second.getType() != HitType::Triangle) return result;
    const TriangleHit x4 = second.getTriangleHit();
    ShadingData fourth = gScene.materials.prepareShadingData(gScene.getVertexData(x4),
        gScene.getMaterialID(x4.instanceID), -secondRay.dir);
    fourth.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance fourthMaterial = gScene.materials.getMaterialInstance(fourth, ExplicitLodTextureSampler(0.f));
    const BSDFProperties fourthProperties = fourthMaterial.getProperties(fourth);
    const float distance = length(fourth.posW - third.posW);
    const RTPTSamplingContext sampling = rtptBSDFSamplingContext();
    RTPTSharcStats stats = {};
    float3 cached;
    if (rtptTrySharcQueryOnEdgeFrom(gSharc, fourth, fourthMaterial, fourthProperties, 4u, false, false,
        true, roughness, distance, sampling, secondRay.dir, stats, cached))
        result.current = tail.suffixLight * cached;
    result.previous = result.current;

#if defined(RTPT_GRIS_TEMPORAL_REUSE)
    result.previous = 0.f;
    bool compatibleGeometry = true;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (domain.previousGeometry)
    {
        compatibleGeometry = rtptGrisReplayStaticSurface(tail.reconnectHit) &&
            rtptGrisReplayStaticSurface(first.pack()) && rtptGrisReplayStaticSurface(second.pack()) &&
            rtptGrisReplayRayClear(Ray(firstRay.origin, firstRay.dir, firstRay.tMin, firstT), domain.movedBoundsCount) &&
            rtptGrisReplayRayClear(Ray(secondRay.origin, secondRay.dir, secondRay.tMin, secondT), domain.movedBoundsCount);
        // The stored x3 sample belongs to a static suffix. Changed vertices or
        // visibility leave both mappings unverified.
        if (!compatibleGeometry) result.current = 0.f;
    }
#endif
    if (compatibleGeometry && domain.previousSharcMode != 0u)
    {
        if (domain.previousSharcMode == 1u &&
            all(gGRISPreviousSharc.hashGridParameters.cameraPosition == gSharc.hashGridParameters.cameraPosition))
            result.previous = result.current;
        else if (rtptTrySharcQueryOnEdgeFrom(gGRISPreviousSharc, fourth, fourthMaterial, fourthProperties, 4u,
            false, false, true, roughness, distance, sampling, secondRay.dir, stats, cached))
            result.previous = tail.suffixLight * cached;
    }
#endif
    return result;
}
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
#if !RTPT_GRIS_DUAL_REGIR
    else if (evaluatePrevious && domain.previousLights &&
        rtptGrisTerminalKind(tail.candidate.terminalKind) == uint(GrisTerminalKind::GrisDualPointNee))
        result.previous = rtptGrisEvaluateDualDeep(tail, hit.getTriangleHit(), lightProbability, rng, shadowClear, true);
#endif
#endif
    return result;
}

#include "RTPTGRISDualExplicitReplay.slang"

float3 rtptGrisEvaluateDualRoute(PackedHitInfo primaryHit, ShadingData primary, float3 camera, GrisDualFirstHits hits, uint slot,
    GrisSpatialRecord tail, float3 x2, float lightProbability, inout SampleGenerator rng, out float proposal,
    bool nativeConnection, GrisDualReplayDomain domain, bool deep, float3 deepIncident, float deepLightPdf)
{
    proposal = 0.f;
    const float firstPdf = hits.firstHitAreaPdf[slot];
    if ((hits.attemptedMask & (1u << slot)) == 0u || !(firstPdf > 0.f) || !isfinite(firstPdf)) return 0.f;
    bool certifyPrevious = domain.previousGeometry && deep;
    bool certifyDirect = false;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY && RTPT_GRIS_DUAL_REGIR
    certifyDirect = domain.previousGeometry && !deep &&
        rtptGrisTerminalKind(tail.candidate.terminalKind) == uint(GrisTerminalKind::GrisDualReGIRNee);
    certifyPrevious = certifyPrevious || certifyDirect;
#endif
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY && USE_ENV_LIGHT
    certifyDirect = certifyDirect || (domain.previousGeometry && !deep &&
        rtptGrisTerminalKind(tail.candidate.terminalKind) == uint(GrisTerminalKind::GrisDualEnvironmentNee));
    certifyPrevious = certifyPrevious || certifyDirect;
#endif
    const bool rebuildPrevious = domain.previousGeometry && !certifyPrevious;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (certifyPrevious && (!rtptGrisReplayStaticSurface(hits.x1[slot]) ||
        !rtptGrisReplayStaticSurface(tail.reconnectHit))) return 0.f;
#endif

    const uint root = slot == 0u ? uint(GrisRootComponent::GrisDiffuse) : uint(GrisRootComponent::GrisSpecular);
    primary.mtl.setActiveLobes(rtptGrisRefRootMask(root));
    const IMaterialInstance rootMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float3 x1, firstDirection;
    float firstDistanceSquared;
    ShadingData first;
    if (!rtptGrisRefPosition(hits.x1[slot], x1, rebuildPrevious) ||
        !rtptGrisPrefixDirection(primary.computeRayOrigin(), x1, firstDirection, firstDistanceSquared) ||
        !rtptGrisRefLoad(hits.x1[slot], -firstDirection, first, rebuildPrevious)) return 0.f;
    const IMaterialInstance firstMaterial = gScene.materials.getMaterialInstance(first, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(first, firstMaterial.getLobeTypes(first))) return 0.f;

    float3 connectionDirection;
    float connectionDistanceSquared;
    ShadingData reconnect;
    if (!rtptGrisPrefixDirection(first.computeRayOrigin(), x2, connectionDirection, connectionDistanceSquared) ||
        !rtptGrisRefLoad(tail.reconnectHit, -connectionDirection, reconnect, rebuildPrevious)) return 0.f;
    const IMaterialInstance reconnectMaterial = gScene.materials.getMaterialInstance(reconnect, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(reconnect, reconnectMaterial.getLobeTypes(reconnect))) return 0.f;

    ShadingData visibilityFirst = first;
    ShadingData visibilityReconnect = reconnect;
    uint connectionBoundsCount = 0u;
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    if (certifyPrevious)
    {
        const Ray firstRay = Ray(primary.computeRayOrigin(), firstDirection, 0.f, sqrt(firstDistanceSquared));
        if (!rtptGrisReplayRayClear(firstRay, domain.movedBoundsCount)) return 0.f;
        connectionBoundsCount = domain.movedBoundsCount;
    }
    else if (rebuildPrevious)
    {
        // Evaluate historical scattering at the historical hits, with
        // visibility approximated using their current endpoints and TLAS.
        ShadingData visibilityPrimary;
        float3 currentX1, currentX2;
        if (!rtptGrisRefPrimary(primaryHit, camera, visibilityPrimary) ||
            !rtptGrisRefPosition(hits.x1[slot], currentX1) ||
            !rtptGrisRefPosition(tail.reconnectHit, currentX2) ||
            !rtptGrisRefLoad(hits.x1[slot], visibilityPrimary.posW - currentX1, visibilityFirst) ||
            !rtptGrisRefLoad(tail.reconnectHit, currentX1 - currentX2, visibilityReconnect) ||
            !rtptGrisRefVisible(visibilityPrimary, visibilityFirst)) return 0.f;
    }
#endif
    if (!nativeConnection && !rtptGrisRefVisible(visibilityFirst, visibilityReconnect, connectionBoundsCount)) return 0.f;

    const float connectionGeometry = abs(dot(reconnect.faceN, connectionDirection)) / connectionDistanceSquared;
    const float connectionPdf = firstMaterial.evalPdf(first, connectionDirection);
    if (!(connectionPdf > 0.f) || !isfinite(connectionPdf)) return 0.f;

    const float directionPdf = deep ?
        rtptContinuationPdf(reconnect, reconnectMaterial, rtptBSDFSamplingContext(), tail.suffixDirection) : 1.f;
    proposal = connectionPdf * connectionGeometry * directionPdf * lightProbability;
    if (!(proposal > 0.f) || !isfinite(proposal)) { proposal = 0.f; return 0.f; }

    const float rootGeometry = abs(dot(first.faceN, firstDirection)) / firstDistanceSquared;
    const float3 prefixValue = rootMaterial.eval(primary, firstDirection, rng) * (rootGeometry / firstPdf) *
        firstMaterial.eval(first, connectionDirection, rng) * connectionGeometry;
    float3 incident;
    bool shadowClear;
    if (deep)
    {
        const float mis = deepLightPdf > 0.f ? rtptPowerHeuristic(directionPdf, deepLightPdf) : 1.f;
        incident = reconnectMaterial.eval(reconnect, tail.suffixDirection, rng) * deepIncident * mis;
    }
    else incident = rtptGrisEvaluateDualLight(reconnect, visibilityReconnect, reconnectMaterial, tail,
        lightProbability, rng, domain.previousLights, shadowClear, certifyDirect ? connectionBoundsCount : 0u);
    if (certifyDirect && !shadowClear) return 0.f;
    const float3 value = prefixValue * incident;
    return all(isfinite(value)) ? value : 0.f;
}

GrisDualTailValue rtptGrisEvaluateDualTail(GrisSpatialRecord owner, GrisDualFirstHits hits,
    float3 camera, GrisSpatialRecord tail, float3 deepIncident, inout SampleGenerator rng,
    uint nativeSlot = 2u, GrisDualReplayDomain domain = {}, float deepLightPdf = 0.f)
{
    GrisDualTailValue result = {};
    ShadingData primary;
    float3 x2;
    const bool deep = rtptGrisIsDeepTail(tail);
    if (deep && (gParams.maxBounces < 3u || !all(isfinite(deepIncident)) || !any(deepIncident > 0.f))) return result;
    bool rebuildPrevious = domain.previousGeometry && !deep;
#if RTPT_GRIS_DUAL_REGIR
    if (rtptGrisTerminalKind(tail.candidate.terminalKind) == uint(GrisTerminalKind::GrisDualReGIRNee))
        rebuildPrevious = false;
#endif
#if USE_ENV_LIGHT
    if (rtptGrisTerminalKind(tail.candidate.terminalKind) == uint(GrisTerminalKind::GrisDualEnvironmentNee))
        rebuildPrevious = false;
#endif
    const float lightProbability = rtptGrisDualLightProbability(tail);
    if (!(lightProbability > 0.f) ||
        !rtptGrisRefPrimary(owner.ownerPrimaryHit, camera, primary, rebuildPrevious) ||
        !rtptGrisRefPosition(tail.reconnectHit, x2, rebuildPrevious)) return result;

    result.diffuse = rtptGrisEvaluateDualRoute(owner.ownerPrimaryHit, primary, camera, hits, 0u, tail, x2,
        lightProbability, rng, result.proposalPdf[0], nativeSlot == 0u, domain, deep, deepIncident, deepLightPdf);
    result.specular = rtptGrisEvaluateDualRoute(owner.ownerPrimaryHit, primary, camera, hits, 1u, tail, x2,
        lightProbability, rng, result.proposalPdf[1], nativeSlot == 1u, domain, deep, deepIncident, deepLightPdf);
    return result;
}

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
    return record.candidate.hasWinner &&
        (
#if RTPT_GRIS_DUAL_REGIR
            kind == uint(GrisTerminalKind::GrisDualReGIRNee) ||
#endif
#if RTPT_GRIS_DUAL_SHARC
            kind == uint(GrisTerminalKind::GrisDualSharcTail) ||
#endif
            kind == uint(GrisTerminalKind::GrisDualPointNee) || kind == uint(GrisTerminalKind::GrisDualEmissiveNee) ||
            kind == uint(GrisTerminalKind::GrisDualEnvironmentNee) || kind == uint(GrisTerminalKind::GrisDualEmitter) ||
            kind == uint(GrisTerminalKind::GrisDualEnvironmentMiss)) &&
        HitInfo(record.reconnectHit).getType() == HitType::Triangle;
}

void rtptGrisSelectDualTail(GrisSpatialRecord proposal, GrisDualTailValue value, float weight,
    inout SampleGenerator rng, inout float sum, inout GrisSpatialRecord winner, inout float winnerTarget)
{
    if (!(weight > 0.f) || !isfinite(weight)) return;
    sum += weight;
    if (sampleNext1D(rng) * sum < weight)
    {
        winner = proposal;
        winner.candidate.F = value.diffuse;
        winner.candidate.dualF = value.specular;
        winnerTarget = value.target();
    }
}

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

GrisSpatialRecord rtptGrisBuildDualFresh(GrisSpatialRecord center, GrisDualFirstHits firstHits,
    GrisSpatialRecord direct[2], GrisSpatialRecord deep[2], TriangleHit deepHits[2],
    GrisDualExplicitTerminal bsdfTerminals[2], GrisDualExplicitTerminal lateTerminals[2],
#if RTPT_GRIS_DUAL_SHARC
    GrisSpatialRecord cache[2],
    float3 cacheIncident[2],
#endif
    inout SampleGenerator rng)
{
    const float3 camera = gScene.camera.getPosition();
    GrisSpatialRecord winner = center;
    float sum = 0.f, winnerTarget = 0.f;
    uint eventCount = gParams.maxBounces > 3u ? 4u : 3u;
#if RTPT_GRIS_DUAL_SHARC
    if (gParams.maxBounces > 4u) eventCount = 5u;
#endif
    [loop] for (uint event = 0u; event < eventCount; ++event)
    {
        [unroll] for (uint slot = 0u; slot < 2u; ++slot)
        {
            GrisSpatialRecord proposal = event == 0u ? direct[slot] : deep[slot];
            if (event == 2u) proposal = bsdfTerminals[slot].proposal;
            if (event == 3u) proposal = lateTerminals[slot].proposal;
#if RTPT_GRIS_DUAL_SHARC
            if (event == 4u) proposal = cache[slot];
#endif
            if (!rtptGrisDualTailValid(proposal)) continue;
            const float lightProbability = rtptGrisDualLightProbability(proposal);
            float3 deepIncident = 0.f;
            float deepLightPdf = 0.f;
            bool shadowClear;
            if (event == 1u && lightProbability > 0.f)
                deepIncident = rtptGrisEvaluateDualDeep(proposal, deepHits[slot], lightProbability, rng, shadowClear);
            if (event == 2u)
            {
                deepIncident = bsdfTerminals[slot].incident;
                deepLightPdf = asfloat(proposal.lightPdfOrStableID);
            }
            if (event == 3u) deepIncident = lateTerminals[slot].incident;
#if RTPT_GRIS_DUAL_SHARC
            if (event == 4u) deepIncident = cacheIncident[slot];
#endif
            GrisDualTailValue value = rtptGrisEvaluateDualTail(center, firstHits, camera, proposal, deepIncident,
                rng, slot, {}, deepLightPdf);
            // The native density was captured at the draw (q2 or q2*qDir).
            value.proposalPdf[slot] = proposal.areaPdf * lightProbability;
            const float proposalSum = value.proposalPdf.x + value.proposalPdf.y;
            if (!(proposalSum > 0.f) || !isfinite(proposalSum)) continue;
            rtptGrisSelectDualTail(proposal, value, value.target() / proposalSum, rng, sum, winner, winnerTarget);
        }
    }
    // The summed proposal density already accounts for both strata.
    return rtptGrisFinalizeDualTail(center, winner, sum, winnerTarget, float(countbits(firstHits.attemptedMask)));
}

GrisSpatialRecord rtptGrisMergeDualTails(GrisSpatialRecord canonical, GrisDualFirstHits targetHits,
    GrisSpatialRecord inputs[kGrisMaxReuseInputs], GrisDualFirstHits sourceHits[kGrisMaxReuseInputs],
    float3 sourceCameras[kGrisMaxReuseInputs], uint inputCount, inout SampleGenerator rng
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
    , bool previousLights, bool previousGeometry, uint movedBoundsCount
#endif
#if RTPT_GRIS_DUAL_SHARC && defined(RTPT_GRIS_TEMPORAL_REUSE)
    , uint previousSharcMode
#endif
    )
{
    if (!rtptGrisRefDomainValid(canonical) || inputCount == 0u) return canonical;
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
    GrisSpatialRecord winner = canonical;
    float sum = 0.f, winnerTarget = 0.f, count = canonical.candidate.M;
    bool accepted[kGrisMaxReuseInputs];
    [loop] for (uint j = 0u; j < inputCount; ++j)
    {
        accepted[j] = rtptGrisRefDomainValid(inputs[j]);
#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
        if (previousGeometry && (!rtptGrisReplayStaticSurface(canonical.ownerPrimaryHit) ||
            !rtptGrisReplayStaticSurface(inputs[j].ownerPrimaryHit))) accepted[j] = false;
#endif
        if (accepted[j]) count += inputs[j].candidate.M;
    }

    [loop] for (uint i = 0u; i <= inputCount; ++i)
    {
        const bool center = i == inputCount;
        GrisSpatialRecord proposal = canonical;
        if (!center)
        {
            if (!accepted[i]) continue;
            proposal = inputs[i];
        }
        if (!rtptGrisDualTailValid(proposal) || !(proposal.candidate.W > 0.f)) continue;
        const bool deep = rtptGrisIsDeepTail(proposal);
        GrisDualDeepIncident deepIncident = {};
#if RTPT_GRIS_DUAL_SHARC
        const bool sharc = rtptGrisTerminalKind(proposal.candidate.terminalKind) == uint(GrisTerminalKind::GrisDualSharcTail);
        if (sharc) deepIncident = rtptGrisTraceDualSharc(proposal, sourceDomain);
        else
#endif
        if (proposal.dualExplicitBounce != 0u) deepIncident = rtptGrisTraceDualExplicit(proposal, rng, sourceDomain);
        else if (deep) deepIncident = rtptGrisTraceDualDeep(proposal, rng, sourceDomain, center || sourceDomain.previousGeometry);
        const GrisDualTailValue targetValue = center ? rtptGrisNativeDualTail(proposal) :
            rtptGrisEvaluateDualTail(canonical, targetHits, camera, proposal, deepIncident.current, rng,
                2u, {}, deepIncident.lightPdf);
        const float target = targetValue.target();
        if (!(target > 0.f)) continue;

        float denominator = target;
        float sourceTarget = center ? target : 0.f;
        [loop] for (uint j = 0u; j < inputCount; ++j)
        {
            // Domain support is independent of its realized winning sample.
            if (!accepted[j]) continue;
            // On motion, apply the same old-domain visibility rule to both
            // directions of MIS, including the old domain's own winner.
            bool useNative = !center && j == i && !sourceDomain.previousGeometry;
#if RTPT_GRIS_DUAL_SHARC && defined(RTPT_GRIS_TEMPORAL_REUSE)
            if (sharc && sourceDomain.previousSharcMode == 0u) useNative = false;
#endif
            const float cross = useNative ? rtptGrisNativeDualTail(proposal).target() :
                rtptGrisEvaluateDualTail(inputs[j], sourceHits[j], sourceCameras[j], proposal, deepIncident.previous,
                    rng, 2u, sourceDomain, deepIncident.lightPdf).target();
            denominator += cross;
            if (!center && j == i) sourceTarget = cross;
        }
        const float weight = target * (sourceTarget / denominator) * proposal.candidate.W;
        rtptGrisSelectDualTail(proposal, targetValue, weight, rng, sum, winner, winnerTarget);
    }
    return rtptGrisFinalizeDualTail(canonical, winner, sum, winnerTarget, count);
}
#endif

#endif
