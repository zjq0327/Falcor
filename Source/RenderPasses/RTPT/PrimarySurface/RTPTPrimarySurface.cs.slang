/** Primary camera visibility remains a ComputePass using alpha-tested RayQuery. */
#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
#include "RTPTCamera.slang"
#include "RTPTPrimarySurfaceTypes.slang"

ConstantBuffer<RTPTPrimarySettings> gPrimarySettings;
RWStructuredBuffer<RTPTPrimarySurface> gPrimarySurfaceOutput;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gPrimarySettings.frameDim)) return;
    SampleGenerator sg = SampleGenerator(pixel, gPrimarySettings.sampleIndex);
    const Ray ray = rtptGeneratePrimaryCameraRay(gScene.camera, pixel, gPrimarySettings.frameDim, sg);
    SceneRayQuery<true> query;
    float hitT;
    const HitInfo hit = query.traceRay(ray, hitT);

    RTPTPrimarySurface surface = {};
    surface.packedHit = hit.pack();
    surface.hitT = hitT;
    surface.sampleIndex = gPrimarySettings.sampleIndex;
    surface.frameStamp = gPrimarySettings.frameStamp;
    surface.flags = kRTPTPrimaryRecordReady;
    surface.rayOrigin = ray.origin;
    surface.rayTMin = ray.tMin;
    surface.rayDirection = ray.dir;
    surface.rayTMax = ray.tMax;
    surface.materialID = ~0u;
    surface.guideNormal = float3(0.f, 0.f, 1.f);
    surface.viewZ = 60000.f;

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        const VertexData vertex = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        const BSDFProperties properties = mi.getProperties(sd);
        surface.position = sd.posW;
        surface.materialID = materialID;
        surface.guideNormal = properties.guideNormal;
        surface.roughness = properties.roughness;
        surface.viewZ = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1.f)).w;
        surface.motionW = gScene.getPrevPosW(triangleHit) - sd.posW;
    }
#endif
    gPrimarySurfaceOutput[pixel.y * gPrimarySettings.frameDim.x + pixel.x] = surface;
}
