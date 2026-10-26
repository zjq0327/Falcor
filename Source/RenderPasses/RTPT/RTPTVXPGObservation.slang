#pragma once
#include "RTPTVXPGTypes.slang"

void rtptVXPGStoreRawCellObservation(uint cell, float3 position, float3 normal, float3 local)
{
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) return;
    if (cell == RTPT_VXPG_INVALID) return;
    if (gVXPGBoundMin[cell].w == 0) return;
    InterlockedMax(gVXPGCellLifetime[cell].x,gVXPGParams.frameIndex);
    if (!all(isfinite(local)))
    {
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INVALID], 1u);
        return;
    }
    InterlockedOr(gVXPGBoundMax[cell].w, 1u);
    // Reference uses maxComponent of positive direct-light observations and
    // their per-voxel average. This is proposal importance, not irradiance.
    const float importance = max(local.x, max(local.y, local.z));
    // Bounding model statistics does not clamp final transport radiance.
    const uint64_t fixed = importance>0.f?uint64_t(max(1.f, round(min(importance, 1.e6f) * 4096.f))):uint64_t(0);
    uint64_t previousFlux;
    InterlockedAdd(gVXPGFlux[cell], fixed, previousFlux);
    if (previousFlux > uint64_t(0xffffffffffffffffull) - fixed)
        InterlockedOr(gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW],2u);
    uint old;
    InterlockedAdd(gVXPGCount[cell], 1u, old);
    if (old==0xffffffffu) InterlockedOr(gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW],4u);
    if (old == 0)
    {
        gVXPGRepresentativePosition[cell] = float4(position, 1.f);
        gVXPGRepresentativeNormal[cell] = float4(normal, 0.f);
    }
    rtptVXPGCount(RTPT_VXPG_STATE_INJECTED);
}


uint2 rtptVXPGDiscoveryDim()
{
    return (gVXPGParams.frameDim+gVXPGParams.discoveryStride-1)/gVXPGParams.discoveryStride;
}
uint rtptVXPGDiscoveryRecordCount()
{
    return gVXPGParams.discoveryRecordCount;
}
bool rtptVXPGObservesSharedBounce(uint bounce)
{
    return bounce>=1u && bounce<=gVXPGParams.sharedInjectionBounces;
}
uint2 rtptVXPGDiscoveryPixel(uint index)
{
    const uint stride=gVXPGParams.discoveryStride;
    const uint2 dim=rtptVXPGDiscoveryDim();
    const uint2 origin=uint2(index%dim.x,index/dim.x)*stride;
    const uint2 extent=min(uint2(stride),gVXPGParams.frameDim-origin);
    const uint offset=(rtptVXPGHash(index)+gVXPGParams.frameIndex)%(extent.x*extent.y);
    return origin+uint2(offset%extent.x,offset/extent.x);
}
void rtptVXPGRecordDiscovery(uint2 pixel,uint cell,float3 position,float3 normal,float3 light,uint bounce)
{
    if(!rtptVXPGObservesSharedBounce(bounce))return;
    const uint depth=gVXPGParams.sharedInjectionBounces;
    // One writer per sparse path and depth, independent of primary discovery
    // stride/phase. A shallow hit cannot hide a deeper, not-yet-created cell.
    const uint stride=max(gVXPGParams.sharedInjectionStride,1u);
    const uint2 dim=(gVXPGParams.frameDim+stride-1u)/stride;
    const uint2 tile=pixel/stride;
    const uint index=(tile.x+tile.y*dim.x)*depth+bounce-1u;
    if(index>=rtptVXPGDiscoveryRecordCount())return;
    RTPTVXPGDiscovery record={};
    record.position=float4(position,1.f);record.normal=float4(normal,0.f);
    record.light=float4(light,cell==RTPT_VXPG_INVALID?1.f:0.f);
    gVXPGDiscovery[index]=record;
}
