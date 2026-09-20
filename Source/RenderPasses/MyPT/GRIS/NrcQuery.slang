// Compute-side NRC contract. No DispatchRaysIndex or independent training rays.
__exported import PathReservoir;
import Scene.Shading;
#define NRC_PACK_PATH_16BITS 0
#include "Nrc.hlsli"
#include "../NRC/NrcQueryRecording.slang"

cbuffer NrcCB { NrcConstants gNrcConstants; }
cbuffer GrisNrcCB
{
    uint gNrcQueryDepth;
    uint gNrcRecordEnabled;
}
RWStructuredBuffer<NrcPackedQueryPathInfo> gNrcQueryPathInfo;
RWStructuredBuffer<NrcRadianceParams> gNrcQueryRadianceParams;
RWStructuredBuffer<uint> gNrcCountersData;
StructuredBuffer<float3> gNrcQueryRadiance;

struct NrcCandidate
{
    PathReservoir tree;
    PathSample cache;
    float3 beta;
    float3 suffix;
    float3 explicitRadiance;
    uint selectionState;
    uint queryIndex;
};
RWStructuredBuffer<NrcCandidate> gNrcCandidates;

NrcSurfaceAttributes grisNrcSurface(ShadingData sd, IMaterialInstance mi)
{
    BSDFProperties p = mi.getProperties(sd);
    NrcSurfaceAttributes s = (NrcSurfaceAttributes)0;
    s.encodedPosition = NrcEncodePosition(sd.posW, gNrcConstants);
    s.roughness = p.roughness;
    s.specularF0 = p.specularReflectance;
    s.diffuseReflectance = p.diffuseReflectionAlbedo;
    s.shadingNormal = p.guideNormal;
    s.viewVector = sd.V;
    bool supported = gScene.materials.getMaterialType(sd.materialID) == MaterialType::Standard &&
        !p.isTransmissive && (mi.getLobeTypes(sd) & uint(LobeType::Delta)) == 0u;
    s.isDeltaLobe = !supported;
    return s;
}

uint grisNrcWriteQuery(NrcSurfaceAttributes s)
{
    uint index = NrcIncrementCounter(gNrcCountersData, NrcCounter::Queries);
    NrcRadianceParams p;
    p.encodedPosition = s.encodedPosition;
    p.roughness = s.roughness;
    p.normal = NrcSafeCartesianToSphericalUnorm(s.shadingNormal);
    p.viewDirection = NrcSafeCartesianToSphericalUnorm(s.viewVector);
    p.albedo = s.diffuseReflectance;
    p.specular = s.specularF0;
    gNrcQueryRadianceParams[index] = p;
    return index;
}

void grisNrcWritePath(uint2 pixel, uint candidate, uint queryIndex, float3 beta)
{
    NrcPackedQueryPathInfo path = (NrcPackedQueryPathInfo)0;
    path.queryBufferIndex = queryIndex;
    path.prefixThroughput = NrcEncodeLogLuvHdr(max(float3(0.f), beta));
    uint index = NrcCalculateQueryPathIndex(gNrcConstants.frameDimensions, pixel, candidate, gNrcConstants.samplesPerPixel);
    gNrcQueryPathInfo[index] = path;
}
