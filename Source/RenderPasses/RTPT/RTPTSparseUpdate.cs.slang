/** Shared sparse BSDF-only training paths, always Compute Shader + RayQuery. */
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
struct RTPTSparseSettings
{
    uint2 frameDim;
    uint updateStride;
    uint frameIndex;
    uint updateBounces;
    uint writeSHARC;
    uint writeVXPG;
};
ConstantBuffer<RTPTParams> gParams;
ConstantBuffer<RTPTSparseSettings> gSparseSettings;
#if USE_ENV_LIGHT
ParameterBlock<EnvMapSampler> gEnvMapSampler;
#endif
#include "RTPTLighting.slang"
#include "RTPTSharc.slang"

#if ENABLE_VXPG
#include "VXPG/RTPTVXPGTraining.slang"
#endif

// Preserve the deterministic training-pixel phase for SHaRC and VXPG.
uint rtptSparseHash32(uint value)
{
    value = (value + 0x7ed55d16u) + (value << 12u);
    value = (value ^ 0xc761c23cu) ^ (value >> 19u);
    value = (value + 0x165667b1u) + (value << 5u);
    value = (value + 0xd3a2646cu) ^ (value << 9u);
    value = (value + 0xfd7046c5u) + (value << 3u);
    return (value ^ 0xb55a4f09u) ^ (value >> 16u);
}

void rtptSparseTrace(Ray ray, inout SampleGenerator sg, uint2 pixel)
{
#if ENABLE_SHARC
    SharcState sharcState;
    SharcInit(sharcState);
#endif
    float3 pathThroughput = 1.f;
    float3 previousPosition = 0.f;
    float3 previousNormal = 0.f;
    float previousPdf = 0.f;
    bool previousDelta = true;
    bool previousUsedNEE = false;
    SceneRayQuery<true> query;
    for (uint bounce = 0u; bounce <= gSparseSettings.updateBounces; ++bounce)
    {
#if ENABLE_VXPG
        const bool observeVXPG = gSparseSettings.writeVXPG != 0u && rtptVXPGObservesSharedBounce(bounce);
        if (observeVXPG) rtptVXPGCount(RTPT_VXPG_STATE_INJECT_SECONDARY);
#endif
        float hitT;
        const HitInfo hit = query.traceRay(ray, hitT);
        if (!hit.isValid())
        {
            float3 environment = 0.f;
            float hitMIS = 1.f;
#if USE_ENV_LIGHT
            environment = gScene.envMap.eval(ray.dir);
            if (previousUsedNEE && !previousDelta)
                hitMIS = rtptPowerHeuristic(previousPdf, rtptEnvironmentLightPdf(ray.dir));
#endif
            if (!all(isfinite(environment))) break;
#if ENABLE_SHARC
            if (gSparseSettings.writeSHARC != 0u) rtptSharcUpdateMiss(sharcState, environment * hitMIS);
#endif
            break;
        }
        if (hit.getType() != HitType::Triangle) break;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const TriangleHit triangleHit = hit.getTriangleHit();
        const VertexData vertexData = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(vertexData, materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        const BSDFProperties properties = mi.getProperties(sd);
        float3 emission = 0.f;
        float hitMIS = 1.f;
#if USE_EMISSIVE_LIGHTS
        emission = properties.emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (previousUsedNEE && !previousDelta)
            hitMIS = rtptPowerHeuristic(previousPdf, rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd));
#endif
        if (!all(isfinite(emission))) break;
        const uint lobes = mi.getLobeTypes(sd) & sd.mtl.getActiveLobes();
        if (bounce == gSparseSettings.updateBounces)
        {
#if ENABLE_VXPG
            if (observeVXPG)
            {
                // Do not extend SHaRC's path or change its terminal-vertex value.
                SampleGenerator observationSG = sg;
                float3 raw = 0.f;
                bool rawValid = true;
                if (gParams.useNEE != 0u)
                    rtptVXPGTrainingDirect(sd, mi, false, observationSG, raw, rawValid);
                if (rawValid) rtptVXPGStoreObservation(sd, rtptVXPGTrainingEmission(sd, properties, materialID) + raw, pixel, bounce);
                else InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INVALID], 1u);
            }
#endif
#if ENABLE_SHARC
            if (gSparseSettings.writeSHARC != 0u) rtptSharcUpdateMiss(sharcState, emission * hitMIS);
#endif
            break;
        }
        float3 direct = 0.f;
        const bool useNEE = gParams.useNEE != 0u && (lobes & uint(LobeType::NonDeltaReflection)) != 0u;
