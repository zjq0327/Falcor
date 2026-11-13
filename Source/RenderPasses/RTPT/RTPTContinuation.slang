#pragma once

#include "RTPTFirstHit.slangh"
#include "RTPTDeltaReflection.slang"

#ifndef RTPT_GRIS_DUAL_FIRST_HIT
#define RTPT_GRIS_DUAL_FIRST_HIT 0
#endif

#if RTPT_DELTA_NRD && !RTPT_GRIS_GENERATE
#define RTPT_CONTINUATION_NAME rtptTraceContinuationWithGuide
#else
#define RTPT_CONTINUATION_NAME rtptTraceContinuation
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

void rtptGrisCaptureDualExplicit(GrisSpatialRecord proposal, uint kind, uint bounce, uint2 pathID,
    float3 incident, float lightPdf, out GrisDualExplicitTerminal terminal)
{
    proposal.dualExplicitBounce = bounce;
    proposal.dualExplicitPathID = pathID;
    proposal.lightPdfOrStableID = asuint(lightPdf);
    proposal.candidate.terminalKind = kind | kGrisDeepTail;
    proposal.candidate.hasWinner = true;
    terminal.proposal = proposal;
    terminal.incident = incident;
}

bool rtptGrisCaptureDualNee(ShadingData surface, inout GrisSpatialRecord proposal, inout SampleGenerator rng, bool deep)
{
#if RTPT_GRIS_DUAL_REGIR
    if (rtptReGIRTransportCoverage(false) == 0u) return false;

    RTPTDILightInfo light;
    float innerRISWeight;
    // A failed draw from the cell estimates zero. Returning true consumes
    // this event so the local estimator cannot retry the draw.
    if (!rtptReGIRSelectTransportLight(surface, rng, light, innerRISWeight)) return true;
    float2 uv = 0.f;
#if USE_EMISSIVE_LIGHTS
    if (light.kind == kRTPTDILightEmissive && light.sourceIndex < gScene.lightCollection.getTriangleCount())
        uv = sampleNext2D(rng);
#endif
    proposal.lightPdfOrStableID = light.pad0;
    proposal.lightIsAnalytic = light.kind == kRTPTDILightPoint;
    proposal.suffixLight = float3(uv, innerRISWeight);
    proposal.candidate.terminalKind = uint(GrisTerminalKind::GrisDualReGIRNee);
#else
    const float3 probabilities = rtptLightCategoryProbabilities();
    if (!any(probabilities > 0.f)) return false;

    const uint category = rtptSampleLightCategory(probabilities, rng);
#if USE_ENV_LIGHT
    if (category == 0u)
    {
        const float3 coordinates = float3(sampleNext2D(rng), 0.f);
        if (deep) proposal.suffixLight = coordinates;
        else proposal.suffixDirection = coordinates;
        proposal.candidate.terminalKind = uint(GrisTerminalKind::GrisDualEnvironmentNee);
    }
#endif
#if USE_EMISSIVE_LIGHTS
    if (category == 1u)
    {
        const uint count = gScene.lightCollection.getActiveTriangleCount();
        const uint slot = min(uint(sampleNext1D(rng) * count), count - 1u);
        proposal.lightPdfOrStableID = gScene.lightCollection.activeTriangles[slot];
        const float3 coordinates = float3(sampleNext2D(rng), 0.f);
        if (deep) proposal.suffixLight = coordinates;
        else proposal.suffixDirection = coordinates;
        proposal.candidate.terminalKind = uint(GrisTerminalKind::GrisDualEmissiveNee);
    }
#endif
#if USE_ANALYTIC_LIGHTS
    if (category == 2u)
    {
        // The host enables this mode for point analytic lights.
        proposal.lightPdfOrStableID = rtptSampleAnalyticLightIndex(gScene.getLightCount(), rng);
        proposal.lightIsAnalytic = true;
        proposal.candidate.terminalKind = uint(GrisTerminalKind::GrisDualPointNee);
    }
#endif
#endif
    if (deep) proposal.candidate.terminalKind |= kGrisDeepTail;
    // Keep raw proposals before backface, alpha, radiance and visibility tests.
    proposal.candidate.hasWinner = true;
    return true;
}
#endif

