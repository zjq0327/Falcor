#pragma once
#include "RTPTVXPGTypes.slang"

#ifndef RTPT_VXPG_SHARED_INJECTION
#define RTPT_VXPG_SHARED_INJECTION 0
#endif

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
uint2 rtptVXPGDiscoveryPixel(uint index)
{
    const uint stride=gVXPGParams.discoveryStride;
    const uint2 dim=rtptVXPGDiscoveryDim();
    const uint2 origin=uint2(index%dim.x,index/dim.x)*stride;
    const uint2 extent=min(uint2(stride),gVXPGParams.frameDim-origin);
    const uint offset=(rtptVXPGHash(index)+gVXPGParams.frameIndex)%(extent.x*extent.y);
    return origin+uint2(offset%extent.x,offset/extent.x);
}
void rtptVXPGRecordDiscovery(uint2 pixel,uint cell,float3 position,float3 normal,float3 light)
{

    const uint2 tile=pixel/gVXPGParams.discoveryStride;
    const uint index=tile.x+tile.y*rtptVXPGDiscoveryDim().x;
#if RTPT_VXPG_SHARED_INJECTION
    // The shared producer has its own tile stride and phase. Claim one record
    // per discovery tile instead of requiring two unrelated phases to match.
    uint previous;InterlockedCompareExchange(gVXPGDiscoveryClaims[index],0u,1u,previous);
    if(previous!=0)return;
#else
    if(any(pixel!=rtptVXPGDiscoveryPixel(index)))return;
#endif
    RTPTVXPGDiscovery record={};
    record.position=float4(position,1.f);record.normal=float4(normal,0.f);
    record.light=float4(light,cell==RTPT_VXPG_INVALID?1.f:0.f);
    gVXPGDiscovery[index]=record;
}
