#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
#include "RTPTVXPGDistribution.slang"

RWStructuredBuffer<uint> gVXPGClusterArgs;
RWTexture2D<float4> gVXPGDebug;

// Both endpoints are actual surface samples. Normal orientation and endpoint
// offsets are independent of the proposal boxes; alpha testing uses SceneRayQuery.
bool rtptVXPGVisible(float3 a, float3 na, float3 b, float3 nb)
{
    const float3 delta = b-a;
    const float distance = length(delta);
    if (!(distance > 1.e-5f) || dot(na, delta) <= 0.f || dot(nb, -delta) <= 0.f) return false;
    const float epsilon = min(distance * 0.001f, max(1.e-5f, min(rtptVXPGSurfaceSize(a),rtptVXPGSurfaceSize(b)) * 1.e-3f));
    const float3 origin = a + na * epsilon, target = b + nb * epsilon;
    const float3 segment = target-origin;
    const float length = sqrt(dot(segment, segment));
    if (!(length > 2.f*epsilon)) return false;
    SceneRayQuery<true> query;
    rtptVXPGCountVisibility(2u);
    return query.traceVisibilityRay(Ray(origin, segment/length, 0.f, length-epsilon));
}

[numthreads(128,1,1)]
void representativeRows(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    const uint i=tid.x;
    if (i>=128) return;
    const uint2 tile=uint2(i%16,i/16);
    const uint key=i ^ (gVXPGParams.frameIndex*0x9e3779b9u);
    const float2 jitter=float2(rtptVXPGUniform(key),rtptVXPGUniform(key^0x68bc21ebu));
    const uint2 p=min(uint2((float2(tile)+jitter)*float2(gVXPGParams.frameDim)/float2(16,8)),gVXPGParams.frameDim-1);
    gVXPGRowPosition[i]=gVXPGPrimaryPosition[p];
    gVXPGRowNormal[i]=gVXPGPrimaryNormal[p];
}

[numthreads(64,1,1)]
void prepareClusterArgs(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology())
    {
        // Preserve topology/allocation; reset only current-frame activity.
        if (tid.x == 0 || tid.x == 2 || tid.x == 3 || tid.x == 5 || tid.x == 6) gVXPGClusterState[tid.x] = 0;
        if (tid.x < 3) gVXPGClusterArgs[tid.x] = 1;
        return;
    }
    if (tid.x<8) gVXPGClusterState[tid.x]=0;
    if (tid.x<32) gVXPGClusterInfo[tid.x]=0;
    if (tid.x==0)
    {
        const uint count=min(gVXPGState[3],gVXPGParams.activeCapacity);
        gVXPGClusterArgs[0]=max(1u,min(1024u,count));
        gVXPGClusterArgs[1]=max(1u,(count+1023)/1024);
        gVXPGClusterArgs[2]=1;
    }
}

groupshared uint descriptor[4];
[numthreads(128,1,1)]
void rowVisibility(uint3 group : SV_GroupID, uint lane : SV_GroupIndex)
{
    if (rtptVXPGReuseTopology()) return;
    const uint compact=group.x+group.y*1024;
    if (compact>=min(gVXPGState[3],gVXPGParams.activeCapacity)) return;
    if (lane<4) descriptor[lane]=0;
    GroupMemoryBarrierWithGroupSync();
    const uint cell=gVXPGCompact[compact];
    const float4 row=gVXPGRowPosition[lane], vpl=gVXPGRepresentativePosition[cell];
    bool visible=false;
    if (row.w!=0.f && vpl.w!=0.f)
        visible=rtptVXPGVisible(row.xyz,gVXPGRowNormal[lane].xyz,vpl.xyz,gVXPGRepresentativeNormal[cell].xyz);
    if (visible)
    {
        InterlockedOr(descriptor[lane/32],1u<<(lane%32));
        rtptVXPGCountVisibility(3u);
    }
    GroupMemoryBarrierWithGroupSync();
    if (lane==0) gVXPGVisibility[compact]=uint4(descriptor[0],descriptor[1],descriptor[2],descriptor[3]);
}

