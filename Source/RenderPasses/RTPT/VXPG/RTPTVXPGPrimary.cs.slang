/** Current-frame primary data for VXPG distribution and visibility. RayQuery only. */
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
#include "RTPTVXPGGrid.slang"
#include "../RTPTCamera.slang"

struct RTPTVXPGPrimaryParams { uint seed; uint sampleOffset; uint useNRD; };
ConstantBuffer<RTPTVXPGPrimaryParams> gParams;

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
    gVXPGPrimaryHit[pixel] = 0u;
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) return false;
    SampleGenerator cameraSG = SampleGenerator(pixel, gParams.sampleOffset + gParams.seed * 0x9e3779b9u);
    ray = rtptCameraRay(pixel, gVXPGParams.frameDim, gParams.useNRD != 0, cameraSG);
    SceneRayQuery<true> query;
    float hitT;
    rtptVXPGCount(RTPT_VXPG_STATE_INJECT_PRIMARY);
    hit = query.traceRay(ray, hitT);
#if HIT_INFO_USE_COMPRESSION
    gVXPGPrimaryHit[pixel] = uint4(hit.pack(), 0u, 0u);
#else
    gVXPGPrimaryHit[pixel] = hit.pack();
#endif
    return true;
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
}
