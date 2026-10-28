#include "RTPTLocalLightModel.slang"

[numthreads(64,1,1)]
void analyzeNodes(uint3 tid:SV_DispatchThreadID)
{
    const uint node=tid.x;
    if(node>=gLocalLightParams.tileNodeCount)return;
    uint2 origin;uint size;rtptLocalTileBounds(node,origin,size);
    uint4 state=gLocalTileState[node];
    state.z=state.w=0u;
    if(any(origin>=gLocalLightParams.frameDim)){gLocalTileState[node]=0u;return;}
    bool split=false,haveSurface=false,haveBackground=false;
    float firstDepth=0.f,firstRoughness=0.f;float3 firstNormal=0.f;
    uint2 firstHistoryKey=uint2(RTPT_LIGHT_KIND_INVALID,RTPT_LOCAL_LIGHT_INVALID);
    if(gLocalLightParams.adaptiveEnabled!=0 && size>8u)
    {
        // A stable 4x4 coverage stencil detects edges, normal/depth changes,
        // roughness changes, and confident competing light histories.
        for(uint y=0;y<4u;++y)for(uint x=0;x<4u;++x)
        {
            const uint2 pixel=min(origin+(uint2(x,y)*2u+1u)*size/8u,gLocalLightParams.frameDim-1u);
            const float4 p=gLocalPrimaryPosition[pixel];
            if(p.w==0.f){haveBackground=true;continue;}
            const float4 nr=gLocalPrimaryNormalRoughness[pixel];
            const float depth=abs(mul(gLocalLightParams.viewProjNoJitter,float4(p.xyz,1.f)).w);
            if(haveSurface)
            {
                split=split || abs(depth-firstDepth)>gLocalLightParams.depthThreshold*max(.01f,max(depth,firstDepth)) ||
                    dot(nr.xyz,firstNormal)<gLocalLightParams.normalCosThreshold || abs(nr.w-firstRoughness)>.2f;
            }
            else {firstDepth=depth;firstNormal=nr.xyz;firstRoughness=nr.w;haveSurface=true;}
            const uint2 feedbackCell=pixel/gLocalLightParams.feedbackStride;
            const RTPTLocalLightFeedbackRecord history=gLocalReprojectedHistory[feedbackCell.x+feedbackCell.y*gLocalLightParams.feedbackDim.x];
            if(rtptLocalFeedbackValid(history) && history.pixelInfo.w>=3u && history.positionScore.w>0.f)
            {
                if(firstHistoryKey.x==RTPT_LIGHT_KIND_INVALID)firstHistoryKey=history.key.xy;
                else if(any(firstHistoryKey!=history.key.xy))split=true;
            }
        }
        split=split || (haveSurface && haveBackground);
        if(split){state.x=1u;state.y=0u;}
        else
        {
            state.y=min(state.y+1u,gLocalLightParams.mergeFrames);
            if(state.y>=gLocalLightParams.mergeFrames)state.x=0u;
        }
    }
    else state.x=state.y=0u;
    gLocalTileState[node]=state;
}

[numthreads(8,8,1)]
void mapPixels(uint3 tid:SV_DispatchThreadID)
{
    if(any(tid.xy>=gLocalLightParams.frameDim))return;
    const uint2 root=tid.xy/32u,local=tid.xy%32u;
    const uint base=(root.x+root.y*gLocalLightParams.baseTileDim.x)*21u;
    uint node=base;
    if(gLocalTileState[base].x!=0u)
    {
        const uint child=local.x/16u+(local.y/16u)*2u;
        node=base+1u+child;
        if(gLocalTileState[node].x!=0u)node=base+5u+child*4u+(local.x%16u)/8u+((local.y%16u)/8u)*2u;
    }
    gLocalPixelToTile[tid.xy]=node;
}

struct RTPTTileCandidates
{
    uint2 keys[RTPT_LOCAL_MAX_TILE_LIGHTS];
    float weights[RTPT_LOCAL_MAX_TILE_LIGHTS];
    uint count;
};
void rtptTileAdd(inout RTPTTileCandidates candidates,uint2 key,float weight)
{
    if(key.x==RTPT_LIGHT_KIND_INVALID || key.y==RTPT_LOCAL_LIGHT_INVALID || !(weight>0.f) || !isfinite(weight))return;
    for(uint i=0u;i<candidates.count;++i)
        if(all(candidates.keys[i]==key)){candidates.weights[i]+=min(weight,1.e6f);return;}
    uint index=candidates.count;
    if(index<gLocalLightParams.tileCandidates)++candidates.count;
    else
    {
        index=0u;
        for(uint i=1u;i<candidates.count;++i)if(candidates.weights[i]<candidates.weights[index])index=i;
        if(weight<=candidates.weights[index])return;
    }
    candidates.keys[index]=key;candidates.weights[index]=min(weight,1.e6f);
}