// MRCS K-means++ over 1024 sampled voxel candidates. Uses explicit group
// reduction, so wave width and vendor-specific ballot layout are not assumed.
groupshared uint candidateIds[1024];
groupshared uint4 candidateDesc[1024];
groupshared float candidateMass[1024];
groupshared float candidateDistance[1024];
groupshared float reduction[256];
groupshared uint selectedSeed;
[numthreads(256,1,1)]
void seedClusters(uint lane : SV_GroupIndex)
{
    if (rtptVXPGReuseTopology()) return;
    const uint count=min(gVXPGState[3],gVXPGParams.activeCapacity);
    if (count==0) return;
    for (uint j=0;j<4;++j)
    {
        const uint i=lane+j*256;
        const uint compact=rtptVXPGHash(i ^ (gVXPGParams.frameIndex*0x85ebca6bu))%count;
        candidateIds[i]=compact;
        candidateDesc[i]=gVXPGVisibility[compact];
        candidateMass[i]=gVXPGMass[compact];
        candidateDistance[i]=3.402823e38f;
    }
    if (lane==0) selectedSeed=rtptVXPGHash(gVXPGParams.frameIndex^0xc2b2ae35u)%1024;
    GroupMemoryBarrierWithGroupSync();
    for (uint seed=0;seed<gVXPGParams.clusterCount;++seed)
    {
        const uint selected=selectedSeed;
        const uint4 center=candidateDesc[selected];
        const float intensity=candidateMass[selected];
        if (lane==0)
        {
            RTPTVXPGClusterSeed record={};
            record.visibility=center; record.intensity=intensity; record.compact=candidateIds[selected];
            gVXPGSeeds[seed]=record;
        }
        float weight=0.f;
        for (uint j=0;j<4;++j)
        {
            const uint i=lane+j*256;
            const float distance=rtptVXPGClusterDistance(candidateDesc[i],center,candidateMass[i],intensity);
            candidateDistance[i]=min(candidateDistance[i],distance);
            weight+=candidateDistance[i]*candidateDistance[i];
        }
        reduction[lane]=weight;
        GroupMemoryBarrierWithGroupSync();
        for (uint stride=128;stride>0;stride/=2)
        {
            if (lane<stride) reduction[lane]+=reduction[lane+stride];
            GroupMemoryBarrierWithGroupSync();
        }
        if (lane==0)
        {
            float value=rtptVXPGUniform(seed^gVXPGParams.frameIndex^0x27d4eb2fu)*reduction[0];
            selectedSeed=(seed+1)%1024;
            if (reduction[0]>0.f && isfinite(reduction[0]))
            {
                for (uint i=0;i<1024;++i)
                {
                    const float w=candidateDistance[i]*candidateDistance[i];
                    if (value<w) { selectedSeed=i; break; }
                    value-=w;
                }
            }
        }
        GroupMemoryBarrierWithGroupSync();
    }
}

[numthreads(256,1,1)]
void assignClusters(uint3 tid : SV_DispatchThreadID)
{
    if (rtptVXPGReuseTopology()) return;
    const uint i=tid.x;
    if (i>=min(gVXPGState[3],gVXPGParams.activeCapacity)) return;
    uint best=0;
    float minimum=3.402823e38f;
    const uint4 descriptor=gVXPGVisibility[i];
    for (uint c=0;c<gVXPGParams.clusterCount;++c)
    {
        const RTPTVXPGClusterSeed seed=gVXPGSeeds[c];
        const float distance=rtptVXPGClusterDistance(descriptor,seed.visibility,gVXPGMass[i],seed.intensity);
        if (distance<minimum) { minimum=distance; best=c; }
    }
    gVXPGCluster[i]=best;
    InterlockedAdd(gVXPGClusterInfo[best].y,1u);
}

[numthreads(64,1,1)]
void superpixelCenters(uint3 tid : SV_DispatchThreadID)
{
    const uint row=tid.x;
    if (row>=gVXPGParams.superpixelDim.x*gVXPGParams.superpixelDim.y) return;
    gVXPGSuperpixelCount[row]=0;
    const uint2 tile=uint2(row%gVXPGParams.superpixelDim.x,row/gVXPGParams.superpixelDim.x);
    const uint2 lo=tile*gVXPGParams.superpixelSize, hi=min(lo+gVXPGParams.superpixelSize,gVXPGParams.frameDim);
    uint2 pixel=(lo+hi)/2;
    float4 position=gVXPGPrimaryPosition[pixel];
    if (position.w==0.f)
    {
        // Bounded search of actual samples; no averaged point inside geometry.
        for (uint j=0;j<16 && position.w==0.f;++j)
        {
            pixel=min(lo+uint2((uint2(j%4,j/4)*2+1)*(hi-lo)/8),hi-1);
            position=gVXPGPrimaryPosition[pixel];
        }
    }
    gVXPGSuperpixelPosition[row]=position;
    gVXPGSuperpixelNormal[row]=position.w!=0.f?gVXPGPrimaryNormal[pixel]:float4(0.f);
    if (position.w!=0.f) InterlockedAdd(gVXPGClusterState[0],1u);
}

