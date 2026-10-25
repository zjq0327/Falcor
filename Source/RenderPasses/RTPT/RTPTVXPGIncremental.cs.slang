#include "RTPTVXPGObservation.slang"

uint discoveryCount(){const uint2 d=rtptVXPGDiscoveryDim();return d.x*d.y;}
float4 tokenPosition(uint token)
{
    const uint request=token-1, index=request/2;
    return (request&1u)!=0?gVXPGDiscovery[index].position:gVXPGPrimaryPosition[rtptVXPGDiscoveryPixel(index)];
}
int4 tokenIdentity(uint token)
{
    int4 key;rtptVXPGTryOwnerKey(tokenPosition(token).xyz,key);return key;
}
[numthreads(256,1,1)]
void clearGrid(uint3 tid:SV_DispatchThreadID)
{
    const uint i=tid.x;
    if(i<gVXPGParams.hashCapacity)
    {
        gVXPGHashSlots[i]=0;
    }
    if(i<32)gVXPGState[i]=0;
    if(i<16)gVXPGGridState[i]=0;
    if(i<gVXPGParams.cellCount)
    {
        gVXPGBoundMin[i]=gVXPGBoundMax[i]=0;
        gVXPGInverse[i]=RTPT_VXPG_INVALID;
        gVXPGCellLifetime[i]=0;gVXPGCellKeys[i]=0;
    }
}
[numthreads(256,1,1)]
void beginGrid(uint3 tid:SV_DispatchThreadID)
{
    const uint i=tid.x;
    if(i<gVXPGParams.hashCapacity)gVXPGPendingHash[i]=0;
    if(i<discoveryCount()){RTPTVXPGDiscovery empty={};gVXPGDiscovery[i]=empty;gVXPGDiscoveryClaims[i]=0;}
    if(i==0)gVXPGGridState[1]=gVXPGGridState[2]=0;
}
[numthreads(256,1,1)]
void evictGrid(uint3 tid:SV_DispatchThreadID)
{
    const uint cell=tid.x;
    if(cell>=rtptVXPGGeometryCount() || gVXPGBoundMin[cell].w==0)return;
    const uint4 life=gVXPGCellLifetime[cell];
    if(gVXPGParams.frameIndex-life.x<gVXPGParams.spatialStaleFrames)return;
    // Tombstones retain the probe chain. IDs become reusable only after this
    // frame has removed their tree leaves and published the new proposal.
    gVXPGHashSlots[life.z]=RTPT_VXPG_INVALID;
    gVXPGBoundMin[cell].w=0;
    gVXPGHistory[cell]={};
    uint index;InterlockedAdd(gVXPGGridState[2],1u,index);
    gVXPGRetiredCells[index]=cell;
    InterlockedAdd(gVXPGGridState[4],1u);
    InterlockedAdd(gVXPGGridState[6],0xffffffffu);
}
[numthreads(256,1,1)]
void discover(uint3 tid:SV_DispatchThreadID)
{
    const uint request=tid.x;
    if(request>=2*discoveryCount())return;
    const uint token=request+1;
    const float4 position=tokenPosition(token);
    int4 key;
    if(position.w==0.f || !rtptVXPGTryOwnerKey(position.xyz,key))return;
    const uint cell=rtptVXPGOwner(position.xyz);
    if(cell!=RTPT_VXPG_INVALID)
    {InterlockedMax(gVXPGCellLifetime[cell].x,gVXPGParams.frameIndex);return;}
    const uint first=rtptVXPGKeyHash(key);
    for(uint probe=0;probe<128;++probe)
    {
        const uint slot=(first+probe)&(gVXPGParams.hashCapacity-1);
        uint prior;InterlockedCompareExchange(gVXPGPendingHash[slot],0u,token,prior);
        if(prior==0)
        {
            uint index;InterlockedAdd(gVXPGGridState[1],1u,index);
            gVXPGPendingSlots[index]=slot;return;
        }
        if(all(tokenIdentity(prior)==key))return;
    }
    InterlockedAdd(gVXPGGridState[8],1u);
}
uint allocateCell()
{
    uint available=gVXPGGridState[0];
    while(available!=0)
    {
        uint prior;InterlockedCompareExchange(gVXPGGridState[0],available,available-1,prior);
        if(prior==available)
        {InterlockedAdd(gVXPGGridState[7],1u);return gVXPGFreeCells[available-1];}
        available=prior;
    }
    uint count=gVXPGState[2];
    while(count<gVXPGParams.cellCount)
    {
        uint prior;InterlockedCompareExchange(gVXPGState[2],count,count+1,prior);
        if(prior==count)return count;
        count=prior;
    }
    return RTPT_VXPG_INVALID;
}
[numthreads(256,1,1)]
void insertGrid(uint3 tid:SV_DispatchThreadID)
{
    const uint index=tid.x;
    if(index>=gVXPGGridState[1])return;
    const uint token=gVXPGPendingHash[gVXPGPendingSlots[index]];
    const int4 key=tokenIdentity(token);
    const uint first=rtptVXPGKeyHash(key);
    uint slot=RTPT_VXPG_INVALID;
    for(uint probe=0;probe<128;++probe)
    {
        const uint s=(first+probe)&(gVXPGParams.hashCapacity-1);
        uint prior;InterlockedCompareExchange(gVXPGHashSlots[s],0u,token|0x80000000u,prior);
        if(prior==0){slot=s;break;}
        if(prior==RTPT_VXPG_INVALID)
        {
            InterlockedCompareExchange(gVXPGHashSlots[s],RTPT_VXPG_INVALID,token|0x80000000u,prior);
            if(prior==RTPT_VXPG_INVALID){slot=s;break;}
        }
    }
    if(slot==RTPT_VXPG_INVALID){InterlockedAdd(gVXPGGridState[5],1u);return;}
    const uint cell=allocateCell();
    if(cell==RTPT_VXPG_INVALID)
    {
        gVXPGHashSlots[slot]=RTPT_VXPG_INVALID;
        InterlockedAdd(gVXPGGridState[5],1u);return;
    }
    gVXPGCellKeys[cell]=key;
    gVXPGBoundMin[cell]=uint4(asuint(float3(0.f)),1u);
    gVXPGBoundMax[cell]=uint4(asuint(float3(1.f)),0u);
    gVXPGInverse[cell]=RTPT_VXPG_INVALID;
    gVXPGCount[cell]=0;gVXPGFlux[cell]=uint64_t(0);
    gVXPGRepresentativePosition[cell]=0;gVXPGRepresentativeNormal[cell]=0;
    gVXPGHistory[cell]={};
    gVXPGCellLifetime[cell]=uint4(gVXPGParams.frameIndex,gVXPGCellLifetime[cell].y+1,slot,0);
    gVXPGHashSlots[slot]=cell+1;
    InterlockedAdd(gVXPGGridState[3],1u);InterlockedAdd(gVXPGGridState[6],1u);
}
[numthreads(256,1,1)]
void replay(uint3 tid:SV_DispatchThreadID)
{
    if(tid.x>=discoveryCount())return;
    const RTPTVXPGDiscovery record=gVXPGDiscovery[tid.x];
    if(record.position.w==0.f || record.light.w==0.f)return;
    const uint cell=rtptVXPGOwner(record.position.xyz);
    if(cell!=RTPT_VXPG_INVALID)
        rtptVXPGStoreRawCellObservation(cell,record.position.xyz,record.normal.xyz,record.light.xyz);
}

[numthreads(256,1,1)]
void retire(uint3 tid:SV_DispatchThreadID)
{
    if(tid.x>=gVXPGGridState[2])return;
    const uint cell=gVXPGRetiredCells[tid.x];
    // All render data for this ID has been removed before the slot is freed.
    gVXPGInverse[cell]=RTPT_VXPG_INVALID;
    uint index;InterlockedAdd(gVXPGGridState[0],1u,index);
    gVXPGFreeCells[index]=cell;
}
