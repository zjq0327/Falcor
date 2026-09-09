import Params;
import PathTracer;
import Utils.Math.HashUtils;

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
        PathBuilder builder = tracePathTree(primary, seed, gMaxSurfaceBounces, gRRProbability);
        fresh.mergeTree(builder.reservoir, selection);
        reference += builder.radiance / float(gCandidateCount);
    }
    fresh.finalizeRIS();
    gFresh[index] = fresh;
    gReference[index] = float4(reference, 1.f);
}
