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

#include "RTPTSignalResolve.slang"

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gResolveParams.frameDim)) return;
    const uint index = pixel.y * gResolveParams.frameDim.x + pixel.x;
    const RTPTNRDSignals signals = rtptResolveSignalRecord(gSignalRecords[index]);
    rtptWriteNRDSignals(pixel, signals);
    const float4 radiance = float4(rtptNRDSignalRadiance(signals), 1.f);
    // NRD input mode is host-validated to use 1 spp and no PT accumulation.
    // Final image accumulation remains in the render graph after material restore.
    gNoisyColor[pixel] = radiance;
    gAccumulation[pixel] = radiance;
    gColor[pixel] = radiance;
}
