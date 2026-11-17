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
#include "GRIS/RTPTGRISDualExplicitPath.slang"
#include "GRIS/RTPTGRISReference.slang"

void rtptGrisCaptureDualExplicit(GrisDualNeeTerminal light, uint kind, uint bounce, uint2 pathID,
    float3 incident, uint lightPdfOrIndex, out GrisDualExplicitTerminal terminal)
{
    terminal.incident = incident;
    // x3 NEE can update the deep proposal after an x3 emitter was recorded.
    terminal.suffixLight = light.coordinates;
    terminal.dualExplicitPathID = pathID;
    terminal.dualExplicitBounce = bounce;
    terminal.terminalKind = kind | kGrisDeepTail;
    terminal.lightPdfOrIndex = lightPdfOrIndex;
    terminal.lightIsAnalytic = light.lightIsAnalytic;
}

bool rtptGrisCaptureDualNee(ShadingData surface, inout GrisDualNeeTerminal terminal, inout SampleGenerator rng, bool deep)
{
    const float3 probabilities = rtptLightCategoryProbabilities();
    if (!any(probabilities > 0.f)) return false;

    const uint category = rtptSampleLightCategory(probabilities, rng);
#if USE_ENV_LIGHT
    if (category == 0u)
    {
        terminal.coordinates = float3(sampleNext2D(rng), 0.f);
        terminal.terminalKind = uint(GrisTerminalKind::GrisDualEnvironmentNee);
    }
#endif
#if USE_EMISSIVE_LIGHTS
    if (category == 1u)
    {
        const uint count = gScene.lightCollection.getActiveTriangleCount();
        const uint slot = min(uint(sampleNext1D(rng) * count), count - 1u);
        terminal.lightPdfOrIndex = gScene.lightCollection.activeTriangles[slot];
        terminal.coordinates = float3(sampleNext2D(rng), 0.f);
        terminal.terminalKind = uint(GrisTerminalKind::GrisDualEmissiveNee);
    }
#endif
#if USE_ANALYTIC_LIGHTS
    if (category == 2u)
    {
        // The host enables this mode for point analytic lights.
        terminal.lightPdfOrIndex = rtptSampleAnalyticLightIndex(gScene.getLightCount(), rng);
        terminal.lightIsAnalytic = true;
        terminal.terminalKind = uint(GrisTerminalKind::GrisDualPointNee);
    }
#endif
    if (deep) terminal.terminalKind |= kGrisDeepTail;
    // Keep raw proposals before backface, alpha, radiance and visibility tests.
    terminal.hasWinner = true;
    return true;
}

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
struct GrisNativeFreshPrefix
{
    GrisDualTailValue root;
    float firstGeometry;
    float3 connection;
    float3 outgoingBsdf;
    float outgoingPdf;
};

void rtptGrisOfferNativeFreshEvent(GrisNativeFreshPrefix prefix, uint event, float proposalPdf,
    float3 incident, float lightPdf, bool deltaRoot, inout GrisFreshSlotReservoir reservoir,
    inout SampleGenerator selectionRng)
{
    if (!(proposalPdf > 0.f) || !isfinite(proposalPdf) || !(prefix.firstGeometry > 0.f)) return;
    const bool deep = event != kGrisFixedX1NeeEvent && event != kGrisFreshX2NeeEvent;
    const float3 deepIncident = deep ? incident : float3(0.f);
    if (deep)
    {
        if (!(prefix.outgoingPdf > 0.f) || !all(isfinite(incident)) || !any(incident > 0.f)) return;
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
        if (!all(isfinite(common)) || !any(common > 0.f)) return;
        const float3 diffuse = prefix.root.diffuse * common;
        const float3 specular = prefix.root.specular * common;
        if (all(isfinite(diffuse))) value.diffuse = diffuse;
        if (all(isfinite(specular))) value.specular = specular;
    }
    rtptGrisOfferFreshCandidate(reservoir, event, value, proposalPdf, deepIncident, lightPdf, selectionRng);
}

