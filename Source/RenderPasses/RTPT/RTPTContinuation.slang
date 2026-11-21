#pragma once

#include "RTPTFirstHit.slangh"

#ifndef RTPT_GRIS_DUAL_FIRST_HIT
#define RTPT_GRIS_DUAL_FIRST_HIT 0
#endif

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

#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
#include "GRIS/RTPTGRISReference.slang"

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
struct GrisNativeFreshPrefix
{
    GrisDualTailValue root;
    float firstGeometry;
    float3 connection;
    float3 outgoingBsdf;
    float outgoingPdf;
};

bool rtptGrisOfferNativeFreshEvent(GrisNativeFreshPrefix prefix, uint event, float proposalPdf,
    float3 incident, float lightPdf, bool deltaRoot, inout GrisFreshSlotReservoir reservoir,
    inout SampleGenerator selectionRng)
{
    if (!(proposalPdf > 0.f) || !isfinite(proposalPdf) || !(prefix.firstGeometry > 0.f)) return false;
    const bool deep = event != kGrisFixedX1NeeEvent && event != kGrisFreshX2NeeEvent;
    const float3 deepIncident = deep ? incident : float3(0.f);
    if (deep)
    {
        if (!(prefix.outgoingPdf > 0.f) || !all(isfinite(incident)) || !any(incident > 0.f)) return false;
        const float mis = lightPdf > 0.f ? rtptPowerHeuristic(prefix.outgoingPdf, lightPdf) : 1.f;
        incident = prefix.outgoingBsdf * incident * mis;
    }

    if (event != kGrisFixedX1NeeEvent) incident *= prefix.connection;
    GrisDualTailValue value = {};
    if (deltaRoot)
    {
        const float3 specular = prefix.root.specular * incident;
        if (all(isfinite(specular))) value.specular = specular;
    }
    else
    {
        const float3 common = incident * prefix.firstGeometry;
        if (!all(isfinite(common)) || !any(common > 0.f)) return false;
        const float3 diffuse = prefix.root.diffuse * common;
        const float3 specular = prefix.root.specular * common;
        if (all(isfinite(diffuse))) value.diffuse = diffuse;
        if (all(isfinite(specular))) value.specular = specular;
    }
    return rtptGrisOfferFreshCandidate(reservoir, event, value, proposalPdf, deepIncident, lightPdf, selectionRng);
}

void rtptGrisOfferNativeExplicitEvent(GrisNativeFreshPrefix prefix, uint event, float proposalPdf,
    float3 incident, float lightPdf, bool deltaRoot, inout GrisFreshSlotReservoir reservoir,
    inout SampleGenerator selectionRng, GrisDualNeeTerminal light, uint kind, uint bounce,
    uint lightPdfOrIndex, inout GrisDualExplicitTerminal terminal)
{
    if (rtptGrisOfferNativeFreshEvent(prefix, event, proposalPdf, incident, lightPdf, deltaRoot, reservoir, selectionRng))
    {
        terminal.suffixLight = light.coordinates;
        terminal.terminalKind = kind | kGrisDeepTail;
        terminal.bounce = bounce;
        terminal.lightPdfOrIndex = lightPdfOrIndex;
        terminal.lightIsAnalytic = light.lightIsAnalytic;
    }
}

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
#if RTPT_GRIS_DUAL_FIRST_HIT && !RTPT_GRIS_ALTERNATING
    , inout GrisDualX2Sample x2
    , out GrisDualExplicitTerminal explicitWinner
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    , uint freshSlot
    , uint freshAttemptedMask
    , bool separateFreshRootMeasures
    , RTPTSamplingContext freshDiffuseSampling
    , inout GrisFreshSlotReservoir freshReservoir
    , inout SampleGenerator freshEvaluationRng
    , inout SampleGenerator freshSelectionRng
#endif
#if RTPT_GRIS_DUAL_SHARC
    , inout GrisSpatialRecord cacheSuffix
#endif
#else
    , inout GrisSpatialRecord suffix
#endif
#if !RTPT_GRIS_ALTERNATING && !RTPT_GRIS_DUAL_FIRST_HIT
    , inout GrisPathBuilder pathBuilder
    , inout SampleGenerator terminalRng
#endif
#if RTPT_GRIS_ALTERNATING
    , bool generateSuffix
#ifdef RTPT_GRIS_SHARC_X1_BLEND
    , out bool mixedX1Cache
#endif
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
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
    const uint currentRoot = prefix.rootLobe;
#if RTPT_GRIS_DUAL_FIRST_HIT
    explicitWinner = {};
    x2.rootDirection = 0.f;
    x2.firstNee = {};
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    GrisNativeFreshPrefix nativeFresh = {};
    float freshRootPdf = 0.f;
