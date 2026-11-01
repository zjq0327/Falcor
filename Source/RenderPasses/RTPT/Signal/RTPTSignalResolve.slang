#pragma once

import RenderPasses.Shared.Denoising.NRDConstants;
#include "RTPTSignalTypes.slang"

RTPTNRDSignals rtptResolveSignalRecord(RTPTSignalRecord record)
{
    RTPTNRDSignals signals = {};
    // Preserve the original direct += continuation order for each component.
    signals.diffuse = record.directDiffuse;
    signals.diffuse += record.indirectDiffuse;
    signals.specular = record.directSpecular;
    signals.specular += record.indirectSpecular;
    signals.emission = record.emission;
    signals.diffuseReflectance = record.diffuseReflectance;
    signals.specularReflectance = record.specularReflectance;
    signals.residual = record.residual;
    signals.diffuseHitDistance = record.diffuseHitDistance;
    signals.specularHitDistance = record.specularHitDistance;
    signals.normalRoughness = record.normalRoughness;
    signals.viewZ = record.viewZ;
    signals.motionW = record.motionW;

    // Exactly the existing NRD depth-domain rule. The record still retains
    // the physical continuation distances and their explicit event states.
    if (signals.viewZ >= kNRDDepthRange)
    {
        signals.residual += signals.diffuse + signals.specular;
        signals.diffuse = 0.f;
        signals.specular = 0.f;
        signals.diffuseHitDistance = 0.f;
        signals.specularHitDistance = 0.f;
    }
    return signals;
}

float3 rtptNRDSignalRadiance(RTPTNRDSignals signals)
{
    return signals.emission + signals.diffuse + signals.specular + signals.residual;
}

float4 rtptDemodulateDiffuseSignal(RTPTNRDSignals signals)
{
    return float4(signals.diffuse / signals.diffuseReflectance, signals.diffuseHitDistance);
}

float4 rtptDemodulateSpecularSignal(RTPTNRDSignals signals)
{
    return float4(signals.specular / signals.specularReflectance, signals.specularHitDistance);
}

// The caller declares the existing NRD output resources. This is the only
// material removal step; NRDPass continues to perform its own radiance packing.
void rtptWriteNRDSignals(uint2 pixel, RTPTNRDSignals signals)
{
    gNRDDiffuseRadianceHitDist[pixel] = rtptDemodulateDiffuseSignal(signals);
    gNRDSpecularRadianceHitDist[pixel] = rtptDemodulateSpecularSignal(signals);
    gNRDEmission[pixel] = float4(signals.emission, 1.f);
    gNRDDiffuseReflectance[pixel] = float4(signals.diffuseReflectance, 1.f);
    gNRDSpecularReflectance[pixel] = float4(signals.specularReflectance, 1.f);
    gNRDResidualRadiance[pixel] = float4(signals.residual, 1.f);
    gNRDNormalRoughness[pixel] = signals.normalRoughness;
    gNRDViewZ[pixel] = signals.viewZ;
    gNRDMotionW[pixel] = float4(signals.motionW, 0.f);
}