void rtptGrisOfferNativeFreshNee(GrisNativeFreshPrefix prefix, uint event, float pathPdf,
    ShadingData surface, IMaterialInstance material, GrisDualNeeTerminal terminal, bool deltaRoot,
    inout GrisFreshSlotReservoir reservoir, inout SampleGenerator evaluationRng, inout SampleGenerator selectionRng)
{
    GrisSpatialRecord proposal = {};
    rtptGrisApplyDualNeeTerminal(terminal, event == kGrisFreshX3NeeEvent, proposal);
    const float lightProbability = rtptGrisDualLightProbability(proposal);
    if (!(lightProbability > 0.f)) return;
    bool shadowClear;
    const float3 incident = rtptGrisEvaluateDualLight(surface, surface, material, proposal, lightProbability,
        evaluationRng, false, shadowClear);
    rtptGrisOfferNativeFreshEvent(prefix, event, pathPdf * lightProbability, incident, 0.f, deltaRoot,
        reservoir, selectionRng);
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
    , uint lateSlot
    , out GrisDualExplicitTerminal bsdfTerminal
    , out GrisDualExplicitTerminal lateTerminal
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
    bsdfTerminal = {};
    lateTerminal = {};
    x2.rootDirection = 0.f;
    x2.firstNee = {};
    uint2 explicitPathID = rtptGrisDualExplicitBeginPath();
    float3 explicitThroughput = 1.f;
    const uint lateCount = rtptGrisDualExplicitLateCount(gParams.maxBounces);
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
    float3 prefixThroughput = float3(1.f / rootProbability);
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
                const uint2 missID = rtptGrisDualExplicitAppendMiss(explicitPathID);
                if (bounce == 3u)
                {
                    rtptGrisCaptureDualExplicit(x2.deepLight, uint(GrisTerminalKind::GrisDualEnvironmentMiss),
                        bounce, missID, environment, asuint(lightPdf), bsdfTerminal);
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
                    rtptGrisOfferNativeFreshEvent(nativeFresh, kGrisFreshX3BsdfEvent, freshRootPdf * x2.deepPdf,
                        bsdfTerminal.incident, lightPdf, deltaPrefix, freshReservoir, freshSelectionRng);
#endif
                }
                else if (lateSlot == 2u * (bounce - 4u))
                {
                    rtptGrisCaptureDualExplicit(x2.deepLight, uint(GrisTerminalKind::GrisDualEnvironmentMiss),
                        bounce, missID, explicitThroughput * environment * (misWeight * float(lateCount)), 0u, lateTerminal);
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
                    rtptGrisOfferNativeFreshEvent(nativeFresh, kGrisFreshLateEvent, freshRootPdf * x2.deepPdf,
                        lateTerminal.incident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng);
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
        if (bounce >= 3u && x2.deepPdf > 0.f)
            explicitPathID = rtptGrisDualExplicitAppendHit(explicitPathID, hit.pack());
#endif
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
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
#if RTPT_GRIS_DUAL_FIRST_HIT
        if (rebuildPrefix)
#else
        if (representedPrefix && bounce <= 2u)
#endif
        {
            float3 direction;
            float distanceSquared;
            ShadingData represented;
#if RTPT_GRIS_DUAL_FIRST_HIT
            // The triangle was decoded from hit.pack() already. Reuse its
            // canonical attributes while shading the reconstructed view.
            if (deltaPrefix && bounce == 1u)
            {
                prefix.dualX1 = hit.pack();
                // Discrete probability mass of the restricted mirror root.
                prefix.dualFirstPdf = 1.f;
                prefix.throughputToX1 = throughput;
                representedPrefix = rtptGrisRefLoad(vertex, materialID, -ray.dir, represented);
                if (representedPrefix)
                {
                    const IMaterialInstance representedMI =
                        gScene.materials.getMaterialInstance(represented, ExplicitLodTextureSampler(0.f));
                    representedPrefix = rtptGRISSupportsSurface(represented, representedMI.getLobeTypes(represented));
                    if (representedPrefix) sd = represented;
                }
            }
            else if (rtptGrisPrefixDirection(ray.origin, vertex.posW, direction, distanceSquared) &&
                rtptGrisRefLoad(vertex, materialID, -direction, represented))
#else
            if (rtptGrisPrefixDirection(ray.origin, vertex.posW, direction, distanceSquared) &&
                rtptGrisRefLoad(hit.pack(), -direction, represented))
#endif
            {
#if RTPT_GRIS_DUAL_FIRST_HIT
                // Keep the actual draw even if this walk cannot represent its second edge.
                if (bounce == 1u)
                {
                    const float firstPdf = rtptGRISAreaPdf(represented, ray, previousContinuationPdf);
                    if (firstPdf > 0.f && isfinite(firstPdf))
                    {
                        prefix.dualX1 = hit.pack();
                        prefix.dualFirstPdf = firstPdf;
                    }
                }
#endif
                const IMaterialInstance representedMI = gScene.materials.getMaterialInstance(represented, ExplicitLodTextureSampler(0.f));
                if (rtptGRISSupportsSurface(represented, representedMI.getLobeTypes(represented)))
                {
                    // Evaluate before emission, NEE and terminal selection.
                    // Retain q from the real draw, including its guide leaf;
                    // never ask the guide to evaluate the reconstructed ray.
                    const IMaterialInstance fromMI = gScene.materials.getMaterialInstance(prefixFrom, ExplicitLodTextureSampler(0.f));
                    const float3 edgeValue = fromMI.eval(prefixFrom, direction, sg);
#if RTPT_GRIS_DUAL_FIRST_HIT
                    if (bounce == 2u)
                    {
                        const float geometry = abs(dot(represented.faceN, direction)) / distanceSquared;
                        const float pdf = fromMI.evalPdf(prefixFrom, direction);
                        if (geometry > 0.f && isfinite(geometry) && pdf > 0.f && isfinite(pdf))
                            nativeFresh.connection = edgeValue * geometry;
                    }
#endif
                    throughput = prefixThroughput * edgeValue / previousContinuationPdf;
                    sd = represented;
                }
                else representedPrefix = false;
            }
            else representedPrefix = false;
        }
#endif
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
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
#if RTPT_GRIS_SHARC_REPLAY
        RTPTSharcTailQuery tailQuery;
#endif
        // The guided and BSDF techniques share one continuation on the supported diffuse edges.
        const bool sharedDiffuse = previousSharcSampling.alpha > 0.f;
#ifdef RTPT_GRIS_SHARC_X1_BLEND
        // A blend probe keeps the x1 prefix available for x2 reuse.
        const bool probeX1 = bounce == 1u && HitInfo(prefix.x1Hit).isValid();
#endif
        if (rtptTrySharcQueryOnEdge(sd, mi, sharcProperties, bounce, previousDelta,
            previousGuideSelected && !sharedDiffuse, previousDiffuse || sharedDiffuse, previousRoughness,
            length(sd.posW - previousPosition), previousSharcSampling, ray.dir, sharcStats, cachedRadiance
#if RTPT_GRIS_SHARC_REPLAY
            , tailQuery
#endif
#ifdef RTPT_GRIS_SHARC_X1_BLEND
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
                if (bounce == 4u && cacheSuffix.areaPdf > 0.f)
                {
                    const float3 incident = explicitThroughput * cachedRadiance;
                    if (all(isfinite(incident)) && all(incident >= 0.f))
                    {
                        cacheSuffix.dualExplicitRng = x2.replayRng;
                        rtptGrisOfferNativeFreshEvent(nativeFresh, kGrisFreshSharcEvent, freshRootPdf * cacheSuffix.areaPdf,
                            incident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng);
                        cacheSuffix.dualExplicitBounce = bounce;
                        cacheSuffix.dualExplicitPathID = explicitPathID;
                        cacheSuffix.candidate.terminalKind = uint(GrisTerminalKind::GrisDualSharcTail) | kGrisDeepTail;
                        cacheSuffix.candidate.hasWinner = true;
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
                        rtptGrisCaptureDualExplicit(x2.deepLight, uint(GrisTerminalKind::GrisDualEmitter),
                            bounce, explicitPathID, emission, asuint(lightPdf), bsdfTerminal);
                        rtptGrisOfferNativeFreshEvent(nativeFresh, kGrisFreshX3BsdfEvent, freshRootPdf * x2.deepPdf,
                            bsdfTerminal.incident, lightPdf, deltaPrefix, freshReservoir, freshSelectionRng);
                    }
                    else if (lateSlot == 2u * (bounce - 4u))
                    {
                        rtptGrisCaptureDualExplicit(x2.deepLight, uint(GrisTerminalKind::GrisDualEmitter),
                            bounce, explicitPathID, explicitThroughput * emission * (misWeight * float(lateCount)), 0u, lateTerminal);
                        rtptGrisOfferNativeFreshEvent(nativeFresh, kGrisFreshLateEvent, freshRootPdf * x2.deepPdf,
                            lateTerminal.incident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng);
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
            if (bounce == 1u && representedPrefix && prefix.dualFirstPdf > 0.f)
            {
                captured = rtptGrisCaptureDualNee(sd, x2.firstNee, sg, false);
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
                    captured = rtptGrisCaptureDualNee(sd, x2.directLight, sg, false);
                    if (x2.directLight.hasWinner) onlineNeeEvent = kGrisFreshX2NeeEvent;
                }
            }
            else if (bounce == 3u && x2.deepPdf > 0.f)
            {
                captured = rtptGrisCaptureDualNee(sd, x2.deepLight, neeRng, true);
                if (x2.deepLight.hasWinner) onlineNeeEvent = kGrisFreshX3NeeEvent;
            }
            else if (captureExplicit && bounce >= 4u && x2.deepPdf > 0.f)
            {
                // One uniform slot covers all late explicit events, including
                // slots skipped by misses, unsupported lobes or cache hits.
                captured = true;
                if (lateSlot == 2u * (bounce - 4u) + 1u)
                {
                    GrisDualNeeTerminal light = x2.deepLight;
                    light.hasWinner = false;
                    SampleGenerator evalRng = neeRng;
                    captured = rtptGrisCaptureDualNee(sd, light, neeRng, true);
                    if (light.hasWinner)
                    {
                        GrisSpatialRecord proposal = {};
                        rtptGrisApplyDualNeeTerminal(light, true, proposal);
                        const float lightProbability = rtptGrisDualLightProbability(proposal);
                        bool shadowClear;
                        const float3 value = rtptGrisEvaluateDualLight(sd, sd, mi, proposal, lightProbability,
                            evalRng, false, shadowClear);
                        rtptGrisCaptureDualExplicit(light, light.terminalKind, bounce, explicitPathID,
                            explicitThroughput * value * float(lateCount), light.lightPdfOrIndex, lateTerminal);
                        rtptGrisOfferNativeFreshEvent(nativeFresh, kGrisFreshLateEvent, freshRootPdf * x2.deepPdf * lightProbability,
                            lateTerminal.incident, 0.f, deltaPrefix, freshReservoir, freshSelectionRng);
                    }
                }
            }
            if (onlineNeeEvent != 0xffffffffu)
            {
                const bool firstNee = onlineNeeEvent == kGrisFixedX1NeeEvent;
                const bool secondNee = onlineNeeEvent == kGrisFreshX2NeeEvent;
                const GrisDualNeeTerminal terminal = firstNee ? x2.firstNee : (secondNee ? x2.directLight : x2.deepLight);
                const float pathPdf = freshRootPdf * (firstNee ? 1.f : (secondNee ? x2.areaPdf : x2.deepPdf));
                rtptGrisOfferNativeFreshNee(nativeFresh, onlineNeeEvent, pathPdf, sd, mi, terminal, deltaPrefix,
                    freshReservoir, freshEvaluationRng, freshSelectionRng);
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
#if RTPT_GRIS_GENERATE
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
                x2.direction = bs.wo;
                x2.replayRng = rtptGrisCaptureReplayRng(sg);
            }
        }
        if (bounce >= 3u && x2.deepPdf > 0.f) explicitThroughput *= bs.weight;
#if RTPT_GRIS_DUAL_SHARC
        if (bounce == 3u && gParams.maxBounces > 4u && x2.deepPdf > 0.f &&
            !previousDelta && previousDiffuse)
        {
            cacheSuffix.candidate.rootLobe = currentRoot;
            cacheSuffix.sourceX1 = prefix.dualX1;
            cacheSuffix.reconnectHit = x2.hit;
            cacheSuffix.areaPdf = x2.deepPdf;
            cacheSuffix.suffixDirection = x2.direction;
        }
#endif
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
            prefixThroughput = throughput;
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
            !(bounce >= 2u && x2.deepPdf > 0.f && any(explicitThroughput > 0.f)) &&
#if RTPT_GRIS_DUAL_SHARC
            !(bounce == 3u && cacheSuffix.areaPdf > 0.f) &&
#endif
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
