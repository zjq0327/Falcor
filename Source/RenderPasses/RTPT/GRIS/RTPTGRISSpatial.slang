#include "RTPTGRISReuse.slang"

#if RTPT_GRIS_ALTERNATING
// Current-frame evaluation also uses this dispatch when Temporal is disabled.
RWStructuredBuffer<GrisDualWinner> gGRISSpatialOutput;
#else
StructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
StructuredBuffer<GrisLocalPrefix> gGRISLocalPrefixes;
RWStructuredBuffer<GrisCandidate> gGRISSpatialOutput;
#endif

[numthreads(8, 8, 1)]
void main(uint3 threadID : SV_DispatchThreadID)
{
    const uint2 pixel = threadID.xy;
    if (any(pixel >= gParams.frameDim)) return;
    const uint index = pixel.y * gParams.frameDim.x + pixel.x;
#if RTPT_GRIS_ALTERNATING
    GrisDualWinner result = {};
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    const GrisAlternatingProposal emptyHistory = {};
    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0xc2b2ae35u);
    result = rtptGrisMergeAlternating(pixel, gGRISFresh[index], emptyHistory, rng);
#endif
#else
    const GrisSpatialRecord canonical = gGRISSpatialInput[index];
    GrisCandidate result = canonical.candidate;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    const uint neighborX = pixel.x ^ 1u;
    if (result.prepared && neighborX < gParams.frameDim.x)
    {
        const uint neighborIndex = pixel.y * gParams.frameDim.x + neighborX;
        const GrisSpatialRecord neighbor = gGRISSpatialInput[neighborIndex];
        if (neighbor.candidate.prepared && result.rootLobe == neighbor.candidate.rootLobe)
        {
            SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0x76b5a2d1u);
            result = rtptGrisMerge(canonical, neighbor, gGRISLocalPrefixes[index], gGRISLocalPrefixes[neighborIndex], rng);
        }
    }
#endif
#endif
    gGRISSpatialOutput[index] = result;
}
