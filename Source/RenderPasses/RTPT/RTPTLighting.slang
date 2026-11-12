#pragma once

#include "RTPTSampling.slang"

#ifndef RTPT_USE_RESTIR_DI
#define RTPT_USE_RESTIR_DI 0
#endif
#ifndef RTPT_REGIR_ONLY
#define RTPT_REGIR_ONLY 0
#endif
#ifndef RTPT_GRIS_SUFFIX_REPLAY
#define RTPT_GRIS_SUFFIX_REPLAY 0
#endif

#if RTPT_GRIS_SUFFIX_REPLAY
static const uint kRTPTInvalidReplayLightID = 0xffffffffu;
enum RTPTReplayLightType { None, Point, Emissive, Environment };
#endif

// All directional PDFs in this file are measured in solid angle. LiOverPdf
// includes both the light category probability and the sampler's own PDF.
struct RTPTLightSample
{
    float3 dir;
    float3 LiOverPdf;
    float pdf;
    bool analytic;
    Ray visibilityRay;
#if RTPT_GRIS_SUFFIX_REPLAY
    RTPTReplayLightType replayType;
#endif
};

#include "ReGIR/RTPTReGIRTransport.slang"

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

uint rtptSampleLightCategory(float3 probabilities, inout SampleGenerator sg)
{
    const float u = sampleNext1D(sg);
    if (u < probabilities.x) return 0u;
    return u < probabilities.x + probabilities.y ? 1u : 2u;
}

#if USE_ENV_LIGHT
float rtptEvaluateEnvironmentLightPdf(float3 dir, float probability)
{
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
    return 0.f;
}
#endif

float rtptEnvironmentLightPdf(float3 dir)
{
#if USE_ENV_LIGHT
    return rtptEvaluateEnvironmentLightPdf(dir, rtptLightCategoryProbabilities().x);
#else
    return 0.f;
#endif
}

#if USE_EMISSIVE_LIGHTS
float rtptEvaluateEmissiveLightPdf(
    float3 previousPosition, float3 previousNormal, TriangleHit hit, ShadingData sd, float probability)
{
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
}
#endif

float rtptEmissiveLightPdf(float3 previousPosition, float3 previousNormal, TriangleHit hit, ShadingData sd)
{
#if USE_EMISSIVE_LIGHTS
    return rtptEvaluateEmissiveLightPdf(previousPosition, previousNormal, hit, sd, rtptLightCategoryProbabilities().y);
#else
    return 0.f;
#endif
}

#if USE_ENV_LIGHT
bool rtptSampleEnvironmentLight(float3 origin, float probability, inout SampleGenerator sg, inout RTPTLightSample result)
{
#if RTPT_GRIS_SUFFIX_REPLAY
    result.replayType = RTPTReplayLightType::Environment;
#endif
    EnvMapSample ls;
    if (!gEnvMapSampler.sample(sampleNext2D(sg), ls)) return false;
    result.pdf = ls.pdf * probability;
    if (!(result.pdf > 0.f) || !isfinite(result.pdf)) return false;
    result.dir = ls.dir;
    result.LiOverPdf = ls.Le / result.pdf;
    result.visibilityRay = Ray(origin, ls.dir);
    return true;
}
#endif

#if USE_EMISSIVE_LIGHTS
bool rtptSampleEmissiveLight(
    ShadingData sd, float3 origin, float probability, inout SampleGenerator sg, inout RTPTLightSample result)
{
    EmissiveUniformSampler sampler = {};
    TriangleLightSample ls;
    if (!sampler.sampleLight(sd.posW, sd.getOrientedFaceNormal(), true, sg, ls)) return false;
    result.pdf = ls.pdf * probability;
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
#if RTPT_GRIS_SUFFIX_REPLAY
    result.replayType = RTPTReplayLightType::Emissive;
#endif
    return true;
}
#endif

#if USE_ANALYTIC_LIGHTS
uint rtptSampleAnalyticLightIndex(uint count, inout SampleGenerator sg)
{
    return min(uint(sampleNext1D(sg) * count), count - 1u);
}

