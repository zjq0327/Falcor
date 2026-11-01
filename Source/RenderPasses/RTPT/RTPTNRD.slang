#pragma once

#include "Signal/RTPTSignalResolve.slang"

#ifndef RTPT_SEPARATE_SIGNAL_RESOLVE
#define RTPT_SEPARATE_SIGNAL_RESOLVE 0
#endif

#if RTPT_SEPARATE_SIGNAL_RESOLVE
RWStructuredBuffer<RTPTSignalRecord> gSignalRecords;

void rtptStoreSignalRecord(
    uint2 pixel,
    RTPTNRDSignals directAndGuides,
    float3 indirectDiffuse,
    float3 indirectSpecular,
    uint diffuseDistanceState,
    uint specularDistanceState
)
{
    RTPTSignalRecord record = {};
    record.directDiffuse = directAndGuides.diffuse;
    record.directSpecular = directAndGuides.specular;
    record.indirectDiffuse = indirectDiffuse;
    record.indirectSpecular = indirectSpecular;
    record.emission = directAndGuides.emission;
    record.residual = directAndGuides.residual;
    record.diffuseReflectance = directAndGuides.diffuseReflectance;
    record.specularReflectance = directAndGuides.specularReflectance;
    record.diffuseHitDistance = directAndGuides.diffuseHitDistance;
    record.specularHitDistance = directAndGuides.specularHitDistance;
    record.diffuseDistanceState = diffuseDistanceState;
    record.specularDistanceState = specularDistanceState;
    record.normalRoughness = directAndGuides.normalRoughness;
    record.viewZ = directAndGuides.viewZ;
    record.motionW = directAndGuides.motionW;
    gSignalRecords[pixel.y * gParams.frameDim.x + pixel.x] = record;
}
#endif

/** Establish domain ownership before sampling the original NEE/continuations.
    Prepared is independent of whether the final reservoir is empty, black or
    occluded. No brightness or winner-validity test may select the estimator.
*/
uint rtptLoadPrimaryDICoverage(uint2 pixel, uint sampleIndex, out float3 diffuse, out float3 specular)
{
    diffuse = specular = 0.f;
#if RTPT_USE_RESTIR_DI
    if (gParams.useNEE == 0u) return 0u;
    if (gDISettings.prepared == 0u) return 0u;
    if (any(gDISettings.frameDim != gParams.frameDim)) return 0u;
#if RTPT_USE_PRIMARY_SURFACE
    if (gDISettings.frameStamp != gPrimarySettings.frameStamp) return 0u;
#endif
    if (any(pixel >= gDISettings.frameDim)) return 0u;
    if (sampleIndex != gDISettings.sampleIndex) return 0u;
    uint count, stride;
    gDIResults.GetDimensions(count, stride);
    const uint index = pixel.y * gDISettings.frameDim.x + pixel.x;
    if (index >= count) return 0u;
    const RTPTDIResult result = gDIResults[index];
    if ((result.flags & kRTPTDIResultPrepared) == 0u) return 0u;
    if (result.generation != gDISettings.generation) return 0u;
    if (result.sampleIndex != sampleIndex) return 0u;
    if (result.frameStamp != gDISettings.frameStamp) return 0u;
    if (result.coverageMask != gDISettings.coverageMask) return 0u;
    diffuse = result.diffuse;
    specular = result.specular;
    return result.coverageMask;
#else
    return 0u;
#endif
}

/** NRD uses regular octahedral normals, not equal-area environment coordinates.
    Preserve the projected components before folding; avoid overlapping swizzles.
*/
float2 rtptNRDPackNormal(float3 normal)
{
    const float3 n = normal / max(1e-20f, abs(normal.x) + abs(normal.y) + abs(normal.z));
    const float x = n.z < 0.f ? (1.f - abs(n.y)) * (n.x >= 0.f ? 1.f : -1.f) : n.x;
    const float y = n.z < 0.f ? (1.f - abs(n.x)) * (n.y >= 0.f ? 1.f : -1.f) : n.y;
    return float2(x, y) * 0.5f + 0.5f;
}