[numthreads(64,1,1)]
void buildCandidates(uint3 tid:SV_DispatchThreadID)
{
    const uint node=tid.x;
    if(node>=gLocalLightParams.tileNodeCount)return;
    uint2 origin;uint size;rtptLocalTileBounds(node,origin,size);
    uint4 state=gLocalTileState[node];state.z=state.w=0u;
    if(any(origin>=gLocalLightParams.frameDim)||!rtptLocalNodeIsLeaf(node)){gLocalTileState[node].z=0u;gLocalTileState[node].w=0u;return;}
    RTPTTileCandidates candidates={};
    const uint2 end=min(origin+size,gLocalLightParams.frameDim),beginCell=origin/gLocalLightParams.feedbackStride;
    const uint2 endCell=(end+gLocalLightParams.feedbackStride-1u)/gLocalLightParams.feedbackStride;
    for(uint y=beginCell.y;y<endCell.y;++y)for(uint x=beginCell.x;x<endCell.x;++x)
    {
        const RTPTLocalLightFeedbackRecord r=gLocalReprojectedHistory[x+y*gLocalLightParams.feedbackDim.x];
        if(!rtptLocalFeedbackValid(r)||any(r.pixelInfo.xy<origin)||any(r.pixelInfo.xy>=end))continue;
        const float age=float(gLocalLightParams.frameSerial-r.key.w);
        const float confidence=min(1.f,float(r.pixelInfo.w)/4.f);
        rtptTileAdd(candidates,r.key.xy,r.positionScore.w*confidence*exp2(-age/float(max(1u,gLocalLightParams.historyFrames))));
    }
    const RTPTLocalLightFeedbackRecord probe=gLocalProbeFeedback[node];
    if(rtptLocalFeedbackValid(probe))rtptTileAdd(candidates,probe.key.xy,probe.positionScore.w);
    // Refill with independent catalog proposals. These approximate weights only
    // train the next distribution; they never replace an NEE visibility test.
    const uint2 centerPixel=min(origin+size/2u,gLocalLightParams.frameDim-1u);
    const float4 primary=gLocalPrimaryPosition[centerPixel];
    if(primary.w!=0.f)for(uint category=0u;category<2u;++category)
    {
        uint count=0u;
#if USE_EMISSIVE_LIGHTS
        if(category==0u)count=gScene.lightCollection.getActiveTriangleCount();
#endif
#if USE_ANALYTIC_LIGHTS
        if(category==1u)count=gScene.getLightCount();
#endif
        const uint kind=category==0u?RTPT_LIGHT_KIND_EMISSIVE:RTPT_LIGHT_KIND_ANALYTIC;
        const uint slot=rtptLocalFindCell(primary.xyz),gridCount=rtptLocalGridSize(slot,kind);
        for(uint j=0u;j<2u;++j)
        {
            if(count==0u)break;
            const uint h=rtptLocalHash(node*17u+gLocalLightParams.frameSerial*31u+j+category*191u);
            uint index=h%count;
            if(gridCount>0u)index=rtptLocalGridLightIndex(slot,kind,h%gridCount);
#if USE_EMISSIVE_LIGHTS
            else if(category==0u)index=gScene.lightCollection.activeTriangles[index];
#endif
            float3 center,lo,hi;float power;
            if(!rtptLocalCatalogData(kind,index,center,lo,hi,power))continue;
            const float d2=dot(center-primary.xyz,center-primary.xyz);
            rtptTileAdd(candidates,uint2(kind,index),.05f*power/max(d2,.01f));
        }
    }
    // Bounded insertion sort after key merging. The model contains each key
    // once, with the most useful entries first for sampling and inspection.
    for(uint i=1u;i<candidates.count;++i)
    {
        const uint2 key=candidates.keys[i];const float weight=candidates.weights[i];
        uint j=i;
        while(j>0u && candidates.weights[j-1u]<weight)
        {
            candidates.keys[j]=candidates.keys[j-1u];candidates.weights[j]=candidates.weights[j-1u];--j;
        }
        candidates.keys[j]=key;candidates.weights[j]=weight;
    }
    float total=0.f;
    for(uint i=0u;i<candidates.count;++i)total+=candidates.weights[i];
    if(total>0.f&&isfinite(total))
    {
        for(uint i=0u;i<candidates.count;++i)
        {
            const uint offset=node*gLocalLightParams.tileCandidates+i;
            gLocalTileLights[offset]=candidates.keys[i];gLocalTileWeights[offset]=candidates.weights[i]/total;
        }
        state.z=1u;state.w=candidates.count;
    }
    else state.z=1u;
    gLocalTileState[node].z=state.z;gLocalTileState[node].w=state.w;
}
