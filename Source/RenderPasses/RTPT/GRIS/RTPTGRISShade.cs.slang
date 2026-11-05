#include "../PrimarySurface/RTPTPrimarySurfaceTypes.slang"
#include "RTPTGRISTypes.slang"

ConstantBuffer<RTPTPrimarySettings> gPrimarySettings;
#if RTPT_GRIS_ALTERNATING
StructuredBuffer<GrisDualWinner> gGRISCandidates;
StructuredBuffer<GrisAlternatingFresh> gGRISFresh;
RWStructuredBuffer<GrisDualShadedIndirect> gGRISShadedIndirect;
#else
StructuredBuffer<GrisCandidate> gGRISCandidates;
#if RTPT_GRIS_SPATIAL
StructuredBuffer<GrisLocalPrefix> gGRISLocalPrefixes;
#endif
RWStructuredBuffer<GrisShadedIndirect> gGRISShadedIndirect;
#endif

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gPrimarySettings.frameDim)) return;
    const uint index = pixel.y * gPrimarySettings.frameDim.x + pixel.x;

#if RTPT_GRIS_ALTERNATING
    const GrisDualWinner winner = gGRISCandidates[index];
    const GrisAlternatingFresh fresh = gGRISFresh[index];
    const uint sourceSlot = rtptGrisSourceSlot(fresh.raw.candidate.rootLobe);
    GrisDualShadedIndirect result = {};
    result.preparedMask = fresh.preparedMask;
    result.firstHit[sourceSlot] = fresh.raw.candidate.firstHit;
    result.firstHit[sourceSlot ^ 1u] = fresh.inactiveFirstHit;
    result.radiance[0] = fresh.prefix[0].localRadiance;
    result.radiance[1] = fresh.prefix[1].localRadiance;
    if (winner.hasWinner != 0u)
    {
        result.radiance[0] += winner.F_D * winner.W;
        result.radiance[1] += winner.F_S * winner.W;
    }
#else
    const GrisCandidate candidate = gGRISCandidates[index];
    GrisShadedIndirect result = {};
    result.firstHit.distanceState = kRTPTDistanceUntraced;
    if (candidate.prepared)
    {
        result.rootLobe = candidate.rootLobe;
        result.firstHit = candidate.firstHit;
        if (candidate.hasWinner)
            result.radiance = candidate.F * candidate.W;
#if RTPT_GRIS_SPATIAL
        result.radiance += gGRISLocalPrefixes[index].localRadiance;
#endif
        result.state = any(result.radiance != 0.f)
            ? uint(GrisRecordState::GrisPreparedWinner)
            : uint(GrisRecordState::GrisPreparedZero);
    }
#endif
    gGRISShadedIndirect[index] = result;
}