[numthreads(8,8,1)]
void associateSuperpixels(uint3 tid : SV_DispatchThreadID)
{
    const uint2 pixel=tid.xy;
    if (any(pixel>=gVXPGParams.frameDim)) return;
    uint4 ids=RTPT_VXPG_INVALID;
    float4 distances=3.402823e38f;
    const float4 p=gVXPGPrimaryPosition[pixel];
    if (p.w!=0.f)
    {
        const float3 normal=gVXPGPrimaryNormal[pixel].xyz;
        const int2 tile=int2(pixel/gVXPGParams.superpixelSize);
        bool compatibleFound=false;
        for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x)
        {
            const int2 neighbor=tile+int2(x,y);
            if (any(neighbor<0) || any(neighbor>=int2(gVXPGParams.superpixelDim))) continue;
            const uint row=uint(neighbor.y)*gVXPGParams.superpixelDim.x+uint(neighbor.x);
            const float4 center=gVXPGSuperpixelPosition[row];
            if (center.w==0.f) continue;
            const bool compatible=dot(normal,gVXPGSuperpixelNormal[row].xyz)>0.01f;
            if (compatible && !compatibleFound) { ids=RTPT_VXPG_INVALID; distances=3.402823e38f; compatibleFound=true; }
            if (compatibleFound && !compatible) continue;
            const float2 screen=(float2(pixel)-(float2(neighbor)+0.5f)*gVXPGParams.superpixelSize)/gVXPGParams.superpixelSize;
            const float3 world=(p.xyz-center.xyz)/max(rtptVXPGSurfaceSize(p.xyz),1.e-5f);
            const float distance=max(1.e-6f,dot(world,world)+dot(screen,screen));
            uint maximum=0;
            for (uint k=1;k<4;++k) if (distances[k]>distances[maximum]) maximum=k;
            if (distance<distances[maximum]) { distances[maximum]=distance; ids[maximum]=row; }
        }
    }
    float4 weights=0.f;
    for (uint k=0;k<4;++k) if (ids[k]!=RTPT_VXPG_INVALID) weights[k]=1.f/distances[k];
    // Count exactly the representation consumed by scatter. Normalization can
    // round distinct adjacent weights to a tie, changing the first maximum.
    weights=rtptVXPGNormalizeFuzzyWeights(weights);
    gVXPGFuzzyIds[pixel]=ids;
    gVXPGFuzzyWeights[pixel]=weights;
    const uint row=rtptVXPGNearestFuzzyRow(ids,weights);
    if(row!=RTPT_VXPG_INVALID)InterlockedAdd(gVXPGSuperpixelCount[row],1u);
}

