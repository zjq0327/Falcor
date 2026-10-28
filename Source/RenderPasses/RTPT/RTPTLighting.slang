#pragma once


#include "LocalLights/RTPTLocalLightSampling.slang"

RTPTLightingContext rtptSurfaceLightContext(
    ShadingData sd, uint2 pixel, uint sampleIndex, uint pathDepth, uint kind)
{
    RTPTLightingContext context = rtptMakeLightContext(
        sd.posW, sd.getOrientedFaceNormal(), pixel, sampleIndex, pathDepth, kind);
    context.snapshotGeneration = gLocalLightParams.proposalGeneration;
    return context;
}

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
    if (probability > 0.f)
    {
        // Avoid an in-place swizzle fold: on the current D3D12 shader path
        // it produces inconsistent sample/MIS PDFs. Preserve both components
        // before folding the lower hemisphere.
        const float3 localDir = gScene.envMap.toLocal(dir);
        const float r = sqrt(max(0.f, 1.f - abs(localDir.z)));
        const float v = r * atan2(abs(localDir.y), abs(localDir.x)) * M_2_PI;
        const float u = r - v;
        const float2 folded = localDir.z < 0.f ? float2(1.f - v, 1.f - u) : float2(u, v);
        const float2 uv = folded * sign(localDir.xy) * 0.5f + 0.5f;
        const float integral = gEnvMapSampler.importanceMap.Load(int3(0, 0, gEnvMapSampler.importanceBaseMip));
        const float importance = gEnvMapSampler.importanceMap.SampleLevel(gEnvMapSampler.importanceSampler, uv, 0);
        return probability * (importance / integral) * M_1_4PI;
    }
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

bool rtptSampleLight(ShadingData sd, RTPTLightingContext context, inout SampleGenerator sg, out RTPTLightSample result)
{
    result = {};
    context.positionW = sd.posW;
    context.normalW = sd.getOrientedFaceNormal();
    const float3 probabilities = rtptLightCategoryProbabilities();
    if (all(probabilities == 0.f)) return false;
    const float u = sampleNext1D(sg);
    const float3 origin = sd.computeRayOrigin();

    if (u < probabilities.x)
    {
#if USE_ENV_LIGHT
        EnvMapSample ls;
        if (!gEnvMapSampler.sample(sampleNext2D(sg), ls)) return false;
        result.samplePdf = ls.pdf * probabilities.x;
        result.misReferencePdf = result.samplePdf;
        if (!(result.samplePdf > 0.f) || !isfinite(result.samplePdf)) return false;
        result.selectionPmf = result.referenceSelectionPmf = 1.f;
        result.key.kind = RTPT_LIGHT_KIND_ENVIRONMENT;
        result.key.sceneGeneration = gLocalLightParams.sceneGeneration;
        result.sourceBranch = RTPT_LIGHT_SOURCE_GLOBAL;
        result.snapshotGeneration = gLocalLightParams.proposalGeneration;
        result.dir = ls.dir;
        result.LiOverPdf = ls.Le / result.samplePdf;
        result.visibilityRay = Ray(origin, ls.dir);
#else
        return false;
#endif
    }
    else if (u < probabilities.x + probabilities.y)
    {
#if USE_EMISSIVE_LIGHTS
        RTPTLocalLightSelection selection;
        if (!rtptLocalSelectLight(RTPT_LIGHT_CATEGORY_EMISSIVE, context, sg, selection)) return false;
        result.key = selection.key;
        result.selectionPmf = selection.selectionPmf;
        result.referenceSelectionPmf = selection.referenceSelectionPmf;
        result.sourceBranch = selection.sourceBranch;
        result.snapshotGeneration = selection.snapshotGeneration;
        TriangleLightSample ls;
        if (!sampleTriangle(sd.posW, selection.key.index, sampleNext2D(sg), ls)) return false;
        // Preserve the baseline UniformSampler arithmetic order.
        const float geometryPdf = ls.pdf;
        ls.pdf *= selection.selectionPmf;
        result.samplePdf = ls.pdf * probabilities.y;
        result.misReferencePdf = (geometryPdf * selection.referenceSelectionPmf) * probabilities.y;
        if (!(result.samplePdf > 0.f) || !isfinite(result.samplePdf)) return false;

        // Visibility traversal cannot alpha-test the endpoint after it has been
        // offset off the light. Test the sampled emitter's alpha explicitly.
        const EmissiveTriangle triangle = gScene.lightCollection.getTriangle(ls.triangleIndex);
        VertexData lightVertex = {};
        lightVertex.posW = ls.posW;
        lightVertex.texC = triangle.getTexCoord(sample_triangle(ls.uv));
        if (gScene.materials.alphaTest(lightVertex, triangle.materialID, 0.f)) return false;

        result.dir = ls.dir;
        result.LiOverPdf = ls.Le / result.samplePdf;
        const float3 lightOrigin = computeRayOrigin(ls.posW, ls.normalW);
        result.targetPosition = ls.posW;
        result.finiteTarget = true;
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
        RTPTLocalLightSelection selection;
        if (!rtptLocalSelectLight(RTPT_LIGHT_CATEGORY_ANALYTIC, context, sg, selection)) return false;
        const uint index = selection.key.index;
        result.key = selection.key;
        result.selectionPmf = selection.selectionPmf;
        result.referenceSelectionPmf = selection.referenceSelectionPmf;
        result.sourceBranch = selection.sourceBranch;
        result.snapshotGeneration = selection.snapshotGeneration;
        AnalyticLightSample ls;
        if (!sampleLight(sd.posW, gScene.getLight(index), sg, ls)) return false;
        result.dir = ls.dir;
        result.misReferencePdf = ls.pdf * probabilities.z / float(count);
        // AnalyticLightSample::Li is already divided by its directional PDF.
        if (selection.selectionPmf == selection.referenceSelectionPmf)
        {
            // Keep the existing arithmetic on the global-only path.
            result.samplePdf = result.misReferencePdf;
            result.LiOverPdf = ls.Li * (float(count) / probabilities.z);
        }
        else
        {
            if (!(selection.selectionPmf > 0.f) || !isfinite(selection.selectionPmf)) return false;
            result.samplePdf = (ls.pdf * selection.selectionPmf) * probabilities.z;
            result.LiOverPdf = ls.Li / (selection.selectionPmf * probabilities.z);
        }
        result.analytic = true;
        result.delta = ls.pdf == 0.f;
        result.visibilityRay = Ray(origin, ls.dir, 0.f, ls.distance);
#else
        return false;
#endif
    }

    return dot(sd.getOrientedFaceNormal(), result.dir) > 0.f &&
        all(isfinite(result.LiOverPdf)) && any(result.LiOverPdf > 0.f);
}

