#include "RTPTGRISReuse.slang"
#include "RTPTGRISReference.slang"
#include "../PrimarySurface/RTPTReprojection.slangh"

struct GrisTemporalSettings
{
    float4x4 previousViewProj;
    uint2 previousFrameDim;
    uint historyValid;
    float3 previousCameraPosition;
#if RTPT_GRIS_SUFFIX_REPLAY
    uint suffixReplayLightChange;
    uint suffixReplayGeometryChange;
    uint suffixReplayMovedInstanceBits;
    uint suffixReplayValidateUnchanged;
#endif
#if RTPT_GRIS_SHARC_REPLAY
    uint suffixReplaySharcChange;
#endif
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
#if RTPT_GRIS_SUFFIX_REPLAY
    source.suffixInstanceMask = h.suffixInstanceMask;
    source.terminalBounce = h.terminalBounce;
    source.postX2RngState = h.postX2RngState;
#endif
#if RTPT_GRIS_SHARC_REPLAY
    source.sharcKey = h.sharcKey;
    source.sharcGain = h.sharcGain;
#elif RTPT_GRIS_REGIR_REPLAY
    source.innerRISWeight = h.innerRISWeight;
#endif
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
    GrisSpatialRecord inputs[kGrisMaxReuseInputs];
    float3 sourceCameras[kGrisMaxReuseInputs];
    uint sourceLightEpochs[kGrisMaxReuseInputs];
    uint inputCount = 0u;
#if RTPT_GRIS_SUFFIX_REPLAY
    GrisSuffixReplaySettings replay;
    replay.historyIndex = kGrisMaxReuseInputs;
    replay.lightChanged = gGRISTemporalSettings.suffixReplayLightChange != 0u;
    replay.geometryChanged = gGRISTemporalSettings.suffixReplayGeometryChange != 0u;
    replay.movedInstanceBits = gGRISTemporalSettings.suffixReplayMovedInstanceBits;
    replay.validateUnchanged = gGRISTemporalSettings.suffixReplayValidateUnchanged != 0u &&
        !replay.lightChanged && !replay.geometryChanged;
#if RTPT_GRIS_SHARC_REPLAY
    replay.sharcChanges = gGRISTemporalSettings.suffixReplaySharcChange;
#endif
#endif
    if (rtptGrisLoadSelectedHistory(pixel, inputs[inputCount]))
    {
#if RTPT_GRIS_SUFFIX_REPLAY
        replay.historyIndex = inputCount;
#endif
        sourceLightEpochs[inputCount] = rtptGrisPreviousLightEpoch();
        sourceCameras[inputCount++] = gGRISTemporalSettings.previousCameraPosition;
    }
    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0xc2b2ae35u);
    result = rtptGrisMergeReference(canonical, inputs, sourceCameras, sourceLightEpochs, inputCount, pixel, rng
#if RTPT_GRIS_SUFFIX_REPLAY
        , replay
#endif
    );
#endif
    gGRISSpatialOutput[index] = result;
}
