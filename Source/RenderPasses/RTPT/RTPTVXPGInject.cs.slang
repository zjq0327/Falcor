/** Independent current-frame camera/BRDF VPL injection. RayQuery only. */
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
#include "RTPTVXPGTypes.slang"

struct RTPTVXPGInjectParams { uint seed; uint useNEE; uint sampleOffset; uint useNRD; };
ConstantBuffer<RTPTVXPGInjectParams> gParams;
#if USE_ENV_LIGHT
ParameterBlock<EnvMapSampler> gEnvMapSampler;
#endif
// Reuse the RTPT light system with guiding disabled for this independent model.
#include "RTPTSampling.slang"
#include "RTPTLighting.slang"

bool rtptVXPGShadeHit(HitInfo hit, Ray ray, out ShadingData sd, out uint materialID)
{
    sd = {};
    materialID = 0;
    if (!hit.isValid() || hit.getType() != HitType::Triangle) return false;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    const TriangleHit triangle = hit.getTriangleHit();
    materialID = gScene.getMaterialID(triangle.instanceID);
    sd = gScene.materials.prepareShadingData(gScene.getVertexData(triangle), materialID, -ray.dir);
    sd.mtl.setActiveLobes(uint(LobeType::Reflection));
    return true;
#else
    return false;
#endif
}

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    if (any(tid.xy >= gVXPGParams.frameDim)) return;
    gVXPGPrimaryPosition[tid.xy] = 0.f;
    gVXPGPrimaryNormal[tid.xy] = 0.f;
    if(gVXPGParams.visibilityEnabled!=0) gVXPGPrimaryHit[tid.xy]=0u;
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) return;
    // Distinct stream from production and SHaRC training. Model construction
    // never consumes the production estimator's random dimensions.
    SampleGenerator sg = SampleGenerator(tid.xy, (gVXPGParams.frameIndex + 1u) * 0x85ebca6bu + gParams.seed * 0xc2b2ae35u);
    Ray ray = gScene.camera.computeRayPinhole(tid.xy, gVXPGParams.frameDim);
    if (gParams.useNRD == 0)
    {
        SampleGenerator cameraSG = SampleGenerator(tid.xy, gParams.sampleOffset + gParams.seed * 0x9e3779b9u);
        const float2 p = (float2(tid.xy) + sampleNext2D(cameraSG)) / float2(gVXPGParams.frameDim);
        const float2 ndc = p * float2(2.f, -2.f) + float2(-1.f, 1.f);
        let camera = gScene.camera.data;
        const float3 direction = normalize(ndc.x * camera.cameraU + ndc.y * camera.cameraV + camera.cameraW);
        const float inverseCosine = 1.f / dot(normalize(camera.cameraW), direction);
        ray = Ray(camera.posW, direction, camera.nearZ * inverseCosine, camera.farZ * inverseCosine);
    }
    SceneRayQuery<true> query;
    float hitT;
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INJECT_PRIMARY],1u);
    HitInfo hit = query.traceRay(ray, hitT);
    ShadingData primary;
    uint materialID;
    if (!rtptVXPGShadeHit(hit, ray, primary, materialID)) return;
    const IMaterialInstance primaryMI = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    gVXPGPrimaryPosition[tid.xy] = float4(primary.posW, 1.f);
    gVXPGPrimaryNormal[tid.xy] = float4(primary.getOrientedFaceNormal(), primaryMI.getProperties(primary).roughness);
    if(gVXPGParams.visibilityEnabled!=0)
    {
#if HIT_INFO_USE_COMPRESSION
        gVXPGPrimaryHit[tid.xy]=uint4(hit.pack(),0u,0u);
#else
        gVXPGPrimaryHit[tid.xy]=hit.pack();
#endif
    }
    BSDFSample bs = {};
    if (!primaryMI.sample(primary, sg, bs) || bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo))) return;
    ray = Ray(primary.computeRayOrigin(), bs.wo);
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INJECT_SECONDARY],1u);
    hit = query.traceRay(ray, hitT);
    ShadingData sd;
    if (!rtptVXPGShadeHit(hit, ray, sd, materialID)) return;
    const uint cell = rtptVXPGOwner(sd.posW);
    if (cell == RTPT_VXPG_INVALID || gVXPGBoundMin[cell].w == 0) return;
    const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    const BSDFProperties properties = mi.getProperties(sd);
    float3 local = properties.emission;
    if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
        local *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
    RTPTLightSample ls;
    if (gParams.useNEE != 0 && rtptSampleLight(sd, sg, ls))
    {
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INJECT_SHADOW],1u);
        if (query.traceVisibilityRay(ls.visibilityRay)) local += mi.eval(sd, ls.dir, sg) * ls.LiOverPdf;
    }
    if (!all(isfinite(local)))
    {
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INVALID], 1u);
        return;
    }
    InterlockedOr(gVXPGBoundMax[cell].w, 1u);
    // Reference uses maxComponent of positive direct-light observations and
    // their per-voxel average. This is proposal importance, not irradiance.
    const float importance = max(local.x, max(local.y, local.z));
    if (!(importance > 0.f)) return;
    // Bounding model statistics does not clamp final transport radiance.
    const uint64_t fixed = uint64_t(max(1.f, round(min(importance, 1.e6f) * 4096.f)));
    uint64_t previousFlux;
    InterlockedAdd(gVXPGFlux[cell], fixed, previousFlux);
    if (previousFlux > uint64_t(0xffffffffffffffffull) - fixed)
        InterlockedOr(gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW],1u);
    uint old;
    InterlockedAdd(gVXPGCount[cell], 1u, old);
    if (old==0xffffffffu) InterlockedOr(gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW],1u);
    if (old == 0)
    {
        gVXPGRepresentativePosition[cell] = float4(sd.posW, 1.f);
        gVXPGRepresentativeNormal[cell] = float4(sd.getOrientedFaceNormal(), 0.f);
    }
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INJECTED], 1u);
}
