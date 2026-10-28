#pragma once
import Scene.Scene;
#include "RTPTLocalLightCache.slang"
#include "RTPTFullLightCdf.slang"


void rtptLocalTileBounds(uint node, out uint2 origin, out uint size)
{
    const uint root = node / RTPT_LOCAL_TILE_NODES_PER_ROOT;
    const uint local = node % RTPT_LOCAL_TILE_NODES_PER_ROOT;
    origin = uint2(root % gLocalLightParams.baseTileDim.x, root / gLocalLightParams.baseTileDim.x) * 32u;
    size = 32u;
    if (local >= 1u && local <= 4u)
    {
        const uint child = local - 1u; origin += uint2(child & 1u, child >> 1u) * 16u; size = 16u;
    }
    else if (local >= 5u)
    {
        const uint child = (local - 5u) / 4u, grandchild = (local - 5u) % 4u;
        origin += uint2(child & 1u, child >> 1u) * 16u + uint2(grandchild & 1u, grandchild >> 1u) * 8u; size = 8u;
    }
}

bool rtptLocalNodeIsLeaf(uint node)
{
    const uint base = (node / 21u) * 21u, local = node % 21u;
    if (local == 0) return gLocalTileState[node].x == 0;
    if (gLocalTileState[base].x == 0) return false;
    if (local <= 4u) return gLocalTileState[node].x == 0;
    return gLocalTileState[base + 1u + (local - 5u) / 4u].x != 0;
}

uint rtptLocalGridBase(uint slot, uint kind)
{
    return slot*(gLocalLightParams.fullEmissiveCapacity+gLocalLightParams.fullAnalyticCapacity)+
        (kind == RTPT_LIGHT_KIND_ANALYTIC ? gLocalLightParams.fullEmissiveCapacity : 0u);
}
uint rtptLocalGridLightIndex(uint slot, uint kind, uint entry)
{
#if USE_EMISSIVE_LIGHTS
    if (kind == RTPT_LIGHT_KIND_EMISSIVE) return gScene.lightCollection.activeTriangles[entry];
#endif
    return entry;
}
uint rtptLocalGridSize(uint slot, uint kind)
{
    if (slot == RTPT_LOCAL_LIGHT_INVALID) return 0;
    const uint4 counts = gLocalGridCount[slot];
    const uint count = kind == RTPT_LIGHT_KIND_ANALYTIC ? counts.y : counts.x;
    return count == RTPT_LOCAL_LIGHT_INVALID ? 0u : count;
}
float rtptLocalGridTotal(uint slot, uint kind)
{
    if(slot==RTPT_LOCAL_LIGHT_INVALID)return 0.f;
    const uint4 counts = gLocalGridCount[slot];
    return asfloat(kind == RTPT_LIGHT_KIND_ANALYTIC ? counts.w : counts.z);
}
uint rtptLocalFindGridEntry(uint slot, uint kind, uint index)
{
    const uint count = rtptLocalGridSize(slot, kind);
    if (count == 0u) return RTPT_LOCAL_LIGHT_INVALID;
    if (kind == RTPT_LIGHT_KIND_ANALYTIC) return index < count ? index : RTPT_LOCAL_LIGHT_INVALID;
#if USE_EMISSIVE_LIGHTS
    if (index >= gScene.lightCollection.getTriangleCount()) return RTPT_LOCAL_LIGHT_INVALID;
    const uint ordered = gScene.lightCollection.getActiveTriangleIndex(index);
    return ordered < count ? ordered : RTPT_LOCAL_LIGHT_INVALID;
#else
    return RTPT_LOCAL_LIGHT_INVALID;
#endif
}

bool rtptLocalGridContains(uint slot, uint kind, uint index)
{
    return rtptLocalFindGridEntry(slot, kind, index) != RTPT_LOCAL_LIGHT_INVALID;
}

float rtptLocalGridPmf(uint slot, uint kind, uint index)
{
    const float total = rtptLocalGridTotal(slot, kind);
    if (!(total > 0.f) || !isfinite(total)) return 0.f;
    const uint entry = rtptLocalFindGridEntry(slot, kind, index);
    if (entry == RTPT_LOCAL_LIGHT_INVALID) return 0.f;
    const uint base = rtptLocalGridBase(slot, kind);
    return float(rtptFullCdfMass(gLocalFullCdf,base,entry,gLocalLightParams.cdfEnabled!=0u))*(1.f/float(RTPT_FULL_CDF_BINS));
}

bool rtptLocalCatalogData(uint kind, uint index, out float3 center, out float3 lo, out float3 hi, out float power)
{
    center = lo = hi = 0.f; power = 0.f;
    if (kind == RTPT_LIGHT_KIND_EMISSIVE)
    {
#if USE_EMISSIVE_LIGHTS
        if (index >= gScene.lightCollection.getTriangleCount()) return false;
        const EmissiveTriangle triangle = gScene.lightCollection.getTriangle(index);
        const float3 a = triangle.getPosition(float3(1,0,0)), b = triangle.getPosition(float3(0,1,0)), c = triangle.getPosition(float3(0,0,1));
        lo = min(a,min(b,c)); hi = max(a,max(b,c)); center = (a+b+c)/3.f;
        const float3 radiance = max(gScene.lightCollection.getAverageRadiance(index), 0.f);
        power = max(radiance.x,max(radiance.y,radiance.z)) * triangle.area;
        return all(isfinite(center)) && isfinite(power) && power > 0.f;
#else
        return false;
#endif
    }
    if (kind == RTPT_LIGHT_KIND_ANALYTIC)
    {
#if USE_ANALYTIC_LIGHTS
        if (index >= gScene.getLightCount()) return false;
        const LightData light = gScene.getLight(index);
        if (light.type == LightType::Directional || light.type == LightType::Distant) return false;
        center = light.posW;
        float3 extent=0.f;
        if(light.type==LightType::Rect || light.type==LightType::Disc || light.type==LightType::Sphere)
        {
            center=mul(light.transMat,float4(0,0,0,1)).xyz;
            extent=abs(mul(light.transMat,float4(1,0,0,0)).xyz)+abs(mul(light.transMat,float4(0,1,0,0)).xyz);
            if(light.type==LightType::Sphere)extent+=abs(mul(light.transMat,float4(0,0,1,0)).xyz);
        }
        lo = center - extent; hi = center + extent;
        power = max(light.intensity.x,max(light.intensity.y,light.intensity.z)) * max(1.f,light.surfaceArea);
        return all(isfinite(center)) && all(isfinite(lo)) && all(isfinite(hi)) && isfinite(power) && power > 0.f;
#else
        return false;
#endif
    }
    return false;
}

bool rtptLocalFeedbackValid(RTPTLocalLightFeedbackRecord r)
{
    return r.pixelInfo.z != 0 && r.key.z == gLocalLightParams.sceneGeneration &&
        r.key.x != RTPT_LIGHT_KIND_INVALID && r.key.y != RTPT_LOCAL_LIGHT_INVALID &&
        gLocalLightParams.frameSerial - r.key.w <= gLocalLightParams.historyStaleFrames &&
        all(isfinite(r.positionScore)) && all(isfinite(r.normalWeight));
}
