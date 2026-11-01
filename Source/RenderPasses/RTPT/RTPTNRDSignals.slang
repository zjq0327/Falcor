#pragma once

// These are linear, material-modulated current-pixel values. NRDPass owns
// NRD's encoding; only the final signal writer removes the material factors.
static const float kRTPTNRDMissDistance = 60000.f;

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

// Stage 2B preserves both fresh path sums. No selection or resampling occurs.
// Surface D/S own the primary direct-light event; the two path sums are added
// in the original order by the final resolver. Guides and distances always
// belong to this pixel, including when a path contributes zero radiance.
struct RTPTNRDFrameSignals
{
    RTPTNRDSignals surface;
    float3 diffusePath;
    float3 specularPath;
};

RTPTNRDSignals rtptResolveNRDSignals(RTPTNRDFrameSignals frame)
{
    RTPTNRDSignals signals = frame.surface;
    signals.diffuse += frame.diffusePath;
    signals.specular += frame.specularPath;
    if (signals.viewZ >= kNRDDepthRange)
    {
        signals.residual += signals.diffuse + signals.specular;
        signals.diffuse = signals.specular = 0.f;
        signals.diffuseHitDistance = signals.specularHitDistance = 0.f;
    }
    return signals;
}

void rtptWriteNRDSignals(uint2 pixel, RTPTNRDSignals signals)
{
    gNRDDiffuseRadianceHitDist[pixel] = float4(signals.diffuse / signals.diffuseReflectance, signals.diffuseHitDistance);
    gNRDSpecularRadianceHitDist[pixel] = float4(signals.specular / signals.specularReflectance, signals.specularHitDistance);
    gNRDEmission[pixel] = float4(signals.emission, 1.f);
    gNRDDiffuseReflectance[pixel] = float4(signals.diffuseReflectance, 1.f);
    gNRDSpecularReflectance[pixel] = float4(signals.specularReflectance, 1.f);
    gNRDResidualRadiance[pixel] = float4(signals.residual, 1.f);
    gNRDNormalRoughness[pixel] = signals.normalRoughness;
    gNRDViewZ[pixel] = signals.viewZ;
    gNRDMotionW[pixel] = float4(signals.motionW, 0.f);
}
