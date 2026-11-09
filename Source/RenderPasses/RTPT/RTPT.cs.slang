/** Monte Carlo path tracer using inline ray queries and current-frame signals. */
#ifndef RTPT_SEPARATE_SIGNAL_RESOLVE
#define RTPT_SEPARATE_SIGNAL_RESOLVE 0
#endif
#include "RTPTTransport.slangh"
#if ENABLE_NRD
import RenderPasses.Shared.Denoising.NRDConstants;
#endif

RWTexture2D<float4> gColor;
RWTexture2D<float4> gNoisyColor;
RWTexture2D<float4> gAccumulation;

#if ENABLE_NRD
// Radiance stays linear and unencoded here. NRDPass performs its own packing.
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
RWTexture2D<float4> gDeltaRadiance;
RWTexture2D<float4> gDeltaReflectance;
RWTexture2D<float4> gDeltaEmission;
RWTexture2D<float4> gDeltaNormal;
RWTexture2D<float> gDeltaViewZ;
RWTexture2D<float4> gDeltaMotion;
RWTexture2D<float4> gDeltaRaw;
#endif
#endif

#include "RTPTIntegrator.slang"
#if ENABLE_NRD
#include "RTPTNRD.slang"
#endif

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gParams.frameDim)) return;

    float3 frameAverage = 0.f;
    RTPTSharcStats sharcStats = {};
#if ENABLE_SHARC && SHARC_QUERY && RTPT_USE_GRIS
    const float3 generateStats = gSharcStats[pixel].xyz;
    sharcStats.cacheTerminations = uint(generateStats.x);
    sharcStats.radianceRays = uint(generateStats.y);
    sharcStats.attemptedQueries = uint(generateStats.z);
#endif
    for (uint s = 0; s < gParams.samplesPerPixel; ++s)
    {
        // Offset the absolute sample index by an odd seed stride. Unlike XOR,
        // nearby seeds do not merely permute the same power-of-two sample block.
        // The stream remains independent of how samples are grouped into frames.
        const uint sampleIndex = gParams.sampleOffset + s + gParams.seed * 0x9e3779b9u;
        SampleGenerator sg = SampleGenerator(pixel, sampleIndex);
#if ENABLE_NRD
        // NRD mode uses one shared primary sample and one continuation per
        // reflection component. The host enforces 1 spp without PT accumulation.
        const float3 sampleRadiance = rtptTraceNRD(pixel, sampleIndex, sg, sharcStats);
#else
        const Ray primaryRay = rtptGenerateCameraRay(pixel, sg);
        const float3 sampleRadiance = rtptTracePath(primaryRay, pixel, sampleIndex, s == 0u, sg, sharcStats);
#endif
        frameAverage += (sampleRadiance - frameAverage) / float(s + 1);
    }
#if ENABLE_SHARC
    rtptWriteSharcDebug(pixel, sharcStats);
#endif

#if !(ENABLE_NRD && RTPT_SEPARATE_SIGNAL_RESOLVE)
    gNoisyColor[pixel] = float4(frameAverage, 1.f);
    float3 result = frameAverage;
    if (gParams.accumulate != 0 && gParams.accumulatedSamples != 0)
    {
        const float newSampleWeight = float(gParams.samplesPerPixel) /
            (float(gParams.accumulatedSamples) + float(gParams.samplesPerPixel));
        result = lerp(gAccumulation[pixel].xyz, frameAverage, newSampleWeight);
    }
    gAccumulation[pixel] = float4(result, 1.f);
    gColor[pixel] = float4(result, 1.f);
#endif
}
