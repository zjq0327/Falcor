import Params;
import PathTracer;
import Utils.Math.HashUtils;

RWTexture2D<float4> gPathDebug;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    measurementInit(pixel, kMeasureGeneration);
    uint index = pixelIndex(pixel);
    PrimaryPathContext primary = gPrimary[index];
    PathReservoir fresh = {};
    float3 reference = 0.f;
    SampleGenerator selection = SampleGenerator(jenkinsHash(primary.seed ^ 0xb5297a4du));
    for (uint candidate = 0; candidate < gCandidateCount; ++candidate)
    {
        // The first N candidates are invariant when the candidate budget grows.
        uint seed = jenkinsHash(primary.seed + candidate * 0x9e3779b9u);
#if GRIS_USE_NRC
        PathSample target = {};
        PathTraceResult result = tracePathImpl(primary, seed, gMaxSurfaceBounces, gRRProbability, 0, target,
            gRoughnessThreshold, gNearFieldDistance, true, pixel, candidate, true);
        gNrcCandidates[index * gCandidateCount + candidate] = result.nrc;
#if GRIS_HAS_REFERENCE
        // Optional independent explicit reference. Never records or queries NRC.
        uint phase = measurementSetPhase(kMeasureValidation);
        PathBuilder referenceBuilder = tracePathTree(primary, seed, gMaxSurfaceBounces, gRRProbability, gRoughnessThreshold, gNearFieldDistance);
        reference += referenceBuilder.radiance / float(gCandidateCount);
        measurementSetPhase(phase);
#endif
#else
        PathBuilder builder = tracePathTree(primary, seed, gMaxSurfaceBounces, gRRProbability, gRoughnessThreshold, gNearFieldDistance);
        fresh.mergeTree(builder.reservoir, selection);
        reference += builder.radiance / float(gCandidateCount);
#endif
    }
#if !GRIS_USE_NRC
    fresh.finalizeRIS();
    gFresh[index] = fresh;
#endif
    gReference[index] = float4(reference, 1.f);
#if GRIS_HAS_PATH_DEBUG && !GRIS_USE_NRC
    gPathDebug[pixel] = float4(fresh.sample.rcIndex == 0xffffffff ? 0.f : float(fresh.sample.rcIndex),
        float(fresh.sample.surfaceScatters), float(fresh.sample.prefixFlags), float(fresh.sample.rcAfterFlags));
#endif
}