#endif
#if defined(RTPT_GRIS_DUAL_EXPLICIT_LOCAL_CONTROL)
    const bool captureExplicit = false;
#else
    const bool captureExplicit = true;
#endif
#else
    rtptGRISBeginWalk(pathBuilder);
#endif
#endif
#ifdef RTPT_GRIS_SHARC_X1_BLEND
    mixedX1Cache = false;
    float3 x1CacheContribution = 0.f;
#endif
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
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
    const uint rootLobes = primaryMI.getLobeTypes(primarySD);
    const bool deltaPrefix =
#ifdef RTPT_GRIS_DELTA_REUSE
        primaryLobes == uint(LobeType::DeltaReflection) && previousDelta &&
        rtptGrisSupportsDeltaRoot(primarySD, rootLobes);
#else
        false;
#endif
    bool representedPrefix = rtptGRISPathReuseEnabled() && (deltaPrefix ||
        (!previousDelta && rtptGRISSupportsSurface(primarySD, rootLobes & primaryLobes)));
#if RTPT_GRIS_DUAL_FIRST_HIT
    x2.rootDirection = bs.wo;
#endif
    ShadingData prefixFrom = primarySD;
    float3 segmentThroughput = float3(1.f / rootProbability);
#endif
#if !(RTPT_GRIS_GENERATE && RTPT_GRIS_ALTERNATING)
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL
    if (!representedPrefix && !any(throughput > 0.f)) return float3(0.f);
#else
    if (!any(throughput > 0.f)) return float3(0.f);
#endif
#endif
    float3 radiance = 0.f;
    float3 previousPosition = primarySD.posW;
    float3 previousNormal = primarySD.getOrientedFaceNormal();
    float previousContinuationPdf = bs.pdf;
    bool previousUsedNEE = gParams.useNEE != 0 && !previousDelta;
#if ENABLE_SHARC && SHARC_QUERY
    bool previousDiffuse = !previousGuideSelected && bs.isLobe(LobeType::DiffuseReflection);
    float previousRoughness = primaryMI.getProperties(primarySD).roughness;
#if RTPT_GRIS_GENERATE
#if RTPT_GRIS_DUAL_SHARC
    // Dual Generate first probes at x3. Only the primary edge can sample the guide.
    const RTPTSamplingContext previousSharcSampling = rtptBSDFSamplingContext();
#else
    RTPTSamplingContext previousSharcSampling = primaryLobes == uint(LobeType::DiffuseReflection)
        ? primarySampling : rtptBSDFSamplingContext();
#endif
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
#if RTPT_USE_RESTIR_DI
            const float lightPdf = previousUsedNEE && !previousDelta
                ? (bounce == 1u ? rtptEnvironmentLightPdfForCoverage(ray.dir, rootCoverage) : rtptEnvironmentLightPdf(ray.dir)) : 0.f;
            const float misWeight = previousUsedNEE && !previousDelta ? rtptPowerHeuristic(previousContinuationPdf, lightPdf) : 1.f;
#else
            const float lightPdf = previousUsedNEE && !previousDelta ? rtptEnvironmentLightPdf(ray.dir) : 0.f;
            const float misWeight = previousUsedNEE && !previousDelta ? rtptPowerHeuristic(previousContinuationPdf, lightPdf) : 1.f;
#endif
            const float3 environment = gScene.envMap.eval(ray.dir);
            const float3 contribution = throughput * environment * misWeight;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
            if (captureExplicit && bounce >= 3u && x2.deepPdf > 0.f)
            {
                if (bounce == 3u)
                {
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
                    rtptGrisOfferNativeExplicitEvent(nativeFresh, kGrisFreshX3BsdfEvent, freshRootPdf * x2.deepPdf,
                        environment, lightPdf, deltaPrefix, freshReservoir, freshSelectionRng,
                        x2.deepLight, uint(GrisTerminalKind::GrisDualEnvironmentMiss), bounce, asuint(lightPdf), explicitWinner);
#endif
                }
                else
                {
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
                    const float3 incident = segmentThroughput * environment * misWeight;
                    rtptGrisOfferNativeExplicitEvent(nativeFresh, kGrisFreshLateEvent, freshRootPdf * x2.deepPdf,
                        incident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng,
                        x2.deepLight, uint(GrisTerminalKind::GrisDualEnvironmentMiss), bounce, 0u, explicitWinner);
#endif
                }
                break;
            }
