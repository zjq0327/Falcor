#include "RTPTGRISReuse.slang"
#include "RTPTGRISReference.slang"

StructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
RWStructuredBuffer<GrisSpatialRecord> gGRISSpatialOutput;

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
    GrisSpatialRecord inputs[kGrisMaxReuseInputs];
    float3 sourceCameras[kGrisMaxReuseInputs];
    uint inputCount = 0u;
    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0x76b5a2d1u);
#if RTPT_GRIS_DUAL_FIRST_HIT
    GrisDualFirstHits sourceHits[kGrisMaxReuseInputs];
    rtptGrisGatherSpatialNeighbors(pixel, gGRISSpatialInput, gScene.camera.getPosition(), inputCount, inputs,
        sourceCameras, sourceHits);
    result = rtptGrisMergeDualTails(canonical, gGRISDualFirstHits[index], inputs, sourceHits, sourceCameras, inputCount, rng);
#else
    uint sourceLightEpochs[kGrisMaxReuseInputs];
    rtptGrisGatherSpatialNeighbors(pixel, gGRISSpatialInput, gScene.camera.getPosition(), inputCount, inputs,
        sourceCameras, rtptGrisCurrentLightEpoch(), sourceLightEpochs);
    result = rtptGrisMergeStoredPrefix(canonical, inputs, sourceCameras, sourceLightEpochs, inputCount, rng);
#endif
#endif
    gGRISSpatialOutput[index] = result;
}
