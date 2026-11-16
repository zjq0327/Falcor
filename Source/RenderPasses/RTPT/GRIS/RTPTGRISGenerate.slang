// D-only Generate specializes the fixed-x2 dual-first-hit path.
#if RTPT_GRIS_DUAL_FIRST_HIT && RTPT_GRIS_X2_SUFFIX_MODE == 0
#define RTPT_GRIS_GENERATE_DIFFUSE_ONLY 1
#endif
#include "../DirectLighting/RTPTDICoverage.slang"
#include "../RTPTContinuation.slang"
#if RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
#include "RTPTGRISReference.slang"
#endif

#if RTPT_GRIS_ALTERNATING
RWStructuredBuffer<GrisAlternatingFresh> gGRISFresh;
#elif RTPT_GRIS_SPATIAL
RWStructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
RWStructuredBuffer<GrisLocalContributions> gGRISLocalPrefixes;
#if RTPT_GRIS_DUAL_FIRST_HIT
RWStructuredBuffer<GrisDualFirstHits> gGRISDualFirstHits;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
RWStructuredBuffer<float4> gGRISSpatialDeepIncident;
#endif
#endif
#else
RWStructuredBuffer<GrisCandidate> gGRISCandidates;
#endif

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gParams.frameDim)) return;
    const uint index = pixel.y * gParams.frameDim.x + pixel.x;

    // Every invocation overwrites its record, including primary misses and
    // surfaces outside the supported domain.
    RTPTSharcStats sharcStats = {};
#if RTPT_GRIS_ALTERNATING
    GrisAlternatingFresh fresh = {};
    const uint sourceSlot = (gPrimarySettings.frameStamp - 1u) & 1u;
    fresh.raw.candidate.rootLobe = sourceSlot == 0u ? uint(GrisRootComponent::GrisDiffuse) : uint(GrisRootComponent::GrisSpecular);
    fresh.raw.candidate.firstHit.distanceState = kRTPTDistanceUntraced;
    fresh.inactiveFirstHit.distanceState = kRTPTDistanceUntraced;
#else
    GrisCandidate candidate = {};
    candidate.firstHit.distanceState = kRTPTDistanceUntraced;
#if RTPT_GRIS_SPATIAL
    GrisSpatialRecord spatial = {};
    spatial.candidate.firstHit.distanceState = kRTPTDistanceUntraced;
    GrisLocalContributions local = {};
#if RTPT_GRIS_DUAL_FIRST_HIT
    GrisDualFirstHits dualFirstHits = {};
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
    float4 spatialDeepIncident = {};
#endif
    local.firstHit[0].distanceState = kRTPTDistanceUntraced;
    local.firstHit[1].distanceState = kRTPTDistanceUntraced;
#else
    GrisPathBuilder pathBuilder = {};
#endif
#endif
#endif

    const uint sampleIndex = gParams.sampleOffset + gParams.seed * 0x9e3779b9u;
#if !RTPT_GRIS_ALTERNATING
    SampleGenerator sg = SampleGenerator(pixel, sampleIndex);
#if RTPT_GRIS_SPATIAL
    SampleGenerator terminalRng = SampleGenerator(pixel, sampleIndex ^ 0xa511e9b3u);
