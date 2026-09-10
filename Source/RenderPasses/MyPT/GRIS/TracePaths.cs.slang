import Params;
import PathTracer;
import Utils.Math.HashUtils;

RWTexture2D<float4> gPathDebug;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    uint index = pixelIndex(pixel);
    PrimaryPathContext primary = gPrimary[index];
    PathReservoir fresh = {};
    float3 reference = 0.f;
    SampleGenerator selection = SampleGenerator(jenkinsHash(primary.seed ^ 0xb5297a4du));
    for (uint candidate = 0; candidate < gCandidateCount; ++candidate)
    {
        // The first N candidates are invariant when the candidate budget grows.
        uint seed = jenkinsHash(primary.seed + candidate * 0x9e3779b9u);
        PathBuilder builder = tracePathTree(primary, seed, gMaxSurfaceBounces, gRRProbability, gRoughnessThreshold, gNearFieldDistance);
        fresh.mergeTree(builder.reservoir, selection);
        reference += builder.radiance / float(gCandidateCount);
    }
    fresh.finalizeRIS();
    gFresh[index] = fresh;
    gReference[index] = float4(reference, 1.f);
#if GRIS_HAS_PATH_DEBUG
    gPathDebug[pixel] = float4(fresh.sample.rcIndex == 0xffffffff ? 0.f : float(fresh.sample.rcIndex),
        float(fresh.sample.surfaceScatters), float(fresh.sample.prefixFlags), float(fresh.sample.rcAfterFlags));
#endif
}