/** Trace the selected component on the primary surface.
    The ordinary callers select their component with probability one. Generate
    passes its explicit root-selection probability and captures the candidate event.
    Later vertices use the mixed reflection estimator.
*/
float3 RTPT_CONTINUATION_NAME(
    ShadingData primarySD,
    IMaterialInstance primaryMI,
    uint primaryLobes,
    RTPTSamplingContext primarySampling,
    inout SampleGenerator sg,
    out float firstHitDistance,
    out uint firstHitDistanceState,
    inout RTPTSharcStats sharcStats,
    uint rootCoverage
#if RTPT_DELTA_NRD && !RTPT_GRIS_GENERATE
    , inout RTPTDeltaGuide deltaGuide
#endif
#if RTPT_GRIS_GENERATE
    , float rootProbability
#if RTPT_GRIS_SPATIAL
    , inout GrisLocalPrefix prefix
    , inout GrisSpatialRecord suffix
#if RTPT_GRIS_DUAL_FIRST_HIT && !RTPT_GRIS_ALTERNATING
    , inout GrisSpatialRecord deepSuffix
    , out TriangleHit deepHit
    , uint lateSlot
    , out GrisDualExplicitTerminal bsdfTerminal
    , out GrisDualExplicitTerminal lateTerminal
#if RTPT_GRIS_DUAL_SHARC
    , inout GrisSpatialRecord cacheSuffix
    , out float3 cacheIncident
#endif
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
    deepHit = {};
    bsdfTerminal = {};
    lateTerminal = {};
    uint2 explicitPathID = rtptGrisDualExplicitBeginPath();
    float3 explicitThroughput = 1.f;
    const uint lateCount = rtptGrisDualExplicitLateCount(gParams.maxBounces);
#if defined(RTPT_GRIS_DUAL_EXPLICIT_LOCAL_CONTROL)
    const bool captureExplicit = false;
#else
    const bool captureExplicit = true;
#endif
#if RTPT_GRIS_DUAL_SHARC
    cacheIncident = 0.f;
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
    bool representedPrefix = rtptGRISPathReuseEnabled() && !previousDelta &&
        rtptGRISSupportsSurface(primarySD, primaryMI.getLobeTypes(primarySD) & primaryLobes);
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
            const float lightPdf = 0.f;
            const float misWeight = 1.f;
#elif RTPT_REGIR_TRANSPORT
            const float lightPdf = previousUsedNEE && !previousDelta
                ? rtptEnvironmentLightPdfForCoverage(ray.dir, bounce == 1u ? rootCoverage : previousReGIRCoverage) : 0.f;
            const float misWeight = previousUsedNEE && !previousDelta ? rtptPowerHeuristic(previousContinuationPdf, lightPdf) : 1.f;
#elif RTPT_USE_RESTIR_DI
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
            if (captureExplicit && bounce >= 3u && deepSuffix.areaPdf > 0.f)
            {
                const uint2 missID = rtptGrisDualExplicitAppendMiss(explicitPathID);
                if (bounce == 3u)
                    rtptGrisCaptureDualExplicit(deepSuffix, uint(GrisTerminalKind::GrisDualEnvironmentMiss),
                        bounce, missID, environment, lightPdf, bsdfTerminal);
                else if (lateSlot == 2u * (bounce - 4u))
                    rtptGrisCaptureDualExplicit(deepSuffix, uint(GrisTerminalKind::GrisDualEnvironmentMiss),
                        bounce, missID, explicitThroughput * environment * (misWeight * float(lateCount)), 0.f, lateTerminal);
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
        if (bounce >= 3u && deepSuffix.areaPdf > 0.f)
            explicitPathID = rtptGrisDualExplicitAppendHit(explicitPathID, hit.pack());
#endif
        VertexData vertex = gScene.getVertexData(triangleHit);
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
        if (representedPrefix && bounce <= 2u) vertex = rtptGrisPrefixVertex(triangleHit);
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
        if (representedPrefix && bounce <= 2u)
        {
            float3 direction;
            float distanceSquared;
            ShadingData represented;
            if (rtptGrisPrefixDirection(ray.origin, vertex.posW, direction, distanceSquared) &&
                rtptGrisRefLoad(hit.pack(), -direction, represented))
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
                    throughput = prefixThroughput * fromMI.eval(prefixFrom, direction, sg) / previousContinuationPdf;
                    sd = represented;
                }
                else representedPrefix = false;
            }
            else representedPrefix = false;
        }
