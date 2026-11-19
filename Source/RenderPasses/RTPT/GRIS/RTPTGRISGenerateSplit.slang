struct GrisGenerateRootResult
{
    GrisSpatialRecord winner;
    float weightSum;
    float winnerTarget;
    float3 localRadiance;
    GrisFirstHit localFirstHit;
#if ENABLE_SHARC && SHARC_QUERY
    float3 sharcStats;
#endif
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
    float4 deepIncident;
#endif
};

GrisGenerateRootResult rtptGrisGenerateRoot(
    uint2 pixel, uint sampleIndex, uint slot, out GrisSpatialRecord center, out uint attemptedMask)
{
    GrisGenerateRootResult result = {};
    result.localFirstHit.distanceState = kRTPTDistanceUntraced;
    center = {};
    center.candidate.firstHit.distanceState = kRTPTDistanceUntraced;
    attemptedMask = 0u;

    RTPTPrimarySurface primary;
    if (!rtptTryLoadPrimary(pixel, sampleIndex, primary)) return result;
    const HitInfo hit = HitInfo(primary.packedHit);
    if (hit.getType() != HitType::Triangle) return result;

    center.ownerPrimaryHit = primary.packedHit;
    const TriangleHit triangleHit = hit.getTriangleHit();
    const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd;
    bool canonicalPrimary = false;
    if (rtptGRISPathReuseEnabled())
    {
        const VertexData vertex = rtptGrisPrefixVertex(triangleHit);
        if (all(isfinite(vertex.posW)))
            canonicalPrimary = rtptGrisRefLoad(vertex, materialID, gScene.camera.getPosition() - vertex.posW, sd);
    }
    if (!canonicalPrimary)
    {
        const VertexData vertex = gScene.getVertexData(triangleHit);
        sd = gScene.materials.prepareShadingData(vertex, materialID, -primary.rayDirection);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
    }
    const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    const uint lobes = mi.getLobeTypes(sd);
    const bool hasDiffuse = (lobes & uint(LobeType::DiffuseReflection)) != 0u;
    const bool hasSpecular = (lobes & uint(LobeType::SpecularReflection)) != 0u;
#ifdef RTPT_GRIS_DELTA_REUSE
    const bool deltaSpecular = !hasSpecular && (lobes & uint(LobeType::DeltaReflection)) != 0u;
    const bool supportsDeltaRoot = deltaSpecular && rtptGRISPathReuseEnabled() && rtptGrisSupportsDeltaRoot(sd, lobes);
#else
    const bool deltaSpecular = false;
    const bool supportsDeltaRoot = false;
#endif
    if (!(hasDiffuse || hasSpecular || deltaSpecular)) return result;

    center.candidate.prepared = true;
    center.candidate.M = 1.f;
    if (rtptGRISSupportsSurface(sd, lobes & uint(LobeType::DiffuseReflection)))
        attemptedMask |= 1u;
    if (rtptGRISSupportsSurface(sd, lobes & uint(LobeType::SpecularReflection)) || supportsDeltaRoot)
        attemptedMask |= 2u;

    const uint activeLobe = slot == 0u ? uint(LobeType::DiffuseReflection) :
        uint(deltaSpecular ? LobeType::DeltaReflection : LobeType::SpecularReflection);
    if ((lobes & activeLobe) == 0u) return result;

    // The S worker evaluates the D proposal with the same guide lookup inputs
    // as the D worker, independently of the D path's sampled vertices.
    RTPTSamplingContext diffuseSampling = {};
    if (hasDiffuse)
    {
        ShadingData diffuse = sd;
        diffuse.mtl.setActiveLobes(uint(LobeType::DiffuseReflection));
        diffuseSampling = rtptMakeSamplingContext(diffuse, mi);
    }
    ShadingData component = sd;
    component.mtl.setActiveLobes(activeLobe);
    const RTPTSamplingContext sampling = slot == 0u ? diffuseSampling : rtptBSDFSamplingContext();
    SampleGenerator pathRng = SampleGenerator(pixel, sampleIndex ^ (slot == 0u ? 0x87fb1a4du : 0x98d6d257u));
    SampleGenerator freshEvaluationRng = SampleGenerator(pixel, sampleIndex ^ (0x517cc1b7u + slot));
    SampleGenerator freshSelectionRng = SampleGenerator(pixel, sampleIndex ^ (0x3c6ef373u + slot));
    SampleGenerator eventRng = SampleGenerator(pixel, sampleIndex ^ 0xf5942b8bu);
    const uint lateCount = rtptGrisDualExplicitLateCount(gParams.maxBounces);
    uint lateSlot = 0u;
    if (lateCount > 0u)
    {
        // The serial loop consumes a late-event draw if the D lobe exists,
        // including when its walk gets no reusable candidate.
        if (slot == 1u && hasDiffuse) sampleNext1D(eventRng);
        lateSlot = min(uint(sampleNext1D(eventRng) * lateCount), lateCount - 1u);
    }

    GrisLocalPrefix prefix = {};
    prefix.rootLobe = slot == 0u ? uint(GrisRootComponent::GrisDiffuse) : uint(GrisRootComponent::GrisSpecular);
    GrisDualX2Sample x2Sample = {};
    GrisDualExplicitTerminal explicitWinner;
    GrisFreshSlotReservoir freshSlot = {};
#if RTPT_GRIS_DUAL_SHARC
    GrisSpatialRecord cacheProposal = {};
#endif
    RTPTSharcStats sharcStats = {};
    float3 diDiffuse, diSpecular;
    const uint rootCoverage = rtptLoadPrimaryDICoverage(pixel, sampleIndex, diDiffuse, diSpecular);
    result.localRadiance = rtptTraceContinuation(component, mi, activeLobe, sampling, pathRng,
        result.localFirstHit.hitT, result.localFirstHit.distanceState, sharcStats, rootCoverage, 1.f, prefix,
        x2Sample, lateSlot, explicitWinner, slot, canonicalPrimary ? attemptedMask : 0u,
        supportsDeltaRoot, diffuseSampling, freshSlot, freshEvaluationRng, freshSelectionRng
#if RTPT_GRIS_DUAL_SHARC
        , cacheProposal
#endif
    );
#if ENABLE_SHARC && SHARC_QUERY
    result.sharcStats = float3(sharcStats.cacheTerminations, sharcStats.radianceRays, sharcStats.attemptedQueries);
#endif
    result.weightSum = freshSlot.weightSum;
    if (freshSlot.weightSum > 0.f && isfinite(freshSlot.weightSum))
    {
        const uint event = freshSlot.winnerEvent;
        result.winner = rtptGrisMakeDualFreshProposal(center.ownerPrimaryHit, prefix.dualX1, event, slot,
            x2Sample, explicitWinner, lateSlot
#if RTPT_GRIS_DUAL_SHARC
            , cacheProposal
#endif
#ifdef RTPT_GRIS_DELTA_REUSE
            , slot == 1u && supportsDeltaRoot
#endif
        );
        result.winner.candidate.F = freshSlot.winnerDiffuse;
        result.winner.candidate.dualF = freshSlot.winnerSpecular;
        result.winnerTarget = freshSlot.winnerTarget;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
        result.deepIncident = freshSlot.winnerDeepIncident;
#endif
    }
    return result;
}