#endif
            if (all(isfinite(contribution)))
            {
#if RTPT_GRIS_GENERATE && !RTPT_GRIS_SPATIAL
                rtptSelectGrisTerminal(terminalPicker, terminalRng, contribution, GrisTerminalKind::GrisEnvironment);
#endif
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && !RTPT_GRIS_DUAL_FIRST_HIT
                if (pathBuilder.hasTail)
                {
                    const bool deepTail = bounce > 3u;
                    const float3 incident = deepTail ? pathBuilder.tailThroughput * environment * misWeight : environment;
                    rtptGRISAddPathTerminal(pathBuilder, terminalRng, currentRoot, prefix.x1Hit,
                        contribution, uint(GrisTerminalKind::GrisEnvironment),
                        deepTail, pathBuilder.rcWi, incident, lightPdf, false, bounce, suffix);
                }
                else radiance += contribution;
#else
                radiance += contribution;
#endif
            }
#endif
            break;
        }
        if (hit.getType() != HitType::Triangle) break;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const TriangleHit triangleHit = hit.getTriangleHit();
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
        const bool rebuildPrefix = representedPrefix && bounce <= 2u;
        VertexData vertex;
        if (rebuildPrefix) vertex = rtptGrisPrefixVertex(triangleHit);
        else vertex = gScene.getVertexData(triangleHit);
#else
        VertexData vertex = gScene.getVertexData(triangleHit);
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
        if (representedPrefix && bounce <= 2u) vertex = rtptGrisPrefixVertex(triangleHit);
#endif
#endif
        if (bounce == 1)
            firstHitDistance = min(kRTPTNRDMissDistance, max(1e-5f, length(vertex.posW - primarySD.posW)));
#if RTPT_GRIS_GENERATE && RTPT_GRIS_ALTERNATING
        if (!any(throughput > 0.f)) break;
#endif
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
        ShadingData sd = {};
        bool canonicalHit = false;
        const bool deltaX1 = deltaPrefix && bounce == 1u;
        float3 direction;
        float distanceSquared;
        if (rebuildPrefix)
        {
            // The triangle was decoded from hit.pack() already. Reuse its
            // canonical attributes while shading the reconstructed view.
            if (deltaX1)
            {
                prefix.dualX1 = hit.pack();
                // Discrete probability mass of the restricted mirror root.
                prefix.dualFirstPdf = 1.f;
                prefix.throughputToX1 = throughput;
                canonicalHit = rtptGrisRefLoad(vertex, materialID, -ray.dir, sd);
            }
            else
            {
                canonicalHit = rtptGrisPrefixDirection(ray.origin, vertex.posW, direction, distanceSquared) &&
                    rtptGrisRefLoad(vertex, materialID, -direction, sd);
                // Keep the actual draw even if this walk cannot represent its second edge.
                if (canonicalHit && bounce == 1u)
                {
                    const float firstPdf = rtptGRISAreaPdf(sd, ray, previousContinuationPdf);
                    if (firstPdf > 0.f && isfinite(firstPdf))
                    {
                        prefix.dualX1 = hit.pack();
                        prefix.dualFirstPdf = firstPdf;
                    }
                }
            }
        }
        if (!canonicalHit)
        {
            sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
            sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        }
        IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        if (rebuildPrefix)
        {
            representedPrefix = canonicalHit && rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd));
            if (representedPrefix && !deltaX1)
            {
                // Retain q from the actual draw, including its guide leaf.
                const IMaterialInstance fromMI = gScene.materials.getMaterialInstance(prefixFrom, ExplicitLodTextureSampler(0.f));
                const float3 edgeValue = fromMI.eval(prefixFrom, direction, sg);
                if (bounce == 2u)
                {
                    const float geometry = abs(dot(sd.faceN, direction)) / distanceSquared;
                    const float pdf = fromMI.evalPdf(prefixFrom, direction);
                    if (geometry > 0.f && isfinite(geometry) && pdf > 0.f && isfinite(pdf))
                        nativeFresh.connection = edgeValue * geometry;
                }
                throughput = segmentThroughput * edgeValue / previousContinuationPdf;
            }
            else if (canonicalHit && !representedPrefix)
            {
                sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
                sd.mtl.setActiveLobes(uint(LobeType::Reflection));
                mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
            }
        }
#else
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
        if (representedPrefix && bounce <= 2u)
        {
            float3 direction;
            float distanceSquared;
            ShadingData represented;
            if (rtptGrisPrefixDirection(ray.origin, vertex.posW, direction, distanceSquared) &&
                rtptGrisRefLoad(hit.pack(), -direction, represented))
            {
                const IMaterialInstance representedMI = gScene.materials.getMaterialInstance(represented, ExplicitLodTextureSampler(0.f));
                if (rtptGRISSupportsSurface(represented, representedMI.getLobeTypes(represented)))
                {
                    // Evaluate before emission, NEE and terminal selection.
                    // Retain q from the real draw, including its guide leaf;
                    // never ask the guide to evaluate the reconstructed ray.
                    const IMaterialInstance fromMI = gScene.materials.getMaterialInstance(prefixFrom, ExplicitLodTextureSampler(0.f));
                    const float3 edgeValue = fromMI.eval(prefixFrom, direction, sg);
                    throughput = segmentThroughput * edgeValue / previousContinuationPdf;
                    sd = represented;
                }
                else representedPrefix = false;
            }
            else representedPrefix = false;
        }
