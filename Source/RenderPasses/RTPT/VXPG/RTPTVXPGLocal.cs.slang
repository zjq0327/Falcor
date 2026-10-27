#include "RTPTVXPGHistoryResolve.slang"
#include "RTPTVXPGDistribution.slang"

cbuffer VXPGLocalLevel { uint localTreeLevel; };

uint rtptVXPGGlobalBase()
{
    return gVXPGWorkArgs[RTPT_VXPG_WORK_LEAF_BASE];
}

[numthreads(1,1,1)]
void beginLocal(uint3 tid : SV_DispatchThreadID)
{
    uint reason = gVXPGParams.treeReset != 0 ? RTPT_VXPG_REBUILD_RESET : 0u;
    if (gVXPGTreeState[RTPT_VXPG_TREE_TOPOLOGY_AGE] + 1u >= gVXPGParams.treeRefreshFrames) reason |= RTPT_VXPG_REBUILD_PERIODIC;
    if (gVXPGTreeState[RTPT_VXPG_TREE_TOPOLOGY_VALID] == 0) reason |= RTPT_VXPG_REBUILD_INVALID;
    gVXPGTreeState[RTPT_VXPG_TREE_FULL_BUILD] = reason != 0 ? 1u : 0u;
    gVXPGTreeState[RTPT_VXPG_TREE_REBUILD_REASON] = reason;
    gVXPGTreeState[RTPT_VXPG_TREE_DIRTY_LEAVES] = gVXPGTreeState[RTPT_VXPG_TREE_GLOBAL_NODES] = gVXPGTreeState[RTPT_VXPG_TREE_FOREST_NODES] = gVXPGTreeState[RTPT_VXPG_TREE_MEMBERSHIP_CHANGES] = 0;
}

[numthreads(256,1,1)]
void resolveLocal(uint3 tid : SV_DispatchThreadID)
{
    const uint cell = tid.x;
    if (cell >= rtptVXPGGeometryCount()) return;
    const float mass = rtptVXPGResolveMass(cell);
    gVXPGCellMass[cell] = mass;
    const bool wasActive = gVXPGInverse[cell] != RTPT_VXPG_INVALID;
    if (wasActive != (mass > 0.f)) InterlockedAdd(gVXPGTreeState[RTPT_VXPG_TREE_MEMBERSHIP_CHANGES], 1u);
}

[numthreads(1,1,1)]
void selectLocal(uint3 tid : SV_DispatchThreadID)
{
    if (gVXPGTreeState[RTPT_VXPG_TREE_MEMBERSHIP_CHANGES] != 0) { gVXPGTreeState[RTPT_VXPG_TREE_FULL_BUILD] = 1; gVXPGTreeState[RTPT_VXPG_TREE_REBUILD_REASON] |= RTPT_VXPG_REBUILD_MEMBERSHIP; }
    if (gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] != 0 || gVXPGState[RTPT_VXPG_STATE_INVALID] != 0) { gVXPGTreeState[RTPT_VXPG_TREE_FULL_BUILD] = 1; gVXPGTreeState[RTPT_VXPG_TREE_REBUILD_REASON] |= RTPT_VXPG_REBUILD_INVALID; }
    gVXPGState[RTPT_VXPG_STATE_ACTIVE] = rtptVXPGReuseTopology() ? gVXPGTreeState[RTPT_VXPG_TREE_PREVIOUS_ACTIVE] : 0u;
}

