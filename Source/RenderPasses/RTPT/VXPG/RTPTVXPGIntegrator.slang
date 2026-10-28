#pragma once
#include "RTPTVXPGSampling.slang"

bool rtptVXPGRenderingActive()
{
    if (gVXPGParams.enabled == 0 || gVXPGParams.useGuiding == 0) return false;
    if (gVXPGState[RTPT_VXPG_STATE_READY] != gVXPGParams.generation) return false;
#if ENABLE_SHARC && SHARC_QUERY
#if !RTPT_SHARC_PAIR
    if (gSharcSettings.useCache != 0) return false;
#endif
#endif
    return true;
}

bool rtptVXPGPrepareHit(HitInfo hit, Ray ray, out ShadingData sd, out uint materialID)
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

bool rtptVXPGPrepareGuideHit(HitInfo hit, Ray ray, RTPTVXPGContext guide, RTPTVXPGCandidate candidate,
    out ShadingData sd, out uint materialID)
{
    sd = {};
    materialID = 0;
    if (!hit.isValid() || hit.getType() != HitType::Triangle) return false;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    const TriangleHit triangle = hit.getTriangleHit();
    const VertexData vertex = gScene.getVertexData(triangle);
    // prepareShadingData copies vertex.posW unchanged. Reject against that same
    // interpolated position before preparing material-dependent shading data.
    if (!rtptVXPGAccept(guide, candidate, vertex.posW)) return false;
    materialID = gScene.getMaterialID(triangle.instanceID);
    sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);
    sd.mtl.setActiveLobes(uint(LobeType::Reflection));
    return true;
#else
    return false;
#endif
}

float3 rtptVXPGEmission(ShadingData sd, IMaterialInstance mi, uint materialID)
{
    float3 emission = mi.getProperties(sd).emission;
    if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
        emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
    return all(isfinite(emission)) ? emission : float3(0.f);
}

uint rtptVXPGActiveLobes(ShadingData sd, IMaterialInstance mi)
{
    return mi.getLobeTypes(sd) & sd.mtl.getActiveLobes() & uint(LobeType::Reflection);
}

uint rtptVXPGSelectComponent(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg, out float invRho)
{
    const uint lobes = rtptVXPGActiveLobes(sd, mi);
    const uint count = countbits(lobes);
    invRho = float(count);
    if (count == 0) return 0;
    uint selected = min(uint(sampleNext1D(sg) * count), count - 1);
    const uint masks[3] = {uint(LobeType::DiffuseReflection), uint(LobeType::SpecularReflection), uint(LobeType::DeltaReflection)};
    for (uint i = 0; i < 3; ++i)
    {
        if ((lobes & masks[i]) == 0) continue;
        if (selected == 0) return masks[i];
        --selected;
    }
    return 0;
}

// ShortBranch shares the SHaRC training partition for NEE/emission MIS.
// The separate BRDF/guide partition compensates continuation sampling below.
float3 rtptVXPGDirectFromSample(ShadingData sd, IMaterialInstance mi,
    RTPTLightSample light, inout SampleGenerator sg, out float3 raw)
{
    float weight = 1.f;
    float continuationPdf = 0.f;
    if (!light.analytic)
    {
        continuationPdf = mi.evalPdf(sd, light.dir);
        weight = rtptPowerHeuristic(light.misReferencePdf, continuationPdf);
    }
    raw = mi.eval(sd, light.dir, sg) * light.LiOverPdf;
    const float3 value = raw * weight;
    // Keep the original evaluation/RNG and radiance behavior, but reject an
    // invalid BSDF density from the independent feedback stream.
    if (!isfinite(continuationPdf)) raw = float3(continuationPdf);
    return all(isfinite(value)) ? value : float3(0.f);
}