#endif
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
#endif
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
        if (bounce == 1u && representedPrefix && freshAttemptedMask != 0u)
        {
            freshRootPdf = rtptGrisFreshRootPdfSumAtVertex(prefix.dualFirstPdf, freshSlot, freshAttemptedMask,
                x2.rootDirection, vertex.posW, vertex.faceNormalW, primarySD, primaryMI, freshDiffuseSampling,
                separateFreshRootMeasures);
            if (deltaPrefix)
            {
                nativeFresh.firstGeometry = 1.f;
                nativeFresh.root.specular = prefix.throughputToX1;
            }
            else
            {
                float3 direction;
                float distanceSquared;
                if (rtptGrisPrefixDirection(ray.origin, sd.posW, direction, distanceSquared))
                {
                    const float geometry = abs(dot(sd.faceN, direction)) / distanceSquared;
                    if (geometry > 0.f && isfinite(geometry))
                    {
                        nativeFresh.firstGeometry = geometry;
                        nativeFresh.root = rtptGrisEvaluateFixedX1Root(primarySD, direction, 1.f, freshEvaluationRng);
                    }
                }
            }
        }
#endif
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_DUAL_FIRST_HIT
#if !RTPT_GRIS_ALTERNATING
        // A failed represented edge or unsupported root stays fully local.
        // Never publish its sampled-ray numerator into the packed-hit domain.
        if (!representedPrefix && bounce <= 2u) prefix.x1Hit = makeInvalidHit().pack();
        if (representedPrefix)
#endif
        rtptGRISCapturePrefix(bounce, sd, mi, hit, ray.dir, throughput, prefix);
#if !RTPT_GRIS_ALTERNATING
        if (bounce == 1u && HitInfo(prefix.x1Hit).isValid())
            pathBuilder.areaPdf = rtptGRISAreaPdf(sd, ray, previousContinuationPdf);
        rtptGRISBeginInterface(bounce, sd, mi, hit, ray, previousContinuationPdf, previousDelta, prefix, pathBuilder, suffix);
#if RTPT_GRIS_SUFFIX_REPLAY
        if (bounce > 2u && pathBuilder.hasTail)
            pathBuilder.suffixInstanceMask |= rtptGrisSuffixInstanceBit(triangleHit.instanceID.index);
#endif
#endif
#endif

#if ENABLE_SHARC && SHARC_QUERY
        const BSDFProperties sharcProperties = mi.getProperties(sd);
        float3 cachedRadiance;
#if RTPT_GRIS_GENERATE
#if RTPT_GRIS_SHARC_REPLAY && !RTPT_GRIS_DUAL_SHARC
        RTPTSharcTailQuery tailQuery;
#endif
#if !RTPT_GRIS_DUAL_SHARC
        // The guided and BSDF techniques share one continuation on the supported diffuse edges.
        const bool sharedDiffuse = previousSharcSampling.alpha > 0.f;
#endif
#ifdef RTPT_GRIS_SHARC_X1_BLEND
        // A blend probe keeps the x1 prefix available for x2 reuse.
        const bool probeX1 = bounce == 1u && HitInfo(prefix.x1Hit).isValid();