#if ENABLE_VXPG
        if (observeVXPG)
        {
            float3 raw = 0.f;
            bool rawValid = true;
            if (useNEE) direct = rtptVXPGTrainingDirect(sd, mi, true, sg, raw, rawValid);
            else if (gParams.useNEE != 0u)
            {
                SampleGenerator observationSG = sg;
                rtptVXPGTrainingDirect(sd, mi, false, observationSG, raw, rawValid);
            }
            if (rawValid) rtptVXPGStoreObservation(sd, rtptVXPGTrainingEmission(sd, properties, materialID) + raw, pixel, bounce);
            else InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INVALID], 1u);
        }
        else
#endif
        direct = useNEE ? rtptEstimateDirect(sd, mi, sg) : float3(0.f);
        if (!all(isfinite(direct))) break;
#if ENABLE_SHARC
        if (gSparseSettings.writeSHARC != 0u)
        {
            const SharcHitData cacheHit = rtptMakeSharcHit(sd, properties, emission * hitMIS);
            if (!rtptSharcUpdateHit(sharcState, cacheHit, direct, sampleNext1D(sg)))
                rtptSharcUpdateMiss(sharcState, direct + emission * hitMIS);
        }
#endif
        BSDFSample bs = {};
        bool continued = mi.sample(sd, sg, bs);
        const bool delta = bs.isLobe(LobeType::Delta);
        if (continued && (!all(isfinite(bs.wo)) || !all(isfinite(bs.weight)) ||
            (!delta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))))) break;
        continued = continued && !bs.isLobe(LobeType::Transmission) && any(bs.weight > 0.f);
        float3 transport = continued ? bs.weight : float3(0.f);
        if (continued)
        {
            pathThroughput *= bs.weight;
            if (!all(isfinite(pathThroughput))) break;
            if (gParams.useRussianRoulette != 0u && bounce + 1u >= gParams.rrStartBounce)
            {
                const float survival = min(0.95f, max(pathThroughput.x, max(pathThroughput.y, pathThroughput.z)));
                if (!(survival > 0.f) || sampleNext1D(sg) >= survival) continued = false;
                else
                {
                    transport /= survival;
                    pathThroughput /= survival;
                }
            }
        }
        if (!continued) break;
#if ENABLE_SHARC
        if (gSparseSettings.writeSHARC != 0u) SharcSetThroughput(sharcState, transport);
#endif
        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        previousPdf = bs.pdf;
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
    const uint stride = max(gSparseSettings.updateStride, 1u);
    const uint2 tileDim = (gSparseSettings.frameDim + stride - 1u) / stride;
    const uint2 tile = dispatchThreadID.xy;
    if (any(tile >= tileDim)) return;
    const uint2 origin = tile * stride;
    const uint2 extent = min(uint2(stride), gSparseSettings.frameDim - origin);
    const uint phase = rtptSparseHash32(tile.x * 0x9e3779b9u ^ tile.y * 0x85ebca6bu ^ gParams.seed);
    const uint offset = (phase + gSparseSettings.frameIndex) % max(extent.x * extent.y, 1u);
    const uint2 pixel = origin + uint2(offset % max(extent.x, 1u), offset / max(extent.x, 1u));
#if ENABLE_VXPG
    if (gSparseSettings.writeVXPG != 0u) rtptVXPGCount(RTPT_VXPG_STATE_SHARED_PATHS);
#endif
    const uint sampleIndex = gParams.sampleOffset + gSparseSettings.frameIndex * 0x85ebca6bu + gParams.seed * 0x9e3779b9u;
    SampleGenerator sg = SampleGenerator(pixel, sampleIndex);
    const float2 p = (float2(pixel) + sampleNext2D(sg)) / float2(gSparseSettings.frameDim);
    const float2 ndc = p * float2(2.f, -2.f) + float2(-1.f, 1.f);
    let camera = gScene.camera.data;
    const float3 direction = normalize(ndc.x * camera.cameraU + ndc.y * camera.cameraV + camera.cameraW);
    const float inverseCosine = 1.f / dot(normalize(camera.cameraW), direction);
    const Ray ray = Ray(camera.posW, direction, camera.nearZ * inverseCosine, camera.farZ * inverseCosine);
    rtptSparseTrace(ray, sg, pixel);
}
