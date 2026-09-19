// MyPT's adapter to the pinned NVIDIA NRC shader API. Included by PathTransport.
#ifndef MYPT_NRC_ADAPTER
#define MYPT_NRC_ADAPTER

#define NRC_PACK_PATH_16BITS 0
// The host supplies the SDK include directory for source and deployed shaders.
#include "Nrc.hlsli"

cbuffer NrcCB { NrcConstants gNrcConstants; }
cbuffer NrcRuntimeCB
{
    uint2 gNrcFrameDim;
    uint2 gNrcTrainingDim;
    uint gNrcUseCache;
    uint gNrcTrainingMaxBounces;
}

RWStructuredBuffer<NrcPackedQueryPathInfo> gNrcQueryPathInfo;
RWStructuredBuffer<NrcPackedTrainingPathInfo> gNrcTrainingPathInfo;
RWStructuredBuffer<NrcPackedPathVertex> gNrcTrainingPathVertices;
RWStructuredBuffer<NrcRadianceParams> gNrcQueryRadianceParams;
RWStructuredBuffer<uint> gNrcCountersData;

// SDK-skipped vertices form one recorded transport segment. Complete that
// segment explicitly at a query point; cap pathological mirror cycles.
static const uint kNrcMaxDirectProbeSegments = 64u;

#ifndef MYPT_HAS_NRC_QUERY_DEBUG
#define MYPT_HAS_NRC_QUERY_DEBUG 0
#endif
#ifndef MYPT_HAS_NRC_TRAINING_DEBUG
#define MYPT_HAS_NRC_TRAINING_DEBUG 0
#endif
#if MYPT_HAS_NRC_QUERY_DEBUG
globallycoherent RWTexture2D<uint4> gNrcQueryDebug;
#endif
#if MYPT_HAS_NRC_TRAINING_DEBUG
globallycoherent RWTexture2D<uint4> gNrcTrainingDebug;
#endif

// The host limits trainingDimensions to frameDimensions. Disjoint integer cells
// give every training path a unique full-resolution owner even at odd sizes.
uint2 nrcOwnerPixel(uint2 dispatchPixel)
{
#if NRC_UPDATE
    uint2 begin = dispatchPixel * gNrcFrameDim / gNrcTrainingDim;
    uint2 end = (dispatchPixel + 1u) * gNrcFrameDim / gNrcTrainingDim;
    uint h = jenkinsHash(dispatchPixel.x + dispatchPixel.y * gNrcTrainingDim.x);
    uint2 jitter = uint2(jenkinsHash(h ^ gFrameCount), jenkinsHash(h ^ gFrameCount ^ 0x9e3779b9u));
    return begin + jitter % max(uint2(1u), end - begin);
#else
    return dispatchPixel;
#endif
}

void nrcMeasurementAdd(uint4 delta)
{
#if NRC_UPDATE && MYPT_HAS_NRC_TRAINING_DEBUG
    uint2 owner = nrcOwnerPixel(DispatchRaysIndex().xy);
    DeviceMemoryBarrier();
    gNrcTrainingDebug[owner] = gNrcTrainingDebug[owner] + delta;
    DeviceMemoryBarrier();
#elif !NRC_UPDATE && MYPT_HAS_NRC_QUERY_DEBUG
    uint2 owner = DispatchRaysIndex().xy;
    DeviceMemoryBarrier();
    gNrcQueryDebug[owner] = gNrcQueryDebug[owner] + delta;
    DeviceMemoryBarrier();
#endif
}

NrcContext nrcContext()
{
    NrcBuffers buffers;
    buffers.queryPathInfo = gNrcQueryPathInfo;
    buffers.trainingPathInfo = gNrcTrainingPathInfo;
    buffers.trainingPathVertices = gNrcTrainingPathVertices;
    buffers.queryRadianceParams = gNrcQueryRadianceParams;
    buffers.countersData = gNrcCountersData;
    return NrcCreateContext(gNrcConstants, buffers, DispatchRaysIndex().xy);
}

NrcPathState nrcInitialPathState(uint2 owner)
{
    // NRC decisions never consume the transport sample generator.
    uint h = jenkinsHash(owner.x ^ jenkinsHash(owner.y) ^ gFrameCount ^ gSeed ^ 0xc2b2ae35u);
    return NrcCreatePathState(gNrcConstants, float(h >> 8) * (1.f / 16777216.f));
}

NrcSurfaceAttributes nrcSurface(ShadingData sd, IMaterialInstance mi)
{
    BSDFProperties p = mi.getProperties(sd);
    NrcSurfaceAttributes surface = (NrcSurfaceAttributes)0;
    surface.encodedPosition = NrcEncodePosition(sd.posW, gNrcConstants);
    surface.roughness = p.roughness;
    surface.specularF0 = p.specularReflectance;
    surface.diffuseReflectance = p.diffuseReflectionAlbedo;
    surface.shadingNormal = p.guideNormal;
    surface.viewVector = sd.V;
    // Treat unsupported vertices as skipped vertices in the SDK. Their actual
    // BSDF is still traced, so all their segment weights remain in the path.
    // This can conservatively delay the spread heuristic; it cannot fabricate
    // a material feature or truncate a transmission/delta chain.
    uint lobes = mi.getLobeTypes(sd);
    bool supported = gScene.materials.getMaterialType(sd.materialID) == MaterialType::Standard;
    supported = supported && !p.isTransmissive && (lobes & uint(LobeType::Delta)) == 0u;
    surface.isDeltaLobe = !supported;
    return surface;
}

#endif