#endif
#if RTPT_GRIS_DUAL_SHARC
        const bool x3EdgeValid = bounce == 3u && x2.deepPdf > 0.f &&
            (previousDiffuse || (previousRoughness > 0.f && isfinite(previousRoughness)));
        const bool cacheEdgeValid = bounce >= 4u || x3EdgeValid;
        const bool cacheDiffuse = previousDiffuse;
        const float cacheRoughness = previousRoughness;
        if (cacheEdgeValid && rtptTryGrisDualSharcQueryOnEdgeFrom(gSharc, sd, mi, sharcProperties, bounce, previousDelta,
            false, cacheDiffuse, cacheRoughness,
#else
        if (rtptTrySharcQueryOnEdge(sd, mi, sharcProperties, bounce, previousDelta,
            previousGuideSelected && !sharedDiffuse, previousDiffuse || sharedDiffuse, previousRoughness,
#endif
            length(sd.posW - previousPosition), previousSharcSampling, ray.dir, sharcStats, cachedRadiance
#if RTPT_GRIS_SHARC_REPLAY && !RTPT_GRIS_DUAL_SHARC
            , tailQuery
#endif
#if defined(RTPT_GRIS_SHARC_X1_BLEND) && !RTPT_GRIS_DUAL_SHARC
            , probeX1
#endif
            ))
#else
        if (rtptTrySharcQuery(sd, mi, sharcProperties, bounce, previousDelta, previousGuideSelected, previousDiffuse, previousRoughness,
            length(sd.posW - previousPosition), sharcStats, cachedRadiance))
#endif
        {
            const float3 contribution = throughput * cachedRadiance;
#ifdef RTPT_GRIS_SHARC_X1_BLEND
            if (probeX1)
            {
                mixedX1Cache = all(isfinite(contribution));
                if (mixedX1Cache) x1CacheContribution = contribution;
            }
            else
#endif
            {
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_SHARC
                if (x2.deepPdf > 0.f)
                {
                    // x2's BSDF is applied by the shared prefix evaluation.
                    const float3 incident = bounce == 3u ? cachedRadiance : segmentThroughput * cachedRadiance;
                    if (all(isfinite(incident)) && all(incident >= 0.f))
                    {
                        if (rtptGrisOfferNativeFreshEvent(nativeFresh, kGrisFreshSharcEvent, freshRootPdf * x2.deepPdf,
                            incident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng))
                        {
                            cacheSuffix.candidate.rootLobe = currentRoot;
                            cacheSuffix.candidate.terminalKind = uint(GrisTerminalKind::GrisDualSharcTail) | kGrisDeepTail;
                            cacheSuffix.candidate.hasWinner = true;
                            cacheSuffix.sourceX1 = prefix.dualX1;
                            cacheSuffix.reconnectHit = x2.hit;
                            cacheSuffix.areaPdf = x2.deepPdf;
                            cacheSuffix.suffixDirection = x2.direction;
                            cacheSuffix.dualExplicitRng = x2.replayRng;
                            cacheSuffix.dualExplicitBounce = bounce;
                        }
                        break;
                    }
                }
#endif
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && !RTPT_GRIS_DUAL_FIRST_HIT && RTPT_GRIS_CACHE_TAIL
                if (pathBuilder.hasTail)
                {
                    float3 incident = pathBuilder.tailThroughput * cachedRadiance;
#if RTPT_GRIS_SHARC_REPLAY
                    const float3 sharcGain = pathBuilder.tailThroughput * tailQuery.materialFactor;
                    const float3 refreshedIncident = sharcGain * tailQuery.rawRadiance;
                    // Preserve the original incident and allow ray replay if
                    // folding the material factor would overflow.
                    const bool canRefresh = all(isfinite(sharcGain)) && all(isfinite(refreshedIncident));
                    if (canRefresh) incident = refreshedIncident;
#endif
                    rtptGRISAddPathTerminal(pathBuilder, terminalRng, currentRoot, prefix.x1Hit,
                        contribution, uint(GrisTerminalKind::GrisSharcTail), true,
                        pathBuilder.rcWi, incident, 0.f, false, bounce, suffix
#if RTPT_GRIS_SHARC_REPLAY
                        , canRefresh ? tailQuery.key : uint2(0u), canRefresh ? sharcGain : float3(0.f)
#endif
                        );
                    break;
                }
#endif
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && RTPT_GRIS_ALTERNATING
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
        }
#endif

#if USE_EMISSIVE_LIGHTS
        float3 emission = mi.getProperties(sd).emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (any(emission > 0.f))
        {
            bool coveredRootEvent = false;
#if RTPT_USE_RESTIR_DI
            if (bounce == 1u && !previousDelta)
                coveredRootEvent = rtptDICoversEmissiveHit(triangleHit, rootCoverage);
#endif
            if (!coveredRootEvent)
            {
                const bool hasNeeCompetitor = previousUsedNEE && !previousDelta;
                const float lightPdf = hasNeeCompetitor ?
#if RTPT_USE_RESTIR_DI
                        bounce == 1u ? rtptEmissiveLightPdfForCoverage(previousPosition, previousNormal, triangleHit, sd, rootCoverage)
                                     : rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd)
#else
                        rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd)
#endif
                    : 0.f;
                const float misWeight = hasNeeCompetitor ? rtptPowerHeuristic(previousContinuationPdf, lightPdf) : 1.f;
                const float3 contribution = throughput * emission * misWeight;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
                if (captureExplicit && bounce >= 3u && x2.deepPdf > 0.f)
                {
                    if (bounce == 3u)
                    {
                        rtptGrisOfferNativeExplicitEvent(nativeFresh, kGrisFreshX3BsdfEvent, freshRootPdf * x2.deepPdf,
                            emission, lightPdf, deltaPrefix, freshReservoir, freshSelectionRng,
                            x2.deepLight, uint(GrisTerminalKind::GrisDualEmitter), bounce, asuint(lightPdf), explicitWinner);
                    }
                    else
                    {
                        const float3 incident = segmentThroughput * emission * misWeight;
                        rtptGrisOfferNativeExplicitEvent(nativeFresh, kGrisFreshLateEvent, freshRootPdf * x2.deepPdf,
                            incident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng,
                            x2.deepLight, uint(GrisTerminalKind::GrisDualEmitter), bounce, 0u, explicitWinner);
                    }
                }
                else
#endif
                if (all(isfinite(contribution)))
                {
#if RTPT_GRIS_GENERATE && !RTPT_GRIS_SPATIAL
                    rtptSelectGrisTerminal(terminalPicker, terminalRng, contribution, GrisTerminalKind::GrisEmitter);
#endif
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && !RTPT_GRIS_DUAL_FIRST_HIT
                    // An emitter at x2 is a local endpoint without x2 scattering.
                    if (pathBuilder.hasTail)
                    {
                        const bool deepTail = bounce > 3u;
                        const float3 incident = deepTail ? pathBuilder.tailThroughput * emission * misWeight : emission;
                        rtptGRISAddPathTerminal(pathBuilder, terminalRng, currentRoot, prefix.x1Hit,
                            contribution, uint(GrisTerminalKind::GrisEmitter),
                            deepTail, pathBuilder.rcWi, incident, lightPdf, false, bounce, suffix);
                    }
                    else radiance += contribution;
#else
                    radiance += contribution;
#endif
                }
            }
            // The covered emission is one event; the hit's reflected indirect
            // transport below remains eligible for NEE, guiding and SHaRC.
        }
#endif
        if (bounce == gParams.maxBounces) break;
#if RTPT_GRIS_GENERATE || RTPT_USE_GRIS
        // GRIS guides only the primary diffuse edge. x1 and every later
        // vertex retain BSDF-only proposals for both root walks.
        const RTPTSamplingContext sampling = rtptBSDFSamplingContext();
#else
        const RTPTSamplingContext sampling = rtptMakeSamplingContext(sd, mi);
#endif

        const bool hasNonDeltaLobes = (mi.getLobeTypes(sd) & uint(LobeType::NonDeltaReflection)) != 0;
        previousUsedNEE = gParams.useNEE != 0 && hasNonDeltaLobes;
        if (previousUsedNEE)
        {
            float3 contribution = 0.f;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL
#if !RTPT_GRIS_ALTERNATING
#if RTPT_GRIS_DUAL_FIRST_HIT
            bool captured = false;
            SampleGenerator neeRng = sg;
            if (bounce >= 3u && x2.deepPdf > 0.f)
                neeRng = rtptGrisForkReplayNEERng(sg, bounce);
            uint onlineNeeEvent = 0xffffffffu;
            GrisDualNeeTerminal lateLight = {};
            SampleGenerator evaluationRng = freshEvaluationRng;
            if (bounce == 1u && representedPrefix && prefix.dualFirstPdf > 0.f)
            {
                captured = rtptGrisCaptureDualNee(x2.firstNee, sg, false);
                if (captured)
                {
                    x2.firstNee.terminalKind |= kGrisFixedX1Nee;
                    onlineNeeEvent = kGrisFixedX1NeeEvent;
                }
            }
            else if (bounce == 2u && representedPrefix && !previousDelta && prefix.dualFirstPdf > 0.f)
            {
                const float secondPdf = rtptGRISAreaPdf(sd, ray, previousContinuationPdf);
                if (secondPdf > 0.f && isfinite(secondPdf))
                {
                    // Deep can use this draw even when NEE consumes a zero sample.
                    x2.hit = hit.pack();
                    x2.areaPdf = secondPdf;
                    captured = rtptGrisCaptureDualNee(x2.directLight, sg, false);
                    if (x2.directLight.hasWinner) onlineNeeEvent = kGrisFreshX2NeeEvent;
                }
            }
            else if (bounce == 3u && x2.deepPdf > 0.f)
            {
                captured = rtptGrisCaptureDualNee(x2.deepLight, neeRng, true);
                if (x2.deepLight.hasWinner) onlineNeeEvent = kGrisFreshX3NeeEvent;
            }
            else if (captureExplicit && bounce >= 4u && x2.deepPdf > 0.f)
            {
                // Evaluate late NEE from the replay stream before the light draw.
                evaluationRng = neeRng;
                captured = rtptGrisCaptureDualNee(lateLight, neeRng, true);
                if (lateLight.hasWinner) onlineNeeEvent = kGrisFreshLateEvent;
            }
            if (onlineNeeEvent != 0xffffffffu)
            {
                const bool firstNee = onlineNeeEvent == kGrisFixedX1NeeEvent;
                const bool secondNee = onlineNeeEvent == kGrisFreshX2NeeEvent;
                const bool lateNee = onlineNeeEvent == kGrisFreshLateEvent;
                const GrisDualNeeTerminal terminal = lateNee ? lateLight :
                    (firstNee ? x2.firstNee : (secondNee ? x2.directLight : x2.deepLight));
                GrisSpatialRecord proposal = {};
                rtptGrisApplyDualNeeTerminal(terminal, lateNee || onlineNeeEvent == kGrisFreshX3NeeEvent, proposal);
                const float lightProbability = rtptGrisDualLightProbability(proposal);
                if (lateNee || lightProbability > 0.f)
                {
                    bool shadowClear;
                    const float3 incident = rtptGrisEvaluateDualLight(sd, sd, mi, proposal, lightProbability,
                        evaluationRng, false, shadowClear);
                    if (lateNee)
                    {
                        const float3 tailIncident = segmentThroughput * incident;
                        rtptGrisOfferNativeExplicitEvent(nativeFresh, kGrisFreshLateEvent, freshRootPdf * x2.deepPdf * lightProbability,
                            tailIncident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng,
                            terminal, terminal.terminalKind, bounce, terminal.lightPdfOrIndex, explicitWinner);
                    }
                    else
                    {
                        freshEvaluationRng = evaluationRng;
                        const float pathPdf = freshRootPdf * (firstNee ? 1.f : (secondNee ? x2.areaPdf : x2.deepPdf));
                        rtptGrisOfferNativeFreshEvent(nativeFresh, onlineNeeEvent, pathPdf * lightProbability,
                            incident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng);
                    }
                }
            }
            if (!captured)
            {
                if (bounce >= 3u && x2.deepPdf > 0.f)
                    contribution = throughput * rtptEstimateDirect(sd, mi, sampling, neeRng);
                else contribution = throughput * rtptEstimateDirect(sd, mi, sampling, sg);
            }
#else
#if RTPT_GRIS_SUFFIX_REPLAY
            if (bounce > 2u && pathBuilder.hasTail)
            {
                SampleGenerator neeRng = rtptGrisForkReplayNEERng(sg, bounce);
                contribution = rtptGRISCapturePathNEE(bounce, sd, mi, sampling, throughput, query,
                    currentRoot, prefix.x1Hit, neeRng, terminalRng, pathBuilder, suffix);
            }
            else
#endif
            {
                contribution = rtptGRISCapturePathNEE(bounce, sd, mi, sampling, throughput, query,
                    currentRoot, prefix.x1Hit, sg, terminalRng, pathBuilder, suffix);
            }
#endif
#else
            if (bounce == 2 && HitInfo(prefix.x1Hit).isValid() && rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd)))
            {
                contribution = rtptGRISCaptureDirectTerminal(sd, mi, sampling, hit, ray,
                    previousContinuationPdf, throughput, query, sg, suffix);
            }
            else
