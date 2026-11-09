#include "RTPTGRISReuse.slang"
#include "RTPTGRISReference.slang"
#include "../PrimarySurface/RTPTReprojection.slangh"

struct GrisTemporalSettings
{
    float4x4 previousViewProj;
    uint2 previousFrameDim;
    uint historyValid;
    float3 previousCameraPosition;
};

ConstantBuffer<GrisTemporalSettings> gGRISTemporalSettings;
StructuredBuffer<GrisTemporalFreshHistory> gGRISHistory;
StructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
RWStructuredBuffer<GrisSpatialRecord> gGRISSpatialOutput;

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
bool rtptGrisLoadSelectedHistory(uint2 pixel, out GrisSpatialRecord source)
{
    source = {};
    if (gGRISTemporalSettings.historyValid == 0u) return false;
    RTPTPrimarySurface primary;
    if (!rtptTryLoadPrimary(pixel, gPrimarySettings.sampleIndex, primary)) return false;
    float2 previousPixel;
    float previousDepth;
    const uint2 previousDim = gGRISTemporalSettings.previousFrameDim;
    if (!rtptProjectPreviousPixel(primary.position + primary.motionW, previousDim,
        gGRISTemporalSettings.previousViewProj, previousPixel, previousDepth)) return false;
    const int2 previousIndex = int2(round(previousPixel));
    if (any(previousIndex < 0) || any(uint2(previousIndex) >= previousDim)) return false;
    const GrisTemporalFreshHistory h = gGRISHistory[uint(previousIndex.y) * previousDim.x + uint(previousIndex.x)];
    if (!(h.M > 0.f) || !HitInfo(h.ownerPrimaryHit).isValid()) return false;
    source.ownerPrimaryHit = h.ownerPrimaryHit;
    source.sourceX1 = h.sourceX1;
    source.reconnectHit = h.reconnectHit;
    source.areaPdf = h.sourceAreaPdf;
    source.suffixDirection = h.suffixDirection;
    source.suffixLight = h.suffixLight;
    source.lightPdfOrStableID = h.lightPdfOrStableID;
    source.lightIsAnalytic = (h.terminalAndFlags & kGrisHistoryAnalytic) != 0u;
    source.candidate.terminalKind = h.terminalAndFlags & ~kGrisHistoryAnalytic;
    source.candidate.rootLobe = h.rootLobe;
    source.candidate.F = h.F;
    source.candidate.W = h.W;
    source.candidate.M = min(h.M, 20.f);
    source.candidate.prepared = true;
    source.candidate.hasWinner = h.W > 0.f && rtptGrisHasTerminal(source);
    return true;
}
#endif

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
    uint sourceLightEpochs[2];
    uint inputCount = 0u;
    if (rtptGrisLoadSelectedHistory(pixel, inputs[inputCount]))
    {
        sourceLightEpochs[inputCount] = rtptGrisPreviousLightEpoch();
        sourceCameras[inputCount++] = gGRISTemporalSettings.previousCameraPosition;
    }
#if RTPT_GRIS_SPATIAL_REUSE
    const uint neighborX = pixel.x ^ 1u;
    if (neighborX < gPrimarySettings.frameDim.x)
    {
        inputs[inputCount] = gGRISSpatialInput[pixel.y * gPrimarySettings.frameDim.x + neighborX];
        sourceLightEpochs[inputCount] = rtptGrisCurrentLightEpoch();
        sourceCameras[inputCount++] = gScene.camera.getPosition();
    }
#endif
    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0xc2b2ae35u);
    result = rtptGrisMergeReference(canonical, inputs, sourceCameras, sourceLightEpochs, inputCount, pixel, rng);
#endif
    gGRISSpatialOutput[index] = result;
}