bool rtptSampleAnalyticLightData(ShadingData sd, float3 origin, LightData light, uint count, float probability,
    inout SampleGenerator sg, inout RTPTLightSample result)
{
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, light, sg, ls)) return false;
    result.dir = ls.dir;
    result.pdf = ls.pdf * probability / float(count);
    // AnalyticLightSample::Li is already divided by its directional PDF.
    result.LiOverPdf = ls.Li * (float(count) / probability);
    result.analytic = true;
    result.visibilityRay = Ray(origin, ls.dir, 0.f, ls.distance);
    return true;
}

bool rtptSampleAnalyticLight(ShadingData sd, float3 origin, uint index, uint count, float probability,
    inout SampleGenerator sg, inout RTPTLightSample result)
{
    const LightData light = gScene.getLight(index);
#if RTPT_GRIS_SUFFIX_REPLAY
    if (light.type == uint(LightType::Point)) result.replayType = RTPTReplayLightType::Point;
#endif
    return rtptSampleAnalyticLightData(sd, origin, light, count, probability, sg, result);
}
#endif

bool rtptValidLightSample(ShadingData sd, RTPTLightSample light)
{
    return dot(sd.getOrientedFaceNormal(), light.dir) > 0.f &&
        all(isfinite(light.LiOverPdf)) && any(light.LiOverPdf > 0.f);
}

#if RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_TEMPORAL_REUSE)
#if USE_ANALYTIC_LIGHTS
StructuredBuffer<LightData> gGRISReplayPreviousLights;
#endif

uint rtptReplayPointLightIndex(inout SampleGenerator sg)
{
#if USE_ANALYTIC_LIGHTS
    const float3 probabilities = rtptLightCategoryProbabilities();
    if (probabilities.z > 0.f && rtptSampleLightCategory(probabilities, sg) == 2u)
    {
        const uint index = rtptSampleAnalyticLightIndex(gScene.getLightCount(), sg);
        if (gScene.getLight(index).type == uint(LightType::Point)) return index;
    }
#endif
    return kRTPTInvalidReplayLightID;
}

bool rtptReplayPointLightChanged(uint lightID)
{
#if USE_ANALYTIC_LIGHTS
    if (lightID >= gScene.getLightCount()) return false;
    const LightData current = gScene.getLight(lightID);
    const LightData previous = gGRISReplayPreviousLights[lightID];
    return any(current.posW != previous.posW) || any(current.intensity != previous.intensity);
#else
    return false;
#endif
}

bool rtptReplayPointLight(ShadingData sd, uint lightID, bool previous, inout SampleGenerator sg, out RTPTLightSample result)
{
    result = {};
#if USE_ANALYTIC_LIGHTS
    const uint count = gScene.getLightCount();
    if (lightID >= count) return false;
    const float probability = rtptLightCategoryProbabilities().z;
    if (!(probability > 0.f)) return false;
    const LightData light = previous ? gGRISReplayPreviousLights[lightID] : gScene.getLight(lightID);
    if (light.type != uint(LightType::Point)) return false;
    return rtptSampleAnalyticLightData(sd, sd.computeRayOrigin(), light, count, probability, sg, result) &&
        rtptValidLightSample(sd, result);
#else
    return false;
#endif
}
#endif

bool rtptSampleLight(ShadingData sd, inout SampleGenerator sg, out RTPTLightSample result)
{
    result = {};
    const float3 probabilities = rtptLightCategoryProbabilities();
    if (all(probabilities == 0.f)) return false;
    const uint category = rtptSampleLightCategory(probabilities, sg);
    const float3 origin = sd.computeRayOrigin();

    if (category == 0u)
    {
#if USE_ENV_LIGHT
        if (!rtptSampleEnvironmentLight(origin, probabilities.x, sg, result)) return false;
#else
        return false;
#endif
    }
    else if (category == 1u)
    {
#if USE_EMISSIVE_LIGHTS
        if (!rtptSampleEmissiveLight(sd, origin, probabilities.y, sg, result)) return false;
#else
        return false;
#endif
    }
    else
    {
#if USE_ANALYTIC_LIGHTS
        if (probabilities.z <= 0.f) return false;
        const uint count = gScene.getLightCount();
        const uint index = rtptSampleAnalyticLightIndex(count, sg);
        if (!rtptSampleAnalyticLight(sd, origin, index, count, probabilities.z, sg, result)) return false;
#else
        return false;
#endif
    }

    return rtptValidLightSample(sd, result);
}

