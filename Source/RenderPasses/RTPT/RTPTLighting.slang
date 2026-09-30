#pragma once

// All directional PDFs in this file are measured in solid angle. LiOverPdf
// includes both the light category probability and the sampler's own PDF.
struct RTPTLightSample
{
    float3 dir;
    float3 LiOverPdf;
    float pdf;
    bool analytic;
    Ray visibilityRay;
};

float rtptPowerHeuristic(float pdf, float otherPdf)
{
    if (!(pdf > 0.f)) return 0.f;
    if (!(otherPdf > 0.f)) return 1.f;
    // Scale before squaring to avoid overflow at grazing light samples.
    const float scale = max(pdf, otherPdf);
    const float p = pdf / scale;
    const float q = otherPdf / scale;
    return p * p / (p * p + q * q);
}

bool rtptEnvironmentHasEnergy()
{
#if USE_ENV_LIGHT
    const float integral = gEnvMapSampler.importanceMap.Load(int3(0, 0, gEnvMapSampler.importanceBaseMip));
    return integral > 0.f && isfinite(integral);
#else
    return false;
#endif
}

// x: environment, y: emissive triangles, z: analytic lights.
float3 rtptLightCategoryProbabilities()
{
    float3 p = 0.f;
    if (gParams.useNEE == 0) return p;
#if USE_ENV_LIGHT
    p.x = rtptEnvironmentHasEnergy() ? 1.f : 0.f;
#endif
#if USE_EMISSIVE_LIGHTS
    p.y = gScene.lightCollection.getActiveTriangleCount() > 0 ? 1.f : 0.f;
#endif
#if USE_ANALYTIC_LIGHTS
    p.z = gScene.getLightCount() > 0 ? 1.f : 0.f;
#endif
    const float sum = p.x + p.y + p.z;
    return sum > 0.f ? p / sum : float3(0.f);
}

float rtptEnvironmentLightPdf(float3 dir)
{
#if USE_ENV_LIGHT
    const float probability = rtptLightCategoryProbabilities().x;
    if (probability > 0.f) return probability * gEnvMapSampler.evalPdf(dir);
#endif
    return 0.f;
}

float rtptEmissiveLightPdf(float3 previousPosition, float3 previousNormal, TriangleHit hit, ShadingData sd)
{
#if USE_EMISSIVE_LIGHTS
    const float probability = rtptLightCategoryProbabilities().y;
    if (probability <= 0.f || !sd.frontFacing) return 0.f;

    const uint triangleIndex = gScene.lightCollection.getTriangleIndex(hit.instanceID, hit.primitiveIndex);
    if (triangleIndex == LightCollection::kInvalidIndex) return 0.f;
    if (gScene.lightCollection.getActiveTriangleIndex(triangleIndex) == LightCollection::kInvalidIndex) return 0.f;

    TriangleLightHit lightHit;
    lightHit.triangleIndex = triangleIndex;
    lightHit.posW = sd.posW;
    // The light sampler uses the unflipped face normal (one-sided emission).
    lightHit.normalW = gScene.lightCollection.getTriangle(triangleIndex).normal;
    EmissiveUniformSampler sampler = {};
    return probability * sampler.evalPdf(previousPosition, previousNormal, true, lightHit);
#else
    return 0.f;
#endif
}

bool rtptSampleLight(ShadingData sd, inout SampleGenerator sg, out RTPTLightSample result)
{
    result = {};
    const float3 probabilities = rtptLightCategoryProbabilities();
    if (all(probabilities == 0.f)) return false;
    const float u = sampleNext1D(sg);
    const float3 origin = sd.computeRayOrigin();

    if (u < probabilities.x)
    {
#if USE_ENV_LIGHT
        EnvMapSample ls;
        if (!gEnvMapSampler.sample(sampleNext2D(sg), ls)) return false;
        result.pdf = ls.pdf * probabilities.x;
        if (!(result.pdf > 0.f) || !isfinite(result.pdf)) return false;
        result.dir = ls.dir;
        result.LiOverPdf = ls.Le / result.pdf;
        result.visibilityRay = Ray(origin, ls.dir);
#else
        return false;
#endif
    }
    else if (u < probabilities.x + probabilities.y)
    {
#if USE_EMISSIVE_LIGHTS
        EmissiveUniformSampler sampler = {};
        TriangleLightSample ls;
        if (!sampler.sampleLight(sd.posW, sd.getOrientedFaceNormal(), true, sg, ls)) return false;
        result.pdf = ls.pdf * probabilities.y;
        if (!(result.pdf > 0.f) || !isfinite(result.pdf)) return false;

        // Visibility traversal cannot alpha-test the endpoint after it has been
        // offset off the light. Test the sampled emitter's alpha explicitly.
        const EmissiveTriangle triangle = gScene.lightCollection.getTriangle(ls.triangleIndex);
        VertexData lightVertex = {};
        lightVertex.posW = ls.posW;
        lightVertex.texC = triangle.getTexCoord(sample_triangle(ls.uv));
        if (gScene.materials.alphaTest(lightVertex, triangle.materialID, 0.f)) return false;

        result.dir = ls.dir;
        result.LiOverPdf = ls.Le / result.pdf;
        const float3 lightOrigin = computeRayOrigin(ls.posW, ls.normalW);
        const float3 shadowVector = lightOrigin - origin;
        const float distance = length(shadowVector);
        if (!(distance > 0.f) || !isfinite(distance)) return false;
        result.visibilityRay = Ray(origin, shadowVector / distance, 0.f, distance);
#else
        return false;
#endif
    }
    else
    {
#if USE_ANALYTIC_LIGHTS
        if (probabilities.z <= 0.f) return false;
        const uint count = gScene.getLightCount();
        const uint index = min(uint(sampleNext1D(sg) * count), count - 1);
        AnalyticLightSample ls;
        if (!sampleLight(sd.posW, gScene.getLight(index), sg, ls)) return false;
        result.dir = ls.dir;
        result.pdf = ls.pdf * probabilities.z / float(count);
        // AnalyticLightSample::Li is already divided by its directional PDF.
        result.LiOverPdf = ls.Li * (float(count) / probabilities.z);
        result.analytic = true;
        result.visibilityRay = Ray(origin, ls.dir, 0.f, ls.distance);
#else
        return false;
#endif
    }

    return dot(sd.getOrientedFaceNormal(), result.dir) > 0.f &&
        all(isfinite(result.LiOverPdf)) && any(result.LiOverPdf > 0.f);
}

float3 rtptEstimateDirect(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg)
{
    RTPTLightSample ls;
    if (!rtptSampleLight(sd, sg, ls)) return float3(0.f);

    // Falcor's analytic lights have no intersectable geometry, hence no
    // competing BSDF technique. This includes its analytic area lights.
    float misWeight = 1.f;
    if (!ls.analytic)
    {
        const float bsdfPdf = mi.evalPdf(sd, ls.dir);
        if (!isfinite(bsdfPdf)) return float3(0.f);
        misWeight = rtptPowerHeuristic(ls.pdf, bsdfPdf);
    }

    // mi.eval() already includes the shading-normal cosine.
    const float3 contribution = mi.eval(sd, ls.dir, sg) * ls.LiOverPdf * misWeight;
    if (!all(isfinite(contribution)) || !any(contribution > 0.f)) return float3(0.f);
    SceneRayQuery<true> query;
    return query.traceVisibilityRay(ls.visibilityRay) ? contribution : float3(0.f);
}
