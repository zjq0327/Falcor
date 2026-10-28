#pragma once
import Scene.Scene;
import Utils.Sampling.SampleGeneratorInterface;
#include "RTPTLocalLightModel.slang"
#include "RTPTLocalLightFeedback.slang"

float rtptLocalGlobalSelectionPmf(uint category, uint index)
{
    if (category == RTPT_LIGHT_CATEGORY_EMISSIVE)
    {
#if USE_EMISSIVE_LIGHTS
        const uint count = gScene.lightCollection.getActiveTriangleCount();
        if (count == 0 || index >= gScene.lightCollection.getTriangleCount()) return 0.f;
        if (gScene.lightCollection.getActiveTriangleIndex(index) == RTPT_LOCAL_LIGHT_INVALID) return 0.f;
        return 1.f / float(count);
#else
        return 0.f;
#endif
    }
    if (category == RTPT_LIGHT_CATEGORY_ANALYTIC)
    {
#if USE_ANALYTIC_LIGHTS
        const uint count = gScene.getLightCount();
        return count > 0 && index < count ? 1.f / float(count) : 0.f;
#else
        return 0.f;
#endif
    }
    return 0.f;
}

// One immutable query snapshot. Tile/Grid support is resolved once and reused
// by branch selection and by the actual mixture PMF of the selected light.
struct RTPTLocalPreparedDistribution
{
    uint gridSlot;
    uint gridCount;
    float gridTotal;
    uint tileNode;
    uint tileCount;
    uint tileSupportMask;
    float tileTotal;
    float tileFraction;
    float gridFraction;
};

RTPTLocalPreparedDistribution rtptLocalPrepareDistribution(RTPTLightingContext context, uint kind)
{
    RTPTLocalPreparedDistribution d = {};
    d.gridSlot = rtptLocalFindCell(context.positionW);
    d.gridCount = rtptLocalGridSize(d.gridSlot,kind);
    d.gridTotal = rtptLocalGridTotal(d.gridSlot,kind);
    d.tileNode = RTPT_LOCAL_LIGHT_INVALID;
    const bool grid = d.gridCount > 0 && d.gridTotal > 0.f && isfinite(d.gridTotal);
    if (!grid) return d;
    if (gLocalLightParams.tileEnabled != 0 && context.kind == RTPT_LIGHT_QUERY_MAIN_PRIMARY &&
        context.pathDepth == 0 && all(context.pixel < gLocalLightParams.frameDim))
    {
        const uint node = gLocalPixelToTile[context.pixel];
        if (node < gLocalLightParams.tileNodeCount && gLocalTileState[node].z != 0)
        {
            d.tileCount = min(gLocalTileState[node].w,gLocalLightParams.tileCandidates);
            for(uint i=0;i<d.tileCount;++i)
            {
                const uint offset = node*gLocalLightParams.tileCandidates+i;
                const uint2 key = gLocalTileLights[offset];
                const float weight = max(0.f,gLocalTileWeights[offset]);
                if (key.x == kind && weight > 0.f && isfinite(weight) &&
                    rtptLocalGridContains(d.gridSlot,kind,key.y))
                {
                    d.tileSupportMask |= 1u << i;
                    d.tileTotal += weight;
                }
            }
            if (d.tileTotal > 0.f && isfinite(d.tileTotal)) d.tileNode = node;
            else { d.tileTotal = 0.f; d.tileSupportMask = 0u; }
        }
    }
    const bool tile = d.tileNode != RTPT_LOCAL_LIGHT_INVALID;
    d.tileFraction = tile ? .75f : 0.f;
    d.gridFraction = tile ? .25f : 1.f;
    return d;
}

float rtptLocalTilePmf(RTPTLocalPreparedDistribution d, uint kind, uint index)
{
    if(d.tileNode == RTPT_LOCAL_LIGHT_INVALID || !(d.tileTotal > 0.f)) return 0.f;
    float weight = 0.f;
    for(uint i=0;i<d.tileCount;++i)
    {
        if ((d.tileSupportMask & (1u << i)) == 0u) continue;
        const uint offset = d.tileNode*gLocalLightParams.tileCandidates+i;
        if(all(gLocalTileLights[offset] == uint2(kind,index))) weight += max(0.f,gLocalTileWeights[offset]);
    }
    return weight / d.tileTotal;
}

float rtptLocalEvalSelectionPmf(RTPTLocalPreparedDistribution d, RTPTLightKey key)
{
    if (key.sceneGeneration != gLocalLightParams.sceneGeneration) return 0.f;
    const uint category = key.kind == RTPT_LIGHT_KIND_EMISSIVE ? RTPT_LIGHT_CATEGORY_EMISSIVE : RTPT_LIGHT_CATEGORY_ANALYTIC;
    if(key.kind != RTPT_LIGHT_KIND_EMISSIVE && key.kind != RTPT_LIGHT_KIND_ANALYTIC) return 0.f;
    const float global = rtptLocalGlobalSelectionPmf(category,key.index);
    if(!(global>0.f))return 0.f;
    if (!(d.gridFraction > 0.f)) return global;
    return d.gridFraction*rtptLocalGridPmf(d.gridSlot,key.kind,key.index)+
        d.tileFraction*rtptLocalTilePmf(d,key.kind,key.index);
}

