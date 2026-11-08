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
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    GrisSpatialRecord inputs[2];
    float3 sourceCameras[2];
    uint inputCount = 0u;
#if RTPT_GRIS_SPATIAL_REUSE
    const uint neighborX = pixel.x ^ 1u;
    if (neighborX < gPrimarySettings.frameDim.x)
    {
        inputs[inputCount] = gGRISSpatialInput[pixel.y * gPrimarySettings.frameDim.x + neighborX];
        sourceCameras[inputCount++] = gScene.camera.getPosition();
    }
#endif
    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0x76b5a2d1u);
    result = rtptGrisMergeReference(canonical, inputs, sourceCameras, inputCount, pixel, rng);
#endif
    gGRISSpatialOutput[index] = result;
}