float3 rtptVXPGDirect(ShadingData sd, IMaterialInstance mi, RTPTLightingContext context,
    inout SampleGenerator sg, bool shortBranch = false)
{
    if (gParams.useNEE == 0 || (rtptVXPGActiveLobes(sd, mi) & uint(LobeType::NonDeltaReflection)) == 0) return 0.f;
    RTPTLightSample light;
    if (!rtptSampleLight(sd, context, sg, light))
    {
        rtptLocalRecordFeedback(context, light, float3(0.f), false);
        return 0.f;
    }
    SceneRayQuery<true> query;
    rtptVXPGCount(shortBranch?RTPT_VXPG_STATE_PG_SHADOW:RTPT_VXPG_STATE_MAIN_SHADOW);
    const bool visible = query.traceVisibilityRay(light.visibilityRay);
    float3 raw = 0.f, value = 0.f;
    if (visible) value = rtptVXPGDirectFromSample(sd, mi, light, sg, raw);
    if (all(isfinite(raw))) rtptLocalRecordFeedback(context, light, raw, visible, true);
    return value;
}

void rtptVXPGCountRadianceRay(inout RTPTSharcStats stats)
{
#if ENABLE_SHARC && SHARC_QUERY
    ++stats.radianceRays;
#endif
}

float3 rtptVXPGShortBranch(ShadingData source, IMaterialInstance sourceMI, ShadingData component,
    RTPTVXPGContext guide, uint2 pixel, uint sampleIndex, uint bounce, float invRho,
    inout SampleGenerator sg, inout RTPTSharcStats stats)
{
    rtptVXPGCount(RTPT_VXPG_STATE_ATTEMPTS);
    rtptVXPGCount(RTPT_VXPG_STATE_PRIMARY_ATTEMPTS + bounce);
    RTPTVXPGCandidate candidate;
    const float4 u = float4(sampleNext2D(sg), sampleNext2D(sg));
    if (!rtptVXPGSample(guide, u, candidate))
    {
        rtptVXPGCount(RTPT_VXPG_STATE_REJECTED);
        return 0.f;
    }
    SceneRayQuery<true> query;
    float t;
    const Ray ray = Ray(guide.origin, candidate.direction);
    rtptVXPGCount(RTPT_VXPG_STATE_GUIDE_RAYS);
    rtptVXPGCountRadianceRay(stats);
    const HitInfo hit = query.traceRay(ray, t);
    ShadingData sd;
    uint materialID;
    if (!rtptVXPGPrepareGuideHit(hit, ray, guide, candidate, sd, materialID))
    {
        rtptVXPGCount(RTPT_VXPG_STATE_REJECTED);
        return 0.f;
    }
    rtptVXPGCount(RTPT_VXPG_STATE_ACCEPTED);
    const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    const float p = sourceMI.evalPdf(component, candidate.direction);
#if ENABLE_SHARC && SHARC_QUERY && RTPT_SHARC_PAIR
    const BSDFProperties sourceProperties = sourceMI.getProperties(source);
    const BSDFProperties hitProperties = mi.getProperties(sd);
    if (rtptSharcPairEligible(sd, mi, hitProperties, bounce+1, false, true, gVXPGParams.pgUseCache != 0,
        component.mtl.getActiveLobes() == uint(LobeType::DiffuseReflection), sourceProperties.roughness, length(sd.posW-source.posW)))
    {
        ++stats.attemptedQueries;
        float3 cachedLocal, cachedSuffix;
        if (rtptSharcReadPair(rtptMakeSharcHit(sd, hitProperties, float3(0.f)), cachedLocal, cachedSuffix))
        {
            ++stats.cacheTerminations;
            rtptVXPGCount(RTPT_VXPG_STATE_PG_CACHE_HITS);
            const RTPTVXPGMISWeights cachedWeights = rtptVXPGWeights(p, candidate.pdf, true);
            return sourceMI.eval(component, candidate.direction, sg) * invRho * (cachedLocal+cachedSuffix) *
                (cachedWeights.guideLocal/candidate.pdf);
        }
    }
#endif
    const RTPTVXPGMISWeights weights = rtptVXPGWeights(p, candidate.pdf, false);
    float3 local = 0.f;
#if USE_EMISSIVE_LIGHTS
    float emissionWeight = 1.f;
    if (gParams.useNEE != 0)
    {
        const float reference = sourceMI.evalPdf(source, candidate.direction);
        emissionWeight = rtptPowerHeuristic(reference, rtptEmissiveLightPdf(source.posW, source.getOrientedFaceNormal(), hit.getTriangleHit(), sd));
    }
    local = rtptVXPGEmission(sd, mi, materialID) * emissionWeight;
#endif
    if (bounce + 1 < gParams.maxBounces)
    {
        const RTPTLightingContext lightContext = rtptSurfaceLightContext(
            sd, pixel, sampleIndex, bounce + 1u, RTPT_LIGHT_QUERY_SECONDARY);
        local += rtptVXPGDirect(sd, mi, lightContext, sg, true);
    }
    return sourceMI.eval(component, candidate.direction, sg) * invRho * local * (weights.guideLocal / candidate.pdf);
}

