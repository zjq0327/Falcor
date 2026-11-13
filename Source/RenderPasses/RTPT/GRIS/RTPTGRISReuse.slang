#pragma once
#include "RTPTGRISTypes.slang"
#include "RTPTGRISSupport.slang"

#ifndef RTPT_GRIS_SPATIAL_REUSE
#define RTPT_GRIS_SPATIAL_REUSE 0
#endif

static const uint kGrisSpatialNeighborCount = 3u;
static const uint kGrisMaxReuseInputs = 1u + (RTPT_GRIS_SPATIAL_REUSE ? kGrisSpatialNeighborCount : 0u);

#if RTPT_GRIS_DUAL_FIRST_HIT && (RTPT_GRIS_SPATIAL_REUSE || defined(RTPT_GRIS_TEMPORAL_REUSE))
StructuredBuffer<GrisDualFirstHits> gGRISDualFirstHits;
#endif

#if RTPT_GRIS_SPATIAL_REUSE && SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
Texture1D<float2> gGRISNeighborOffsets;

bool rtptGrisLoadSpatialSurface(uint2 pixel, out ShadingData surface)
{
    surface = {};
    RTPTPrimarySurface primary;
    if (!rtptTryLoadPrimary(pixel, gPrimarySettings.sampleIndex, primary)) return false;
    return rtptGrisRefLoad(primary.packedHit, -primary.rayDirection, surface);
}

void rtptGrisGatherSpatialNeighbors(uint2 pixel, StructuredBuffer<GrisSpatialRecord> spatialInput,
    float3 camera, inout uint inputCount,
    inout GrisSpatialRecord inputs[kGrisMaxReuseInputs], inout float3 sourceCameras[kGrisMaxReuseInputs],
#if RTPT_GRIS_DUAL_FIRST_HIT
    inout GrisDualFirstHits sourceHits[kGrisMaxReuseInputs])
#else
    uint lightEpoch,
    inout uint sourceLightEpochs[kGrisMaxReuseInputs])
#endif
{
    ShadingData center;
    if (!rtptGrisLoadSpatialSurface(pixel, center)) return;
    const float centerDistance = distance(camera, center.posW);
    uint offsetCount;
    gGRISNeighborOffsets.GetDimensions(offsetCount);
    SampleGenerator neighborRng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0x9b13b92du);
    const uint startIndex = uint(sampleNext1D(neighborRng) * float(offsetCount));
    for (uint i = 0u; i < kGrisSpatialNeighborCount; ++i)
    {
        const uint offsetIndex = (startIndex + i) & (offsetCount - 1u);
        const int2 neighbor = int2(pixel) + int2(gGRISNeighborOffsets[offsetIndex] * 20.f);
        if (any(neighbor < 0) || any(uint2(neighbor) >= gPrimarySettings.frameDim) || all(uint2(neighbor) == pixel))
            continue;

        ShadingData source;
        if (!rtptGrisLoadSpatialSurface(uint2(neighbor), source)) continue;
        if (!(dot(center.frame.N, source.frame.N) >= 0.5f &&
            abs(centerDistance - distance(camera, source.posW)) < 0.1f * centerDistance)) continue;

        const uint index = uint(neighbor.y) * gPrimarySettings.frameDim.x + uint(neighbor.x);
        inputs[inputCount] = spatialInput[index];
        sourceCameras[inputCount] = camera;
#if RTPT_GRIS_DUAL_FIRST_HIT
        sourceHits[inputCount] = gGRISDualFirstHits[index];
#else
        sourceLightEpochs[inputCount] = lightEpoch;
#endif
        ++inputCount;
    }
}
#endif

float rtptGrisTarget(float3 F)
{
    return dot(abs(F), float3(0.2126f, 0.7152f, 0.0722f));
}