// Dispatch D first. S/delta consumes the pending result and publishes Fresh in place.
[numthreads(8, 8, 1)]
void generateDiffuse(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gParams.frameDim)) return;

    const uint index = pixel.y * gParams.frameDim.x + pixel.x;
    const uint sampleIndex = gParams.sampleOffset + gParams.seed * 0x9e3779b9u;
    GrisSpatialRecord center;
    uint attemptedMask;
    const GrisGenerateRootResult diffuse = rtptGrisGenerateRoot(pixel, sampleIndex, 0u, center, attemptedMask);

    gGRISLocalPrefixes[index].diffuse = float3(0.f) + diffuse.localRadiance;
    gGRISLocalPrefixes[index].firstHit[0] = diffuse.localFirstHit;
#if ENABLE_SHARC && SHARC_QUERY
    gSharcStats[pixel] = float4(diffuse.sharcStats, 0.f);
#endif

    if (diffuse.weightSum > 0.f && isfinite(diffuse.weightSum))
    {
        GrisSpatialRecord pending = diffuse.winner;
        pending.candidate.W = diffuse.weightSum;
        pending.candidate.M = diffuse.winnerTarget;
        gGRISSpatialInput[index] = pending;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
        gGRISSpatialDeepIncident[index] = diffuse.deepIncident;
#endif
    }
    else
    {
        // Every pixel publishes its weight, including a miss or an absent D lobe.
        gGRISSpatialInput[index].candidate.W = diffuse.weightSum;
    }
}

[numthreads(8, 8, 1)]
void generateSpecularMerge(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gParams.frameDim)) return;

    const uint index = pixel.y * gParams.frameDim.x + pixel.x;
    const uint sampleIndex = gParams.sampleOffset + gParams.seed * 0x9e3779b9u;
    GrisSpatialRecord center;
    uint attemptedMask;
    const GrisGenerateRootResult specular = rtptGrisGenerateRoot(pixel, sampleIndex, 1u, center, attemptedMask);

    gGRISLocalPrefixes[index].specular = float3(0.f) + specular.localRadiance;
    gGRISLocalPrefixes[index].firstHit[1] = specular.localFirstHit;
#if ENABLE_SHARC && SHARC_QUERY
    // MainRender consumes the combined D and S counters.
    gSharcStats[pixel] = float4(gSharcStats[pixel].xyz + specular.sharcStats, 0.f);
#endif

#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
    float4 deepIncident = {};
    bool keepDiffuseIncident = false;
#endif
    if (center.candidate.prepared)
    {
        GrisFreshSlotReservoir diffuseWeight = {};
        diffuseWeight.weightSum = gGRISSpatialInput[index].candidate.W;
        const float total = diffuseWeight.weightSum + specular.weightSum;
        GrisSpatialRecord winner = center;
        float winnerTarget = 0.f;
        if (total > 0.f && isfinite(total))
        {
            GrisFreshSlotReservoir specularWeight = {};
            specularWeight.weightSum = specular.weightSum;
            SampleGenerator mergeRng = SampleGenerator(pixel, sampleIndex ^ 0xd1b54a35u);
            if (rtptGrisChooseFreshSlot(diffuseWeight, specularWeight, mergeRng) == 0u)
            {
                winner = gGRISSpatialInput[index];
                winnerTarget = winner.candidate.M;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
                keepDiffuseIncident = true;
#endif
            }
            else
            {
                winner = specular.winner;
                winnerTarget = specular.winnerTarget;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
                deepIncident = specular.deepIncident;
#endif
            }
        }
        center = rtptGrisFinalizeDualTail(center, winner, total, winnerTarget, float(countbits(attemptedMask)));
    }

    gGRISSpatialInput[index] = center;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
    if (!keepDiffuseIncident)
        gGRISSpatialDeepIncident[index] = deepIncident;
#endif
}
