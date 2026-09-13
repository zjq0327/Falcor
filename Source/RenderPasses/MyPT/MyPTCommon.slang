// Shared helpers extracted from MyPT.rt.slang. See the license in that file.
__exported import Scene.Shading;
__exported import Utils.Sampling.SampleGenerator;
__exported import Rendering.Lights.LightHelpers;
__exported import Rendering.Lights.EmissiveLightSampler;
import Utils.Geometry.GeometryHelpers;

// Power sampling owns an alias-table buffer in this Falcor version; bind it from C++.
ParameterBlock<EmissiveLightSampler> gMyPTEmissiveSampler;

ShadingData loadShadingData(const HitInfo hit, const float3 rayDir)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    return gScene.materials.prepareShadingData(v, materialID, -rayDir);
}

bool sampleMyPTAnalyticLight(ShadingData sd, inout SampleGenerator sg, out AnalyticLightSample ls, out float invPdf)
{
    uint lightCount = gScene.getLightCount();
    ls = {};
    invPdf = float(lightCount);
    if (lightCount == 0) return false;
    uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    return sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls);
}

bool sampleMyPTEmissiveLight(ShadingData sd, inout SampleGenerator sg, out TriangleLightSample ls)
{
    return gMyPTEmissiveSampler.sampleLight(sd.posW, sd.getOrientedFaceNormal(), false, sg, ls);
}

bool getMyPTEmissiveVisibilityRay(ShadingData sd, TriangleLightSample ls,
    out float3 origin, out float3 direction, out float distance)
{
    // Reference ReSTIRPTPass::generateEmissiveSample offsets BOTH endpoints.
    // Keeping the original direction/distance after moving the origin can hit
    // the sampled emitter itself. Keep these offsets out of transport BSDF/PDFs.
    float3 target = computeRayOrigin(ls.posW, ls.normalW);
    origin = computeRayOrigin(sd.posW, dot(sd.faceN, target - sd.posW) >= 0.f ? sd.faceN : -sd.faceN);
    float3 edge = target - origin;
    distance = length(edge);
    direction = 0.f;
    if (!(distance > 0.f) || !isfinite(distance)) return false;
    direction = edge / distance;
    return true;
}

bool sampleMyPTBSDF(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, out BSDFSample bs, bool importance)
{
    return mi.sample(sd, sg, bs, importance);
}

float evalMyPTBSDFPdf(ShadingData sd, IMaterialInstance mi, float3 direction, bool importance)
{
    float pdf = mi.evalPdf(sd, direction, importance);
    // Falcor 8 StandardMaterialInstance.evalPdfReference uses signed wo.z on
    // transmission, although sampleReference returns 0.5 * abs(wo.z) / pi.
    return !importance && gScene.materials.getMaterialType(sd.materialID) == MaterialType::Standard ? abs(pdf) : pdf;
}

// Keep the PT power heuristic; GRIS calls this with powerHeuristic=false for balance MIS.
float evalMIS(float p0, float p1, bool powerHeuristic = true)
{
    float q0 = powerHeuristic ? p0 * p0 : p0;
    float q1 = powerHeuristic ? p1 * p1 : p1;
    return q0 + q1 > 0.f ? q0 / (q0 + q1) : 0.f;
}