groupshared uint superpixelScan[256];
[numthreads(256,1,1)]
void prefixSuperpixels(uint3 tid : SV_DispatchThreadID,uint lane : SV_GroupIndex,uint3 group : SV_GroupID)
{
    const uint rows=gVXPGParams.superpixelDim.x*gVXPGParams.superpixelDim.y;
    const uint count=tid.x<rows?gVXPGSuperpixelCount[tid.x]:0u;
    superpixelScan[lane]=count;
    GroupMemoryBarrierWithGroupSync();
    for(uint offset=1;offset<256;offset*=2)
    {
        const uint value=lane>=offset?superpixelScan[lane-offset]:0;
        GroupMemoryBarrierWithGroupSync();
        superpixelScan[lane]+=value;
        GroupMemoryBarrierWithGroupSync();
    }
    if(tid.x<rows)
    {
        gVXPGSuperpixelRange[tid.x]=uint2(superpixelScan[lane]-count,count);
        gVXPGSuperpixelCount[tid.x]=0;
    }
    if(lane==255)gVXPGSuperpixelBlocks[group.x]=superpixelScan[255];
}
[numthreads(1,1,1)]
void prefixSuperpixelBlocks(uint3 tid : SV_DispatchThreadID)
{
    const uint rows=gVXPGParams.superpixelDim.x*gVXPGParams.superpixelDim.y;
    uint prefix=0;
    // The resource budget bounds the number of screen pixels before allocation.
    for(uint block=0;block<(rows+255)/256;++block)
    {
        const uint count=gVXPGSuperpixelBlocks[block];
        gVXPGSuperpixelBlocks[block]=prefix;
        prefix+=count;
    }
    if(prefix>gVXPGParams.frameDim.x*gVXPGParams.frameDim.y)InterlockedOr(gVXPGState[4],8u);
    gVXPGState[26]=prefix;
}
[numthreads(256,1,1)]
void finalizeSuperpixelRanges(uint3 tid : SV_DispatchThreadID)
{
    const uint row=tid.x;
    if(row>=gVXPGParams.superpixelDim.x*gVXPGParams.superpixelDim.y)return;
    gVXPGSuperpixelRange[row].x+=gVXPGSuperpixelBlocks[row/256];
}
[numthreads(8,8,1)]
void scatterSuperpixelPoints(uint3 tid : SV_DispatchThreadID)
{
    const uint2 pixel=tid.xy;
    if(any(pixel>=gVXPGParams.frameDim))return;
    const uint4 ids=gVXPGFuzzyIds[pixel];
    const float4 weights=gVXPGFuzzyWeights[pixel];
    const uint row=rtptVXPGNearestFuzzyRow(ids,weights);
    if(row==RTPT_VXPG_INVALID)return;
    uint slot;
    InterlockedAdd(gVXPGSuperpixelCount[row],1u,slot);
    const uint2 range=gVXPGSuperpixelRange[row];
    if(slot>=range.y || range.x+slot>=gVXPGParams.frameDim.x*gVXPGParams.frameDim.y)
    {InterlockedOr(gVXPGState[4],16u);return;}
    gVXPGSuperpixelPoints[range.x+slot]=pixel.x+pixel.y*gVXPGParams.frameDim.x;
}

