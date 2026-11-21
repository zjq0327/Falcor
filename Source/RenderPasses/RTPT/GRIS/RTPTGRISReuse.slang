#pragma once
#include "RTPTGRISTypes.slang"
#include "RTPTGRISSupport.slang"

#ifndef RTPT_GRIS_SPATIAL_REUSE
#define RTPT_GRIS_SPATIAL_REUSE 0
#endif

static const uint kGrisSpatialNeighborCount = 3u;
static const uint kGrisMaxReuseInputs = 1u + (RTPT_GRIS_SPATIAL_REUSE ? kGrisSpatialNeighborCount : 0u);

float rtptGrisBalanceWeight(float own, float other)
{
    const float total = own + other;
    return total > 0.f && isfinite(total) ? own / total : 0.f;
}

// Both arguments must be densities in the same measure for this candidate.
float rtptGrisTalbotWeight(float ownTarget, float ownCount, float otherTarget, float otherCount)
{
    return rtptGrisBalanceWeight(ownTarget * ownCount, otherTarget * otherCount);
}

float rtptGrisPairwiseCenterWeight(float centerTarget, float centerCount, float neighborTarget, float neighborCount)
{
    return rtptGrisTalbotWeight(centerTarget, centerCount / float(kGrisSpatialNeighborCount), neighborTarget, neighborCount);
}

float rtptGrisPairwiseNeighborWeight(float centerTarget, float centerCount, float neighborTarget, float neighborCount)
{
    return rtptGrisTalbotWeight(neighborTarget, neighborCount, centerTarget, centerCount / float(kGrisSpatialNeighborCount));
}

#if RTPT_GRIS_SPATIAL_REUSE && SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
Texture1D<float2> gGRISNeighborOffsets;

bool rtptGrisLoadSpatialSurface(uint2 pixel, out ShadingData surface)
{
    surface = {};
    RTPTPrimarySurface primary;
    if (!rtptTryLoadPrimary(pixel, gPrimarySettings.sampleIndex, primary)) return false;
    return rtptGrisRefLoad(primary.packedHit, -primary.rayDirection, surface);
}

void rtptGrisGatherSpatialNeighbors(uint2 pixel, float3 camera, inout uint inputCount,
#if RTPT_GRIS_DUAL_FIRST_HIT
    inout uint sourceIndices[kGrisMaxReuseInputs])
#else
    StructuredBuffer<GrisSpatialRecord> spatialInput,
    inout GrisSpatialRecord inputs[kGrisMaxReuseInputs], inout float3 sourceCameras[kGrisMaxReuseInputs])
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
#if RTPT_GRIS_DUAL_FIRST_HIT
        sourceIndices[inputCount] = index;
#else
        inputs[inputCount] = spatialInput[index];
        sourceCameras[inputCount] = camera;
#endif
        ++inputCount;
    }
}
#endif

float rtptGrisTarget(float3 F)
{
    return dot(abs(F), float3(0.2126f, 0.7152f, 0.0722f));
}