/** The root DI domain covers the entire light-collection triangle catalogue,
    including triangles absent from the legacy active-triangle proposal. A
    zero proxy power or an empty reservoir never gives ownership back to NEE.
*/
bool rtptDICoversEmissiveHit(TriangleHit hit, uint coverage)
{
#if RTPT_USE_RESTIR_DI || RTPT_REGIR_TRANSPORT
    if ((coverage & kRTPTDICoverEmissive) == 0u) return false;
    const uint index = gScene.lightCollection.getTriangleIndex(hit.instanceID, hit.primitiveIndex);
    if (index == LightCollection::kInvalidIndex) return false;
    return index < gScene.lightCollection.getTriangleCount();
#else
    return false;
#endif
}

uint rtptAnalyticLightCountForCoverage(uint coverage)
{
#if USE_ANALYTIC_LIGHTS
#if RTPT_REGIR_TRANSPORT
    if ((coverage & kRTPTDICoverPoint) != 0u && gReGIRSettings.active != 0u)
        return gReGIRSettings.uncoveredAnalyticCount;
#endif
#if RTPT_USE_RESTIR_DI
    if ((coverage & kRTPTDICoverPoint) != 0u) return gDISettings.uncoveredAnalyticCount;
#endif
    return gScene.getLightCount();
#else
    return 0u;
#endif
}

// Each nonempty remaining category receives equal probability, exactly as in
// the legacy proposal. Analytic lights use the filtered list's actual size.
float3 rtptLightCategoryProbabilitiesForCoverage(uint coverage)
{
    if (coverage == 0u) return rtptLightCategoryProbabilities();
    float3 p = 0.f;
    if (gParams.useNEE == 0u) return p;
#if USE_ENV_LIGHT
    p.x = rtptEnvironmentHasEnergy() ? 1.f : 0.f;
#endif
#if USE_EMISSIVE_LIGHTS
#if RTPT_USE_RESTIR_DI || RTPT_REGIR_TRANSPORT
    if ((coverage & kRTPTDICoverEmissive) == 0u)
#endif
        p.y = gScene.lightCollection.getActiveTriangleCount() > 0u ? 1.f : 0.f;
#endif
#if USE_ANALYTIC_LIGHTS
    p.z = rtptAnalyticLightCountForCoverage(coverage) > 0u ? 1.f : 0.f;
#endif
    const float sum = p.x + p.y + p.z;
    return sum > 0.f ? p / sum : float3(0.f);
}

float rtptEnvironmentLightPdfForCoverage(float3 dir, uint coverage)
{
    if (coverage == 0u) return rtptEnvironmentLightPdf(dir);
#if USE_ENV_LIGHT
    return rtptEvaluateEnvironmentLightPdf(dir, rtptLightCategoryProbabilitiesForCoverage(coverage).x);
#else
    return 0.f;
#endif
}

float rtptEmissiveLightPdfForCoverage(
    float3 previousPosition, float3 previousNormal, TriangleHit hit, ShadingData sd, uint coverage)
{
    if (coverage == 0u) return rtptEmissiveLightPdf(previousPosition, previousNormal, hit, sd);
#if USE_EMISSIVE_LIGHTS
    return rtptEvaluateEmissiveLightPdf(previousPosition, previousNormal, hit, sd,
        rtptLightCategoryProbabilitiesForCoverage(coverage).y);
#else
    return 0.f;
#endif
}