float rtptVXPGPairContribution(uint row,uint cluster,uint sampleIndex,uint4 info,uint2 range)
{
    const uint key=rtptVXPGHash(row*131u+cluster*17u+sampleIndex*0x9e3779b9u+gVXPGParams.frameIndex*0x85ebca6bu);
    const uint compact=rtptVXPGClusterMember(info,rtptVXPGUniform(key));
    if(compact==RTPT_VXPG_INVALID)return 0.f;
    const uint cell=gVXPGCompact[compact];
    const uint point=min(uint(rtptVXPGUniform(key^0xc2b2ae35u)*range.y),range.y-1);
    const uint pixelIndex=gVXPGSuperpixelPoints[range.x+point];
    const uint2 pixel=uint2(pixelIndex%gVXPGParams.frameDim.x,pixelIndex/gVXPGParams.frameDim.x);
    const float3 a=gVXPGPrimaryPosition[pixel].xyz, na=gVXPGPrimaryNormal[pixel].xyz;
    const float3 b=gVXPGRepresentativePosition[cell].xyz, nb=gVXPGRepresentativeNormal[cell].xyz;
    const float3 delta=b-a;
    const float distance2=dot(delta,delta);
    if(!(distance2>1.e-10f) || !rtptVXPGVisible(a,na,b,nb))return 0.f;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
#if HIT_INFO_USE_COMPRESSION
    const HitInfo hit=HitInfo(gVXPGPrimaryHit[pixel].xy);
#else
    const HitInfo hit=HitInfo(gVXPGPrimaryHit[pixel]);
#endif
    if(!hit.isValid() || hit.getType()!=HitType::Triangle)return 0.f;
    const TriangleHit triangle=hit.getTriangleHit();
    const uint materialID=gScene.getMaterialID(triangle.instanceID);
    ShadingData sd=gScene.materials.prepareShadingData(gScene.getVertexData(triangle),materialID,normalize(gScene.camera.data.posW-a));
    sd.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance mi=gScene.materials.getMaterialInstance(sd,ExplicitLodTextureSampler(0.f));
    SampleGenerator sg=SampleGenerator(uint2(row,cluster),key);
    const float3 f=mi.eval(sd,delta/sqrt(distance2),sg);
    const float contribution=max(f.x,max(f.y,f.z))/distance2;
    if(isfinite(contribution) && contribution>=0.f)
    {
        if(contribution>0.f)rtptVXPGCount(25u);
        return contribution/32.f;
    }
    InterlockedAdd(gVXPGState[11],1u);
#endif
    return 0.f;
}
groupshared float topContributions[32];
[numthreads(32,1,1)]
void topLevelLeaves(uint3 group : SV_GroupID,uint lane : SV_GroupIndex)
{
    const uint matrix=group.x+group.y*1024;
    const uint row=matrix/32,cluster=matrix%32;
    if(row>=gVXPGParams.superpixelDim.x*gVXPGParams.superpixelDim.y)return;
    const uint4 info=gVXPGClusterInfo[cluster];
    const uint2 range=gVXPGSuperpixelRange[row];
    const float4 source=gVXPGSuperpixelPosition[row];
    const bool valid=gVXPGClusterState[6]==gVXPGParams.generation && cluster<gVXPGParams.clusterCount && info.y>0 && range.y>0 && source.w!=0.f;
    // One group evaluates the reference's 32 actual point pairs in parallel.
    float contribution=0.f;
    if(valid)contribution=rtptVXPGPairContribution(row,cluster,lane,info,range);
    topContributions[lane]=contribution;
    GroupMemoryBarrierWithGroupSync();
    for(uint stride=16;stride>0;stride/=2)
    {
        if(lane<stride)topContributions[lane]+=topContributions[lane+stride];
        GroupMemoryBarrierWithGroupSync();
    }
    if(lane==0)
    {
        float weight=0.f;
        if(valid)
        {
            const RTPTVXPGNode root=gVXPGForest[info.z+1];
            weight=0.95f*root.mass*topContributions[0]+0.05f*rtptVXPGNodeImportance(root,source.xyz,gVXPGSuperpixelNormal[row].xyz);
        }
        gVXPGTopTree[row*64+32+cluster]=isfinite(weight)?weight:0.f;
    }
}

[numthreads(64,1,1)]
void topLevelParents(uint3 tid : SV_DispatchThreadID)
{
    const uint row=tid.x;
    if (row>=gVXPGParams.superpixelDim.x*gVXPGParams.superpixelDim.y) return;
    const uint base=row*64;
    for (uint i=31;i>0;--i) gVXPGTopTree[base+i]=gVXPGTopTree[base+2*i]+gVXPGTopTree[base+2*i+1];
    if (gVXPGTopTree[base+1]>0.f) InterlockedAdd(gVXPGClusterState[5],1u);
}

[numthreads(8,8,1)]
void debugDistribution(uint3 tid : SV_DispatchThreadID)
{
    if (any(tid.xy>=gVXPGParams.frameDim)) return;
    const float4 p=gVXPGPrimaryPosition[tid.xy];
    float3 color=0.f;
    uint id=RTPT_VXPG_INVALID;
    if (p.w!=0.f)
    {
        const uint cell=rtptVXPGOwner(p.xyz);
        if (gVXPGParams.debugMode==1)
        {
            const float4 weights=gVXPGFuzzyWeights[tid.xy];
            uint dominant=0;
            for(uint k=1;k<4;++k)if(weights[k]>weights[dominant])dominant=k;
            id=gVXPGFuzzyIds[tid.xy][dominant];
        }
        else if (cell!=RTPT_VXPG_INVALID)
        {
            const uint compact=gVXPGInverse[cell];
            if (compact!=RTPT_VXPG_INVALID && compact<gVXPGParams.activeCapacity)
            {
                id=gVXPGCluster[compact];
                if (gVXPGParams.debugMode==3)
                {
                    const uint4 v=countbits(gVXPGVisibility[compact]);
                    color=float3(float(v.x+v.y+v.z+v.w)/128.f);
                }
            }
        }
        if (gVXPGParams.debugMode!=3 && id!=RTPT_VXPG_INVALID)
            color=frac(float3(0.61803399f,0.41421356f,0.73205081f)*float(id+1));
    }
    gVXPGDebug[tid.xy]=float4(color,1.f);
}