float3 rtptEstimateDirect(ShadingData sd, IMaterialInstance mi, RTPTLightingContext context, inout SampleGenerator sg)
{
    RTPTLightSample ls;
    if (!rtptSampleLight(sd, context, sg, ls))
    {
        rtptLocalRecordFeedback(context, ls, float3(0.f), false);
        return float3(0.f);
    }

    // Falcor's analytic lights have no intersectable geometry, hence no
    // competing BSDF technique. This includes its analytic area lights.
    float misWeight = 1.f;
    if (!ls.analytic)
    {
        const float continuationPdf = mi.evalPdf(sd, ls.dir);
        if (!isfinite(continuationPdf)) return float3(0.f);
        misWeight = rtptPowerHeuristic(ls.misReferencePdf, continuationPdf);
    }

    // mi.eval() already includes the shading-normal cosine.
    const float3 raw = mi.eval(sd, ls.dir, sg) * ls.LiOverPdf;
    const float3 contribution = raw * misWeight;
    if (!all(isfinite(contribution))) return float3(0.f);
    if (!any(contribution > 0.f))
    {
        // A true zero BSDF event is an observation. A positive raw value whose
        // MIS partition underflowed has no visibility result and is not logged.
        if (all(isfinite(raw)) && !any(raw > 0.f))
            rtptLocalRecordFeedback(context, ls, float3(0.f), false);
        return float3(0.f);
    }
    SceneRayQuery<true> query;
    const bool visible = query.traceVisibilityRay(ls.visibilityRay);
    if (all(isfinite(raw))) rtptLocalRecordFeedback(context, ls, visible ? raw : float3(0.f), visible, true);
    return visible ? contribution : float3(0.f);
}

#if ENABLE_NRD
/** Evaluate a previously sampled and visibility-tested light for one component.
    A diffuse continuation and a specular continuation are both generated, so
    each component competes with its own BSDF continuation density.
*/
float3 rtptEvaluateDirectComponent(
    ShadingData sd, IMaterialInstance mi, RTPTLightSample ls, inout SampleGenerator sg, out float3 raw)
{
    raw = 0.f;
    float misWeight = 1.f;
    if (!ls.analytic)
    {
        const float continuationPdf = mi.evalPdf(sd, ls.dir);
        if (!isfinite(continuationPdf))
        {
            // Invalid evaluation must not become a valid zero-valued event.
            raw = float3(continuationPdf);
            return float3(0.f);
        }
        misWeight = rtptPowerHeuristic(ls.misReferencePdf, continuationPdf);
    }
    raw = mi.eval(sd, ls.dir, sg) * ls.LiOverPdf;
    const float3 contribution = raw * misWeight;
    return all(isfinite(contribution)) ? contribution : float3(0.f);
}
#endif
