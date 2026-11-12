#define RTPT_GRIS_SPATIAL 1
#include "RTPTGRISTypes.slang"
#include "../PrimarySurface/RTPTPrimarySurfaceTypes.slang"

ConstantBuffer<RTPTPrimarySettings> gPrimarySettings;
StructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
RWStructuredBuffer<GrisTemporalFreshHistory> gGRISHistory;

[numthreads(8, 8, 1)]
void main(uint3 threadID : SV_DispatchThreadID)
{
    const uint2 pixel = threadID.xy;
    if (any(pixel >= gPrimarySettings.frameDim)) return;
    const uint index = pixel.y * gPrimarySettings.frameDim.x + pixel.x;
    const GrisSpatialRecord source = gGRISSpatialInput[index];
    GrisTemporalFreshHistory history = {};
    history.sourceX1 = source.sourceX1;
    history.ownerPrimaryHit = source.ownerPrimaryHit;
    history.rootLobe = source.candidate.rootLobe;
    history.reconnectHit = source.reconnectHit;
    history.sourceAreaPdf = source.areaPdf;
    history.suffixDirection = source.suffixDirection;
    history.suffixLight = source.suffixLight;
    history.lightPdfOrStableID = source.lightPdfOrStableID;
    history.terminalAndFlags = source.candidate.terminalKind |
        (source.lightIsAnalytic ? kGrisHistoryAnalytic : 0u);
    history.F = source.candidate.F;
    history.W = source.candidate.W;
    history.M = source.candidate.M;
#if RTPT_GRIS_SUFFIX_REPLAY
    history.suffixInstanceMask = source.suffixInstanceMask;
    history.terminalBounce = source.terminalBounce;
    history.postX2RngState = source.postX2RngState;
#endif
#if RTPT_GRIS_SHARC_REPLAY
    history.sharcKey = source.sharcKey;
    history.sharcGain = source.sharcGain;
#elif RTPT_GRIS_REGIR_REPLAY_MODE
    history.innerRISWeight = source.innerRISWeight;
#endif
    gGRISHistory[index] = history;
}