float rtptLocalEvalSelectionPmf(RTPTLightingContext context, RTPTLightKey key)
{
    if (key.sceneGeneration != gLocalLightParams.sceneGeneration) return 0.f;
    if(key.kind != RTPT_LIGHT_KIND_EMISSIVE && key.kind != RTPT_LIGHT_KIND_ANALYTIC) return 0.f;
    if(gLocalLightParams.gridEnabled==0 && gLocalLightParams.tileEnabled==0)
        return rtptLocalGlobalSelectionPmf(key.kind == RTPT_LIGHT_KIND_EMISSIVE ? RTPT_LIGHT_CATEGORY_EMISSIVE : RTPT_LIGHT_CATEGORY_ANALYTIC,key.index);
    return rtptLocalEvalSelectionPmf(rtptLocalPrepareDistribution(context,key.kind),key);
}

// Use one branch draw and an independent integer Grid draw for full support.
// The lighting adapter continues to consume the light's geometric samples.
bool rtptLocalSelectLight<S : ISampleGenerator>(
    uint category, RTPTLightingContext context, inout S sg, out RTPTLocalLightSelection selection)
{
    selection = {};
    selection.key.kind = RTPT_LIGHT_KIND_INVALID;
    selection.key.index = RTPT_LOCAL_LIGHT_INVALID;
    selection.key.sceneGeneration = gLocalLightParams.sceneGeneration;
    selection.sourceBranch = RTPT_LIGHT_SOURCE_GLOBAL;
    selection.snapshotGeneration = gLocalLightParams.proposalGeneration;
    uint count=0;
    uint kind=RTPT_LIGHT_KIND_INVALID;
    if (category == RTPT_LIGHT_CATEGORY_EMISSIVE)
    {
#if USE_EMISSIVE_LIGHTS
        count = gScene.lightCollection.getActiveTriangleCount();
        kind = RTPT_LIGHT_KIND_EMISSIVE;
#else
        return false;
#endif
    }
    else if (category == RTPT_LIGHT_CATEGORY_ANALYTIC)
    {
#if USE_ANALYTIC_LIGHTS
        count = gScene.getLightCount();
        kind = RTPT_LIGHT_KIND_ANALYTIC;
#else
        return false;
#endif
    }
    else return false;
    if(count==0)return false;
    const float u=sampleNext1D(sg);
    uint index=RTPT_LOCAL_LIGHT_INVALID;
    selection.key.kind=kind;
    selection.referenceSelectionPmf=1.f/float(count);
    const bool guided = gLocalLightParams.gridEnabled!=0;
    RTPTLocalPreparedDistribution d = {};
    if(guided)
    {
        d=rtptLocalPrepareDistribution(context,kind);
        if(gLocalLightParams.gridEnabled!=0)
        {
            if(gLocalLightParams.debugEnabled!=0)
            {
                uint ignored;
                InterlockedAdd(gLocalGridStats[6],1u,ignored);
                if(d.gridSlot==RTPT_LOCAL_LIGHT_INVALID)InterlockedAdd(gLocalGridStats[7],1u,ignored);
            }
        }
        if(u<d.tileFraction)
        {
            float target=min(u/d.tileFraction,.99999994f)*d.tileTotal;
            for(uint i=0;i<d.tileCount;++i)
            {
                if ((d.tileSupportMask & (1u << i)) == 0u) continue;
                const uint offset=d.tileNode*gLocalLightParams.tileCandidates+i;
                const uint2 key=gLocalTileLights[offset];
                const float weight=max(0.f,gLocalTileWeights[offset]);
                if(!(weight>0.f))continue;
                index=key.y;
                if(target<weight)break;
                target-=weight;
            }
            selection.sourceBranch=RTPT_LIGHT_SOURCE_TILE;
        }
        else if(u<d.tileFraction+d.gridFraction)
        {
            // Remapping the branch draw would leave some one-bin intervals unreachable.
            const uint randomBin=sg.next()>>8u;
            const uint base=rtptLocalGridBase(d.gridSlot,kind);
            const uint entry=gLocalLightParams.cdfEnabled!=0u ?
                rtptFullCdfUpperBound(gLocalFullCdf,base,d.gridCount,randomBin) :
                rtptFullCdfLinear(gLocalFullCdf,base,d.gridCount,randomBin,false);
            if(entry<d.gridCount)index=rtptLocalGridLightIndex(d.gridSlot,kind,entry);
            selection.sourceBranch=RTPT_LIGHT_SOURCE_GRID;
        }
    }
    if(selection.sourceBranch==RTPT_LIGHT_SOURCE_GLOBAL)
    {
        const uint ordered=min(uint(u*count),count-1u);
        if(kind==RTPT_LIGHT_KIND_EMISSIVE)
        {
#if USE_EMISSIVE_LIGHTS
            index=gScene.lightCollection.activeTriangles[ordered];
#endif
        }
        else index=ordered;
    }
    selection.key.index=index;
    if(index==RTPT_LOCAL_LIGHT_INVALID)return false;
    selection.selectionPmf=guided ? rtptLocalEvalSelectionPmf(d,selection.key) : selection.referenceSelectionPmf;
    if(gLocalLightParams.debugEnabled!=0u)
    {
        uint ignored;
        InterlockedAdd(gLocalGridStats[8u+min(context.kind,3u)*3u+selection.sourceBranch],1u,ignored);
    }
    return selection.selectionPmf>0.f && isfinite(selection.selectionPmf);
}
