#pragma once

#include "../RTPTFirstHit.slangh"

struct RTPTNRDSignals
{
    float3 diffuse;
    float3 specular;
    float3 emission;
    float3 diffuseReflectance;
    float3 specularReflectance;
    float3 residual;
    float diffuseHitDistance;
    float specularHitDistance;
    float4 normalRoughness;
    float viewZ;
    float3 motionW;
};

/** Current-frame transport results. All radiance is still materialized.
    No material instance, sampling context or path state crosses this boundary.
    The buffer is allocated from shader reflection; the current DX layout is
    144 bytes per pixel. Distance states remain useful even for zero radiance.
*/
struct RTPTSignalRecord
{
    float3 directDiffuse;
    float diffuseHitDistance;
    float3 directSpecular;
    float specularHitDistance;
    float3 indirectDiffuse;
    uint diffuseDistanceState;
    float3 indirectSpecular;
    uint specularDistanceState;
    float3 emission;
    float viewZ;
    float3 diffuseReflectance;
    float3 specularReflectance;
    float3 residual;
    float3 motionW;
    float4 normalRoughness;
};
