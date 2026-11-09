/** Assemble current-frame transport signals without tracing or consuming RNG. */
#include "RTPTSignalTypes.slang"

struct RTPTResolveParams
{
    uint2 frameDim;
};
ConstantBuffer<RTPTResolveParams> gResolveParams;
StructuredBuffer<RTPTSignalRecord> gSignalRecords;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gNoisyColor;
RWTexture2D<float4> gAccumulation;
RWTexture2D<float4> gNRDDiffuseRadianceHitDist;
RWTexture2D<float4> gNRDSpecularRadianceHitDist;
RWTexture2D<float4> gNRDEmission;
RWTexture2D<float4> gNRDDiffuseReflectance;
RWTexture2D<float4> gNRDSpecularReflectance;
RWTexture2D<float4> gNRDResidualRadiance;
RWTexture2D<float4> gNRDNormalRoughness;
RWTexture2D<float> gNRDViewZ;
RWTexture2D<float4> gNRDMotionW;
#if RTPT_DELTA_NRD
Texture2D<float4> gDeltaRaw;
#endif

#include "RTPTSignalResolve.slang"

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gResolveParams.frameDim)) return;
    const uint index = pixel.y * gResolveParams.frameDim.x + pixel.x;
    RTPTNRDSignals signals = rtptResolveSignalRecord(gSignalRecords[index]);
    const float4 radiance = float4(rtptNRDSignalRadiance(signals), 1.f);
#if RTPT_DELTA_NRD
    // Raw reference retains the original contribution. Only composition routes
    // supported delta lanes to the independent denoiser instead of residual.
    const float4 delta = gDeltaRaw[pixel];
    if (delta.a == 1.f) signals.residual -= delta.rgb;
#endif
    rtptWriteNRDSignals(pixel, signals);
    // NRD input mode is host-validated to use 1 spp and no PT accumulation.
    // Final image accumulation remains in the render graph after material restore.
    gNoisyColor[pixel] = radiance;
    gAccumulation[pixel] = radiance;
    gColor[pixel] = radiance;
}
