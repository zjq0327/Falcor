#include "RTPTVXPGTypes.slang"

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

RTPTVXPGHistory rtptVXPGAdjacentHistory(uint cell,RTPTVXPGHistory previous,uint count)
{
    if(previous.valid!=0 || count==0)return previous;
    const float3 motion=gVXPGParams.lodCamera-gVXPGParams.lodPreviousCamera;
    if(dot(motion,motion)<=1.e-6f)return previous;
    const float3 position=gVXPGRepresentativePosition[cell].xyz;
    int4 oldKey;
    if(!rtptVXPGDistanceKey(position,gVXPGParams.lodPreviousCamera,gVXPGParams.lodSceneScale,oldKey))return previous;
    const int4 current=rtptVXPGCellIdentity(cell);
    if(abs(oldKey.w-current.w)!=1)return previous;
    const uint source=rtptVXPGFindKey(oldKey);
    if(source==RTPT_VXPG_INVALID || source==cell)return previous;
    const RTPTVXPGHistory donor=gVXPGHistoryPrevious[source];
    if(donor.valid!=1u || donor.weight<4.f || donor.age>=gVXPGParams.historyStaleFrames)return previous;
    const float3 a=gVXPGNormalPrevious[source].xyz,b=gVXPGRepresentativeNormal[cell].xyz;
    if(dot(a,b)<.8f){InterlockedAdd(gVXPGHistoryStats[5],1u);return previous;}
    const float retention=1.f-rcp(float(max(1u,gVXPGParams.historyFrames)));
    previous.mean=donor.mean;
    previous.weight=min(2.f,donor.weight*pow(retention,float(donor.age+1u)));
    previous.age=0;previous.valid=3u;
    InterlockedAdd(gVXPGHistoryStats[4],1u);
    InterlockedAdd(gVXPGHistoryStats[6],1u);
    return previous;
}

float rtptVXPGResolveMass(uint cell)
{
    if (cell >= rtptVXPGGeometryCount() || gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) return 0.f;
    const uint count = gVXPGCount[cell];
    if (gVXPGBoundMin[cell].w == 0) return 0.f;
    float mean = count > 0 ? float(gVXPGFlux[cell]) / (4096.f * float(count)) : 0.f;
    // Every VXPG model resolves its persistent importance history.
    {
        const RTPTVXPGHistory previous = rtptVXPGAdjacentHistory(cell,gVXPGHistory[cell],count);
        const RTPTVXPGHistory history = rtptVXPGResolveHistory(previous, mean, count,
            gVXPGParams.historyFrames, gVXPGParams.historyStaleFrames);
        gVXPGHistory[cell] = history;
        if (history.valid != 0) InterlockedAdd(gVXPGHistoryStats[0], 1u);
        if (history.valid != 0 && count == 0) InterlockedAdd(gVXPGHistoryStats[1], 1u);
        if (previous.valid != 0 && history.valid == 0) InterlockedAdd(gVXPGHistoryStats[2], 1u);
        if (count > 0) InterlockedAdd(gVXPGHistoryStats[3], 1u);
        if (history.valid == 0) return 0.f;
        mean = history.mean;
        {
            const float retention=1.f-rcp(float(max(1u,gVXPGParams.historyFrames)));
            // A fresh observation has full age confidence even when the window
            // is one. Avoid the shader backend's undefined pow(0, 0) case.
            const float ageConfidence = history.age == 0 ? 1.f : pow(retention, float(history.age));
            mean *= min(1.f, history.weight / 4.f) * max(.1f, ageConfidence);
        }
        // Coverage reuse can retain a different LOD of this surface. Keep its
        // history until expiry, but only publish the current camera owner.
        if (count == 0)
        {
            int4 owner;
            if (!rtptVXPGTryOwnerKey(gVXPGRepresentativePosition[cell].xyz, owner) ||
                any(owner != rtptVXPGCellIdentity(cell))) return 0.f;
        }
    }
    const float3 extent=rtptVXPGWorldMax(cell)-rtptVXPGWorldMin(cell);
    const float area=max(extent.x*extent.y,max(extent.y*extent.z,extent.z*extent.x));
    // Reference premultiplies the mean observation by the largest box-face
    // area, estimating voxel power rather than selecting by irradiance alone.
    const float mass=mean*area;
    if (!isfinite(mass)) { InterlockedAdd(gVXPGState[11],1u); return 0.f; }
    if (!(mass>0.f)) return 0.f;
    return mass;
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
        const bool published = valid && (gVXPGParams.visibilityEnabled == 0 || gVXPGClusterState[6] == gVXPGParams.generation);
        gVXPGTreeState[8] = published ? 1u : 0u;
        gVXPGTreeState[1] = min(gVXPGState[3], gVXPGParams.activeCapacity);
        const bool reuse = rtptVXPGReuseTopology();
        gVXPGTreeState[7] = reuse ? gVXPGTreeState[7] + 1u : 0u;
        if (published) gVXPGTreeState[reuse ? 4u : 3u] += 1u;
    }
}
