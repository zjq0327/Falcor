#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import RenderPasses.MyPT.MyPTCommon;

struct VisibilityProbe
{
    float4 position;
    float4 normal;
    float4 lightPosition;
    float4 lightNormal;
};

StructuredBuffer<VisibilityProbe> gProbes;
// Old/new visibility and old/new closest-hit material IDs (invalid on miss).
RWStructuredBuffer<uint4> gResults;
// Old TMax, old hit T, new TMax, production helper success.
RWStructuredBuffer<float4> gSegments;

uint hitMaterial(HitInfo hit)
{
    if (!hit.isValid()) return 0xffffffffu;
    return gScene.getMaterialID(hit.getTriangleHit().instanceID);
}

[numthreads(1, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    VisibilityProbe probe = gProbes[tid.x];
    ShadingData sd = {};
    sd.posW = probe.position.xyz;
    sd.faceN = probe.normal.xyz;
    TriangleLightSample ls = {};
    ls.posW = probe.lightPosition.xyz;
    ls.normalW = probe.lightNormal.xyz;
    float3 originalEdge = ls.posW - sd.posW;
    ls.distance = length(originalEdge);
    ls.dir = originalEdge / ls.distance;

    // Keep the faulty construction only as a regression witness. The tested
    // implementation below is imported from production, not copied here.
    float3 oldOrigin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);
    Ray oldRay = Ray(oldOrigin, ls.dir, 0.f, ls.distance * (1.f - 1e-5f));
    SceneRayQuery<true> query;
    float oldHitT;
    HitInfo oldHit = query.traceRay(oldRay, oldHitT);
    bool oldVisible = query.traceVisibilityRay(oldRay);

    float3 origin, direction;
    float distance;
    bool valid = getMyPTEmissiveVisibilityRay(sd, ls, origin, direction, distance);
    uint newMaterial = 0xffffffffu;
    bool newVisible = false;
    if (valid)
    {
        Ray newRay = Ray(origin, direction, 0.f, distance);
        float newHitT;
        HitInfo newHit = query.traceRay(newRay, newHitT);
        newMaterial = hitMaterial(newHit);
        newVisible = query.traceVisibilityRay(newRay);
    }
    gResults[tid.x] = uint4(uint(oldVisible), uint(newVisible), hitMaterial(oldHit), newMaterial);
    gSegments[tid.x] = float4(oldRay.tMax, oldHitT, distance, valid ? 1.f : 0.f);
}
