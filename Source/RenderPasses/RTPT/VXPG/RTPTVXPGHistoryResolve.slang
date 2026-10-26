#pragma once
#include "RTPTVXPGGrid.slang"

// Resolve observations into persistent importance; shared by update kernels.
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
