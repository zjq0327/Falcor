#include "../PrimarySurface/RTPTPrimarySurfaceTypes.slang"
#include "RTPTGRISTypes.slang"

ConstantBuffer<RTPTPrimarySettings> gPrimarySettings;
#if RTPT_GRIS_SPATIAL
StructuredBuffer<GrisSpatialRecord> gGRISSpatialOutput;
#else
StructuredBuffer<GrisCandidate> gGRISCandidates;
#endif
RWStructuredBuffer<GrisShadedIndirect> gGRISShadedIndirect;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gPrimarySettings.frameDim)) return;
    const uint index = pixel.y * gPrimarySettings.frameDim.x + pixel.x;

#if RTPT_GRIS_SPATIAL
    const GrisCandidate candidate = gGRISSpatialOutput[index].candidate;
#else
    const GrisCandidate candidate = gGRISCandidates[index];
#endif
    GrisShadedIndirect result = {};
    result.firstHit.distanceState = kRTPTDistanceUntraced;
    if (candidate.prepared)
    {
        result.rootLobe = candidate.rootLobe;
        result.state = uint(GrisRecordState::GrisPreparedZero);
        if (candidate.hasWinner)
        {
            result.radiance = candidate.F * candidate.W;
            result.state = uint(GrisRecordState::GrisPreparedWinner);
            result.firstHit = candidate.firstHit;
        }
    }
    gGRISShadedIndirect[index] = result;
}
