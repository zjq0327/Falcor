#define RTPT_GRIS_SPATIAL 1
#include "RTPTGRISTypes.slang"
#include "../PrimarySurface/RTPTPrimarySurfaceTypes.slang"

ConstantBuffer<RTPTPrimarySettings> gPrimarySettings;
#if RTPT_GRIS_SEPARATE_OWNER
StructuredBuffer<RTPTPrimarySurface> gPrimarySurfaces;
RWStructuredBuffer<PackedHitInfo> gGRISPreviousPrimaryHits;
#endif
#include "RTPTGRISStorage.slang"
StructuredBuffer<GrisStoredRecord> gGRISSpatialInput;
RWStructuredBuffer<GrisTemporalFreshHistory> gGRISHistory;

[numthreads(8, 8, 1)]
void main(uint3 threadID : SV_DispatchThreadID)
{
    const uint2 pixel = threadID.xy;
    if (any(pixel >= gPrimarySettings.frameDim)) return;
    const uint index = pixel.y * gPrimarySettings.frameDim.x + pixel.x;
    const GrisStoredRecord source = gGRISSpatialInput[index];
    GrisTemporalFreshHistory history = {};
    history.sourceX1 = source.sourceX1;
#if RTPT_GRIS_SEPARATE_OWNER
    gGRISPreviousPrimaryHits[index] = gPrimarySurfaces[index].packedHit;
#else
    history.ownerPrimaryHit = source.ownerPrimaryHit;
#endif
    history.reconnectHit = source.reconnectHit;
    history.sourceAreaPdf = source.areaPdf;
    history.suffixDirection = source.suffixDirection;
    history.suffixLight = source.suffixLight;
    history.lightPdfOrIndex = source.lightPdfOrIndex;
    history.F = source.candidate.F;
#if RTPT_GRIS_DUAL_FIRST_HIT
    history.terminalAndFlags = source.candidate.packedFlags;
    history.dualF = source.candidate.dualF;
    history.dualExplicitRng = source.dualExplicitRng;
#else
    history.rootLobe = source.candidate.rootLobe;
    history.terminalAndFlags = source.candidate.terminalKind |
        (source.lightIsAnalytic ? kGrisHistoryAnalytic : 0u);
#endif
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
#endif
    gGRISHistory[index] = history;
}