/** Trace a component selected deterministically on the primary surface.
    The primary lobe-selection probability is one. Later vertices use the
    mixed reflection estimator, including optional guiding, NEE and symmetric MIS.
*/
float3 rtptTraceNRDContinuation(
    ShadingData primarySD,
    IMaterialInstance primaryMI,
    uint primaryLobes,
    RTPTSamplingContext primarySampling,
    inout SampleGenerator sg,
    out float firstHitDistance,
    out uint firstHitDistanceState,
    inout RTPTSharcStats sharcStats,
    uint rootCoverage
)
{
    firstHitDistance = kRTPTNRDMissDistance;
    firstHitDistanceState = kRTPTDistanceSampleRejected;
    primarySD.mtl.setActiveLobes(primaryLobes);
    BSDFSample bs = {};
    bool previousGuideSelected = false;
    if (!rtptSampleContinuation(primarySD, primaryMI, primarySampling, sg, bs, previousGuideSelected)) return float3(0.f);
    if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) return float3(0.f);

    bool previousDelta = bs.isLobe(LobeType::Delta);
    if (!previousDelta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))) return float3(0.f);
    float3 throughput = bs.weight;
    if (!any(throughput > 0.f)) return float3(0.f);
    float3 radiance = 0.f;
    float3 previousPosition = primarySD.posW;
    float3 previousNormal = primarySD.getOrientedFaceNormal();
    float previousContinuationPdf = bs.pdf;
    bool previousUsedNEE = gParams.useNEE != 0 && !previousDelta;
#if RTPT_REGIR_TRANSPORT
    uint previousReGIRCoverage = 0u;
#endif
#if ENABLE_SHARC && SHARC_QUERY
    bool previousDiffuse = !previousGuideSelected && bs.isLobe(LobeType::DiffuseReflection);
    float previousRoughness = primaryMI.getProperties(primarySD).roughness;
#endif
    Ray ray = Ray(primarySD.computeRayOrigin(), bs.wo);
    SceneRayQuery<true> query;
    firstHitDistanceState = kRTPTDistanceUntraced;

    // Always trace the first component ray before roulette so the distance is
    // available even when the radiance estimator later terminates.
    for (uint bounce = 1; bounce <= gParams.maxBounces; ++bounce)
    {
        float hitT;
#if ENABLE_SHARC && SHARC_QUERY
        ++sharcStats.radianceRays;
#endif
        const HitInfo hit = query.traceRay(ray, hitT);
        if (bounce == 1)
            firstHitDistanceState = hit.isValid() ? kRTPTDistanceHit : kRTPTDistanceMiss;
        if (bounce == 1 && hit.isValid())
            firstHitDistance = min(kRTPTNRDMissDistance, max(1e-5f, hitT));

        if (!hit.isValid())
        {
#if USE_ENV_LIGHT
#if RTPT_REGIR_TRANSPORT
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousContinuationPdf,
                    rtptEnvironmentLightPdfForCoverage(ray.dir, bounce == 1u ? rootCoverage : previousReGIRCoverage))
                : 1.f;
#elif RTPT_USE_RESTIR_DI
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousContinuationPdf,
                    bounce == 1u ? rtptEnvironmentLightPdfForCoverage(ray.dir, rootCoverage) : rtptEnvironmentLightPdf(ray.dir))
                : 1.f;
#else
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousContinuationPdf, rtptEnvironmentLightPdf(ray.dir))
                : 1.f;
#endif
            const float3 contribution = throughput * gScene.envMap.eval(ray.dir) * misWeight;
            if (all(isfinite(contribution))) radiance += contribution;
#endif
            break;
        }
        if (hit.getType() != HitType::Triangle) break;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const TriangleHit triangleHit = hit.getTriangleHit();
        const VertexData vertex = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        if (bounce == 1)
            firstHitDistance = min(kRTPTNRDMissDistance, max(1e-5f, length(sd.posW - primarySD.posW)));

#if ENABLE_SHARC && SHARC_QUERY
        const BSDFProperties sharcProperties = mi.getProperties(sd);
        float3 cachedRadiance;
        if (rtptTrySharcQuery(sd, mi, sharcProperties, bounce, previousDelta, previousGuideSelected, previousDiffuse, previousRoughness,
            length(sd.posW - previousPosition), sharcStats, cachedRadiance))
        {
            const float3 contribution = throughput * cachedRadiance;
            if (all(isfinite(contribution))) radiance += contribution;
            break;
        }
#endif