/** Sample the light domain left over after DI or ReGIR claims its coverage. */
bool rtptSampleLightForCoverage(ShadingData sd, uint coverage, inout SampleGenerator sg, out RTPTLightSample result)
{
    if (coverage == 0u) return rtptSampleLight(sd, sg, result);
    result = {};
    const float3 probabilities = rtptLightCategoryProbabilitiesForCoverage(coverage);
    if (all(probabilities == 0.f)) return false;
    const float u = sampleNext1D(sg);
    const float3 origin = sd.computeRayOrigin();
    if (u < probabilities.x)
    {
#if USE_ENV_LIGHT
        if (!rtptSampleEnvironmentLight(origin, probabilities.x, sg, result)) return false;
#else
        return false;
#endif
    }
    else if (u < probabilities.x + probabilities.y)
    {
#if USE_EMISSIVE_LIGHTS
        if (!rtptSampleEmissiveLight(sd, origin, probabilities.y, sg, result)) return false;
#else
        return false;
#endif
    }
    else
    {
#if USE_ANALYTIC_LIGHTS
        if (probabilities.z <= 0.f) return false;
        const uint count = rtptAnalyticLightCountForCoverage(coverage);
        if (count == 0u) return false;
        const uint rank = min(uint(sampleNext1D(sg) * count), count - 1u);
        uint index = rank;
#if RTPT_REGIR_TRANSPORT
        if ((coverage & kRTPTDICoverPoint) != 0u && gReGIRSettings.active != 0u)
            index = gReGIRTransportUncoveredAnalyticIndices[rank];
        else
#endif
#if RTPT_USE_RESTIR_DI
        if ((coverage & kRTPTDICoverPoint) != 0u) index = gDIUncoveredAnalyticIndices[rank];
#else
        { }
#endif
        if (index >= gScene.getLightCount()) return false;
        if (!rtptSampleAnalyticLight(sd, origin, index, count, probabilities.z, sg, result)) return false;
#else
        return false;
#endif
    }
    return dot(sd.getOrientedFaceNormal(), result.dir) > 0.f &&
        all(isfinite(result.LiOverPdf)) && any(result.LiOverPdf > 0.f);
}

float3 rtptEvaluateLightSample(ShadingData sd, IMaterialInstance mi, RTPTSamplingContext sampling,
    RTPTLightSample ls, inout SampleGenerator sg, bool hasBSDFCompetitor = true)
{
    // Falcor's analytic lights have no intersectable geometry, hence no
    // competing BSDF technique. This includes its analytic area lights.
    float misWeight = 1.f;
    if (hasBSDFCompetitor && !ls.analytic)
    {
        const float continuationPdf = rtptContinuationPdf(sd, mi, sampling, ls.dir);
        if (!isfinite(continuationPdf)) return float3(0.f);
        misWeight = rtptPowerHeuristic(ls.pdf, continuationPdf);
    }

    // mi.eval() already includes the shading-normal cosine.
    return mi.eval(sd, ls.dir, sg) * ls.LiOverPdf * misWeight;
}

float3 rtptEstimateDirectSample(ShadingData sd, IMaterialInstance mi, RTPTSamplingContext sampling,
    inout SampleGenerator sg, out RTPTLightSample ls, bool hasBSDFCompetitor = true)
{
    if (!rtptSampleLight(sd, sg, ls)) return float3(0.f);
    const float3 contribution = rtptEvaluateLightSample(sd, mi, sampling, ls, sg, hasBSDFCompetitor);
    if (!all(isfinite(contribution)) || !any(contribution > 0.f)) return float3(0.f);
    SceneRayQuery<true> query;
    return query.traceVisibilityRay(ls.visibilityRay) ? contribution : float3(0.f);
}

#if RTPT_REGIR_TRANSPORT
float3 rtptEstimateReGIRDirectSample(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg,
    out RTPTLightSample lightSample, out uint stableID, out float2 uv, out float estimatorWeight)
{
    if (!rtptReGIRSampleTransportLight(sd, sg, lightSample, stableID, uv, estimatorWeight)) return float3(0.f);
    const float3 value = mi.eval(sd, lightSample.dir, sg) * lightSample.LiOverPdf;
    if (!all(isfinite(value)) || !any(value > 0.f)) return float3(0.f);
    SceneRayQuery<true> query;
    return query.traceVisibilityRay(lightSample.visibilityRay) ? value : float3(0.f);
}

float3 rtptEstimateReGIRDirectSample(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg,
    out RTPTLightSample lightSample)
{
    uint unusedID;
    float2 unusedUV;
    float unusedWeight;
    return rtptEstimateReGIRDirectSample(sd, mi, sg, lightSample, unusedID, unusedUV, unusedWeight);
}

