#pragma once

#ifndef RTPT_REGIR_TRANSPORT
#define RTPT_REGIR_TRANSPORT 0
#endif

#if RTPT_REGIR_TRANSPORT
#include "../DirectLighting/RTPTDITypes.slang"
#include "RTPTReGIRCellLists.slang"
StructuredBuffer<RTPTDILightInfo> gReGIRTransportCatalog;
StructuredBuffer<uint> gReGIRTransportUncoveredAnalyticIndices;

uint rtptReGIRTransportCoverage(bool training)
{
    if (gReGIRSettings.active == 0u || gReGIRSettings.lightCount == 0u) return 0u;
    if (training ? gReGIRSettings.trainingEnabled == 0u : gReGIRSettings.secondaryEnabled == 0u) return 0u;
    return gReGIRSettings.coverageMask;
}

bool rtptReGIRLoadTransportLight(ShadingData sd, uint lightIndex, out RTPTDILightInfo light)
{
    light = {};
    if (lightIndex >= gReGIRSettings.lightCount) return false;
    uint catalogCount, catalogStride;
    gReGIRTransportCatalog.GetDimensions(catalogCount, catalogStride);
    if (lightIndex >= catalogCount) return false;
    light = gReGIRTransportCatalog[lightIndex];
    if (light.generation != gReGIRSettings.generation) return false;
    // The same receiver-local cutoff is used by DI Initial/reuse/final shade.
    // Rejecting this sample is a counted zero event, never a resampling retry.
    if (light.pad0 >= gReGIRSettings.stableIdCount) return false;
    return rtptReGIRLightCanAffectCell(gReGIRLightDescriptors[light.pad0], sd.posW, float3(0.f));
}

bool rtptReGIRBuildTransportSample(ShadingData sd, RTPTDILightInfo light, float2 uv, float estimatorWeight,
    out RTPTLightSample result)
{
    result = {};
    const float3 rayOrigin = sd.computeRayOrigin();
    if (light.kind == kRTPTDILightEmissive)
    {
#if USE_EMISSIVE_LIGHTS
        if (light.sourceIndex >= gScene.lightCollection.getTriangleCount()) return false;
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

bool rtptReGIRRebuildTransportSample(ShadingData sd, uint stableID, float2 uv, float estimatorWeight,
    out RTPTLightSample result)
{
    result = {};
    if (stableID >= gReGIRSettings.stableIdCount || !(estimatorWeight > 0.f) || !isfinite(estimatorWeight)) return false;
    RTPTDILightInfo light;
    if (!rtptReGIRLoadTransportLight(sd, gReGIRIdToCatalog[stableID], light) || light.pad0 != stableID) return false;
    return rtptReGIRBuildTransportSample(sd, light, uv, estimatorWeight, result);
}

/** One uniformly selected published RIS slot with a fresh light-surface UV.
    For a slot built from K uniform cell-list proposals, its published weight is
    sum(t_i * N / K) / t_selected. Thus weight * f(light,uv)/p(uv|light)
    estimates the covered local-light integral in expectation over the build.
    Reusing slots correlates estimates; it does not turn this weight into a PDF.
    A populated cell's empty/zero slot contributes zero and never triggers a retry.
*/
bool rtptReGIRSelectTransportLight(ShadingData sd, inout SampleGenerator sg,
    out RTPTDILightInfo light, out float estimatorWeight)
{
    light = {};
    estimatorWeight = 0.f;
    const RTPTReGIRCellView view = rtptReGIRGetCellView(sd.posW, sampleNext3D(sg));
    if (view.ready == 0u || view.count == 0u) return false;
    const uint cell = view.cell;
    uint lightIndex;
    if (rtptReGIRHasPublishedRIS(view))
    {
        const uint localSlot = min(uint(sampleNext1D(sg) * gReGIRSettings.lightsPerCell),
            gReGIRSettings.lightsPerCell - 1u);
        const uint slot = cell * gReGIRSettings.lightsPerCell + localSlot;
        if (slot >= gReGIRSettings.slotCount) return false;
        uint count, stride;
        gReGIRRIS.GetDimensions(count, stride);
        if (slot >= count) return false;
        const uint2 stored = gReGIRRIS[slot];
        // This RTPT build never writes SDK compact-light payloads.
        lightIndex = stored.x & 0x7fffffffu;
        estimatorWeight = asfloat(stored.y);
    }
    else
    {
        // A new cell has a complete list but no published RIS yet. Draw only
        // from that list, including the complete procedural form under cache
        // pressure; never draw an unordered/global candidate and reject it.
        const uint threshold = (0u - view.count) % view.count;
        uint random;
        do { random = sg.next(); } while (random < threshold);
        lightIndex = rtptReGIRLoadCandidate(view, random % view.count);
        estimatorWeight = float(view.count);
    }
    return estimatorWeight > 0.f && isfinite(estimatorWeight) && rtptReGIRLoadTransportLight(sd, lightIndex, light);
}

bool rtptReGIRSampleTransportLight(ShadingData sd, inout SampleGenerator sg, out RTPTLightSample result,
    out uint stableID, out float2 uv, out float estimatorWeight)
{
    result = {};
    stableID = 0u;
    uv = 0.f;
    RTPTDILightInfo light;
    if (!rtptReGIRSelectTransportLight(sd, sg, light, estimatorWeight)) return false;
#if USE_EMISSIVE_LIGHTS
    if (light.kind == kRTPTDILightEmissive && light.sourceIndex < gScene.lightCollection.getTriangleCount())
        uv = sampleNext2D(sg);
#endif
    stableID = light.pad0;
    return rtptReGIRBuildTransportSample(sd, light, uv, estimatorWeight, result);
}

bool rtptReGIRSampleTransportLight(ShadingData sd, inout SampleGenerator sg, out RTPTLightSample result)
{
    uint unusedID;
    float2 unusedUV;
    float unusedWeight;
    return rtptReGIRSampleTransportLight(sd, sg, result, unusedID, unusedUV, unusedWeight);
}
#else
uint rtptReGIRTransportCoverage(bool training) { return 0u; }
#endif
