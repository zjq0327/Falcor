// Shared helpers extracted from MyPT.rt.slang. See the license in that file.
__exported import Scene.Shading;
__exported import Utils.Sampling.SampleGenerator;
__exported import Rendering.Lights.LightHelpers;
__exported import Rendering.Lights.EmissiveLightSampler;

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

bool sampleMyPTBSDF(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, out BSDFSample bs, bool importance)
{
    return mi.sample(sd, sg, bs, importance);
}

// Keep the PT power heuristic; GRIS calls this with powerHeuristic=false for balance MIS.
float evalMIS(float p0, float p1, bool powerHeuristic = true)
{
    float q0 = powerHeuristic ? p0 * p0 : p0;
    float q1 = powerHeuristic ? p1 * p1 : p1;
    return q0 + q1 > 0.f ? q0 / (q0 + q1) : 0.f;
}