#if USE_EMISSIVE_LIGHTS
        float3 emission = mi.getProperties(sd).emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (any(emission > 0.f))
        {
#if RTPT_USE_RESTIR_DI || RTPT_REGIR_TRANSPORT
            bool coveredRootEvent = false;
#if RTPT_REGIR_TRANSPORT
            if (!previousDelta)
                coveredRootEvent = rtptDICoversEmissiveHit(triangleHit, bounce == 1u ? rootCoverage : previousReGIRCoverage);
#else
            if (bounce == 1u && !previousDelta)
                coveredRootEvent = rtptDICoversEmissiveHit(triangleHit, rootCoverage);
#endif
            if (!coveredRootEvent)
            {
                const float misWeight = previousUsedNEE && !previousDelta
                    ? rtptPowerHeuristic(previousContinuationPdf,
#if RTPT_REGIR_TRANSPORT
                        rtptEmissiveLightPdfForCoverage(previousPosition, previousNormal, triangleHit, sd,
                            bounce == 1u ? rootCoverage : previousReGIRCoverage))
#else
                        bounce == 1u ? rtptEmissiveLightPdfForCoverage(previousPosition, previousNormal, triangleHit, sd, rootCoverage)
                                     : rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd))
#endif
                    : 1.f;
                const float3 contribution = throughput * emission * misWeight;
                if (all(isfinite(contribution))) radiance += contribution;
            }
            // The covered emission is one event; the hit's reflected indirect
            // transport below remains eligible for NEE, guiding and SHaRC.
#else
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousContinuationPdf, rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd))
                : 1.f;
            const float3 contribution = throughput * emission * misWeight;
            if (all(isfinite(contribution))) radiance += contribution;
#endif
        }
#endif
        if (bounce == gParams.maxBounces) break;
        const RTPTSamplingContext sampling = rtptMakeSamplingContext(sd, mi);

        const bool hasNonDeltaLobes = (mi.getLobeTypes(sd) & uint(LobeType::NonDeltaReflection)) != 0;
        previousUsedNEE = gParams.useNEE != 0 && hasNonDeltaLobes;
#if RTPT_REGIR_TRANSPORT
        previousReGIRCoverage = previousUsedNEE ? rtptReGIRTransportCoverage(false) : 0u;
#endif
        if (previousUsedNEE)
        {
            const float3 contribution = throughput * rtptEstimateDirect(sd, mi, sampling, sg);
            if (all(isfinite(contribution))) radiance += contribution;
        }

        bs = {};
        if (!rtptSampleContinuation(sd, mi, sampling, sg, bs, previousGuideSelected)) break;
        if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) break;
        previousDelta = bs.isLobe(LobeType::Delta);
#if ENABLE_SHARC && SHARC_QUERY
        previousDiffuse = !previousGuideSelected && bs.isLobe(LobeType::DiffuseReflection);
        previousRoughness = sharcProperties.roughness;
#endif
        if (!previousDelta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))) break;
        throughput *= bs.weight;
        if (!all(isfinite(throughput)) || !any(throughput > 0.f)) break;
        if (gParams.useRussianRoulette != 0 && bounce + 1 >= gParams.rrStartBounce)
        {
            const float survival = min(0.95f, max(throughput.x, max(throughput.y, throughput.z)));
            if (sampleNext1D(sg) >= survival) break;
            throughput /= survival;
        }

        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        previousContinuationPdf = bs.pdf;
        ray = Ray(sd.computeRayOrigin(), bs.wo);
#else
        break;
#endif
    }
    return all(isfinite(radiance)) ? radiance : float3(0.f);
}

// Existing callers, including the delta residual, retain the complete old
// contribution domain. Only the root non-delta D/S calls pass DI ownership.
float3 rtptTraceNRDContinuation(
    ShadingData primarySD,
    IMaterialInstance primaryMI,
    uint primaryLobes,
    RTPTSamplingContext primarySampling,
    inout SampleGenerator sg,
    out float firstHitDistance,
    out uint firstHitDistanceState,
    inout RTPTSharcStats sharcStats
)
{
    return rtptTraceNRDContinuation(primarySD, primaryMI, primaryLobes, primarySampling, sg,
        firstHitDistance, firstHitDistanceState, sharcStats, 0u);
}

