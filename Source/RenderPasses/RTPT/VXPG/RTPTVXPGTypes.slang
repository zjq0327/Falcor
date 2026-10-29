#pragma once
#include "RTPTVXPGLayout.slangh"

#ifndef RTPT_VXPG_DETAILED_DIAGNOSTICS
#define RTPT_VXPG_DETAILED_DIAGNOSTICS 0
#endif

#ifndef RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY
#define RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY 1
#endif

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

// Importance history, not cached transport radiance.
struct RTPTVXPGHistory
{
    float mean;
    float weight;
    uint age;
    uint valid;
};

struct RTPTVXPGDiscovery { float4 position; float4 normal; float4 light; };

struct RTPTVXPGClusterSeed { uint4 visibility; float intensity; uint compact; uint2 padding; };

// The record stays 32 bytes. Build-time lo/hi are an AABB until its only parent
// has consumed it; forestLevel then stores center in lo and radius in hi.x.
// Roots are converted by publishClusters. Published/frozen nodes use only the
// query representation; a rebuild initializes fresh AABBs before conversion.
// With RTPT_VXPG_PRECOMPUTED_NODE_GEOMETRY=0, lo/hi remain AABBs throughout.
struct RTPTVXPGNode { float3 lo; float mass; float3 hi; uint compact; };