// Starts at an already intersected primary surface. Only the main continuation
// enters the loop; A's guide branch is a nonrecursive local-light query.
float3 rtptVXPGTraceSurface(ShadingData primary, uint primaryMaterialID, uint primaryLobes,
    uint2 pixel, uint sampleIndex, uint channel, bool primaryEmission, bool primaryNEEDone,
    out float firstDistance, inout RTPTSharcStats stats)
{
    float3 radiance = 0.f, throughput = 1.f;
    float localWeight = 1.f, suffixWeight = 1.f, arrivalWeight = 1.f;
    firstDistance = 60000.f;
    ShadingData sd = primary;
    uint materialID = primaryMaterialID;
    SceneRayQuery<true> query;
    for (uint bounce = 0; bounce <= gParams.maxBounces; ++bounce)
    {
        sd.mtl.setActiveLobes(bounce == 0 ? primaryLobes : uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        const BSDFProperties properties = mi.getProperties(sd);
        SampleGenerator componentSG = SampleGenerator(pixel ^ uint2(channel * 0x9e3779b9u, bounce * 0x85ebca6bu), sampleIndex + 0x101u);
        SampleGenerator brdfSG = SampleGenerator(pixel ^ uint2(channel * 0xc2b2ae35u, bounce * 0x27d4eb2fu), sampleIndex + 0x211u);
        SampleGenerator guideSG = SampleGenerator(pixel ^ uint2(channel * 0x165667b1u, bounce * 0xd3a2646cu), sampleIndex + 0x307u);
        SampleGenerator lightSG = SampleGenerator(pixel ^ uint2(channel * 0xfd7046c5u, bounce * 0xb55a4f09u), sampleIndex + 0x409u);
        if ((bounce == 0 && primaryEmission) || (bounce > 0 && USE_EMISSIVE_LIGHTS != 0))
            radiance += throughput * localWeight * rtptVXPGEmission(sd, mi, materialID) * arrivalWeight;
        if (bounce == gParams.maxBounces) break;
        RTPTVXPGContext guide;
        const bool hasGuide = rtptVXPGGetSurfaceContext(sd.computeRayOrigin(), sd.posW, sd.getOrientedFaceNormal(), pixel, sampleIndex, bounce, guide);
        const bool usedNEE = gParams.useNEE != 0 && (rtptVXPGActiveLobes(sd, mi) & uint(LobeType::NonDeltaReflection)) != 0;
        const RTPTLightingContext lightContext = rtptSurfaceLightContext(sd, pixel, sampleIndex, bounce,
            bounce == 0 ? RTPT_LIGHT_QUERY_MAIN_PRIMARY : RTPT_LIGHT_QUERY_SECONDARY);
        if (!(bounce == 0 && primaryNEEDone))
            radiance += throughput * localWeight * rtptVXPGDirect(sd, mi, lightContext, lightSG);
        const float3 continuationThroughput = throughput * suffixWeight;
        float invRho;
        const uint lobe = rtptVXPGSelectComponent(sd, mi, componentSG, invRho);
        if (lobe == 0) break;
        ShadingData component = sd;
        component.mtl.setActiveLobes(lobe);
        const bool continuous = (lobe & uint(LobeType::NonDeltaReflection)) != 0;
        const bool eligible = hasGuide && continuous;
        // The A branch executes independently of BRDF sample validity/cache.
        if (eligible)
            radiance += continuationThroughput * rtptVXPGShortBranch(sd, mi, component, guide, pixel, sampleIndex, bounce, invRho, guideSG, stats);
        BSDFSample bs = {};
        if (!mi.sample(component, brdfSG, bs) || bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) break;
        const float p = bs.pdf;
        float3 factor = bs.weight * invRho;
        if (continuous) factor *= p;
        const bool delta = !continuous;
        const Ray ray = Ray(sd.computeRayOrigin(), bs.wo);
        rtptVXPGCount(RTPT_VXPG_STATE_BRDF_RAYS);
        float t;
        rtptVXPGCountRadianceRay(stats);
        const HitInfo hit = query.traceRay(ray, t);
        ShadingData next;
        uint nextMaterialID;
        const bool nextValid = rtptVXPGPrepareHit(hit, ray, next, nextMaterialID);
        if (bounce == 0)
            firstDistance = nextValid ? min(60000.f, max(1.e-5f, length(next.posW - sd.posW))) : 60000.f;
        const float q = eligible && nextValid ? rtptVXPGHitPdf(guide, next.posW) : 0.f;
        bool guideCacheAtBRDF = false;
        bool brdfCache = false;
        float3 cachedLocal = 0.f, cachedSuffix = 0.f;
#if ENABLE_SHARC && SHARC_QUERY && RTPT_SHARC_PAIR
        if (nextValid)
        {
            const IMaterialInstance nextMI = gScene.materials.getMaterialInstance(next, ExplicitLodTextureSampler(0.f));
            const BSDFProperties nextProperties = nextMI.getProperties(next);
            const float segment = length(next.posW-sd.posW);
            const bool diffuse = lobe == uint(LobeType::DiffuseReflection);
            const SharcHitData cacheHit = rtptMakeSharcHit(next, nextProperties, float3(0.f));
            if (gVXPGParams.pgUseCache != 0 && q > 0.f && rtptSharcPairEligible(next, nextMI, nextProperties,
                bounce+1, delta, true, true, diffuse, properties.roughness, segment))
            {
                rtptVXPGCount(RTPT_VXPG_STATE_PG_CACHE_CHECKS);
                guideCacheAtBRDF = rtptSharcReadPair(cacheHit, cachedLocal, cachedSuffix);
            }
            if (rtptSharcPairEligible(next, nextMI, nextProperties, bounce+1, delta, false, false, diffuse, properties.roughness, segment))
            {
                ++stats.attemptedQueries;
                brdfCache = guideCacheAtBRDF || rtptSharcReadPair(cacheHit, cachedLocal, cachedSuffix);
            }
        }
#endif
        localWeight = suffixWeight = 1.f;
        if (!delta)
        {
            const float denominator = p;
            if (!(denominator > 0.f) || !isfinite(denominator)) break;
            factor /= denominator;
            if (eligible)
            {
                const RTPTVXPGMISWeights weights = rtptVXPGWeights(p, q, guideCacheAtBRDF);
                localWeight = weights.brdfLocal;
                suffixWeight = weights.brdfSuffix;
            }
        }
        throughput = continuationThroughput * factor;
        if (!all(isfinite(throughput)) || !any(throughput > 0.f)) break;
#if ENABLE_SHARC && SHARC_QUERY && RTPT_SHARC_PAIR
        if (brdfCache)
        {
            rtptVXPGCount(RTPT_VXPG_STATE_BRDF_CACHE_HITS);
            radiance += throughput * (localWeight*cachedLocal + suffixWeight*cachedSuffix);
            ++stats.cacheTerminations;
            break;
        }
#endif
        const float referencePdf = delta ? 0.f : mi.evalPdf(sd, ray.dir);
        if (!hit.isValid())
        {
#if USE_ENV_LIGHT
            const float weight = usedNEE && !delta ? rtptPowerHeuristic(referencePdf, rtptEnvironmentLightPdf(ray.dir)) : 1.f;
            radiance += throughput * localWeight * gScene.envMap.eval(ray.dir) * weight;
#endif
            break;
        }
        if (!nextValid) break;
        arrivalWeight = 1.f;
        if (usedNEE && !delta)
            arrivalWeight = rtptPowerHeuristic(referencePdf, rtptEmissiveLightPdf(sd.posW, sd.getOrientedFaceNormal(), hit.getTriangleHit(), next));
        if (gParams.useRussianRoulette != 0 && bounce+1 >= gParams.rrStartBounce)
        {
            const float survival = min(0.95f, max(throughput.x, max(throughput.y, throughput.z)));
            if (sampleNext1D(brdfSG) >= survival) break;
            throughput /= survival;
        }
        sd = next;
        materialID = nextMaterialID;
    }
    if (!all(isfinite(radiance)))
    {
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INVALID], 1u);
        return 0.f;
    }
    return radiance;
}

