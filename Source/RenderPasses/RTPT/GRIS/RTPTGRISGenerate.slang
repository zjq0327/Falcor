#if RTPT_GRIS_SPATIAL
RWStructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
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
    GrisCandidate candidate = {};
    candidate.firstHit.distanceState = kRTPTDistanceUntraced;
    RTPTSharcStats sharcStats = {};
#if RTPT_GRIS_SPATIAL
    GrisSpatialRecord spatial = {};
#endif

    const uint sampleIndex = gParams.sampleOffset + gParams.seed * 0x9e3779b9u;
    SampleGenerator sg = SampleGenerator(pixel, sampleIndex);
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

#if RTPT_REGIR_ONLY
                const uint rootCoverage = rtptReGIRRootCoverage();
#else
                float3 diDiffuse, diSpecular;
                const uint rootCoverage = rtptLoadPrimaryDICoverage(pixel, sampleIndex, diDiffuse, diSpecular);
#endif
                // Keep picker draws separate from the path's scattering and light draws.
                SampleGenerator terminalRng = SampleGenerator(pixel, sampleIndex ^ 0xa511e9b3u);
                TerminalPicker picker = {};
                GrisFirstHit firstHit;
                rtptTraceNRDContinuation(sd, mi, activeLobe, sampling, sg,
                    firstHit.hitT, firstHit.distanceState, sharcStats, rootCoverage, rootProbability, picker, terminalRng);

                if (picker.winnerH > 0.f)
                {
                    const float W = picker.sumH / picker.winnerH;
                    if (isfinite(W) && all(isfinite(picker.winnerF * W)))
                    {
                        candidate.F = picker.winnerF;
                        candidate.W = W;
                        candidate.terminalKind = picker.winnerKind;
                        candidate.hasWinner = true;
                        candidate.firstHit = firstHit;
#if RTPT_GRIS_SPATIAL
                        spatial = picker.winnerSpatial;
#endif
                    }
                }
            }
        }
#endif
    }
#if RTPT_GRIS_SPATIAL
    spatial.candidate = candidate;
    spatial.M = candidate.prepared ? 1.f : 0.f;
    gGRISSpatialInput[index] = spatial;
#else
    gGRISCandidates[index] = candidate;
#endif
#if ENABLE_SHARC && SHARC_QUERY
    // MainRender adds its own path counters and primary-surface diagnostics.
    gSharcStats[pixel] = float4(float(sharcStats.cacheTerminations), float(sharcStats.radianceRays),
        float(sharcStats.attemptedQueries), 0.f);
#endif
}
