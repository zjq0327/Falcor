#pragma once
#include "RTPTVXPGTypes.slang"
#include "RTPTVXPGMath.slang"
#include "RTPTVXPGGeometry.slang"
#include "RTPTVXPGDistribution.slang"

struct RTPTVXPGContext
{
    float3 origin;
    uint currentCell;
    uint generation;
    uint leafCapacity;
    float totalMass;
    float3 normal;
    uint topRow;
    bool clustered;
};
struct RTPTVXPGCandidate
{
    float3 direction;
    float pdf;
    uint targetCell;
    uint targetCompact;
    uint generation;
};

bool rtptVXPGGetContext(float3 rayOrigin, float3 surfacePosition, uint bounce, out RTPTVXPGContext context)
{
    context = {};
    if (gVXPGParams.enabled == 0 || gVXPGParams.useGuiding == 0 || bounce >= 2) return false;
    if (gVXPGState[RTPT_VXPG_STATE_READY] != gVXPGParams.generation) return false;
    context.origin = rayOrigin;
    context.currentCell = rtptVXPGOwner(surfacePosition);
    context.generation = gVXPGParams.generation;
    context.leafCapacity = 1u << uint(firstbithigh(gVXPGParams.activeCapacity - 1u) + 1);
    context.totalMass = gVXPGGlobalTree[1];
    return context.totalMass > 0.f && isfinite(context.totalMass);
}

bool rtptVXPGGetSurfaceContext(float3 rayOrigin, float3 surfacePosition, float3 normal,
    uint2 pixel, uint sampleIndex, uint bounce, out RTPTVXPGContext context)
{
    if (!rtptVXPGGetContext(rayOrigin,surfacePosition,bounce,context)) return false;
    context.normal=normal;
    if (bounce!=0 || gVXPGParams.visibilityEnabled==0 || gVXPGClusterState[6]!=context.generation) return true;
    const uint4 ids=gVXPGFuzzyIds[pixel];
    const float4 weights=gVXPGFuzzyWeights[pixel];
    // This latent choice is shared by primary NEE and every NRD component.
    // Both techniques use q(.|row), rather than mixing conditional/marginal PDF.
    float u=rtptVXPGUniform(pixel.x+pixel.y*gVXPGParams.frameDim.x+(sampleIndex+1u)*0x9e3779b9u);
    for (uint i=0;i<4;++i)
    {
        if (ids[i]!=RTPT_VXPG_INVALID && u<weights[i])
        {
            const uint row=ids[i];
            const float total=gVXPGTopTree[row*64+1];
            if (total>0.f && isfinite(total))
            {
                context.topRow=row; context.totalMass=total; context.clustered=true;
            }
            break;
        }
        u-=weights[i];
    }
    return true;
}

float rtptVXPGVoxelProbability(RTPTVXPGContext context, uint compact)
{
    if (!context.clustered) return gVXPGMass[compact]/context.totalMass;
    const uint c=gVXPGCluster[compact];
    if (c>=gVXPGParams.clusterCount) return 0.f;
    const uint4 info=gVXPGClusterInfo[c];
    float probability=gVXPGTopTree[context.topRow*64+32+c]/context.totalMass;
    uint node=gVXPGCompactToLeaf[compact];
    while (node>1 && probability>0.f)
    {
        const uint parent=node/2;
        const float left=rtptVXPGLeftProbability(gVXPGForest[info.z+2*parent],gVXPGForest[info.z+2*parent+1],context.origin,context.normal);
        probability*=((node&1u)==0)?left:1.f-left;
        node=parent;
    }
    return probability;
}

