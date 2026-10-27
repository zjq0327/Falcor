#include "RTPTVXPGDistribution.slang"

cbuffer VXPGTreeLevel { uint nodeOffset; uint nodeCount; uint leafCapacity; };

void workDispatch(uint offset,uint count,uint y=1)
{
    gVXPGWorkArgs[offset]=max(1u,(count+255u)/256u);
    gVXPGWorkArgs[offset+RTPT_VXPG_DISPATCH_Y]=y;
    gVXPGWorkArgs[offset+RTPT_VXPG_DISPATCH_Z]=1;
}
[numthreads(1,1,1)]
void geometryWork(uint3 tid:SV_DispatchThreadID)
{
    workDispatch(RTPT_VXPG_WORK_GEOMETRY,rtptVXPGGeometryCount());
}
[numthreads(1,1,1)]
void activeWork(uint3 tid:SV_DispatchThreadID)
{
    const uint count=min(gVXPGState[RTPT_VXPG_STATE_ACTIVE],gVXPGParams.activeCapacity);
    uint leaves=1;while(leaves<count)leaves*=2;
    gVXPGWorkArgs[RTPT_VXPG_WORK_LEAF_BASE]=leaves;
    gVXPGWorkArgs[RTPT_VXPG_WORK_SORT_CAPACITY]=max(256u,leaves);
    gVXPGWorkArgs[RTPT_VXPG_WORK_SORT_GROUPS]=max(1u,leaves/256u);
    workDispatch(RTPT_VXPG_WORK_ACTIVE,count);
    workDispatch(RTPT_VXPG_WORK_GLOBAL_LEAVES,leaves);
    workDispatch(RTPT_VXPG_WORK_SORT,max(256u,leaves));
    for(uint level=1;level<=RTPT_VXPG_WORK_LEVEL_COUNT;++level)
    {
        workDispatch(RTPT_VXPG_WORK_GLOBAL_LEVELS+(level-1)*RTPT_VXPG_DISPATCH_WORDS,leaves>>level);
        workDispatch(RTPT_VXPG_WORK_FOREST_LEVELS+(level-1)*RTPT_VXPG_DISPATCH_WORDS,leaves>>level,gVXPGParams.clusterCount);
    }
}
[numthreads(1,1,1)]
void forestWork(uint3 tid:SV_DispatchThreadID)
{
    workDispatch(RTPT_VXPG_WORK_FOREST_NODES,gVXPGClusterState[RTPT_VXPG_CLUSTER_FOREST_NODES]);
}

[numthreads(RTPT_VXPG_STATE_WORDS, 1, 1)]
void clearDiagnostics(uint3 tid : SV_DispatchThreadID)
{
    if(tid.x<RTPT_VXPG_QUERY_WORDS)gVXPGQueryStats[tid.x]=0;
    // A frozen proposal still gets fresh render activity. Preserve its model
    // structure (including gathered points at 26); construction activity is
    // explicitly unavailable on frames with no construction dispatch.
    if ((tid.x >= RTPT_VXPG_STATE_ATTEMPTS && tid.x <= RTPT_VXPG_STATE_POSITIVE_PAIRS) || (tid.x >= RTPT_VXPG_STATE_OWNER_MAX_PROBES && tid.x < RTPT_VXPG_STATE_WORDS))
        gVXPGState[tid.x] = 0;
}

[numthreads(256, 1, 1)]
void clearFrame(uint3 tid : SV_DispatchThreadID)
{
    if(tid.x<RTPT_VXPG_QUERY_WORDS)gVXPGQueryStats[tid.x]=0;
    if (tid.x < RTPT_VXPG_HISTORY_BORROWED) gVXPGHistoryStats[tid.x] = 0;
    if(tid.x>=RTPT_VXPG_HISTORY_BORROWED && tid.x<RTPT_VXPG_HISTORY_WORDS && (tid.x<RTPT_VXPG_HISTORY_BORROWED_TOTAL || gVXPGParams.historyReset!=0))gVXPGHistoryStats[tid.x]=0;
    if (tid.x >= RTPT_VXPG_STATE_ACTIVE && tid.x < RTPT_VXPG_STATE_WORDS) gVXPGState[tid.x] = 0;
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
    base=gVXPGWorkArgs[RTPT_VXPG_WORK_LEAF_BASE];
    if (tid.x >= base) return;
    const uint count = min(gVXPGState[RTPT_VXPG_STATE_ACTIVE], gVXPGParams.activeCapacity);
    gVXPGGlobalTree[base + tid.x] = tid.x < count ? gVXPGMass[tid.x] : 0.f;
}

[numthreads(256, 1, 1)]
void globalLevel(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    uint count=nodeCount,offset=nodeOffset;
    count=gVXPGWorkArgs[RTPT_VXPG_WORK_LEAF_BASE]>>nodeOffset;offset=count;
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
        const bool published = valid && gVXPGClusterState[RTPT_VXPG_CLUSTER_READY] == gVXPGParams.generation;
        gVXPGTreeState[RTPT_VXPG_TREE_TOPOLOGY_VALID] = published ? 1u : 0u;
        gVXPGTreeState[RTPT_VXPG_TREE_PREVIOUS_ACTIVE] = min(gVXPGState[RTPT_VXPG_STATE_ACTIVE], gVXPGParams.activeCapacity);
        const bool reuse = rtptVXPGReuseTopology();
        gVXPGTreeState[RTPT_VXPG_TREE_TOPOLOGY_AGE] = reuse ? gVXPGTreeState[RTPT_VXPG_TREE_TOPOLOGY_AGE] + 1u : 0u;
        if (published) gVXPGTreeState[reuse ? RTPT_VXPG_TREE_LOCAL_UPDATES : RTPT_VXPG_TREE_FULL_BUILDS] += 1u;
    }
}
