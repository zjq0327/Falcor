/** Sparse cache-training paths use compute dispatches and inline RayQuery. */
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
import Rendering.Materials.IsotropicGGX;

// The host binds the same RTPT parameter layout as the main dispatch.
struct RTPTParams
{
    uint2 frameDim;
    uint samplesPerPixel;
    uint maxBounces;
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
ParameterBlock<EnvMapSampler> gEnvMapSampler;
#endif

#ifndef SHARC_UPDATE
#define SHARC_UPDATE 1
#endif
#ifndef SHARC_QUERY
#define SHARC_QUERY 0
#endif
#include "RTPTLighting.slang"
#include "RTPTSharc.slang"
#include "RTPTIntegrator.slang"

void rtptUpdateSharcPath(Ray ray, uint2 pixel, uint sampleIndex, inout SampleGenerator sg)
{
    SharcState state;
    SharcInit(state);
    float3 pathThroughput = 1.f; // Only used to select roulette survival.
    float3 previousPosition = 0.f;
    float3 previousNormal = 0.f;
    float previousBsdfPdf = 0.f;
    bool previousDelta = true;
    bool previousUsedNEE = false;
    SceneRayQuery<true> query;

    for (uint bounce = 0; bounce <= gSharcSettings.updateBounces; ++bounce)
    {
        float hitT;
        const HitInfo hit = query.traceRay(ray, hitT);
        if (!hit.isValid())
        {
#if USE_ENV_LIGHT
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousBsdfPdf, rtptEnvironmentLightPdf(ray.dir))
                : 1.f;
            const float3 environment = gScene.envMap.eval(ray.dir) * misWeight;
            if (all(isfinite(environment))) SharcUpdateMiss(gSharc, state, environment);
#endif
            break;
        }
        if (hit.getType() != HitType::Triangle) break;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const TriangleHit triangleHit = hit.getTriangleHit();
        const VertexData vertex = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        const BSDFProperties properties = mi.getProperties(sd);
        float3 emission = 0.f;
#if USE_EMISSIVE_LIGHTS
        emission = properties.emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (previousUsedNEE && !previousDelta)
            emission *= rtptPowerHeuristic(previousBsdfPdf,
                rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd));
        if (!all(isfinite(emission))) emission = 0.f;
#endif

        // A depth-limited vertex supplies emission to earlier vertices, but
        // must not train its own cache entry with a truncated zero reflection.
        if (bounce == gSharcSettings.updateBounces)
        {
            SharcUpdateMiss(gSharc, state, emission);
            break;
        }

        const bool hasNonDeltaLobes = (mi.getLobeTypes(sd) & uint(LobeType::NonDeltaReflection)) != 0;
        const bool useNEE = gParams.useNEE != 0 && hasNonDeltaLobes;
        const RTPTLightingContext lightContext = rtptSurfaceLightContext(
            sd, pixel, sampleIndex, bounce, RTPT_LIGHT_QUERY_TRAINING);
        const float3 direct = useNEE ? rtptEstimateDirect(sd, mi, lightContext, sg) : float3(0.f);
        // SEPARATE_EMISSIVE stores only reflected Lo at this vertex. Arrival
        // MIS applies to emission propagated to earlier vertices, never to the
        // new vertex's NEE/cache value. No camera throughput is submitted here.
        const SharcHitData cacheHit = rtptMakeSharcHit(sd, properties, emission);
        if (!SharcUpdateHit(gSharc, state, cacheHit, direct, sampleNext1D(sg)))
        {
            // With cache resampling and responsive lighting disabled, false
            // means insertion failed before any radiance reached earlier
            // vertices. Preserve their estimator and continue the path without
            // registering this vertex; SetThroughput below still updates state.
            const float3 contribution = direct + emission;
            if (all(isfinite(contribution))) SharcUpdateMiss(gSharc, state, contribution);
        }

        BSDFSample bs = {};
        if (!mi.sample(sd, sg, bs)) break;
        if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) break;
        const bool delta = bs.isLobe(LobeType::Delta);
        if (!delta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))) break;
        if (!any(bs.weight > 0.f)) break;

        float3 segmentThroughput = bs.weight;
        pathThroughput *= bs.weight;
        if (!all(isfinite(pathThroughput))) break;
        if (gParams.useRussianRoulette != 0 && bounce + 1 >= gParams.rrStartBounce)
        {
            const float survival = min(0.95f, max(pathThroughput.x, max(pathThroughput.y, pathThroughput.z)));
            if (!(survival > 0.f) || sampleNext1D(sg) >= survival) break;
            segmentThroughput /= survival;
            pathThroughput /= survival;
        }
        // BSDFSample::weight already contains f*cos/pdf, including mixed-lobe
        // selection. SHaRC carries products to prior vertices itself.
        SharcSetThroughput(state, segmentThroughput);
        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        previousBsdfPdf = bs.pdf;
        previousDelta = delta;
        previousUsedNEE = useNEE;
        ray = Ray(sd.computeRayOrigin(), bs.wo);
#else
        break;
#endif
    }
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint stride = max(gSharcSettings.updateStride, 1u);
    const uint2 tile = dispatchThreadID.xy;
    const uint2 tileDim = (gSharcSettings.frameDim + stride - 1u) / stride;
    if (any(tile >= tileDim)) return;
    const uint2 pixel = rtptSharcUpdatePixel(tile);
    const uint sampleIndex = gParams.sampleOffset + gSharcSettings.frameIndex * 0x85ebca6bu + gParams.seed * 0x9e3779b9u;
    SampleGenerator sg = SampleGenerator(pixel, sampleIndex);
    const Ray ray = rtptGenerateCameraRay(pixel, sg);
    rtptUpdateSharcPath(ray, pixel, sampleIndex, sg);
}
