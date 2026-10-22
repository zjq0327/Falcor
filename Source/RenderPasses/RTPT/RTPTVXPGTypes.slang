#pragma once

static const uint RTPT_VXPG_INVALID = 0xffffffffu;
static const uint RTPT_VXPG_STATE_JOBS = 0;
static const uint RTPT_VXPG_STATE_GEOMETRY_OVERFLOW = 1;
static const uint RTPT_VXPG_STATE_OCCUPIED = 2;
static const uint RTPT_VXPG_STATE_ACTIVE = 3;
static const uint RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW = 4;
static const uint RTPT_VXPG_STATE_READY = 5;
static const uint RTPT_VXPG_STATE_ATTEMPTS = 6;
static const uint RTPT_VXPG_STATE_ACCEPTED = 7;
static const uint RTPT_VXPG_STATE_REJECTED = 8;
static const uint RTPT_VXPG_STATE_DISTANCE_RAYS = 9;
static const uint RTPT_VXPG_STATE_PG_CACHE_HITS = 10;
static const uint RTPT_VXPG_STATE_INVALID = 11;
static const uint RTPT_VXPG_STATE_INJECTED = 12;
static const uint RTPT_VXPG_STATE_INJECT_SHADOW = 16;
static const uint RTPT_VXPG_STATE_INJECT_PRIMARY = 17;
static const uint RTPT_VXPG_STATE_INJECT_SECONDARY = 18;
static const uint RTPT_VXPG_STATE_GUIDE_RAYS = 19;
static const uint RTPT_VXPG_STATE_BRDF_RAYS = 20;
static const uint RTPT_VXPG_STATE_PRIMARY_RAYS = 21;
static const uint RTPT_VXPG_STATE_PG_SHADOW = 22;
static const uint RTPT_VXPG_STATE_MAIN_SHADOW = 23;
static const uint RTPT_VXPG_STATE_BRDF_CACHE_HITS = 24;

struct RTPTVXPGParams
{
    uint2 frameDim;
    uint resolution;
    uint cellCount;
    float3 gridMin;
    float cellSize;
    uint activeCapacity;
    uint triangleCount;
    uint jobCapacity;
    uint frameIndex;
    uint generation;
    uint enabled;
    uint useGuiding;
    uint estimator;
    float guideFraction;
    uint pgUseCache;
    uint visibilityEnabled;
    uint debugEnabled;
    uint debugMode;
    uint superpixelSize;
    uint clusterCount;
    uint2 superpixelDim;
};
ConstantBuffer<RTPTVXPGParams> gVXPGParams;
RWStructuredBuffer<uint4> gVXPGBoundMin;
RWStructuredBuffer<uint4> gVXPGBoundMax;
RWStructuredBuffer<uint> gVXPGState;
RWStructuredBuffer<uint> gVXPGInverse;
RWStructuredBuffer<uint> gVXPGCompact;
RWStructuredBuffer<uint> gVXPGCount;
RWStructuredBuffer<uint64_t> gVXPGFlux;
RWStructuredBuffer<float> gVXPGMass;
RWStructuredBuffer<float> gVXPGGlobalTree;
RWStructuredBuffer<float4> gVXPGRepresentativePosition;
RWStructuredBuffer<float4> gVXPGRepresentativeNormal;
RWTexture2D<float4> gVXPGPrimaryPosition;
RWTexture2D<float4> gVXPGPrimaryNormal;
RWTexture2D<uint4> gVXPGPrimaryHit;

// 128 representative primary points, matching the reference MRCS descriptor.
RWStructuredBuffer<float4> gVXPGRowPosition;
RWStructuredBuffer<float4> gVXPGRowNormal;
RWStructuredBuffer<uint4> gVXPGVisibility;
struct RTPTVXPGClusterSeed { uint4 visibility; float intensity; uint compact; uint2 padding; };
RWStructuredBuffer<RTPTVXPGClusterSeed> gVXPGSeeds;
RWStructuredBuffer<uint> gVXPGCluster;
// x: sorted leaf range start, y: count, z: heap allocation, w: leaf base.
RWStructuredBuffer<uint4> gVXPGClusterInfo;
struct RTPTVXPGNode { float3 lo; float mass; float3 hi; uint compact; };
RWStructuredBuffer<RTPTVXPGNode> gVXPGForest;
RWStructuredBuffer<uint> gVXPGCompactToLeaf;
RWStructuredBuffer<float4> gVXPGSuperpixelPosition;
RWStructuredBuffer<float4> gVXPGSuperpixelNormal;
RWTexture2D<uint4> gVXPGFuzzyIds;
RWTexture2D<float4> gVXPGFuzzyWeights;
RWStructuredBuffer<float> gVXPGTopTree;
RWStructuredBuffer<uint> gVXPGSuperpixelCount;
RWStructuredBuffer<uint2> gVXPGSuperpixelRange;
RWStructuredBuffer<uint> gVXPGSuperpixelBlocks;
RWStructuredBuffer<uint> gVXPGSuperpixelPoints;
// Separate from renderer counters, also persists while frozen.
// 0: valid superpixels, 1: nonempty clusters, 2: visibility rays,
// 3: visible pairs, 4: forest node allocation, 5: top rows, 6: publication.
RWStructuredBuffer<uint> gVXPGClusterState;

uint rtptVXPGHash(uint x)
{
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}
float rtptVXPGUniform(uint x) { return float(rtptVXPGHash(x) >> 8) * (1.f / 16777216.f); }

uint rtptVXPGFlatten(uint3 cell)
{
    return cell.x + gVXPGParams.resolution * (cell.y + gVXPGParams.resolution * cell.z);
}
uint3 rtptVXPGUnflatten(uint cell)
{
    const uint r = gVXPGParams.resolution;
    return uint3(cell % r, (cell / r) % r, cell / (r*r));
}
uint rtptVXPGOwner(float3 position)
{
    const float3 p = (position - gVXPGParams.gridMin) / gVXPGParams.cellSize;
    if (!all(isfinite(p)) || any(p < 0.f) || any(p >= float(gVXPGParams.resolution))) return RTPT_VXPG_INVALID;
    return rtptVXPGFlatten(uint3(floor(p)));
}
float3 rtptVXPGWorldMin(uint cell)
{
    return gVXPGParams.gridMin + asfloat(gVXPGBoundMin[cell].xyz) * gVXPGParams.cellSize;
}
float3 rtptVXPGWorldMax(uint cell)
{
    return gVXPGParams.gridMin + asfloat(gVXPGBoundMax[cell].xyz) * gVXPGParams.cellSize;
}