bool rtptVXPGSample(RTPTVXPGContext context, float4 u, out RTPTVXPGCandidate candidate)
{
    candidate = {};
    candidate.targetCell = RTPT_VXPG_INVALID;
    candidate.targetCompact = RTPT_VXPG_INVALID;
    candidate.generation = context.generation;
    uint node = 1;
    float value = min(u.x, 0.99999994f) * context.totalMass;
    float probability = 0.f;
    uint compact;
    if (context.clustered)
    {
        const uint base=context.topRow*64;
        while (node<32)
        {
            const float left=gVXPGTopTree[base+2*node];
            if (value<left) node*=2;
            else { value-=left; node=node*2+1; }
        }
        const uint c=node-32;
        if (c>=gVXPGParams.clusterCount) return false;
        const uint4 info=gVXPGClusterInfo[c];
        const float mass=gVXPGTopTree[base+node];
        if (!(mass>0.f) || info.y==0) return false;
        probability=mass/context.totalMass;
        float random=min(0.99999994f,value/mass);
        node=1;
        while (node<info.w)
        {
            const float left=rtptVXPGLeftProbability(gVXPGForest[info.z+2*node],gVXPGForest[info.z+2*node+1],context.origin,context.normal);
            if (random<left) { probability*=left; random/=left; node*=2; }
            else { probability*=1.f-left; random=(random-left)/(1.f-left); node=node*2+1; }
            random=min(random,0.99999994f);
        }
        compact=gVXPGForest[info.z+node].compact;
    }
    else
    {
        while (node < context.leafCapacity)
        {
            const float left = gVXPGGlobalTree[node * 2];
            if (value < left) node *= 2;
            else { value -= left; node = node * 2 + 1; }
        }
        compact=node-context.leafCapacity;
    }
    if (compact >= min(gVXPGState[RTPT_VXPG_STATE_ACTIVE], gVXPGParams.activeCapacity)) return false;
    if (!context.clustered) probability=gVXPGMass[compact]/context.totalMass;
    const uint cell = gVXPGCompact[compact];
    candidate.targetCell = cell;
    candidate.targetCompact = compact;
    // Selecting the source voxel is a null event, without a retry or a change
    // to the normalized voxel distribution used by the reverse evaluator.
    if (cell == context.currentCell) return false;
    const RTPTVXPGSphericalBox box = rtptVXPGSphericalBox(context.origin, rtptVXPGWorldMin(cell), rtptVXPGWorldMax(cell));
    if (!rtptVXPGSampleBox(box, u.yzw, candidate.direction)) return false;
    // The downward traversal already evaluated every conditional probability.
    // The reverse evaluator remains independent for BRDF/NEE hit endpoints.
    candidate.pdf = probability / box.solidAngle;
    return candidate.pdf > 0.f && isfinite(candidate.pdf);
}

float rtptVXPGHitPdf(RTPTVXPGContext context, float3 hitPosition)
{
    const uint cell = rtptVXPGOwner(hitPosition);
    if (cell == RTPT_VXPG_INVALID || cell == context.currentCell) return 0.f;
    const uint compact = gVXPGInverse[cell];
    if (compact == RTPT_VXPG_INVALID || compact >= gVXPGParams.activeCapacity) return 0.f;
    const float3 lo = rtptVXPGWorldMin(cell), hi = rtptVXPGWorldMax(cell);
    if (any(hitPosition < lo) || any(hitPosition > hi)) return 0.f;
    const float solidAngle = rtptVXPGBoxSolidAngle(context.origin, lo, hi);
    if (!(solidAngle > 0.f)) return 0.f;
    const float pdf = rtptVXPGVoxelProbability(context,compact) / solidAngle;
    return isfinite(pdf) && pdf > 0.f ? pdf : 0.f;
}

bool rtptVXPGAccept(RTPTVXPGContext context, RTPTVXPGCandidate candidate, float3 hitPosition)
{
    // A candidate belongs to one immutable proposal. Keep the ownership and
    // support checks without reconstructing its already evaluated density.
    if (candidate.generation != context.generation || context.generation != gVXPGParams.generation ||
        gVXPGState[RTPT_VXPG_STATE_READY] != context.generation) return false;
    if (context.clustered && gVXPGClusterState[6] != context.generation) return false;
    if (!(candidate.pdf > 0.f) || !isfinite(candidate.pdf) || !all(isfinite(candidate.direction)) ||
        !all(isfinite(hitPosition))) return false;
    const uint cell = rtptVXPGOwner(hitPosition);
    if (cell == RTPT_VXPG_INVALID || cell == context.currentCell || cell != candidate.targetCell) return false;
    const uint compact = gVXPGInverse[cell];
    if (compact != candidate.targetCompact || compact >= min(gVXPGState[RTPT_VXPG_STATE_ACTIVE], gVXPGParams.activeCapacity))
        return false;
    const float3 lo = rtptVXPGWorldMin(cell), hi = rtptVXPGWorldMax(cell);
    return all(isfinite(lo)) && all(isfinite(hi)) && all(hi > lo) && all(hitPosition >= lo) && all(hitPosition <= hi);
}