#endif
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
#if RTPT_DELTA_NRD && !RTPT_GRIS_GENERATE
        if (deltaGuide.enabled && bounce == 1u)
            rtptCaptureDeltaGuide(sd, mi, mi.getProperties(sd), triangleHit, throughput, deltaGuide);
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
                    const float3 incident = cacheSuffix.suffixLight * cachedRadiance;
                    if (all(isfinite(incident)) && all(incident >= 0.f))
                    {
                        cacheIncident = incident;
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
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
                if (captureExplicit && bounce >= 3u && deepSuffix.areaPdf > 0.f)
                {
                    if (bounce == 3u)
                        rtptGrisCaptureDualExplicit(deepSuffix, uint(GrisTerminalKind::GrisDualEmitter),
                            bounce, explicitPathID, emission, lightPdf, bsdfTerminal);
                    else if (lateSlot == 2u * (bounce - 4u))
                        rtptGrisCaptureDualExplicit(deepSuffix, uint(GrisTerminalKind::GrisDualEmitter),
                            bounce, explicitPathID, explicitThroughput * emission * (misWeight * float(lateCount)), 0.f, lateTerminal);
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
#if RTPT_REGIR_TRANSPORT
        previousReGIRCoverage = previousUsedNEE ? rtptReGIRTransportCoverage(false) : 0u;
#endif
        if (previousUsedNEE)
        {
            float3 contribution = 0.f;
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL
#if !RTPT_GRIS_ALTERNATING
#if RTPT_GRIS_DUAL_FIRST_HIT
            bool captured = false;
            SampleGenerator neeRng = sg;
            if (bounce >= 3u && deepSuffix.areaPdf > 0.f)
                neeRng = rtptGrisForkReplayNEERng(sg, bounce);
            if (bounce == 2u && representedPrefix && !previousDelta && prefix.dualFirstPdf > 0.f)
            {
                const float secondPdf = rtptGRISAreaPdf(sd, ray, previousContinuationPdf);
                if (secondPdf > 0.f && isfinite(secondPdf))
                {
                    suffix.candidate.rootLobe = currentRoot;
                    suffix.sourceX1 = prefix.dualX1;
                    suffix.reconnectHit = hit.pack();
                    suffix.areaPdf = secondPdf;
                    captured = rtptGrisCaptureDualNee(sd, suffix, sg, false);
                }
            }
            else if (bounce == 3u && deepSuffix.areaPdf > 0.f)
            {
                captured = rtptGrisCaptureDualNee(sd, deepSuffix, neeRng, true);
                // Generate can evaluate x3 with the native traversal result.
                if (deepSuffix.candidate.hasWinner) deepHit = triangleHit;
            }
            else if (captureExplicit && bounce >= 4u && deepSuffix.areaPdf > 0.f)
            {
                // One uniform slot covers all late explicit events, including
                // slots skipped by misses, unsupported lobes or cache hits.
                captured = true;
                if (lateSlot == 2u * (bounce - 4u) + 1u)
                {
                    GrisSpatialRecord proposal = deepSuffix;
                    proposal.candidate.hasWinner = false;
                    SampleGenerator evalRng = neeRng;
                    captured = rtptGrisCaptureDualNee(sd, proposal, neeRng, true);
                    if (proposal.candidate.hasWinner)
                    {
                        proposal.dualExplicitBounce = bounce;
                        proposal.dualExplicitPathID = explicitPathID;
                        const float lightProbability = rtptGrisDualLightProbability(proposal);
                        bool shadowClear;
                        const float3 value = rtptGrisEvaluateDualLight(sd, sd, mi, proposal, lightProbability,
                            evalRng, false, shadowClear);
                        lateTerminal.proposal = proposal;
                        lateTerminal.incident = explicitThroughput * value * float(lateCount);
                    }
                }
            }
            if (!captured)
            {
                if (bounce >= 3u && deepSuffix.areaPdf > 0.f)
                    contribution = throughput * rtptEstimateDirect(sd, mi, sampling, neeRng);
                else contribution = throughput * rtptEstimateDirect(sd, mi, sampling, sg);
            }
#else
#if RTPT_GRIS_SUFFIX_REPLAY
            if ((bounce > 2u && pathBuilder.hasTail) ||
                (RTPT_GRIS_REGIR_REPLAY && bounce == 2u && pathBuilder.hasInterface))
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
#if RTPT_GRIS_GENERATE && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
        if (rtptGRISPathReuseEnabled() && bounce <= 2u && rtptGRISSupportsSurface(sd, mi.getLobeTypes(sd)))
        {
            // Both interfaces after the root are BSDF-only. Reconnection
            // requires the full numerator and marginal direction density,
            // rather than a BSDF-selected lobe's individual weight.
            const float marginalPdf = rtptContinuationPdf(sd, mi, sampling, bs.wo);
            if (!(marginalPdf > 0.f) || !isfinite(marginalPdf)) break;
            bs.pdf = marginalPdf;
            bs.weight = mi.eval(sd, bs.wo, sg) / marginalPdf;
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
        if (bounce == 2u && gParams.maxBounces >= 3u && suffix.areaPdf > 0.f && !previousDelta)
        {
            const float deepPdf = suffix.areaPdf * bs.pdf;
            if (deepPdf > 0.f && isfinite(deepPdf))
            {
                deepSuffix.candidate.rootLobe = currentRoot;
                deepSuffix.sourceX1 = prefix.dualX1;
                deepSuffix.reconnectHit = hit.pack();
                deepSuffix.areaPdf = deepPdf;
                deepSuffix.suffixDirection = bs.wo;
                deepSuffix.dualExplicitRng = rtptGrisCaptureReplayRng(sg);
            }
        }
        if (bounce >= 3u && deepSuffix.areaPdf > 0.f) explicitThroughput *= bs.weight;
#if RTPT_GRIS_DUAL_SHARC
        if (bounce == 3u && gParams.maxBounces > 4u && deepSuffix.areaPdf > 0.f &&
            !previousDelta && previousDiffuse)
        {
            cacheSuffix.candidate.rootLobe = currentRoot;
            cacheSuffix.sourceX1 = deepSuffix.sourceX1;
            cacheSuffix.reconnectHit = deepSuffix.reconnectHit;
            cacheSuffix.areaPdf = deepSuffix.areaPdf;
            cacheSuffix.suffixDirection = deepSuffix.suffixDirection;
            // x3 and its incoming direction are shared. The sampled diffuse
            // event carries its own continuation weight downstream of x2.
            cacheSuffix.suffixLight = bs.weight;
            cacheSuffix.sharcDirection = bs.wo;
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
            !(bounce >= 2u && deepSuffix.areaPdf > 0.f && any(explicitThroughput > 0.f)) &&
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

#if !RTPT_GRIS_GENERATE
#if RTPT_DELTA_NRD
// Compatibility wrapper: ordinary D/S transport and its RNG are unchanged.
float3 rtptTraceContinuation(
    ShadingData primarySD, IMaterialInstance primaryMI, uint primaryLobes,
    RTPTSamplingContext primarySampling, inout SampleGenerator sg,
    out float firstHitDistance, out uint firstHitDistanceState,
    inout RTPTSharcStats sharcStats, uint rootCoverage)
{
    RTPTDeltaGuide unused = {};
    return rtptTraceContinuationWithGuide(primarySD, primaryMI, primaryLobes, primarySampling, sg,
        firstHitDistance, firstHitDistanceState, sharcStats, rootCoverage, unused);
}
#endif
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
