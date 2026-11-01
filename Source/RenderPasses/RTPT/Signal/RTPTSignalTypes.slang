#pragma once

// Keep the established finite miss convention for NRD's fp16 resources.
static const float kRTPTNRDMissDistance = 60000.f;

// These describe the continuation event, independently of its radiance.
// In particular, a black hit is not a missing distance and a rejected sample
// keeps the legacy numeric distance without pretending that a ray missed.
static const uint kRTPTDistanceNoLobe = 0u;
static const uint kRTPTDistanceSampleRejected = 1u;
static const uint kRTPTDistanceHit = 2u;
static const uint kRTPTDistanceMiss = 3u;
static const uint kRTPTDistanceUntraced = 4u;

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