#endif
#endif
#if !(RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING)
            {
#if RTPT_GRIS_GENERATE && RTPT_GRIS_ALTERNATING
                const bool continues = generateSuffix && bounce == 1u;
                contribution = throughput * rtptEstimateDirect(sd, mi, sampling, sg, continues);
#else
                contribution = throughput * rtptEstimateDirect(sd, mi, sampling, sg);
#endif
            }
#endif
            if (all(isfinite(contribution)))
            {
#if RTPT_GRIS_GENERATE && !RTPT_GRIS_SPATIAL
                rtptSelectGrisTerminal(terminalPicker, terminalRng, contribution, GrisTerminalKind::GrisNee);
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
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
        if (rtptGRISPathReuseEnabled() && (!deltaPrefix || representedPrefix) && bounce <= 2u &&
            rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd)))
        {
            // Both interfaces after the root are BSDF-only. Reconnection
            // requires the full numerator and marginal direction density,
            // rather than a BSDF-selected lobe's individual weight.
            const float marginalPdf = rtptContinuationPdf(sd, mi, sampling, bs.wo);
            if (!(marginalPdf > 0.f) || !isfinite(marginalPdf)) break;
            bs.pdf = marginalPdf;
            const float3 numerator = mi.eval(sd, bs.wo, sg);
#if RTPT_GRIS_DUAL_FIRST_HIT
            if (bounce == 2u)
            {
                nativeFresh.outgoingBsdf = numerator;
                nativeFresh.outgoingPdf = marginalPdf;
            }
#endif
            bs.weight = numerator / marginalPdf;
            if (!all(isfinite(bs.weight))) break;
        }
