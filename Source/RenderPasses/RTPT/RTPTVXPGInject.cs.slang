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
#include "RTPTCamera.slang"

struct RTPTVXPGInjectParams { uint seed; uint useNEE; uint sampleOffset; uint useNRD; };
ConstantBuffer<RTPTVXPGInjectParams> gParams;
#if USE_ENV_LIGHT
ParameterBlock<EnvMapSampler> gEnvMapSampler;
#endif
// Reuse the RTPT light system with guiding disabled for this independent model.
#include "RTPTLighting.slang"
#include "RTPTVXPGTraining.slang"

#ifndef RTPT_VXPG_SHARED_INJECTION
#define RTPT_VXPG_SHARED_INJECTION 0
#endif

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

bool rtptVXPGProducePrimary(uint2 pixel, out Ray ray, out HitInfo hit)
{
    ray = {};
    hit = {};
    gVXPGPrimaryPosition[pixel] = 0.f;
    gVXPGPrimaryNormal[pixel] = 0.f;
    if (gVXPGParams.visibilityEnabled != 0) gVXPGPrimaryHit[pixel] = 0u;
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) return false;
    SampleGenerator cameraSG = SampleGenerator(pixel, gParams.sampleOffset + gParams.seed * 0x9e3779b9u);
    ray = rtptCameraRay(pixel, gVXPGParams.frameDim, gParams.useNRD != 0, cameraSG);
    SceneRayQuery<true> query;
    float hitT;
    rtptVXPGCount(RTPT_VXPG_STATE_INJECT_PRIMARY);
    hit = query.traceRay(ray, hitT);
    if (gVXPGParams.visibilityEnabled != 0)
    {
#if HIT_INFO_USE_COMPRESSION
        gVXPGPrimaryHit[pixel] = uint4(hit.pack(), 0u, 0u);
#else
        gVXPGPrimaryHit[pixel] = hit.pack();
#endif
    }
    return true;
}

void rtptVXPGInjectSecondary(ShadingData primary, IMaterialInstance primaryMI, inout SampleGenerator sg, uint2 pixel)
{
    BSDFSample bs = {};
    if (!primaryMI.sample(primary, sg, bs) || bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo))) return;
    const Ray ray = Ray(primary.computeRayOrigin(), bs.wo);
    SceneRayQuery<true> query;
    float hitT;
    rtptVXPGCount(RTPT_VXPG_STATE_INJECT_SECONDARY);
    const HitInfo hit = query.traceRay(ray, hitT);
    ShadingData sd;
    uint materialID;
    if (!rtptVXPGShadeHit(hit, ray, sd, materialID)) return;
    const uint cell = rtptVXPGOwner(sd.posW);
    const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    const BSDFProperties properties = mi.getProperties(sd);
    float3 local = properties.emission;
    if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
        local *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
    RTPTLightSample ls;
    if (gParams.useNEE != 0 && rtptSampleLight(sd, sg, ls))
    {
        rtptVXPGCount(RTPT_VXPG_STATE_INJECT_SHADOW);
        if (query.traceVisibilityRay(ls.visibilityRay)) local += mi.eval(sd, ls.dir, sg) * ls.LiOverPdf;
    }
    rtptVXPGRecordDiscovery(pixel,cell,sd.posW,sd.getOrientedFaceNormal(),local);
    rtptVXPGStoreCellObservation(cell, sd, local);
}

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    if (any(tid.xy >= gVXPGParams.frameDim)) return;
    Ray ray;
    HitInfo hit;
    if (!rtptVXPGProducePrimary(tid.xy, ray, hit)) return;
    ShadingData primary;
    uint materialID;
    if (!rtptVXPGShadeHit(hit, ray, primary, materialID)) return;
    const IMaterialInstance primaryMI = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    gVXPGPrimaryPosition[tid.xy] = float4(primary.posW, 1.f);
    gVXPGPrimaryNormal[tid.xy] = float4(primary.getOrientedFaceNormal(), primaryMI.getProperties(primary).roughness);
#if !RTPT_VXPG_SHARED_INJECTION
    // Keep the original independent training stream and all secondary samples.
    SampleGenerator sg = SampleGenerator(tid.xy, (gVXPGParams.frameIndex + 1u) * 0x85ebca6bu + gParams.seed * 0xc2b2ae35u);
    rtptVXPGInjectSecondary(primary, primaryMI, sg, tid.xy);
#endif
}
