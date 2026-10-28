/** Shared current-frame primary geometry for RTPT consumers. RayQuery only. */
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
#include "../RTPTCamera.slang"

struct RTPTPrimarySurfaceParams
{
    uint2 frameDim;
    uint seed;
    uint sampleOffset;
    uint useNRD;
};
ConstantBuffer<RTPTPrimarySurfaceParams> gParams;
RWTexture2D<float4> gPrimaryPosition;
RWTexture2D<float4> gPrimaryNormalRoughness;
RWTexture2D<uint4> gPrimaryHit;

bool rtptPrimaryPrepareHit(HitInfo hit, Ray ray, out ShadingData sd, out uint materialID)
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
    if (any(tid.xy >= gParams.frameDim)) return;
    const uint2 pixel = tid.xy;
    gPrimaryPosition[pixel] = 0.f;
    gPrimaryNormalRoughness[pixel] = 0.f;
    gPrimaryHit[pixel] = 0u;
    SampleGenerator cameraSG = SampleGenerator(pixel, gParams.sampleOffset + gParams.seed * 0x9e3779b9u);
    const Ray ray = rtptCameraRay(pixel, gParams.frameDim, gParams.useNRD != 0, cameraSG);
    SceneRayQuery<true> query;
    float hitT;
    const HitInfo hit = query.traceRay(ray, hitT);
#if HIT_INFO_USE_COMPRESSION
    gPrimaryHit[pixel] = uint4(hit.pack(), 0u, 0u);
#else
    gPrimaryHit[pixel] = hit.pack();
#endif
    ShadingData primary;
    uint materialID;
    if (!rtptPrimaryPrepareHit(hit, ray, primary, materialID)) return;
    const IMaterialInstance primaryMI = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    gPrimaryPosition[pixel] = float4(primary.posW, 1.f);
    gPrimaryNormalRoughness[pixel] = float4(primary.getOrientedFaceNormal(), primaryMI.getProperties(primary).roughness);
}