#endif
        previousDelta = bs.isLobe(LobeType::Delta);
#if ENABLE_SHARC && SHARC_QUERY
        previousDiffuse = !previousGuideSelected && bs.isLobe(LobeType::DiffuseReflection);
        previousRoughness = sharcProperties.roughness;
#if RTPT_GRIS_GENERATE && !RTPT_GRIS_DUAL_SHARC
        previousSharcSampling = sampling;
#endif
#endif
        if (!previousDelta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))) break;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
        if (bounce == 2u && gParams.maxBounces >= 3u && x2.areaPdf > 0.f && !previousDelta)
        {
            const float deepPdf = x2.areaPdf * bs.pdf;
            if (deepPdf > 0.f && isfinite(deepPdf))
            {
                x2.deepPdf = deepPdf;
#if ENABLE_SHARC && SHARC_QUERY && RTPT_GRIS_DUAL_SHARC
                // A represented x2 already has the packed hit's UV, explicit LOD and
                // supported front-facing material. Its full lobes and roughness are
                // view independent for PBRTDiffuse and Standard. Reuse the edge
                // state for x3; the next BSDF draw replaces it for x4 and later.
                const float faceLengthSquared = dot(vertex.faceNormalW, vertex.faceNormalW);
                const bool canProbeX3 = gSharcSettings.useCache != 0u && gSharcSettings.minBounce <= 3u &&
                    faceLengthSquared > 0.f && isfinite(faceLengthSquared);
                previousDiffuse = canProbeX3 && mi.getLobeTypes(sd) == uint(LobeType::DiffuseReflection);
                previousRoughness = canProbeX3 ? sharcProperties.roughness : 0.f;
#endif
                x2.direction = bs.wo;
                x2.replayRng = rtptGrisCaptureReplayRng(sg);
            }
        }
        if (bounce >= 3u && x2.deepPdf > 0.f)
        {
            // x2 consumed the last canonical prefix weight. Start the suffix on the outgoing x3 edge.
            segmentThroughput = bounce == 3u ? bs.weight : segmentThroughput * bs.weight;
        }
