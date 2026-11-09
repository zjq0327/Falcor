#pragma once

#include "RTPTGRISTypes.slang"
#include "RTPTGRISSupport.slang"

#ifndef RTPT_GRIS_REFERENCE_REUSE
#define RTPT_GRIS_REFERENCE_REUSE 1
#endif

// Fixed-x2 reference implementation. The auxiliary prefix exchange is performed
// in a common surface-prefix/reference-tail domain, not with the legacy sum of
// connection-area PDFs. RR must be disabled, and proposals from x2 onward
// must be BSDF-only. The configured primary diffuse edge may use PG; the
// actual proposal densities are captured in R. Cell-only ReGIR paths flatten
// their inner sampling factor at the fixed x2/tail. Legacy ReGIR reconstruction
// and legacy cache terminals remain outside this explicit-path domain.
//
// areaPdf stores R = Q_owner / sigma_reference after NormalizeGenerated().
// The public record keeps the established MC convention: F_nu=F*R, W_nu=W/R.
// sigma_reference uses a fixed sphere density at x2 and the shared sampling
// factors after x2. Thus R only needs two prefix-area factors and one local ratio.
// History may span ordinary root-PG publications: retain each record's stored R
// and W. Cross evaluation and auxiliary densities never query the current guide.
// A GrisSharcTail retains its generation-time incident factor in suffixLight.
// Prefix/x2 factors are reevaluated, but the tail is never retraced or queried.
// This intentionally mixes historical cache estimates; it does not refresh
// old samples to, or promise unbiasedness for, the current SHaRC field.

#if RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)

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

bool rtptGrisRefVisible(ShadingData from, ShadingData to)
{
    const float3 origin = from.computeRayOrigin();
    const float3 displacement = to.computeRayOrigin() - origin;
    const float distanceSquared = dot(displacement, displacement);
    if (!(distanceSquared > 0.f) || !isfinite(distanceSquared)) return false;
    const float distance = sqrt(distanceSquared);
    SceneRayQuery<true> query;
    return query.traceVisibilityRay(Ray(origin, displacement / distance, 0.f, distance));
}

// Prefix proposal r: an explicitly selected root label followed by a uniform
// sphere direction and its first intersection. Using the sphere gives support
// even when a normal-mapped material's reflection hemisphere differs from the
// geometric/shading frame. Misses remain valid auxiliary states conceptually;
// no legal incoming path has such an x1, so all inverse neighbor terms are zero.
GrisReferencePrefix rtptGrisRefDrawPrefix(PackedHitInfo primaryHit, float3 cameraPosition, inout SampleGenerator rng)
{
    GrisReferencePrefix result = {};
    result.x1 = makeInvalidHit().pack();
    ShadingData primary;
    if (!rtptGrisRefPrimary(primaryHit, cameraPosition, primary)) return result;
    const float diffuseProbability = rtptGrisRefRootProbability(primary, uint(GrisRootComponent::GrisDiffuse));
    const float specularProbability = rtptGrisRefRootProbability(primary, uint(GrisRootComponent::GrisSpecular));
    if (!(diffuseProbability + specularProbability > 0.f)) return result;
    const float rootDraw = sampleNext1D(rng);
    result.rootLobe = rootDraw < diffuseProbability ? uint(GrisRootComponent::GrisDiffuse) : uint(GrisRootComponent::GrisSpecular);
    const float2 u = sampleNext2D(rng);
    const float z = 1.f - 2.f * u.x;
    const float radial = sqrt(max(0.f, 1.f - z * z));
    const float phi = 6.28318530717958648f * u.y;
    const float3 direction = float3(radial * cos(phi), radial * sin(phi), z);
    SceneRayQuery<true> query;
    float hitT;
    const HitInfo hit = query.traceRay(Ray(primary.computeRayOrigin(), direction), hitT);
    if (hit.getType() == HitType::Triangle)
    {
        result.x1 = hit.pack();
        result.valid = true;
    }
    return result;
}

GrisReferencePrefix rtptGrisRefRecordPrefix(GrisSpatialRecord record)
{
    GrisReferencePrefix result = {};
    result.x1 = record.sourceX1;
    result.rootLobe = record.candidate.rootLobe;
    result.valid = HitInfo(result.x1).getType() == HitType::Triangle;
    return result;
}

