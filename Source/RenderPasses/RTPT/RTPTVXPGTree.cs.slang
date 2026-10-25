#include "RTPTVXPGDistribution.slang"

cbuffer VXPGClusterBuild { uint sortShift; uint sortCapacity; uint sortGroups; uint treeLevel; };
#define sortCapacity (gVXPGWorkArgs[1])
#define sortGroups (gVXPGWorkArgs[2])
RWStructuredBuffer<uint2> gVXPGSortInput;
RWStructuredBuffer<uint2> gVXPGSortOutput;
RWStructuredBuffer<uint> gVXPGHistogram;
RWStructuredBuffer<uint> gVXPGBinOffsets;

uint rtptVXPGMorton(uint3 xyz)
{
    uint result=0;
    for (uint bit=0;bit<7;++bit)
        result|=((xyz.x>>bit)&1u)<<(3*bit) | ((xyz.y>>bit)&1u)<<(3*bit+1) | ((xyz.z>>bit)&1u)<<(3*bit+2);
    return result;
}

[numthreads(256,1,1)]
void encodeVoxels(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    if (tid.x>=sortCapacity) return;
    uint2 code=uint2(RTPT_VXPG_INVALID);
    if (tid.x<min(gVXPGState[3],gVXPGParams.activeCapacity))
    {
        const uint cell=gVXPGCompact[tid.x];
        const float3 center=0.5f*(rtptVXPGWorldMin(cell)+rtptVXPGWorldMax(cell));
        const uint3 xyz=uint3(clamp((center-gVXPGParams.sortMin)/max(gVXPGParams.sortExtent,float3(1.e-6f)),0.f,1.f)*127.f);
        code=uint2((gVXPGCluster[tid.x]<<21)|rtptVXPGMorton(xyz),tid.x);
    }
    gVXPGSortOutput[tid.x]=code;
}

groupshared uint histogram[256];
groupshared uint keys[256];
[numthreads(256,1,1)]
void radixHistogram(uint3 tid : SV_DispatchThreadID, uint lane : SV_GroupIndex, uint3 group : SV_GroupID)
{
    if (rtptVXPGReuseTopology()) return;
    histogram[lane]=0;
    GroupMemoryBarrierWithGroupSync();
    if (tid.x<sortCapacity)
        InterlockedAdd(histogram[(gVXPGSortInput[tid.x].x>>sortShift)&255u],1u);
    GroupMemoryBarrierWithGroupSync();
    gVXPGHistogram[group.x*256+lane]=histogram[lane];
}

[numthreads(256,1,1)]
void radixPrefix(uint lane : SV_GroupIndex)
{
    if (rtptVXPGReuseTopology()) return;
    uint sum=0;
    for (uint group=0;group<sortGroups;++group)
    {
        const uint offset=group*256+lane;
        const uint count=gVXPGHistogram[offset];
        gVXPGHistogram[offset]=sum;
        sum+=count;
    }
    histogram[lane]=sum;
    GroupMemoryBarrierWithGroupSync();
    // 256-bin scan is bounded and independent of active voxel count.
    if (lane==0)
    {
        uint prefix=0;
        for (uint bin=0;bin<256;++bin) { gVXPGBinOffsets[bin]=prefix; prefix+=histogram[bin]; }
    }
}

[numthreads(256,1,1)]
void radixScatter(uint3 tid : SV_DispatchThreadID, uint lane : SV_GroupIndex, uint3 group : SV_GroupID)
{
    if (rtptVXPGReuseTopology()) return;
    const uint2 code=tid.x<sortCapacity?gVXPGSortInput[tid.x]:uint2(RTPT_VXPG_INVALID);
    const uint bin=(code.x>>sortShift)&255u;
    keys[lane]=bin;
    GroupMemoryBarrierWithGroupSync();
    if (tid.x>=sortCapacity) return;
    // Stable rank within this block. No wave-size assumption or CPU readback.
    uint rank=0;
    for (uint i=0;i<lane;++i) if (keys[i]==bin) ++rank;
    const uint offset=gVXPGBinOffsets[bin]+gVXPGHistogram[group.x*256+bin]+rank;
    gVXPGSortOutput[offset]=code;
}