// Keep the original continuation interface for the inline fallback and delta
// residual. Its unobserved event-state output is removed by shader compilation.
float3 rtptTraceNRDContinuation(
    ShadingData primarySD,
    IMaterialInstance primaryMI,
    uint primaryLobes,
    RTPTSamplingContext primarySampling,
    inout SampleGenerator sg,
    out float firstHitDistance,
    inout RTPTSharcStats sharcStats
)
{
    uint unusedDistanceState;
    return rtptTraceNRDContinuation(primarySD, primaryMI, primaryLobes, primarySampling, sg,
        firstHitDistance, unusedDistanceState, sharcStats);
}

float3 rtptTraceNRD(Ray ray, uint2 pixel, uint sampleIndex, inout SampleGenerator sg, inout RTPTSharcStats sharcStats)
{
    RTPTNRDSignals signals = {};
    signals.diffuseReflectance = 1.f;
    signals.specularReflectance = 1.f;
    signals.normalRoughness = float4(0.5f, 0.5f, 0.f, 0.f);
    signals.viewZ = kRTPTNRDMissDistance;
#if RTPT_SEPARATE_SIGNAL_RESOLVE
    float3 indirectDiffuse = 0.f;
    float3 indirectSpecular = 0.f;
    uint diffuseDistanceState = kRTPTDistanceNoLobe;
    uint specularDistanceState = kRTPTDistanceNoLobe;
#endif

    SceneRayQuery<true> query;
    float hitT;
#if ENABLE_SHARC && SHARC_QUERY
    ++sharcStats.radianceRays;
#endif
#if RTPT_USE_PRIMARY_SURFACE
    RTPTPrimarySurface primarySurface;
    const bool primaryLoaded = rtptTryLoadPrimary(pixel, sampleIndex, ray, primarySurface);
    HitInfo hit;
    if (primaryLoaded)
    {
        hit = HitInfo(primarySurface.packedHit);
        hitT = primarySurface.hitT;
    }
    else
        hit = query.traceRay(ray, hitT);
#else
    const HitInfo hit = query.traceRay(ray, hitT);
#endif
    if (!hit.isValid())
    {
#if USE_ENV_BACKGROUND
        const float3 background = gScene.envMap.eval(ray.dir);
        signals.emission = all(isfinite(background)) ? background : float3(0.f);
#endif
#if RTPT_SEPARATE_SIGNAL_RESOLVE
        rtptStoreSignalRecord(pixel, signals, indirectDiffuse, indirectSpecular, diffuseDistanceState, specularDistanceState);
        return 0.f;
#else
        rtptWriteNRDSignals(pixel, signals);
        return signals.emission;
#endif
    }

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
#if ENABLE_SHARC && SHARC_QUERY
        rtptCaptureSharcPrimary(sd, properties, sharcStats);
#endif
        signals.emission = properties.emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            signals.emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (!all(isfinite(signals.emission))) signals.emission = 0.f;

        signals.diffuseReflectance = max(kNRDMinReflectance, properties.diffuseReflectionAlbedo);
        const float NdotV = saturate(dot(properties.guideNormal, sd.V));
        const float alpha = properties.roughness * properties.roughness;
        signals.specularReflectance = max(kNRDMinReflectance, approxSpecularIntegralGGX(properties.specularReflectionAlbedo, alpha, NdotV));
        // Reconstruct NRD guides from this same primary hit in the original
        // shading context. Reusing separately compiled fast-math guides can
        // change viewZ/motion by one ULP and perturb denoiser history.
        signals.normalRoughness = float4(rtptNRDPackNormal(properties.guideNormal), properties.roughness, 0.f);
        signals.viewZ = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1.f)).w;
        signals.motionW = gScene.getPrevPosW(triangleHit) - sd.posW;

        const uint lobes = mi.getLobeTypes(sd);
        const bool hasDiffuse = (lobes & uint(LobeType::DiffuseReflection)) != 0;
        const bool hasSpecular = (lobes & uint(LobeType::SpecularReflection)) != 0;
        const bool hasDeltaSpecular = (lobes & uint(LobeType::DeltaReflection)) != 0;
        ShadingData diffuseSD = sd;
        diffuseSD.mtl.setActiveLobes(uint(LobeType::DiffuseReflection));
        ShadingData specularSD = sd;
        specularSD.mtl.setActiveLobes(uint(LobeType::SpecularReflection));
        RTPTSamplingContext diffuseSampling = rtptBSDFSamplingContext();
        RTPTSamplingContext specularSampling = rtptBSDFSamplingContext();
        if (hasDiffuse) diffuseSampling = rtptMakeSamplingContext(diffuseSD, mi);
        if (hasSpecular) specularSampling = rtptMakeSamplingContext(specularSD, mi);

        uint rootCoverage = 0u;