float3 rtptVXPGTracePath(Ray ray, uint2 pixel, uint sampleIndex, inout RTPTSharcStats stats)
{
    SceneRayQuery<true> query;
    float t;
    rtptVXPGCountRadianceRay(stats);
    const HitInfo hit = query.traceRay(ray, t);
    rtptVXPGCount(RTPT_VXPG_STATE_PRIMARY_RAYS);
    ShadingData sd;
    uint materialID;
    if (!rtptVXPGPrepareHit(hit, ray, sd, materialID))
    {
#if USE_ENV_BACKGROUND
        return !hit.isValid() ? gScene.envMap.eval(ray.dir) : float3(0.f);
#else
        return 0.f;
#endif
    }
#if ENABLE_SHARC && SHARC_QUERY
    const IMaterialInstance primaryMI = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    rtptCaptureSharcPrimary(sd, primaryMI.getProperties(sd), stats);
#endif
    float unusedDistance;
    return rtptVXPGTraceSurface(sd, materialID, uint(LobeType::Reflection), pixel, sampleIndex, 0, true, false, unusedDistance, stats);
}

#if ENABLE_NRD
float3 rtptVXPGTraceNRD(Ray ray, uint2 pixel, uint sampleIndex, inout RTPTSharcStats stats)
{
    RTPTNRDSignals signals = {};
    signals.diffuseReflectance = signals.specularReflectance = 1.f;
    signals.normalRoughness = float4(0.5f, 0.5f, 0.f, 0.f);
    signals.viewZ = 60000.f;
    SceneRayQuery<true> query;
    float t;
    rtptVXPGCountRadianceRay(stats);
    rtptVXPGCount(RTPT_VXPG_STATE_PRIMARY_RAYS);
    const HitInfo hit = query.traceRay(ray, t);
    ShadingData sd;
    uint materialID;
    if (!rtptVXPGPrepareHit(hit, ray, sd, materialID))
    {
#if USE_ENV_BACKGROUND
        if (!hit.isValid()) signals.emission = gScene.envMap.eval(ray.dir);
#endif
        rtptWriteNRDSignals(pixel, signals);
        return signals.emission;
    }
    const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    const BSDFProperties properties = mi.getProperties(sd);
#if ENABLE_SHARC && SHARC_QUERY
    rtptCaptureSharcPrimary(sd, properties, stats);
#endif
    signals.emission = rtptVXPGEmission(sd, mi, materialID);
    signals.diffuseReflectance = max(kNRDMinReflectance, properties.diffuseReflectionAlbedo);
    const float NdotV = saturate(dot(properties.guideNormal, sd.V));
    const float alpha = properties.roughness * properties.roughness;
    signals.specularReflectance = max(kNRDMinReflectance, approxSpecularIntegralGGX(properties.specularReflectionAlbedo, alpha, NdotV));
    signals.normalRoughness = float4(rtptNRDPackNormal(properties.guideNormal), properties.roughness, 0.f);
    signals.viewZ = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1.f)).w;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    signals.motionW = gScene.getPrevPosW(hit.getTriangleHit()) - sd.posW;