[numthreads(1,1,1)]
void allocateForest(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    uint first=0, nodes=0, nonempty=0;
    for (uint c=0;c<32;++c)
    {
        const uint count=gVXPGClusterInfo[c].y;
        uint leaves=1;
        while (leaves<count) leaves*=2;
        gVXPGClusterInfo[c]=uint4(first,count,nodes,leaves);
        if (count>0) ++nonempty;
        first+=count;
        nodes+=2*leaves;
    }
    // Sum(nextPow2(n)) < 2*N plus empty cluster roots.
    gVXPGClusterState[1]=nonempty;
    gVXPGClusterState[4]=nodes;
    if (nodes>4*gVXPGParams.activeCapacity+64) InterlockedAdd(gVXPGState[11],1u);
}

[numthreads(256,1,1)]
void initializeForest(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    if (tid.x>=gVXPGClusterState[4]) return;
    RTPTVXPGNode node={};
    node.compact=RTPT_VXPG_INVALID;
    gVXPGForest[tid.x]=node;
}

[numthreads(256,1,1)]
void forestLeaves(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    if (tid.x>=min(gVXPGState[3],gVXPGParams.activeCapacity)) return;
    const uint compact=gVXPGSortInput[tid.x].y;
    const uint cell=gVXPGCompact[compact], cluster=gVXPGCluster[compact];
    const uint4 info=gVXPGClusterInfo[cluster];
    const uint leaf=info.z+info.w+tid.x-info.x;
    RTPTVXPGNode node={};
    node.lo=rtptVXPGWorldMin(cell); node.hi=rtptVXPGWorldMax(cell);
    node.mass=gVXPGMass[compact]; node.compact=compact;
    gVXPGForest[leaf]=node;
    gVXPGCompactToLeaf[compact]=leaf-info.z;
}

RTPTVXPGNode rtptVXPGFinalizeNode(RTPTVXPGNode node)
{
    const float3 center=0.5f*(node.lo+node.hi);
    const float radius=0.5f*length(node.hi-node.lo);
    node.lo=center;
    node.hi=float3(radius,0.f,0.f);
    return node;
}

[numthreads(256,1,1)]
void forestLevel(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    const uint c=tid.y;
    if (c>=gVXPGParams.clusterCount) return;
    const uint4 info=gVXPGClusterInfo[c];
    const uint offset=info.w>>treeLevel;
    if (offset==0 || tid.x>=offset) return;
    const uint node=info.z+offset+tid.x;
    const RTPTVXPGNode left=gVXPGForest[info.z+2*(offset+tid.x)];
    const RTPTVXPGNode right=gVXPGForest[info.z+2*(offset+tid.x)+1];
    RTPTVXPGNode parent={};
    parent.mass=left.mass+right.mass;
    parent.lo=left.mass>0.f?(right.mass>0.f?min(left.lo,right.lo):left.lo):right.lo;
    parent.hi=left.mass>0.f?(right.mass>0.f?max(left.hi,right.hi):left.hi):right.hi;
    parent.compact=RTPT_VXPG_INVALID;
    gVXPGForest[node]=parent;
#if RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY
    // This level's parents [offset,2*offset) and children [2*offset,4*offset)
    // are disjoint, and each child has exactly one consumer. The next dispatch
    // reads the still-unconverted parents, after the existing forest barrier.
    gVXPGForest[info.z+2*(offset+tid.x)]=rtptVXPGFinalizeNode(left);
    gVXPGForest[info.z+2*(offset+tid.x)+1]=rtptVXPGFinalizeNode(right);
#endif
}

[numthreads(1,1,1)]
void publishClusters(uint3 tid : SV_DispatchThreadID)
{
    float sum=0.f;
    for (uint c=0;c<gVXPGParams.clusterCount;++c)
    {
        const uint4 info=gVXPGClusterInfo[c];
        const RTPTVXPGNode clusterRoot=gVXPGForest[info.z+1];
        sum+=clusterRoot.mass;
#if RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY
        // Roots have no parent consumer; this also handles single-leaf and
        // empty clusters. The host barriers the forest before top-tree queries.
        if (!rtptVXPGReuseTopology()) gVXPGForest[info.z+1]=rtptVXPGFinalizeNode(clusterRoot);
#endif
    }
    const float root=gVXPGGlobalTree[1];
    const bool valid=gVXPGClusterState[1]>0 && isfinite(sum) && root>0.f && abs(sum-root)<=max(1.e-4f,root*1.e-4f);
    gVXPGClusterState[6]=valid?gVXPGParams.generation:0;
    if (!valid && root>0.f) InterlockedAdd(gVXPGState[11],1u);
}
