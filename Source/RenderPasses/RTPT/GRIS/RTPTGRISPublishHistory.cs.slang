#define RTPT_GRIS_SPATIAL 1
#include "RTPTGRISTypes.slang"
#include "../PrimarySurface/RTPTPrimarySurfaceTypes.slang"

ConstantBuffer<RTPTPrimarySettings> gPrimarySettings;
#if RTPT_GRIS_ALTERNATING
StructuredBuffer<GrisAlternatingFresh> gGRISFresh;
#else
StructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
StructuredBuffer<GrisLocalPrefix> gGRISLocalPrefixes;
#endif
RWStructuredBuffer<GrisTemporalFreshHistory> gGRISHistory;

[numthreads(8, 8, 1)]
void main(uint3 threadID : SV_DispatchThreadID)
{
    const uint2 pixel = threadID.xy;
    if (any(pixel >= gPrimarySettings.frameDim)) return;
    const uint index = pixel.y * gPrimarySettings.frameDim.x + pixel.x;
#if RTPT_GRIS_ALTERNATING
    const GrisAlternatingFresh fresh = gGRISFresh[index];
    const GrisSpatialRecord source = fresh.raw;
    const GrisLocalPrefix prefix = fresh.prefix[rtptGrisSourceSlot(source.candidate.rootLobe)];
#else
    const GrisLocalPrefix prefix = gGRISLocalPrefixes[index];
    const GrisSpatialRecord source = gGRISSpatialInput[index];
#endif

    GrisTemporalFreshHistory history = {};
    history.sourceX1 = prefix.x1Hit;
    history.sourceFirstDir = prefix.firstDirW;
    history.rootLobe = source.candidate.rootLobe;
    history.reconnectHit = source.reconnectHit;
    history.sourceAreaPdf = source.areaPdf;
    history.suffixDirection = source.suffixDirection;
    history.suffixLight = source.suffixLight;
    history.lightPdfOrStableID = source.lightPdfOrStableID;
    history.terminalAndFlags = source.candidate.terminalKind | (source.lightIsAnalytic ? kGrisHistoryAnalytic : 0u);
    gGRISHistory[index] = history;
}
