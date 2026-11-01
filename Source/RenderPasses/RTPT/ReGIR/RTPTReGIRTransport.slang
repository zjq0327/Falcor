#pragma once

#ifndef RTPT_REGIR_TRANSPORT
#define RTPT_REGIR_TRANSPORT 0
#endif

#if RTPT_REGIR_TRANSPORT
#include "../DirectLighting/RTPTDITypes.slang"

/** A read-only view of the same model published by the SDK build. These flat
    parameters use the SDK's actual Grid runtime values, including its jitter
    conversion. The buffer contains finalized RIS weights, not marginal PDFs.
*/
struct RTPTReGIRTransportSettings
{
    float3 center;
    float cellSize;
    uint3 cellCount;
    uint lightsPerCell;
    float samplingJitter;
    uint risBufferOffset;
    uint slotCount;
    uint active;
    uint lightCount;
    uint generation;
    uint coverageMask;
    uint uncoveredAnalyticCount;
    uint secondaryEnabled;
    uint trainingEnabled;
    uint pad0;
    uint pad1;
};

ConstantBuffer<RTPTReGIRTransportSettings> gReGIRTransportSettings;
StructuredBuffer<uint2> gReGIRTransportRIS;
StructuredBuffer<RTPTDILightInfo> gReGIRTransportCatalog;
StructuredBuffer<uint> gReGIRTransportUncoveredAnalyticIndices;

uint rtptReGIRTransportCoverage(bool training)
{
    if (gReGIRTransportSettings.active == 0u || gReGIRTransportSettings.lightCount == 0u) return 0u;
    if (training ? gReGIRTransportSettings.trainingEnabled == 0u : gReGIRTransportSettings.secondaryEnabled == 0u) return 0u;
    return gReGIRTransportSettings.coverageMask;
}

/** One uniformly selected published RIS slot with a fresh light-surface UV.
    For a slot built from K uniform catalogue proposals, its SDK weight is
    sum(t_i * N / K) / t_selected. Thus weight * f(light,uv)/p(uv|light)
    estimates the covered local-light integral in expectation over the build.
    Reusing slots correlates estimates; it does not turn this weight into a PDF.
    An in-grid empty/zero slot contributes zero and never triggers a retry.
*/
bool rtptReGIRSampleTransportLight(ShadingData sd, inout SampleGenerator sg, out RTPTLightSample result)
{
    result = {};
    const float3 jitter = sampleNext3D(sg) - 0.5f;
    const float3 samplingPosition = sd.posW + jitter *
        (gReGIRTransportSettings.samplingJitter * gReGIRTransportSettings.cellSize);
    const float3 origin = gReGIRTransportSettings.center -
        float3(gReGIRTransportSettings.cellCount) * (gReGIRTransportSettings.cellSize * 0.5f);
    const int3 cell = int3(floor((samplingPosition - origin) / gReGIRTransportSettings.cellSize));
    const bool inGrid = all(cell >= 0) && all(cell < int3(gReGIRTransportSettings.cellCount));
    uint lightIndex;
    float estimatorWeight;
    if (inGrid)
    {
        const uint cellIndex = uint(cell.x) + (uint(cell.y) + uint(cell.z) * gReGIRTransportSettings.cellCount.y) *
            gReGIRTransportSettings.cellCount.x;
        const uint localSlot = min(uint(sampleNext1D(sg) * gReGIRTransportSettings.lightsPerCell),
            gReGIRTransportSettings.lightsPerCell - 1u);
        const uint slot = cellIndex * gReGIRTransportSettings.lightsPerCell + localSlot;
        if (slot >= gReGIRTransportSettings.slotCount) return false;
        uint count, stride;
        gReGIRTransportRIS.GetDimensions(count, stride);
        const uint address = gReGIRTransportSettings.risBufferOffset + slot;
        if (address >= count) return false;
        const uint2 stored = gReGIRTransportRIS[address];
        // This RTPT build never writes SDK compact-light payloads.
        lightIndex = stored.x & 0x7fffffffu;
        estimatorWeight = asfloat(stored.y);
    }
    else
    {
        // Out-of-grid is a predeclared proposal fallback, independent of value.
        lightIndex = min(uint(sampleNext1D(sg) * gReGIRTransportSettings.lightCount),
            gReGIRTransportSettings.lightCount - 1u);
        estimatorWeight = float(gReGIRTransportSettings.lightCount);
    }
    if (!(estimatorWeight > 0.f) || !isfinite(estimatorWeight)) return false;
    if (lightIndex >= gReGIRTransportSettings.lightCount) return false;
    uint catalogCount, catalogStride;
    gReGIRTransportCatalog.GetDimensions(catalogCount, catalogStride);
    if (lightIndex >= catalogCount) return false;
    const RTPTDILightInfo light = gReGIRTransportCatalog[lightIndex];
    if (light.generation != gReGIRTransportSettings.generation) return false;
    const float3 rayOrigin = sd.computeRayOrigin();
    if (light.kind == kRTPTDILightEmissive)
    {
#if USE_EMISSIVE_LIGHTS
        if (light.sourceIndex >= gScene.lightCollection.getTriangleCount()) return false;
        const float2 uv = sampleNext2D(sg);
        TriangleLightSample sampled;
        if (!sampleTriangle(sd.posW, light.sourceIndex, uv, sampled)) return false;
        if (!(sampled.pdf > 0.f) || !isfinite(sampled.pdf)) return false;
        const EmissiveTriangle triangle = gScene.lightCollection.getTriangle(light.sourceIndex);
        VertexData vertex = {};
        vertex.posW = sampled.posW;
        vertex.texC = triangle.getTexCoord(sample_triangle(uv));
        if (gScene.materials.alphaTest(vertex, triangle.materialID, 0.f)) return false;
        result.dir = sampled.dir;
        result.LiOverPdf = sampled.Le * (estimatorWeight / sampled.pdf);
        const float3 lightOrigin = computeRayOrigin(sampled.posW, sampled.normalW);
        const float3 shadow = lightOrigin - rayOrigin;
        const float distance = length(shadow);
        if (!(distance > 0.f) || !isfinite(distance)) return false;
        result.visibilityRay = Ray(rayOrigin, shadow / distance, 0.f, distance);
#else
        return false;
#endif
    }
    else if (light.kind == kRTPTDILightPoint)
    {
#if USE_ANALYTIC_LIGHTS
        if (light.sourceIndex >= gScene.getLightCount()) return false;
        const LightData data = gScene.getLight(light.sourceIndex);
        if (data.type != uint(LightType::Point)) return false;
        AnalyticLightSample sampled;
        if (!samplePointLight(sd.posW, data, sampled)) return false;
        result.dir = sampled.dir;
        result.LiOverPdf = sampled.Li * estimatorWeight;
        result.analytic = true;
        result.visibilityRay = Ray(rayOrigin, sampled.dir, 0.f, sampled.distance);
#else
        return false;
#endif
    }
    else return false;
    // No marginal proposal PDF is exposed. The caller gives this estimator
    // exclusive ownership of the covered local direct-light domain.
    result.pdf = 0.f;
    return dot(sd.getOrientedFaceNormal(), result.dir) > 0.f && all(isfinite(result.LiOverPdf)) && any(result.LiOverPdf > 0.f);
}
#else
uint rtptReGIRTransportCoverage(bool training) { return 0u; }
#endif
