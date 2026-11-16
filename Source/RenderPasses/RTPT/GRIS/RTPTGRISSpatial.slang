#include "RTPTGRISReuse.slang"
#include "RTPTGRISReference.slang"

StructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
RWStructuredBuffer<GrisSpatialRecord> gGRISSpatialOutput;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
StructuredBuffer<float4> gGRISSpatialDeepIncident;
#endif

[numthreads(8, 8, 1)]
void main(uint3 threadID : SV_DispatchThreadID)
{
    const uint2 pixel = threadID.xy;
    if (any(pixel >= gPrimarySettings.frameDim)) return;
    const uint index = pixel.y * gPrimarySettings.frameDim.x + pixel.x;
    GrisSpatialRecord canonical = gGRISSpatialInput[index];
    GrisSpatialRecord result = canonical;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH) && RTPT_GRIS_SPATIAL_REUSE && \
    (RTPT_GRIS_DUAL_FIRST_HIT || defined(RTPT_GRIS_STORED_PREFIX_REUSE))
    uint inputCount = 0u;
    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0x76b5a2d1u);
#if RTPT_GRIS_DUAL_FIRST_HIT
    GrisDualFirstHits sourceHits[kGrisMaxReuseInputs];
    uint sourceIndices[kGrisMaxReuseInputs];
    rtptGrisGatherSpatialNeighbors(pixel, gScene.camera.getPosition(), inputCount, sourceHits, sourceIndices);
    if (inputCount != 0u && rtptGrisRefDomainValid(canonical))
    {
        const GrisDualTemporalWinner selection = rtptGrisMergeDualTails(canonical, gGRISDualFirstHits[index],
            gGRISSpatialInput, sourceIndices, sourceHits, inputCount, rng
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
            , gGRISSpatialDeepIncident, index
#endif
        );
        // Reload the payload after selection to keep it out of the MIS loop.
        const GrisSpatialRecord center = gGRISSpatialInput[index];
        const uint winnerIndex = selection.inputIndex == inputCount ? index : sourceIndices[selection.inputIndex];
        GrisSpatialRecord winner = gGRISSpatialInput[winnerIndex];
        winner.candidate.F = selection.diffuse;
        winner.candidate.dualF = selection.specular;
        result = rtptGrisFinalizeDualTail(center, winner, selection.sum, selection.target, selection.count);
    }
#else
    GrisSpatialRecord inputs[kGrisMaxReuseInputs];
    float3 sourceCameras[kGrisMaxReuseInputs];
    rtptGrisGatherSpatialNeighbors(pixel, gScene.camera.getPosition(), inputCount, gGRISSpatialInput,
        inputs, sourceCameras);
    result = rtptGrisMergeStoredPrefix(canonical, inputs, sourceCameras, inputCount, rng);
#endif
#endif
    gGRISSpatialOutput[index] = result;
}
