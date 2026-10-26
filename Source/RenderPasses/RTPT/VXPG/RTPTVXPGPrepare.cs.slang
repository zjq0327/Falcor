#include "RTPTVXPGDistribution.slang"

cbuffer VXPGTreeLevel { uint nodeOffset; uint nodeCount; uint leafCapacity; };

void workDispatch(uint offset,uint count,uint y=1)
{
    gVXPGWorkArgs[offset]=max(1u,(count+255u)/256u);
    gVXPGWorkArgs[offset+1]=y;
    gVXPGWorkArgs[offset+2]=1;
}
[numthreads(1,1,1)]
void geometryWork(uint3 tid:SV_DispatchThreadID)
{
    workDispatch(4,rtptVXPGGeometryCount());
}
[numthreads(1,1,1)]
void activeWork(uint3 tid:SV_DispatchThreadID)
{
    const uint count=min(gVXPGState[3],gVXPGParams.activeCapacity);
    uint leaves=1;while(leaves<count)leaves*=2;
    gVXPGWorkArgs[0]=leaves;
    gVXPGWorkArgs[1]=max(256u,leaves);
    gVXPGWorkArgs[2]=max(1u,leaves/256u);
    workDispatch(8,count);
    workDispatch(12,leaves);
    workDispatch(16,max(256u,leaves));
    for(uint level=1;level<=18;++level)
    {
        workDispatch(32+(level-1)*3,leaves>>level);
        workDispatch(96+(level-1)*3,leaves>>level,gVXPGParams.clusterCount);
    }
}
[numthreads(1,1,1)]
void forestWork(uint3 tid:SV_DispatchThreadID)
{
    workDispatch(20,gVXPGClusterState[4]);
}

[numthreads(32, 1, 1)]
void clearDiagnostics(uint3 tid : SV_DispatchThreadID)
{
    if(tid.x<8)gVXPGQueryStats[tid.x]=0;
    // A frozen proposal still gets fresh render activity. Preserve its model
    // structure (including gathered points at 26); construction activity is
    // explicitly unavailable on frames with no construction dispatch.
    if ((tid.x >= 6 && tid.x <= 25) || (tid.x >= 27 && tid.x < 32))
        gVXPGState[tid.x] = 0;
}

[numthreads(256, 1, 1)]
void clearFrame(uint3 tid : SV_DispatchThreadID)
{
    if(tid.x<8)gVXPGQueryStats[tid.x]=0;
    if (tid.x < 4) gVXPGHistoryStats[tid.x] = 0;
    if(tid.x>=4 && tid.x<8 && (tid.x<6 || gVXPGParams.historyReset!=0))gVXPGHistoryStats[tid.x]=0;
    if (tid.x >= 3 && tid.x < 32) gVXPGState[tid.x] = 0;
    if (tid.x >= rtptVXPGGeometryCount()) return;
    gVXPGFlux[tid.x] = uint64_t(0);
    gVXPGCount[tid.x] = 0;
    if ( gVXPGParams.treeReset != 0)
        gVXPGInverse[tid.x] = RTPT_VXPG_INVALID;
    gVXPGBoundMax[tid.x].w = 0;
    if (gVXPGParams.historyReset != 0) gVXPGHistory[tid.x] = {};
}

[numthreads(256, 1, 1)]
void globalLeaves(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    uint base=leafCapacity;
    base=gVXPGWorkArgs[0];
    if (tid.x >= base) return;
    const uint count = min(gVXPGState[RTPT_VXPG_STATE_ACTIVE], gVXPGParams.activeCapacity);
    gVXPGGlobalTree[base + tid.x] = tid.x < count ? gVXPGMass[tid.x] : 0.f;
}

[numthreads(256, 1, 1)]
void globalLevel(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    uint count=nodeCount,offset=nodeOffset;
    count=gVXPGWorkArgs[0]>>nodeOffset;offset=count;
    if (tid.x >= count) return;
    const uint node = offset + tid.x;
    gVXPGGlobalTree[node] = gVXPGGlobalTree[node*2] + gVXPGGlobalTree[node*2+1];
}

[numthreads(1, 1, 1)]
void publish(uint3 tid : SV_DispatchThreadID)
{
    const bool valid = gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] == 0 &&
        gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] == 0 &&
        gVXPGState[RTPT_VXPG_STATE_INVALID] == 0 &&
        gVXPGState[RTPT_VXPG_STATE_ACTIVE] > 0 && gVXPGGlobalTree[1] > 0.f && isfinite(gVXPGGlobalTree[1]);
    gVXPGState[RTPT_VXPG_STATE_READY] = valid ? gVXPGParams.generation : 0;
    {
        const bool published = valid && gVXPGClusterState[6] == gVXPGParams.generation;
        gVXPGTreeState[8] = published ? 1u : 0u;
        gVXPGTreeState[1] = min(gVXPGState[3], gVXPGParams.activeCapacity);
        const bool reuse = rtptVXPGReuseTopology();
        gVXPGTreeState[7] = reuse ? gVXPGTreeState[7] + 1u : 0u;
        if (published) gVXPGTreeState[reuse ? 4u : 3u] += 1u;
    }
}
