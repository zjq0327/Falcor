#include "../PrimarySurface/RTPTPrimarySurfaceTypes.slang"
#include "RTPTGRISTypes.slang"

ConstantBuffer<RTPTPrimarySettings> gPrimarySettings;
#if RTPT_GRIS_ALTERNATING
StructuredBuffer<GrisDualWinner> gGRISCandidates;
StructuredBuffer<GrisAlternatingFresh> gGRISFresh;
RWStructuredBuffer<GrisDualShadedIndirect> gGRISShadedIndirect;
#else
#if RTPT_GRIS_SPATIAL
StructuredBuffer<GrisSpatialRecord> gGRISCandidates;
#else
StructuredBuffer<GrisCandidate> gGRISCandidates;
#endif
#if RTPT_GRIS_SPATIAL
StructuredBuffer<GrisLocalContributions> gGRISLocalPrefixes;
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
    result.preparedMask = fresh.preparedMask & kGrisPreparedLobesMask;
    result.firstHit[sourceSlot] = fresh.raw.candidate.firstHit;
    result.firstHit[sourceSlot ^ 1u] = fresh.inactiveFirstHit;
    result.radiance[0] = fresh.prefix[0].localRadiance;
    result.radiance[1] = fresh.prefix[1].localRadiance;
    if (winner.hasWinner != 0u)
    {
#ifdef RTPT_GRIS_SHARC_X1_BLEND
        const uint mixMask = fresh.preparedMask >> kGrisX1CacheBlendShift;
        const float explicitWeight = 1.f - gPrimarySettings.grisSharcX1Blend;
        if ((mixMask & 1u) != 0u) result.radiance[0] += (winner.F_D * winner.W) * explicitWeight;
        else result.radiance[0] += winner.F_D * winner.W;
        if ((mixMask & 2u) != 0u) result.radiance[1] += (winner.F_S * winner.W) * explicitWeight;
        else result.radiance[1] += winner.F_S * winner.W;
#else
        result.radiance[0] += winner.F_D * winner.W;
        result.radiance[1] += winner.F_S * winner.W;
#endif
    }
#else
#if RTPT_GRIS_SPATIAL
    const GrisCandidate candidate = gGRISCandidates[index].candidate;
#else
    const GrisCandidate candidate = gGRISCandidates[index];
#endif
    GrisShadedIndirect result = {};
#if RTPT_GRIS_DUAL_FIRST_HIT
    const GrisLocalContributions local = gGRISLocalPrefixes[index];
    result.firstHit = local.firstHit;
    if (candidate.prepared)
    {
        result.localDiffuse = local.diffuse;
        result.localSpecular = local.specular;
        if (candidate.hasWinner)
        {
            result.radiance[0] = candidate.F * candidate.W;
            result.radiance[1] = candidate.dualF * candidate.W;
        }
        result.state = candidate.hasWinner ? uint(GrisRecordState::GrisPreparedWinner) : uint(GrisRecordState::GrisPreparedZero);
    }
#else
    result.firstHit.distanceState = kRTPTDistanceUntraced;
    if (candidate.prepared)
    {
        result.rootLobe = candidate.rootLobe;
        result.firstHit = candidate.firstHit;
        if (candidate.hasWinner)
            result.radiance = candidate.F * candidate.W;
#if RTPT_GRIS_SPATIAL
            result.localDiffuse = gGRISLocalPrefixes[index].diffuse;
            result.localSpecular = gGRISLocalPrefixes[index].specular;
#endif
        result.state = any(result.radiance != 0.f) || any(result.localDiffuse != 0.f) || any(result.localSpecular != 0.f)
            ? uint(GrisRecordState::GrisPreparedWinner)
            : uint(GrisRecordState::GrisPreparedZero);
    }
#endif
#endif
    gGRISShadedIndirect[index] = result;
}
