#include "../DirectLighting/RTPTDICoverage.slang"
#include "../RTPTContinuation.slang"

#if RTPT_GRIS_ALTERNATING
RWStructuredBuffer<GrisAlternatingFresh> gGRISFresh;
#elif RTPT_GRIS_SPATIAL
RWStructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
RWStructuredBuffer<GrisLocalPrefix> gGRISLocalPrefixes;
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
    GrisLocalPrefix prefix = {};
#endif
#endif

    const uint sampleIndex = gParams.sampleOffset + gParams.seed * 0x9e3779b9u;
#if !RTPT_GRIS_ALTERNATING
    SampleGenerator sg = SampleGenerator(pixel, sampleIndex);
#endif
    RTPTPrimarySurface primary;
    if (rtptTryLoadPrimary(pixel, sampleIndex, primary))
    {
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const HitInfo hit = HitInfo(primary.packedHit);
        if (hit.getType() == HitType::Triangle)
        {
            const TriangleHit triangleHit = hit.getTriangleHit();
            const VertexData vertex = gScene.getVertexData(triangleHit);
            const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
            ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -primary.rayDirection);
            sd.mtl.setActiveLobes(uint(LobeType::Reflection));
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

            if (hasDiffuse || hasSpecular)
            {
                candidate.prepared = true;
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

#if RTPT_GRIS_SPATIAL
                prefix.localRadiance = rtptTraceContinuation(sd, mi, activeLobe, sampling, sg,
                    candidate.firstHit.hitT, candidate.firstHit.distanceState, sharcStats, rootCoverage, rootProbability, prefix, spatial);
                candidate.F = spatial.candidate.F;
                candidate.terminalKind = spatial.candidate.terminalKind;
                candidate.W = 1.f;
                candidate.hasWinner = rtptGrisHasTerminal(spatial);
#else
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
#endif
            }
#endif
        }
#endif
    }
#if RTPT_GRIS_ALTERNATING
    gGRISFresh[index] = fresh;
#elif RTPT_GRIS_SPATIAL
    spatial.candidate = candidate;
    gGRISSpatialInput[index] = spatial;
    gGRISLocalPrefixes[index] = prefix;
#else
    gGRISCandidates[index] = candidate;
#endif
#if ENABLE_SHARC && SHARC_QUERY
    // MainRender adds its own path counters and primary-surface diagnostics.
    gSharcStats[pixel] = float4(float(sharcStats.cacheTerminations), float(sharcStats.radianceRays),
        float(sharcStats.attemptedQueries), 0.f);
#endif
}