#endif
#endif
    RTPTPrimarySurface primary;
    if (rtptTryLoadPrimary(pixel, sampleIndex, primary))
    {
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const HitInfo hit = HitInfo(primary.packedHit);
        if (hit.getType() == HitType::Triangle)
        {
#if RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
            spatial.ownerPrimaryHit = primary.packedHit;
#endif
            const TriangleHit triangleHit = hit.getTriangleHit();
#if defined(RTPT_GRIS_GENERATE_DIFFUSE_ONLY) && RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING && RTPT_GRIS_DUAL_FIRST_HIT
            ShadingData sd;
            GrisDualSpatialVertex primaryVertex;
            const bool canonicalPrimary = rtptGRISPathReuseEnabled() &&
                rtptGrisLoadDualSpatialVertex(primary.packedHit, primaryVertex) &&
                rtptGrisShadeDualSpatialVertex(primaryVertex, gScene.camera.getPosition() - primaryVertex.vertex.posW, sd);
            if (!canonicalPrimary)
            {
                const VertexData vertex = gScene.getVertexData(triangleHit);
                const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
                sd = gScene.materials.prepareShadingData(vertex, materialID, -primary.rayDirection);
                sd.mtl.setActiveLobes(uint(LobeType::Reflection));
            }
#else
            const VertexData vertex = gScene.getVertexData(triangleHit);
            const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
            ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -primary.rayDirection);
            sd.mtl.setActiveLobes(uint(LobeType::Reflection));
#if RTPT_GRIS_SPATIAL && !RTPT_GRIS_ALTERNATING
            // Match the camera view used to evaluate a represented prefix.
            ShadingData representedPrimary;
            const bool canonicalPrimary = rtptGRISPathReuseEnabled() &&
                rtptGrisRefPrimary(primary.packedHit, gScene.camera.getPosition(), representedPrimary);
            if (canonicalPrimary) sd = representedPrimary;
#endif
#endif
            const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
            const uint lobes = mi.getLobeTypes(sd);
            float3 diDiffuse, diSpecular;
            uint rootCoverage = rtptLoadPrimaryDICoverage(pixel, sampleIndex, diDiffuse, diSpecular);
#if RTPT_REGIR_TRANSPORT
            // Match Main when the primary DI record did not claim the light domain.
            if (rootCoverage == 0u) rootCoverage = rtptReGIRRootCoverage();
#endif
#if RTPT_GRIS_ALTERNATING
            [unroll]
            for (uint slot = 0u; slot < 2u; ++slot)
            {
                const uint activeLobe = slot == 0u ? uint(LobeType::DiffuseReflection) : uint(LobeType::SpecularReflection);
                if ((lobes & activeLobe) == 0u) continue;
                const bool generateSuffix = slot == sourceSlot;
                sd.mtl.setActiveLobes(activeLobe);
                const RTPTSamplingContext sampling = slot == 0u ? rtptMakeSamplingContext(sd, mi) : rtptBSDFSamplingContext();
                SampleGenerator sg = SampleGenerator(pixel, sampleIndex ^ (slot == 0u ? 0x87fb1a4du : 0x98d6d257u));
                GrisLocalPrefix prefix = {};
                GrisSpatialRecord suffix = {};
                GrisFirstHit firstHit;
#ifdef RTPT_GRIS_SHARC_X1_BLEND
                bool mixedX1Cache;
#endif
                prefix.localRadiance = rtptTraceContinuation(sd, mi, activeLobe, sampling, sg,
                    firstHit.hitT, firstHit.distanceState, sharcStats, rootCoverage, 1.f, prefix, suffix, generateSuffix
#ifdef RTPT_GRIS_SHARC_X1_BLEND
                    , mixedX1Cache
#endif
                );
                fresh.prefix[slot] = prefix;
                fresh.preparedMask |= 1u << slot;
#ifdef RTPT_GRIS_SHARC_X1_BLEND
                if (mixedX1Cache) fresh.preparedMask |= 1u << (slot + kGrisX1CacheBlendShift);
#endif
                if (generateSuffix)
                {
                    suffix.candidate.rootLobe = fresh.raw.candidate.rootLobe;
                    suffix.candidate.firstHit = firstHit;
                    fresh.raw = suffix;
                }
                else fresh.inactiveFirstHit = firstHit;
            }
#else
            const bool hasDiffuse = (lobes & uint(LobeType::DiffuseReflection)) != 0u;
            const bool hasSpecular = (lobes & uint(LobeType::SpecularReflection)) != 0u;

#if RTPT_GRIS_SPATIAL
            if (hasDiffuse || hasSpecular)
            {
                spatial.candidate.prepared = true;
                spatial.candidate.M = 1.f;
#if RTPT_GRIS_DUAL_FIRST_HIT
                GrisDualX2Sample x2Samples[2] = {};
                GrisDualDeepSample deepSamples[2] = {};
                GrisDualExplicitTerminal bsdfTerminals[2] = {};
                GrisDualExplicitTerminal lateTerminals[2] = {};
                SampleGenerator eventRng = SampleGenerator(pixel, sampleIndex ^ 0xf5942b8bu);
                const uint lateCount = rtptGrisDualExplicitLateCount(gParams.maxBounces);
#if RTPT_GRIS_X2_SUFFIX_MODE >= 2
                // Draw independently of both first-hit walks. Run the prefix-only
                // walk first so the suffix executes once per wave under one mask.
                SampleGenerator rootRng = SampleGenerator(pixel, sampleIndex ^ 0x3b16d74fu);
                const float2 rootProbability = hasDiffuse && hasSpecular ? float2(0.5f) : float2(hasDiffuse ? 1.f : 0.f, hasSpecular ? 1.f : 0.f);
                const uint suffixRoot = sampleNext1D(rootRng) < rootProbability.x ? 0u : 1u;
                uint lateSlots[2] = {};
                [unroll] for (uint slot = 0u; slot < 2u; ++slot)
                {
                    const uint lobe = slot == 0u ? uint(LobeType::DiffuseReflection) : uint(LobeType::SpecularReflection);
                    if (lateCount != 0u && (lobes & lobe) != 0u)
                        lateSlots[slot] = min(uint(sampleNext1D(eventRng) * lateCount), lateCount - 1u);
                }
#endif
#if defined(RTPT_GRIS_SINGLE_DEEP_PATH)
                // Draw before tracing the roots so each walk can finish in a
                // single invocation without checkpointing its x3 state.
#if defined(RTPT_GRIS_GENERATE_DIFFUSE_ONLY)
                const bool selectDeepRoot = false;
#else
                const bool selectDeepRoot = lateCount != 0u && hasDiffuse && hasSpecular;
#endif
                SampleGenerator deepRootRng = SampleGenerator(pixel, sampleIndex ^ 0x3b16d74fu);
                const uint deepRoot = selectDeepRoot && sampleNext1D(deepRootRng) >= 0.5f ? 1u : 0u;
                const float inverseDeepProbability = selectDeepRoot ? 2.f : 1.f;
#endif
#if RTPT_GRIS_DUAL_SHARC
                GrisSpatialRecord cacheProposals[2] = {};
                float3 cacheIncident[2] = {};
#endif
#endif
                [unroll]
#if defined(RTPT_GRIS_GENERATE_DIFFUSE_ONLY)
                for (uint slot = 0u; slot < 1u; ++slot)
#elif RTPT_GRIS_X2_SUFFIX_MODE >= 2
                for (uint walk = 0u; walk < 2u; ++walk)
#else
                for (uint slot = 0u; slot < 2u; ++slot)
#endif
                {
#if RTPT_GRIS_X2_SUFFIX_MODE >= 2
                    const uint slot = walk == 0u ? 1u - suffixRoot : suffixRoot;
#endif
                    const uint activeLobe = slot == 0u ? uint(LobeType::DiffuseReflection) : uint(LobeType::SpecularReflection);
                    if ((lobes & activeLobe) == 0u) continue;
                    const uint currentRoot = slot == 0u ? uint(GrisRootComponent::GrisDiffuse) : uint(GrisRootComponent::GrisSpecular);
                    ShadingData component = sd;
                    component.mtl.setActiveLobes(activeLobe);
                    const RTPTSamplingContext sampling = slot == 0u
                        ? rtptMakeSamplingContext(component, mi) : rtptBSDFSamplingContext();
                    SampleGenerator pathRng = SampleGenerator(pixel, sampleIndex ^ (slot == 0u ? 0x87fb1a4du : 0x98d6d257u));
                    GrisLocalPrefix prefix = {};
                    prefix.rootLobe = currentRoot;
                    GrisFirstHit firstHit;
#if RTPT_GRIS_DUAL_FIRST_HIT
                    if (rtptGRISSupportsSurface(component, lobes & activeLobe))
                        dualFirstHits.attemptedMask |= 1u << slot;
#if RTPT_GRIS_X2_SUFFIX_MODE >= 2
                    const uint lateSlot = lateSlots[slot];
#else
                    const uint lateSlot = lateCount == 0u ? 0u : min(uint(sampleNext1D(eventRng) * lateCount), lateCount - 1u);
#endif
                    const float3 localRadiance = rtptTraceContinuation(component, mi, activeLobe, sampling, pathRng,
                        firstHit.hitT, firstHit.distanceState, sharcStats, rootCoverage, 1.f, prefix,
                        x2Samples[slot], deepSamples[slot], lateSlot,
#if defined(RTPT_GRIS_GENERATE_DIFFUSE_ONLY)
                        canonicalPrimary,
#endif
                        bsdfTerminals[slot], lateTerminals[slot]
#if defined(RTPT_GRIS_SINGLE_DEEP_PATH)
                        , (!selectDeepRoot || slot == deepRoot) ? inverseDeepProbability : 0.f
#endif
#if RTPT_GRIS_DUAL_SHARC
                        , cacheProposals[slot], cacheIncident[slot]
#endif
#if RTPT_GRIS_X2_SUFFIX_MODE >= 2
                        , walk == 0u ? 0.f : rootProbability[suffixRoot]
#endif
                    );
                    dualFirstHits.x1[slot] = prefix.dualX1;
                    dualFirstHits.firstHitAreaPdf[slot] = prefix.dualFirstPdf;
                    local.firstHit[slot] = firstHit;
#else
                    const float3 localRadiance = rtptTraceContinuation(component, mi, activeLobe, sampling, pathRng,
                        firstHit.hitT, firstHit.distanceState, sharcStats, rootCoverage, 1.f,
                        prefix, spatial, pathBuilder, terminalRng);
                    if (spatial.candidate.hasWinner && spatial.candidate.rootLobe == currentRoot)
                        spatial.candidate.firstHit = firstHit;
#endif
                    if (slot == 0u) local.diffuse += localRadiance;
                    else local.specular += localRadiance;
                }
#if RTPT_GRIS_DUAL_FIRST_HIT
                spatial = rtptGrisBuildDualFresh(spatial, dualFirstHits, x2Samples, deepSamples,
                    bsdfTerminals, lateTerminals,
#if RTPT_GRIS_DUAL_SHARC
                    cacheProposals, cacheIncident,
#endif
                    terminalRng
#if RTPT_GRIS_X2_SUFFIX_MODE >= 2
                    , rootProbability
#endif
#if defined(RTPT_GRIS_SINGLE_DEEP_PATH)
                    , inverseDeepProbability
#endif
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
                    , spatialDeepIncident
#endif
                );
#else
                // One stratified D+S group, one shared terminal winner, M=1.
                rtptGRISFinalizePath(pathBuilder, spatial);
#endif
            }
#else
            // Legacy non-suffix capture is not selected by the fixed-x2 host.
            if (hasDiffuse || hasSpecular)
            {
                candidate.prepared = true;
                candidate.M = 1.f;
                bool chooseDiffuse = hasDiffuse;
                float rootProbability = 1.f;
                if (hasDiffuse && hasSpecular)
                {
                    rootProbability = 0.5f;
                    chooseDiffuse = sampleNext1D(sg) < rootProbability;
                }
                candidate.rootLobe = chooseDiffuse ? uint(GrisRootComponent::GrisDiffuse) : uint(GrisRootComponent::GrisSpecular);
                const uint activeLobe = chooseDiffuse ? uint(LobeType::DiffuseReflection) : uint(LobeType::SpecularReflection);
                sd.mtl.setActiveLobes(activeLobe);
                const RTPTSamplingContext sampling = chooseDiffuse ? rtptMakeSamplingContext(sd, mi) : rtptBSDFSamplingContext();

                // Keep picker draws separate from the path's scattering and light draws.
                SampleGenerator terminalRng = SampleGenerator(pixel, sampleIndex ^ 0xa511e9b3u);
                TerminalPicker picker = {};
                rtptTraceContinuation(sd, mi, activeLobe, sampling, sg,
                    candidate.firstHit.hitT, candidate.firstHit.distanceState, sharcStats, rootCoverage, rootProbability, picker, terminalRng);

                if (picker.winnerH > 0.f)
                {
                    const float W = picker.sumH / picker.winnerH;
                    if (isfinite(W) && all(isfinite(picker.winnerF * W)))
                    {
                        candidate.F = picker.winnerF;
                        candidate.W = W;
                        candidate.terminalKind = picker.winnerKind;
                        candidate.hasWinner = true;
                    }
                }
            }
#endif
#endif
        }
#endif
    }
#if RTPT_GRIS_ALTERNATING
    gGRISFresh[index] = fresh;
#elif RTPT_GRIS_SPATIAL
#if RTPT_GRIS_DUAL_FIRST_HIT
    gGRISDualFirstHits[index] = dualFirstHits;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
    gGRISSpatialDeepIncident[index] = spatialDeepIncident;
#endif
#elif SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    GrisLocalPrefix selectedPrefix = {};
    selectedPrefix.x1Hit = spatial.sourceX1;
    selectedPrefix.rootLobe = spatial.candidate.rootLobe;
    SampleGenerator normalizationRng = SampleGenerator(pixel, sampleIndex ^ 0x687f083du);
    rtptGrisNormalizeGenerated(spatial, selectedPrefix, normalizationRng);
#endif
    gGRISSpatialInput[index] = spatial;
    gGRISLocalPrefixes[index] = local;
#else
    gGRISCandidates[index] = candidate;
#endif
#if ENABLE_SHARC && SHARC_QUERY
    // MainRender adds its own path counters and primary-surface diagnostics.
    gSharcStats[pixel] = float4(float(sharcStats.cacheTerminations), float(sharcStats.radianceRays),
        float(sharcStats.attemptedQueries), 0.f);
#endif
}