#endif
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && !RTPT_GRIS_DUAL_FIRST_HIT
        if (bounce == 2u && pathBuilder.hasInterface)
        {
            // Use the PDF from the actual x2 sample, after the interface's
            // marginal-PDF override. A previous x2 NEE winner keeps R_head.
            const float tailRatio = pathBuilder.areaPdf * (bs.pdf / kGrisReferenceDirectionPdf);
            if (tailRatio > 0.f && isfinite(tailRatio))
            {
                pathBuilder.areaPdf = tailRatio;
                pathBuilder.rcWi = bs.wo;
                pathBuilder.tailThroughput = float3(1.f);
                pathBuilder.hasTail = true;
#if RTPT_GRIS_SUFFIX_REPLAY
                pathBuilder.postX2RngState = rtptGrisCaptureReplayRng(sg);
#endif
            }
            else
            {
                // Keep the remaining complete estimate local if its reference
                // representation cannot be stored. Do not discard radiance.
                pathBuilder.hasInterface = false;
                pathBuilder.hasTail = false;
            }
        }
        else if (pathBuilder.hasTail) pathBuilder.tailThroughput *= bs.weight;
#endif
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
        if (representedPrefix && bounce == 1u)
        {
            prefixFrom = sd;
            segmentThroughput = throughput;
        }
#endif
        throughput *= bs.weight;
        if (!all(isfinite(throughput))) break;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
        // A sampled zero can become positive at the represented endpoint.
        // Trace that endpoint before deciding support, rather than losing it
        // before the canonical numerator has been evaluated.
        if (!(representedPrefix && bounce == 1u) &&
#if RTPT_GRIS_DUAL_FIRST_HIT
            // A zero native route can still propose a tail for the other lobe.
            !(bounce >= 2u && x2.deepPdf > 0.f && (bounce == 2u || any(segmentThroughput > 0.f))) &&
#endif
            !any(throughput > 0.f)) break;
#else
        if (!any(throughput > 0.f)) break;
#endif
        if (gParams.useRussianRoulette != 0 && bounce + 1 >= gParams.rrStartBounce)
        {
            const float survival = min(0.95f, max(throughput.x, max(throughput.y, throughput.z)));
            if (sampleNext1D(sg) >= survival) break;
            throughput /= survival;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && !RTPT_GRIS_DUAL_FIRST_HIT
            if (pathBuilder.hasTail) pathBuilder.tailThroughput /= survival;
#endif
        }

        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        previousContinuationPdf = bs.pdf;
        ray = Ray(sd.computeRayOrigin(), bs.wo);
#else
        break;
#endif
    }
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && !RTPT_GRIS_DUAL_FIRST_HIT
    rtptGRISFinalizePath(pathBuilder, suffix);
#endif
#ifdef RTPT_GRIS_SHARC_X1_BLEND
    const float3 explicitRadiance = all(isfinite(radiance)) ? radiance : float3(0.f);
    if (mixedX1Cache)
    {
        const float blend = gPrimarySettings.grisSharcX1Blend;
        return blend * x1CacheContribution + (1.f - blend) * explicitRadiance;
    }
    return explicitRadiance;
#else
    return all(isfinite(radiance)) ? radiance : float3(0.f);
#endif
}
