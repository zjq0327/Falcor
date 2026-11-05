#include "RTPTGRISSpatial.slang"
#include "../ReSTIRDI/RTPTDIReprojection.slangh"

struct GrisTemporalHistoryFrame
{
    float4x4 previousViewProj;
    uint2 previousFrameDim;
    uint previousFrameStamp;
    uint historyGeneration;
    bool historyValid;
};

ConstantBuffer<GrisTemporalHistoryFrame> gGRISTemporalHistory;
StructuredBuffer<RTPTPrimarySurface> gGRISPreviousPrimarySurface;
StructuredBuffer<GrisSpatialRecord> gGRISPreviousReservoir;
RWStructuredBuffer<GrisSpatialRecord> gGRISTemporalOutput;

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
GrisSpatialRecord rtptGrisReuseHistory(uint index, uint2 pixel, GrisSpatialRecord canonical)
{
    if (!canonical.candidate.prepared || !gGRISTemporalHistory.historyValid || gPrimarySettings.prepared == 0u) return canonical;
    if (any(gGRISTemporalHistory.previousFrameDim != gParams.frameDim)) return canonical;

    const RTPTPrimarySurface current = gPrimarySurfaces[index];
    ShadingData dst;
    if (!rtptGrisLoadRoot(current, dst)) return canonical;
    float2 projectedPixel;
    float projectedDepth;
    // Scene motion is excluded by the history producer. Project the same world point.
    if (!rtptDIProjectPreviousPixel(current.position, gGRISTemporalHistory.previousFrameDim,
        gGRISTemporalHistory.previousViewProj, projectedPixel, projectedDepth)) return canonical;

    const int2 previousPixel = int2(round(projectedPixel));
    if (any(previousPixel < 0) || any(previousPixel >= int2(gGRISTemporalHistory.previousFrameDim))) return canonical;
    const uint previousIndex = uint(previousPixel.y) * gGRISTemporalHistory.previousFrameDim.x + uint(previousPixel.x);
    const RTPTPrimarySurface previous = gGRISPreviousPrimarySurface[previousIndex];
    ShadingData src;
    if (!rtptGrisLoadRoot(previous, gGRISTemporalHistory.previousFrameStamp, src)) return canonical;

    const TriangleHit currentHit = HitInfo(current.packedHit).getTriangleHit();
    const TriangleHit previousHit = HitInfo(previous.packedHit).getTriangleHit();
    if (currentHit.instanceID.index != previousHit.instanceID.index || current.materialID != previous.materialID) return canonical;
    if (!isfinite(previous.viewZ) || abs(previous.viewZ - projectedDepth) > 0.02f * projectedDepth) return canonical;
    if (!(dot(current.guideNormal, previous.guideNormal) >= 0.9f)) return canonical;

    GrisSpatialRecord history = gGRISPreviousReservoir[previousIndex];
    if (!history.candidate.prepared || !(history.M > 0.f) || !isfinite(history.M)) return canonical;
    // Limit the historical proxy's confidence without modifying the historical UCW.
    history.M = min(history.M, 8.f * canonical.M);
    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0x517cc1b7u);
    return rtptGrisMerge(canonical, history, dst, src, rng);
}
#endif

[numthreads(8, 8, 1)]
void main(uint3 threadID : SV_DispatchThreadID)
{
    const uint2 pixel = threadID.xy;
    if (any(pixel >= gParams.frameDim)) return;
    const uint index = pixel.y * gParams.frameDim.x + pixel.x;
    const GrisSpatialRecord canonical = gGRISSpatialInput[index];
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    gGRISTemporalOutput[index] = rtptGrisReuseHistory(index, pixel, canonical);
#else
    gGRISTemporalOutput[index] = canonical;
#endif
}