#endif
    const uint lobes = rtptVXPGActiveLobes(sd, mi);
    ShadingData diffuse = sd, specular = sd;
    diffuse.mtl.setActiveLobes(uint(LobeType::DiffuseReflection));
    specular.mtl.setActiveLobes(uint(LobeType::SpecularReflection));
    SampleGenerator lightSG = SampleGenerator(pixel ^ uint2(0x68bc21ebu, 0x02e5be93u), sampleIndex + 0x601u);
    RTPTLightSample light;
    const RTPTLightingContext lightContext = rtptSurfaceLightContext(
        sd, pixel, sampleIndex, 0u, RTPT_LIGHT_QUERY_MAIN_PRIMARY);
    if (gParams.useNEE != 0 && (lobes & uint(LobeType::NonDeltaReflection)) != 0)
    {
        const bool sampled = rtptSampleLight(sd, lightContext, lightSG, light);
        bool visible = false;
        float3 rawDiffuse = 0.f, rawSpecular = 0.f;
        if (sampled)
        {
            rtptVXPGCount(RTPT_VXPG_STATE_MAIN_SHADOW);
            visible = query.traceVisibilityRay(light.visibilityRay);
            if (visible)
            {
                if ((lobes & uint(LobeType::DiffuseReflection)) != 0)
                    signals.diffuse = rtptVXPGDirectFromSample(diffuse, mi, light, lightSG, rawDiffuse);
                if ((lobes & uint(LobeType::SpecularReflection)) != 0)
                    signals.specular = rtptVXPGDirectFromSample(specular, mi, light, lightSG, rawSpecular);
            }
        }
        const float3 raw = rawDiffuse + rawSpecular;
        if (all(isfinite(raw))) rtptLocalRecordFeedback(lightContext, light, raw, visible, sampled);
    }
    if ((lobes & uint(LobeType::DiffuseReflection)) != 0)
        signals.diffuse += rtptVXPGTraceSurface(sd, materialID, uint(LobeType::DiffuseReflection), pixel, sampleIndex, 1, false, true, signals.diffuseHitDistance, stats);
    if ((lobes & uint(LobeType::SpecularReflection)) != 0)
        signals.specular += rtptVXPGTraceSurface(sd, materialID, uint(LobeType::SpecularReflection), pixel, sampleIndex, 2, false, true, signals.specularHitDistance, stats);
    if ((lobes & uint(LobeType::DeltaReflection)) != 0)
    {
        float unused;
        signals.residual = rtptVXPGTraceSurface(sd, materialID, uint(LobeType::DeltaReflection), pixel, sampleIndex, 3, false, true, unused, stats);
    }
    if (signals.viewZ >= kNRDDepthRange)
    {
        signals.residual += signals.diffuse + signals.specular;
        signals.diffuse = signals.specular = 0.f;
        signals.diffuseHitDistance = signals.specularHitDistance = 0.f;
    }
    rtptWriteNRDSignals(pixel, signals);
    return signals.emission + signals.diffuse + signals.specular + signals.residual;
}
#endif