float rtptGrisRefPrefixPdf(PackedHitInfo primaryHit, float3 cameraPosition, GrisReferencePrefix prefix)
{
    if (!prefix.valid) return 0.f;
    ShadingData primary;
    float3 position;
    if (!rtptGrisRefPrimary(primaryHit, cameraPosition, primary) || !rtptGrisRefPosition(prefix.x1, position)) return 0.f;
    const float rootProbability = rtptGrisRefRootProbability(primary, prefix.rootLobe);
    if (!(rootProbability > 0.f)) return 0.f;
    const float3 edge = position - primary.computeRayOrigin();
    const float distanceSquared = dot(edge, edge);
    if (!(distanceSquared > 0.f) || !isfinite(distanceSquared)) return 0.f;
    const float3 direction = edge * rsqrt(distanceSquared);
    ShadingData first;
    if (!rtptGrisRefLoad(prefix.x1, -direction, first) || !rtptGrisRefVisible(primary, first)) return 0.f;
    const float geometry = abs(dot(first.faceN, direction)) / distanceSquared;
    const float pdf = rootProbability * kGrisReferenceDirectionPdf * geometry;
    return pdf > 0.f && isfinite(pdf) ? pdf : 0.f;
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

// Evaluate one complete path in the reference-tail domain for any source/target
// owner. All interface BSDFs, both prefix edges and their visibility are reevaluated.
// The returned ratio is a BSDF-only owner representation, not an additional
// importance correction. The actual root-PG ratio is captured at generation.
float3 rtptGrisRefEvaluate(PackedHitInfo primaryHit, float3 cameraPosition,
    GrisReferencePrefix prefix, GrisSpatialRecord tail, inout SampleGenerator rng,
    out float ownerRatio, out float firstDistance)
{
    ownerRatio = 0.f;
    firstDistance = kRTPTNRDMissDistance;
    if (!prefix.valid || !rtptGrisRefKindSupported(tail)) return 0.f;
    ShadingData primary;
    float3 x1Position, x2Position;
    if (!rtptGrisRefPrimary(primaryHit, cameraPosition, primary) ||
        !rtptGrisRefPosition(prefix.x1, x1Position) || !rtptGrisRefPosition(tail.reconnectHit, x2Position)) return 0.f;
    const float rootProbability = rtptGrisRefRootProbability(primary, prefix.rootLobe);
    if (!(rootProbability > 0.f)) return 0.f;
    primary.mtl.setActiveLobes(rtptGrisRefRootMask(prefix.rootLobe));
    const IMaterialInstance rootMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float3 firstDirection;
    float rootDistanceSquared;
    if (!rtptGrisPrefixDirection(primary.computeRayOrigin(), x1Position, firstDirection, rootDistanceSquared)) return 0.f;
    firstDistance = sqrt(rootDistanceSquared);
    ShadingData first;
    if (!rtptGrisRefLoad(prefix.x1, -firstDirection, first)) return 0.f;
    const IMaterialInstance firstMaterial = gScene.materials.getMaterialInstance(first, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(first, firstMaterial.getLobeTypes(first))) return 0.f;
    const float rootGeometry = abs(dot(first.faceN, firstDirection)) / rootDistanceSquared;
    float3 connectionDirection;
    float connectionDistanceSquared;
    if (!rtptGrisPrefixDirection(first.computeRayOrigin(), x2Position, connectionDirection, connectionDistanceSquared)) return 0.f;
    ShadingData reconnect;
    if (!rtptGrisRefLoad(tail.reconnectHit, -connectionDirection, reconnect)) return 0.f;
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
    // spuriously self-occlude. Only a different owner/prefix needs new tests.
    const bool nativePrefix = all(primaryHit == tail.ownerPrimaryHit) &&
        all(prefix.x1 == tail.sourceX1);
    if (!nativePrefix && (!rtptGrisRefVisible(primary, first) || !rtptGrisRefVisible(first, reconnect))) return 0.f;
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

// An inverse query that is exactly the stored native sample already has its
// source function value. Use it consistently for own and duplicate inputs;
// other prefixes/tails still require the full physical cross evaluation.
float3 rtptGrisRefEvaluateSource(GrisSpatialRecord source, float3 cameraPosition,
    GrisReferencePrefix prefix, GrisSpatialRecord tail, uint sourceLightEpoch, inout SampleGenerator rng)
{
    // Gate the evaluated tail's light, not the source reservoir's realized
    // winner. This also removes old-history density from a new light's fresh
    // MIS denominator. An ineligible source still retains its domain and M.
    if (!rtptGrisSourceAllowsTail(tail, sourceLightEpoch)) return 0.f;
    const bool sameSample = rtptGrisRefSampleValid(source) && prefix.valid &&
        prefix.rootLobe == source.candidate.rootLobe && all(prefix.x1 == source.sourceX1) &&
        all(tail.reconnectHit == source.reconnectHit) &&
        all(asuint(tail.suffixDirection) == asuint(source.suffixDirection)) &&
        all(asuint(tail.suffixLight) == asuint(source.suffixLight)) &&
        tail.candidate.terminalKind == source.candidate.terminalKind &&
        tail.lightPdfOrStableID == source.lightPdfOrStableID && tail.lightIsAnalytic == source.lightIsAnalytic;
    if (sameSample) return source.candidate.F * source.areaPdf;
    float ignoredRatio, ignoredDistance;
    return rtptGrisRefEvaluate(source.ownerPrimaryHit, cameraPosition, prefix, tail, rng, ignoredRatio, ignoredDistance);
}

GrisSpatialRecord rtptGrisMergeReference(GrisSpatialRecord canonical, GrisSpatialRecord inputs[2],
    float3 sourceCameras[2], uint sourceLightEpochs[2], uint inputCount, uint2 pixel, inout SampleGenerator rng)
{
#if !RTPT_GRIS_REFERENCE_REUSE
    return canonical;
#else
    // Unsupported/numerically unrepresentable canonical records retain their
    // complete local estimate. They do not enter a mismatched resampling domain.
    if (gParams.useRussianRoulette != 0u || !rtptGrisRefDomainValid(canonical) ||
        (canonical.candidate.hasWinner && !rtptGrisRefSampleValid(canonical))) return canonical;
    inputCount = min(inputCount, 2u);
    if (inputCount == 0u) return canonical;
    const float3 targetCamera = gScene.camera.getPosition();
    bool domainValid[2];
    bool anyInputDomain = false;
    float totalM = canonical.candidate.M;
    [unroll] for (uint j = 0u; j < 2u; ++j)
    {
        domainValid[j] = j < inputCount && rtptGrisRefDomainValid(inputs[j]) &&
            (!inputs[j].candidate.hasWinner || rtptGrisRefSampleValid(inputs[j]));
        if (domainValid[j]) totalM += inputs[j].candidate.M;
        anyInputDomain = anyInputDomain || domainValid[j];
    }
    if (!anyInputDomain) return canonical;
    // Two independent auxiliary probes. Sharing B between neighbor candidates
    // is allowed; neither probe reuses the canonical path's random prefix.
    const GrisReferencePrefix auxiliary = rtptGrisRefDrawPrefix(canonical.ownerPrimaryHit, targetCamera, rng);
    const GrisReferencePrefix active = rtptGrisRefDrawPrefix(canonical.ownerPrimaryHit, targetCamera, rng);
    const float auxiliaryPdf = rtptGrisRefPrefixPdf(canonical.ownerPrimaryHit, targetCamera, auxiliary);
    const float activePdf = rtptGrisRefPrefixPdf(canonical.ownerPrimaryHit, targetCamera, active);
    GrisSpatialRecord winner = canonical;
    float3 winnerReferenceF = 0.f;
    float winnerRatio = 0.f;
    float weightSum = 0.f;
    if (rtptGrisRefSampleValid(canonical))
    {
        const float3 value = canonical.candidate.F * canonical.areaPdf;
        const float h = rtptGrisRefTarget(value);
        float mis = 1.f;
        if (auxiliaryPdf > 0.f)
        {
            const float canonicalDensity = canonical.candidate.M * h * auxiliaryPdf;
            float denominator = canonicalDensity;
            const float canonicalPrefixPdf = rtptGrisRefPrefixPdf(canonical.ownerPrimaryHit, targetCamera, rtptGrisRefRecordPrefix(canonical));
            [unroll] for (uint j = 0u; j < 2u; ++j)
            {
                if (!domainValid[j]) continue;
                const float3 cross = rtptGrisRefEvaluateSource(inputs[j], sourceCameras[j], auxiliary, canonical,
                    sourceLightEpochs[j], rng);
                denominator += inputs[j].candidate.M * rtptGrisRefTarget(cross) * canonicalPrefixPdf;
            }
            mis = denominator > 0.f ? canonicalDensity / denominator : 0.f;
        }
        // h(C*R)*(W/R) == h(C)*W; use the cancellation for the native draw.
        const float weight = mis * rtptGrisRefTarget(canonical.candidate.F) * canonical.candidate.W;
        if (weight > 0.f && isfinite(weight))
        {
            weightSum = weight;
            winnerReferenceF = value;
            winnerRatio = canonical.areaPdf;
        }
    }
    [unroll] for (uint i = 0u; i < 2u; ++i)
    {
        if (!domainValid[i] || !rtptGrisRefSampleValid(inputs[i]) ||
            !rtptGrisSourceAllowsTail(inputs[i], sourceLightEpochs[i]) || !(activePdf > 0.f)) continue;
        const GrisReferencePrefix sourcePrefix = rtptGrisRefRecordPrefix(inputs[i]);
        const float sourceAuxiliaryPdf = rtptGrisRefPrefixPdf(canonical.ownerPrimaryHit, targetCamera, sourcePrefix);
        if (!(sourceAuxiliaryPdf > 0.f)) continue;
        float ratio, firstDistance;
        const float3 value = rtptGrisRefEvaluate(canonical.ownerPrimaryHit, targetCamera, active, inputs[i], rng, ratio, firstDistance);
        const float h = rtptGrisRefTarget(value);
        if (!(h > 0.f) || !(ratio > 0.f)) continue;
        float denominator = canonical.candidate.M * h * sourceAuxiliaryPdf;
        float ownDensity = 0.f;
        [unroll] for (uint j = 0u; j < 2u; ++j)
        {
            if (!domainValid[j]) continue;
            const float3 cross = rtptGrisRefEvaluateSource(inputs[j], sourceCameras[j], sourcePrefix, inputs[i],
                sourceLightEpochs[j], rng);
            const float density = inputs[j].candidate.M * rtptGrisRefTarget(cross) * activePdf;
            denominator += density;
            if (j == i) ownDensity = density;
        }
        if (!(denominator > 0.f) || !(ownDensity > 0.f)) continue;
        const float mis = ownDensity / denominator;
        const float weight = mis * h * (inputs[i].candidate.W / inputs[i].areaPdf) * sourceAuxiliaryPdf / activePdf;
        if (!(weight > 0.f) || !isfinite(weight)) continue;
        weightSum += weight;
        if (!isfinite(weightSum)) return canonical;
        if (sampleNext1D(rng) * weightSum <= weight)
        {
            winner = inputs[i];
            winner.ownerPrimaryHit = canonical.ownerPrimaryHit;
            winner.sourceX1 = active.x1;
            winner.candidate.rootLobe = active.rootLobe;
            winner.candidate.firstHit.hitT = min(kRTPTNRDMissDistance, max(1e-5f, firstDistance));
            winner.candidate.firstHit.distanceState = kRTPTDistanceHit;
            winnerReferenceF = value;
            winnerRatio = ratio;
        }
    }
    GrisSpatialRecord result = canonical;
    result.candidate.M = totalM;
    if (!(weightSum > 0.f) || !(winnerRatio > 0.f))
    {
        result.candidate.F = 0.f;
        result.candidate.W = 0.f;
        result.candidate.hasWinner = false;
        return result;
    }
    const float h = rtptGrisRefTarget(winnerReferenceF);
    const float W = winnerRatio * weightSum / h;
    const float3 F = winnerReferenceF / winnerRatio;
    if (!(h > 0.f) || !(W > 0.f) || !isfinite(W) || !all(isfinite(F * W))) return canonical;
    result = winner;
    result.ownerPrimaryHit = canonical.ownerPrimaryHit;
    result.areaPdf = winnerRatio;
    result.candidate.F = F;
    result.candidate.W = W;
    result.candidate.M = totalM;
    result.candidate.prepared = true;
    result.candidate.hasWinner = true;
    return result;
#endif
}

#endif