#if RTPT_USE_RESTIR_DI && RTPT_USE_PRIMARY_SURFACE
        float3 diDiffuse = 0.f;
        float3 diSpecular = 0.f;
        if (primaryLoaded)
            rootCoverage = rtptLoadPrimaryDICoverage(pixel, sampleIndex, diDiffuse, diSpecular);
        if (rootCoverage != 0u)
        {
            signals.diffuse = diDiffuse;
            signals.specular = diSpecular;
        }
#endif

        RTPTLightSample ls;
#if RTPT_USE_RESTIR_DI
        if (rootCoverage != 0u)
        {
            if (gParams.useNEE != 0 && (hasDiffuse || hasSpecular) && rtptSampleLightForCoverage(sd, rootCoverage, sg, ls))
            {
                if (query.traceVisibilityRay(ls.visibilityRay))
                {
                    if (hasDiffuse) signals.diffuse += rtptEvaluateDirectComponent(diffuseSD, mi, ls, diffuseSampling, sg);
                    if (hasSpecular) signals.specular += rtptEvaluateDirectComponent(specularSD, mi, ls, specularSampling, sg);
                }
            }
        }
        else
#endif
        {
            if (gParams.useNEE != 0 && (hasDiffuse || hasSpecular) && rtptSampleLight(sd, sg, ls))
            {
                if (query.traceVisibilityRay(ls.visibilityRay))
                {
                    if (hasDiffuse) signals.diffuse = rtptEvaluateDirectComponent(diffuseSD, mi, ls, diffuseSampling, sg);
                    if (hasSpecular) signals.specular = rtptEvaluateDirectComponent(specularSD, mi, ls, specularSampling, sg);
                }
            }
        }
#if RTPT_SEPARATE_SIGNAL_RESOLVE
        if (hasDiffuse)
            indirectDiffuse = rtptTraceNRDContinuation(sd, mi, uint(LobeType::DiffuseReflection), diffuseSampling, sg,
                signals.diffuseHitDistance, diffuseDistanceState, sharcStats, rootCoverage);
        if (hasSpecular)
            indirectSpecular = rtptTraceNRDContinuation(sd, mi, uint(LobeType::SpecularReflection), specularSampling, sg,
                signals.specularHitDistance, specularDistanceState, sharcStats, rootCoverage);
#else
        uint unusedDiffuseState, unusedSpecularState;
        if (hasDiffuse)
            signals.diffuse += rtptTraceNRDContinuation(sd, mi, uint(LobeType::DiffuseReflection), diffuseSampling, sg,
                signals.diffuseHitDistance, unusedDiffuseState, sharcStats, rootCoverage);
        if (hasSpecular)
            signals.specular += rtptTraceNRDContinuation(sd, mi, uint(LobeType::SpecularReflection), specularSampling, sg,
                signals.specularHitDistance, unusedSpecularState, sharcStats, rootCoverage);
#endif
        if (hasDeltaSpecular)
        {
            float unusedDistance;
            signals.residual = rtptTraceNRDContinuation(sd, mi, uint(LobeType::DeltaReflection), rtptBSDFSamplingContext(), sg, unusedDistance, sharcStats);
        }
#if !RTPT_SEPARATE_SIGNAL_RESOLVE
        // NRD deliberately excludes surfaces outside its denoising range.
        // Preserve their energy through the unfiltered residual channel.
        if (signals.viewZ >= kNRDDepthRange)
        {
            signals.residual += signals.diffuse + signals.specular;
            signals.diffuse = 0.f;
            signals.specular = 0.f;
            signals.diffuseHitDistance = 0.f;
            signals.specularHitDistance = 0.f;
        }
#endif
    }
#endif

#if RTPT_SEPARATE_SIGNAL_RESOLVE
    rtptStoreSignalRecord(pixel, signals, indirectDiffuse, indirectSpecular, diffuseDistanceState, specularDistanceState);
    return 0.f;
#else
    rtptWriteNRDSignals(pixel, signals);
    return signals.emission + signals.diffuse + signals.specular + signals.residual;
#endif
}
