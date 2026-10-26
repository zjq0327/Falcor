#pragma once
#include "RTPTVXPGHistory.slang"


#ifndef RTPT_VXPG_DETAILED_DIAGNOSTICS
#define RTPT_VXPG_DETAILED_DIAGNOSTICS 0
#endif

#ifndef RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY
#define RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY 1
#endif

static const uint RTPT_VXPG_INVALID = 0xffffffffu;
static const uint RTPT_VXPG_STATE_JOBS = 0;
static const uint RTPT_VXPG_STATE_GEOMETRY_OVERFLOW = 1;
static const uint RTPT_VXPG_STATE_OCCUPIED = 2;
static const uint RTPT_VXPG_STATE_ACTIVE = 3;
// Overflow flags: 1 active capacity, 2 flux, 4 observation count,
// 8 superpixel prefix, 16 superpixel count/scatter mismatch.
static const uint RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW = 4;
static const uint RTPT_VXPG_STATE_READY = 5;
static const uint RTPT_VXPG_STATE_ATTEMPTS = 6;
static const uint RTPT_VXPG_STATE_ACCEPTED = 7;
static const uint RTPT_VXPG_STATE_REJECTED = 8;
static const uint RTPT_VXPG_STATE_SELF_REJECTED = 9;
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
static const uint RTPT_VXPG_STATE_OWNER_MAX_PROBES = 27;
static const uint RTPT_VXPG_STATE_SHARED_PATHS = 28;
static const uint RTPT_VXPG_STATE_OWNER_QUERIES = 29;
static const uint RTPT_VXPG_STATE_OWNER_PROBES = 30;
static const uint RTPT_VXPG_STATE_FULL_BRANCH_STEPS = 31;

struct RTPTVXPGParams
{
    uint2 frameDim;
    uint cellCount;
    float3 gridMin;
    float cellSize;
    uint activeCapacity;
    uint frameIndex;
    uint generation;
    uint enabled;
    uint useGuiding;
    uint pgUseCache;
    uint debugEnabled;
    uint debugMode;
    uint superpixelSize;
    uint clusterCount;
    uint2 superpixelDim;
    uint hashCapacity;
    float3 sortMin;
    float3 sortExtent;
    float3 lodCamera;
    float lodSceneScale;
    uint geometryGeneration;
    uint historyFrames;
    uint historyStaleFrames;
    uint historyReset;
    uint treeRefreshFrames;
    uint treeReset;
    uint globalLeafCapacity;
    float3 lodPreviousCamera;
    uint discoveryStride;
    uint spatialStaleFrames;
    uint discoveryRecordCount;
    uint sharedInjectionStride;
    uint sharedInjectionBounces;
};
ConstantBuffer<RTPTVXPGParams> gVXPGParams;
RWStructuredBuffer<uint4> gVXPGBoundMin;
RWStructuredBuffer<uint4> gVXPGBoundMax;
RWStructuredBuffer<uint> gVXPGState;
// Diagnostic-only render writes: forward/reverse query counts and depths.
RWStructuredBuffer<uint> gVXPGQueryStats;
RWStructuredBuffer<uint> gVXPGInverse;
RWStructuredBuffer<uint> gVXPGCompact;
RWStructuredBuffer<uint> gVXPGCount;
RWStructuredBuffer<RTPTVXPGHistory> gVXPGHistory;
RWStructuredBuffer<RTPTVXPGHistory> gVXPGHistoryPrevious;
RWStructuredBuffer<float4> gVXPGNormalPrevious;
// Valid histories, carried histories, expired histories, fresh observations.
RWStructuredBuffer<uint> gVXPGHistoryStats;
RWStructuredBuffer<uint64_t> gVXPGFlux;
RWStructuredBuffer<float> gVXPGMass;
RWStructuredBuffer<float> gVXPGGlobalTree;
RWStructuredBuffer<float> gVXPGCellMass;
// mode(full=1), previous active count, dirty leaves, full/local totals,
// updated global/forest nodes, topology age, previous valid, membership changes,
// full-build reason bits (reset=1, periodic=2, membership=4, invalid=8).
RWStructuredBuffer<uint> gVXPGTreeState;
RWStructuredBuffer<uint> gVXPGDirtyLeaves;
RWStructuredBuffer<uint> gVXPGDirtyNodes;
RWStructuredBuffer<uint> gVXPGLocalArgs;
// free cells, pending entries, retired cells, insertion/eviction/rejection
// totals, live cells. OCCUPIED in gVXPGState remains the cell-ID high-water.
RWStructuredBuffer<uint> gVXPGGridState;
RWStructuredBuffer<uint4> gVXPGCellLifetime;
RWStructuredBuffer<uint> gVXPGFreeCells;
RWStructuredBuffer<uint> gVXPGRetiredCells;
struct RTPTVXPGDiscovery { float4 position; float4 normal; float4 light; };
RWStructuredBuffer<RTPTVXPGDiscovery> gVXPGDiscovery;
RWStructuredBuffer<uint> gVXPGPendingHash;
RWStructuredBuffer<uint> gVXPGPendingSlots;
RWStructuredBuffer<float4> gVXPGRepresentativePosition;
RWStructuredBuffer<float4> gVXPGRepresentativeNormal;
RWStructuredBuffer<uint> gVXPGHashSlots;
RWStructuredBuffer<int4> gVXPGCellKeys;
// Header: actual global leaf base, radix padded count, radix groups.
RWStructuredBuffer<uint> gVXPGWorkArgs;
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
// The record stays 32 bytes. Build-time lo/hi are an AABB until its only parent
// has consumed it; forestLevel then stores center in lo and radius in hi.x.
// Roots are converted by publishClusters. Published/frozen nodes use only the
// query representation; a rebuild initializes fresh AABBs before conversion.
// With RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY=0, lo/hi remain AABBs throughout.
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