[numthreads(256,1,1)]
void compactLocal(uint3 tid : SV_DispatchThreadID)
{
    const uint cell = tid.x;
    if (cell >= rtptVXPGGeometryCount()) return;
    const float mass = gVXPGCellMass[cell];
    if (!rtptVXPGReuseTopology())
    {
        gVXPGInverse[cell] = RTPT_VXPG_INVALID;
        if (!(mass > 0.f)) return;
        uint index;
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_ACTIVE], 1u, index);
        if (index >= gVXPGParams.activeCapacity) { InterlockedOr(gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW], RTPT_VXPG_OVERFLOW_ACTIVE_CAPACITY); return; }
        gVXPGCompact[index] = cell;
        gVXPGInverse[cell] = index;
        gVXPGMass[index] = mass;
    }
    else if (mass > 0.f)
    {
        const uint index = gVXPGInverse[cell];
        if (index >= gVXPGTreeState[RTPT_VXPG_TREE_PREVIOUS_ACTIVE] || index >= gVXPGParams.activeCapacity)
        { InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INVALID], 1u); return; }
        // Exact change detection: no energy is dropped by a dirty threshold.
        if (mass != gVXPGMass[index])
        {
            gVXPGMass[index] = mass;
            uint dirty;
            InterlockedAdd(gVXPGTreeState[RTPT_VXPG_TREE_DIRTY_LEAVES], 1u, dirty);
            gVXPGDirtyLeaves[dirty] = index;
        }
    }
}

[numthreads(1,1,1)]
void localWork(uint3 tid : SV_DispatchThreadID)
{
    gVXPGLocalArgs[RTPT_VXPG_DISPATCH_X] = max(1u, (gVXPGTreeState[RTPT_VXPG_TREE_DIRTY_LEAVES] + 255u) / 256u);
    gVXPGLocalArgs[RTPT_VXPG_DISPATCH_Y] = gVXPGLocalArgs[RTPT_VXPG_DISPATCH_Z] = 1;
}

[numthreads(256,1,1)]
void localLeaves(uint3 tid : SV_DispatchThreadID)
{
    if (!rtptVXPGReuseTopology() || tid.x >= gVXPGTreeState[RTPT_VXPG_TREE_DIRTY_LEAVES]) return;
    const uint compact = gVXPGDirtyLeaves[tid.x];
    gVXPGGlobalTree[rtptVXPGGlobalBase() + compact] = gVXPGMass[compact];
    InterlockedAdd(gVXPGTreeState[RTPT_VXPG_TREE_GLOBAL_NODES], 1u);
    const uint4 info = gVXPGClusterInfo[gVXPGCluster[compact]];
    const uint address=info.z+gVXPGCompactToLeaf[compact];
    gVXPGForest[address].mass = gVXPGMass[compact];
    InterlockedAdd(gVXPGTreeState[RTPT_VXPG_TREE_FOREST_NODES], 1u);
}

[numthreads(256,1,1)]
void localLevel(uint3 tid : SV_DispatchThreadID)
{
    if (!rtptVXPGReuseTopology() || tid.x >= gVXPGTreeState[RTPT_VXPG_TREE_DIRTY_LEAVES]) return;
    const uint compact = gVXPGDirtyLeaves[tid.x];
    const uint node = (rtptVXPGGlobalBase() + compact) >> localTreeLevel;
    uint previous;
    if (node != 0)
    {
        InterlockedExchange(gVXPGDirtyNodes[node], gVXPGParams.generation, previous);
        if (previous != gVXPGParams.generation)
        {
            gVXPGGlobalTree[node] = gVXPGGlobalTree[2*node] + gVXPGGlobalTree[2*node+1];
            InterlockedAdd(gVXPGTreeState[RTPT_VXPG_TREE_GLOBAL_NODES], 1u);
        }
    }
    const uint4 info = gVXPGClusterInfo[gVXPGCluster[compact]];
    const uint local = gVXPGCompactToLeaf[compact] >> localTreeLevel;
    if (local == 0) return;
    const uint address = info.z + local;
    InterlockedExchange(gVXPGDirtyNodes[2*gVXPGParams.globalLeafCapacity + address], gVXPGParams.generation, previous);
    if (previous != gVXPGParams.generation)
    {
        gVXPGForest[address].mass = gVXPGForest[info.z+2*local].mass + gVXPGForest[info.z+2*local+1].mass;
        InterlockedAdd(gVXPGTreeState[RTPT_VXPG_TREE_FOREST_NODES], 1u);
    }
}
