/** Monte Carlo path tracer using inline ray queries and current-frame signals. */
#ifndef RTPT_SEPARATE_SIGNAL_RESOLVE
#define RTPT_SEPARATE_SIGNAL_RESOLVE 0
#endif
#ifndef RTPT_USE_RESTIR_DI
#define RTPT_USE_RESTIR_DI 0
#endif
#ifndef RTPT_USE_GRIS
#define RTPT_USE_GRIS 0
#endif
#ifndef RTPT_GRIS_GENERATE
#define RTPT_GRIS_GENERATE 0
#endif
#ifndef RTPT_GRIS_SPATIAL
#define RTPT_GRIS_SPATIAL 0
#endif
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveUniformSampler;
import Rendering.Lights.EmissiveLightSamplerInterface;
import Rendering.Lights.EmissiveLightSamplerHelpers;

#if ENABLE_NRD || ENABLE_SHARC
import Rendering.Materials.IsotropicGGX;
#endif
#if ENABLE_NRD
import RenderPasses.Shared.Denoising.NRDConstants;
#endif

struct RTPTParams
{
    uint2 frameDim;
    uint samplesPerPixel;
    uint maxBounces;           // Maximum number of BSDF scattering events.
    uint rrStartBounce;
    uint seed;
    uint sampleOffset;
    uint accumulatedSamples;
    uint useNEE;
    uint useRussianRoulette;
    uint accumulate;
};

ConstantBuffer<RTPTParams> gParams;
#if USE_ENV_LIGHT
// Keep the sampler's textures, sampler state and uniforms in their own
// parameter block so the GFX resource layout is valid in compute dispatches.
ParameterBlock<EnvMapSampler> gEnvMapSampler;
#endif
RWTexture2D<float4> gColor;
RWTexture2D<float4> gNoisyColor;
RWTexture2D<float4> gAccumulation;

#if ENABLE_SHARC
#ifndef SHARC_QUERY
#define SHARC_QUERY 1
#endif
RWTexture2D<float4> gSharcDebug;
RWTexture2D<float4> gSharcCacheRadiance;
RWTexture2D<float4> gSharcStats;
#endif

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
#endif

#if RTPT_USE_RESTIR_DI
#include "DirectLighting/RTPTDIResources.slang"
#endif
#include "RTPTSampling.slang"
#include "RTPTLighting.slang"
#include "RTPTSharc.slang"
#include "PrimarySurface/RTPTPrimarySurface.slang"
#include "RTPTIntegrator.slang"
#if ENABLE_NRD
#include "RTPTNRD.slang"
#endif

#if RTPT_GRIS_GENERATE
#include "GRIS/RTPTGRISGenerate.slang"
#elif defined(RTPT_GRIS_TEMPORAL_PASS)
#include "GRIS/RTPTGRISTemporal.slang"
#elif defined(RTPT_GRIS_SPATIAL_PASS)
#include "GRIS/RTPTGRISSpatial.slang"
#else
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
#endif
