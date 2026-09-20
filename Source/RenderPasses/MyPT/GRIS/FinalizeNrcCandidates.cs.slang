import Params;
import NrcQuery;
import Utils.Math.HashUtils;

RWTexture2D<float4> gInitialEstimate;
RWTexture2D<uint4> gNrcCandidateDebug;
RWTexture2D<float4> gPathDebug;

[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint2 pixel = id.xy;
    if (any(pixel >= gDimensions)) return;
    uint index = pixelIndex(pixel);
    PathReservoir fresh = {};
    float3 estimate = 0.f;
    uint4 debug = 0;
    SampleGenerator selection = SampleGenerator(jenkinsHash(gPrimary[index].seed ^ 0xb5297a4du));
    for (uint candidate = 0; candidate < gCandidateCount; ++candidate)
    {
        NrcCandidate pending = gNrcCandidates[index * gCandidateCount + candidate];
        estimate += pending.explicitRadiance;
        if (pending.queryIndex != 0xffffffffu)
        {
            debug.x++;
            float3 C = NrcUnpackQueryRadiance(gNrcConstants, gNrcQueryRadiance[pending.queryIndex]);
            if (any(!isfinite(C))) { debug.z++; pending.tree.invalidCount++; C = 0.f; }
            if (any(C < 0.f)) debug.y++;
            C = max(float3(0.f), C);
            pending.cache.F = pending.beta * C;
            pending.cache.rcIrradiance = pending.suffix * C;
            SampleGenerator treeSelection = SampleGenerator(0u);
            treeSelection.rng.state = pending.selectionState;
            pending.tree.addContribution(pending.cache, treeSelection);
            estimate += pending.cache.F;
        }
        // M counts original candidate trees, not explicit/cache contributions.
        pending.tree.M = 1.f;
        fresh.mergeTree(pending.tree, selection);
    }
    fresh.finalizeRIS();
    gFresh[index] = fresh;
#if GRIS_HAS_INITIAL_ESTIMATE
    gInitialEstimate[pixel] = float4(estimate / float(gCandidateCount), 1.f);
#endif
#if GRIS_HAS_NRC_CANDIDATE_DEBUG
    if (gNrcRecordEnabled != 0u)
    {
        QueryTrainingPath record = gQueryTrainingPaths[queryTrainingIndex(queryTrainingCell(pixel))];
        if (all(record.owner == pixel)) debug.w = record.ownerCandidate + 1u;
    }
    gNrcCandidateDebug[pixel] = debug;
#endif
#if GRIS_HAS_PATH_DEBUG
    gPathDebug[pixel] = float4(fresh.sample.rcIndex == 0xffffffffu ? 0.f : float(fresh.sample.rcIndex),
        float(fresh.sample.surfaceScatters), float(fresh.sample.prefixFlags), float(fresh.sample.rcAfterFlags));
#endif
}
