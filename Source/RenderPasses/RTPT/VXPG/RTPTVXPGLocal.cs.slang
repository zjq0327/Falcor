#include "RTPTVXPGHistoryResolve.slang"
#include "RTPTVXPGDistribution.slang"

cbuffer VXPGLocalLevel { uint localTreeLevel; };

uint rtptVXPGGlobalBase()
{
    return gVXPGWorkArgs[0];
}

[numthreads(1,1,1)]
void beginLocal(uint3 tid : SV_DispatchThreadID)
{
    uint reason = gVXPGParams.treeReset != 0 ? 1u : 0u;
    if (gVXPGTreeState[7] + 1u >= gVXPGParams.treeRefreshFrames) reason |= 2u;
    if (gVXPGTreeState[8] == 0) reason |= 8u;
    gVXPGTreeState[0] = reason != 0 ? 1u : 0u;
    gVXPGTreeState[10] = reason;
    gVXPGTreeState[2] = gVXPGTreeState[5] = gVXPGTreeState[6] = gVXPGTreeState[9] = 0;
}

[numthreads(256,1,1)]
void resolveLocal(uint3 tid : SV_DispatchThreadID)
{
    const uint cell = tid.x;
    if (cell >= rtptVXPGGeometryCount()) return;
    const float mass = rtptVXPGResolveMass(cell);
    gVXPGCellMass[cell] = mass;
    const bool wasActive = gVXPGInverse[cell] != RTPT_VXPG_INVALID;
    if (wasActive != (mass > 0.f)) InterlockedAdd(gVXPGTreeState[9], 1u);
}

[numthreads(1,1,1)]
void selectLocal(uint3 tid : SV_DispatchThreadID)
{
    if (gVXPGTreeState[9] != 0) { gVXPGTreeState[0] = 1; gVXPGTreeState[10] |= 4u; }
    if (gVXPGState[4] != 0 || gVXPGState[11] != 0) { gVXPGTreeState[0] = 1; gVXPGTreeState[10] |= 8u; }
    gVXPGState[3] = rtptVXPGReuseTopology() ? gVXPGTreeState[1] : 0u;
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
        InterlockedAdd(gVXPGState[3], 1u, index);
        if (index >= gVXPGParams.activeCapacity) { InterlockedOr(gVXPGState[4], 1u); return; }
        gVXPGCompact[index] = cell;
        gVXPGInverse[cell] = index;
        gVXPGMass[index] = mass;
    }
    else if (mass > 0.f)
    {
        const uint index = gVXPGInverse[cell];
        if (index >= gVXPGTreeState[1] || index >= gVXPGParams.activeCapacity)
        { InterlockedAdd(gVXPGState[11], 1u); return; }
        // Exact change detection: no energy is dropped by a dirty threshold.
        if (mass != gVXPGMass[index])
        {
            gVXPGMass[index] = mass;
            uint dirty;
            InterlockedAdd(gVXPGTreeState[2], 1u, dirty);
            gVXPGDirtyLeaves[dirty] = index;
        }
    }
}

[numthreads(1,1,1)]
void localWork(uint3 tid : SV_DispatchThreadID)
{
    gVXPGLocalArgs[0] = max(1u, (gVXPGTreeState[2] + 255u) / 256u);
    gVXPGLocalArgs[1] = gVXPGLocalArgs[2] = 1;
}

[numthreads(256,1,1)]
void localLeaves(uint3 tid : SV_DispatchThreadID)
{
    if (!rtptVXPGReuseTopology() || tid.x >= gVXPGTreeState[2]) return;
    const uint compact = gVXPGDirtyLeaves[tid.x];
    gVXPGGlobalTree[rtptVXPGGlobalBase() + compact] = gVXPGMass[compact];
    InterlockedAdd(gVXPGTreeState[5], 1u);
    const uint4 info = gVXPGClusterInfo[gVXPGCluster[compact]];
    const uint address=info.z+gVXPGCompactToLeaf[compact];
    gVXPGForest[address].mass = gVXPGMass[compact];
    InterlockedAdd(gVXPGTreeState[6], 1u);
}

[numthreads(256,1,1)]
void localLevel(uint3 tid : SV_DispatchThreadID)
{
    if (!rtptVXPGReuseTopology() || tid.x >= gVXPGTreeState[2]) return;
    const uint compact = gVXPGDirtyLeaves[tid.x];
    const uint node = (rtptVXPGGlobalBase() + compact) >> localTreeLevel;
    uint previous;
    if (node != 0)
    {
        InterlockedExchange(gVXPGDirtyNodes[node], gVXPGParams.generation, previous);
        if (previous != gVXPGParams.generation)
        {
            gVXPGGlobalTree[node] = gVXPGGlobalTree[2*node] + gVXPGGlobalTree[2*node+1];
            InterlockedAdd(gVXPGTreeState[5], 1u);
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
        InterlockedAdd(gVXPGTreeState[6], 1u);
    }
}
