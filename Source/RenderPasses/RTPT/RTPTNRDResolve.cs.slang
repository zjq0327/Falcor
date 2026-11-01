// Current-pixel signal composition only. No tracing, sampling or model writes.
import RenderPasses.Shared.Denoising.NRDConstants;

cbuffer PerFrame
{
    uint2 gFrameDim;
};

RWTexture2D<float4> gColor;
RWTexture2D<float4> gNoisyColor;
RWTexture2D<float4> gNRDDiffuseRadianceHitDist;
RWTexture2D<float4> gNRDSpecularRadianceHitDist;
RWTexture2D<float4> gNRDEmission;
RWTexture2D<float4> gNRDDiffuseReflectance;
RWTexture2D<float4> gNRDSpecularReflectance;
RWTexture2D<float4> gNRDResidualRadiance;
RWTexture2D<float4> gNRDNormalRoughness;
RWTexture2D<float> gNRDViewZ;
RWTexture2D<float4> gNRDMotionW;

#include "RTPTNRDSignals.slang"
StructuredBuffer<RTPTNRDFrameSignals> gNRDFrameSignals;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gFrameDim)) return;
    const RTPTNRDSignals signals = rtptResolveNRDSignals(gNRDFrameSignals[pixel.y * gFrameDim.x + pixel.x]);
    rtptWriteNRDSignals(pixel, signals);
    const float3 radiance = signals.emission + signals.diffuse + signals.specular + signals.residual;
    gNoisyColor[pixel] = float4(radiance, 1.f);
    gColor[pixel] = float4(radiance, 1.f);
}