#endif
float3 rtptEstimateDirect(ShadingData sd, IMaterialInstance mi, RTPTSamplingContext sampling, inout SampleGenerator sg,
    bool hasBSDFCompetitor = true, bool training = false)
{
#if RTPT_REGIR_TRANSPORT
    const uint coverage = rtptReGIRTransportCoverage(training);
    if (coverage != 0u)
    {
        RTPTLightSample local;
        float3 contribution = rtptEstimateReGIRDirectSample(sd, mi, sg, local);
#if !RTPT_REGIR_ONLY
        // The remaining categories retain their actual BSDF/PG MIS density.
        RTPTLightSample remaining;
        if (rtptSampleLightForCoverage(sd, coverage, sg, remaining))
        {
            const float3 value = rtptEvaluateLightSample(sd, mi, sampling, remaining, sg, hasBSDFCompetitor);
            SceneRayQuery<true> query;
            if (all(isfinite(value)) && any(value > 0.f) && query.traceVisibilityRay(remaining.visibilityRay)) contribution += value;
        }
#endif
        return contribution;
    }
#endif
#if RTPT_REGIR_ONLY
    return float3(0.f);
#else
    RTPTLightSample ls;
    return rtptEstimateDirectSample(sd, mi, sampling, sg, ls, hasBSDFCompetitor);
#endif
}

// Sparse cache updates intentionally retain the original BSDF-only transport.
float3 rtptEstimateDirect(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg)
{
    return rtptEstimateDirect(sd, mi, rtptBSDFSamplingContext(), sg, true, true);
}

#if ENABLE_NRD
#if RTPT_REGIR_TRANSPORT
uint rtptReGIRRootCoverage()
{
    return gParams.useNEE != 0u && gReGIRSettings.active != 0u ? gReGIRSettings.coverageMask : 0u;
}

/** A freshly traced root can fail the primary-record bitwise ray guard. It
    still belongs to the cell-only local-light model: construct/query its cell
    and evaluate a counted world-space estimate, never the global light pool.
    Return coverage even for a legitimate zero/empty cell to retain ownership.
*/
uint rtptEstimateReGIRRootDirect(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg,
    out float3 diffuse, out float3 specular)
{
    diffuse = specular = float3(0.f);
    const uint coverage = rtptReGIRRootCoverage();
    if (coverage == 0u) return 0u;
    RTPTLightSample light;
    if (!rtptReGIRSampleTransportLight(sd, sg, light)) return coverage;
    SceneRayQuery<true> query;
    if (!query.traceVisibilityRay(light.visibilityRay)) return coverage;
    const uint lobes = mi.getLobeTypes(sd);
    if ((lobes & uint(LobeType::DiffuseReflection)) != 0u)
    {
        ShadingData component = sd;
        component.mtl.setActiveLobes(uint(LobeType::DiffuseReflection));
        diffuse = mi.eval(component, light.dir, sg) * light.LiOverPdf;
        if (!all(isfinite(diffuse))) diffuse = 0.f;
    }
    if ((lobes & uint(LobeType::SpecularReflection)) != 0u)
    {
        ShadingData component = sd;
        component.mtl.setActiveLobes(uint(LobeType::SpecularReflection));
        specular = mi.eval(component, light.dir, sg) * light.LiOverPdf;
        if (!all(isfinite(specular))) specular = 0.f;
    }
    return coverage;
}
#endif

/** Evaluate a previously sampled and visibility-tested light for one component.
    A diffuse continuation and a specular continuation are both generated, so
    each component competes with its own BSDF/guide continuation density.
*/
float3 rtptEvaluateDirectComponent(
    ShadingData sd, IMaterialInstance mi, RTPTLightSample ls, RTPTSamplingContext sampling, inout SampleGenerator sg)
{
    float misWeight = 1.f;
    if (!ls.analytic)
    {
        const float continuationPdf = rtptContinuationPdf(sd, mi, sampling, ls.dir);
        if (!isfinite(continuationPdf)) return float3(0.f);
        misWeight = rtptPowerHeuristic(ls.pdf, continuationPdf);
    }
    const float3 contribution = mi.eval(sd, ls.dir, sg) * ls.LiOverPdf * misWeight;
    return all(isfinite(contribution)) ? contribution : float3(0.f);
}
#endif
