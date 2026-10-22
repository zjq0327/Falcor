#pragma once
#include "RTPTVXPGSampling.slang"

bool rtptVXPGRenderingActive()
{
    if (gVXPGParams.enabled == 0 || gVXPGParams.useGuiding == 0) return false;
    if (gVXPGState[RTPT_VXPG_STATE_READY] != gVXPGParams.generation) return false;
#if ENABLE_SHARC && SHARC_QUERY
#if !RTPT_SHARC_PAIR
    if (gVXPGParams.estimator == 0 && gSharcSettings.useCache != 0) return false;
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

// Marginal direction PDF of the explicit component baseline. Discrete lobes
// retain their selection mass but add no density to the continuous measure.
float rtptVXPGReferencePdf(ShadingData sd, IMaterialInstance mi, RTPTVXPGContext guide, bool useGuide,
    float3 direction, float3 targetPosition, bool finiteTarget, bool mixture)
{
    // A shares the existing SHaRC training partition, even though its explicit
    // component proposal is uniform. Pointwise complementary light weights
    // remain valid; the continuation PDF compensation is handled separately.
    if (!mixture) return mi.evalPdf(sd, direction);
    const uint lobes = rtptVXPGActiveLobes(sd, mi);
    const uint count = countbits(lobes);
    if (count == 0) return 0.f;
    const float q = useGuide && finiteTarget ? rtptVXPGHitPdf(guide, targetPosition) : 0.f;
    const uint masks[2] = {uint(LobeType::DiffuseReflection), uint(LobeType::SpecularReflection)};
    float sum = 0.f;
    for (uint i = 0; i < 2; ++i)
    {
        if ((lobes & masks[i]) == 0) continue;
        ShadingData component = sd;
        component.mtl.setActiveLobes(masks[i]);
        const float p = mi.evalPdf(component, direction);
        const float alpha = mixture && useGuide ? gVXPGParams.guideFraction : 0.f;
        sum += rtptVXPGMixturePdf(p, q, alpha);
    }
    return sum / float(count);
}

float3 rtptVXPGDirectFromSample(ShadingData sd, IMaterialInstance mi, RTPTVXPGContext guide, bool hasGuide,
    RTPTLightSample light, bool mixture, inout SampleGenerator sg)
{
    float weight = 1.f;
    if (!light.analytic)
    {
        const float p = rtptVXPGReferencePdf(sd, mi, guide, hasGuide, light.dir, light.targetPosition, light.finiteTarget, mixture);
        weight = rtptPowerHeuristic(light.pdf, p);
    }
    const float3 value = mi.eval(sd, light.dir, sg) * light.LiOverPdf * weight;
    return all(isfinite(value)) ? value : float3(0.f);
}

float3 rtptVXPGDirect(ShadingData sd, IMaterialInstance mi, RTPTVXPGContext guide, bool hasGuide,
    bool mixture, inout SampleGenerator sg, bool shortBranch = false)
{
    if (gParams.useNEE == 0 || (rtptVXPGActiveLobes(sd, mi) & uint(LobeType::NonDeltaReflection)) == 0) return 0.f;
    RTPTLightSample light;
    if (!rtptSampleLight(sd, sg, light)) return 0.f;
    SceneRayQuery<true> query;
    InterlockedAdd(gVXPGState[shortBranch?RTPT_VXPG_STATE_PG_SHADOW:RTPT_VXPG_STATE_MAIN_SHADOW],1u);
    return query.traceVisibilityRay(light.visibilityRay) ? rtptVXPGDirectFromSample(sd, mi, guide, hasGuide, light, mixture, sg) : float3(0.f);
}

void rtptVXPGCountRadianceRay(inout RTPTSharcStats stats)
{
#if ENABLE_SHARC && SHARC_QUERY
    ++stats.radianceRays;
#endif
}

float rtptVXPGDistanceOnly(ShadingData sd, IMaterialInstance mi, inout SampleGenerator sg)
{
    BSDFSample bs = {};
    if (!mi.sample(sd, sg, bs) || !all(isfinite(bs.wo))) return 60000.f;
    SceneRayQuery<true> query;
    float t;
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_DISTANCE_RAYS], 1u);
    const HitInfo hit = query.traceRay(Ray(sd.computeRayOrigin(), bs.wo), t);
    if (!hit.isValid()) return 60000.f;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
        return min(60000.f, max(1.e-5f, length(gScene.getVertexData(hit.getTriangleHit()).posW - sd.posW)));
#endif
    return min(60000.f, max(1.e-5f, t));
}

float3 rtptVXPGShortBranch(ShadingData source, IMaterialInstance sourceMI, ShadingData component,
    RTPTVXPGContext guide, uint bounce, float invRho, inout SampleGenerator sg, inout RTPTSharcStats stats)
{
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_ATTEMPTS], 1u);
    InterlockedAdd(gVXPGState[14u + bounce], 1u);
    RTPTVXPGCandidate candidate;
    const float4 u = float4(sampleNext2D(sg), sampleNext2D(sg));
    if (!rtptVXPGSample(guide, u, candidate))
    {
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_REJECTED], 1u);
        return 0.f;
    }
    SceneRayQuery<true> query;
    float t;
    const Ray ray = Ray(guide.origin, candidate.direction);
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_GUIDE_RAYS],1u);
    rtptVXPGCountRadianceRay(stats);
    const HitInfo hit = query.traceRay(ray, t);
    ShadingData sd;
    uint materialID;
    if (!rtptVXPGPrepareHit(hit, ray, sd, materialID) || !rtptVXPGAccept(guide, candidate, sd.posW))
    {
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_REJECTED], 1u);
        return 0.f;
    }
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_ACCEPTED], 1u);
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
            InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_PG_CACHE_HITS], 1u);
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
        const float reference = rtptVXPGReferencePdf(source, sourceMI, guide, true, candidate.direction, sd.posW, true, false);
        emissionWeight = rtptPowerHeuristic(reference, rtptEmissiveLightPdf(source.posW, source.getOrientedFaceNormal(), hit.getTriangleHit(), sd));
    }
    local = rtptVXPGEmission(sd, mi, materialID) * emissionWeight;
#endif
    if (bounce + 1 < gParams.maxBounces)
    {
        RTPTVXPGContext unused = {};
        local += rtptVXPGDirect(sd, mi, unused, false, false, sg, true);
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
    const bool mixture = gVXPGParams.estimator == 1;
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
        if (!(bounce == 0 && primaryNEEDone))
            radiance += throughput * localWeight * rtptVXPGDirect(sd, mi, guide, hasGuide, mixture, lightSG);
        const float3 continuationThroughput = throughput * suffixWeight;
        float invRho;
        const uint lobe = rtptVXPGSelectComponent(sd, mi, componentSG, invRho);
        if (lobe == 0) break;
        ShadingData component = sd;
        component.mtl.setActiveLobes(lobe);
        const bool continuous = (lobe & uint(LobeType::NonDeltaReflection)) != 0;
        const bool eligible = hasGuide && continuous;
        // The A branch executes independently of BRDF sample validity/cache.
        if (!mixture && eligible)
            radiance += continuationThroughput * rtptVXPGShortBranch(sd, mi, component, guide, bounce, invRho, guideSG, stats);
        const float alpha = mixture && eligible ? gVXPGParams.guideFraction : 0.f;
        const bool guideSelected = alpha > 0.f && sampleNext1D(componentSG) < alpha;
#if ENABLE_NRD
        if (bounce == 0 && guideSelected)
        {
            SampleGenerator distanceSG = SampleGenerator(pixel ^ uint2(channel * 0x7feb352du, 0x846ca68bu), sampleIndex + 0x50bu);
            firstDistance = rtptVXPGDistanceOnly(component, mi, distanceSG);
        }
#endif
        BSDFSample bs = {};
        RTPTVXPGCandidate candidate = {};
        float p = 0.f;
        float3 factor = 0.f;
        if (guideSelected)
        {
            InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_ATTEMPTS], 1u);
            InterlockedAdd(gVXPGState[14u + bounce], 1u);
            if (!rtptVXPGSample(guide, float4(sampleNext2D(guideSG), sampleNext2D(guideSG)), candidate))
            { InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_REJECTED], 1u); break; }
            bs.wo = candidate.direction;
            p = mi.evalPdf(component, bs.wo);
            factor = mi.eval(component, bs.wo, guideSG) * invRho;
        }
        else
        {
            if (!mi.sample(component, brdfSG, bs) || bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) break;
            p = bs.pdf;
            factor = bs.weight * invRho;
            if (continuous) factor *= p;
        }
        const bool delta = !continuous;
        const Ray ray = Ray(sd.computeRayOrigin(), bs.wo);
        InterlockedAdd(gVXPGState[guideSelected?RTPT_VXPG_STATE_GUIDE_RAYS:RTPT_VXPG_STATE_BRDF_RAYS],1u);
        float t;
        rtptVXPGCountRadianceRay(stats);
        const HitInfo hit = query.traceRay(ray, t);
        ShadingData next;
        uint nextMaterialID;
        const bool nextValid = rtptVXPGPrepareHit(hit, ray, next, nextMaterialID);
        if (bounce == 0 && !guideSelected)
            firstDistance = nextValid ? min(60000.f, max(1.e-5f, length(next.posW - sd.posW))) : 60000.f;
        if (guideSelected && (!nextValid || !rtptVXPGAccept(guide, candidate, next.posW)))
        { InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_REJECTED], 1u); break; }
        if (guideSelected) InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_ACCEPTED], 1u);
        const float q = eligible && nextValid ? rtptVXPGHitPdf(guide, next.posW) : 0.f;
        bool guideCacheAtBRDF = false;
        bool brdfCache = false;
        float3 cachedLocal = 0.f, cachedSuffix = 0.f;
#if ENABLE_SHARC && SHARC_QUERY && RTPT_SHARC_PAIR
        if (!mixture && nextValid)
        {
            const IMaterialInstance nextMI = gScene.materials.getMaterialInstance(next, ExplicitLodTextureSampler(0.f));
            const BSDFProperties nextProperties = nextMI.getProperties(next);
            const float segment = length(next.posW-sd.posW);
            const bool diffuse = lobe == uint(LobeType::DiffuseReflection);
            const SharcHitData cacheHit = rtptMakeSharcHit(next, nextProperties, float3(0.f));
            if (gVXPGParams.pgUseCache != 0 && q > 0.f && rtptSharcPairEligible(next, nextMI, nextProperties,
                bounce+1, delta, true, true, diffuse, properties.roughness, segment))
            {
                InterlockedAdd(gVXPGState[13], 1u);
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
            const float denominator = mixture ? rtptVXPGMixturePdf(p, q, alpha) : p;
            if (!(denominator > 0.f) || !isfinite(denominator)) break;
            factor /= denominator;
            if (!mixture && eligible)
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
            InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_BRDF_CACHE_HITS],1u);
            radiance += throughput * (localWeight*cachedLocal + suffixWeight*cachedSuffix);
            ++stats.cacheTerminations;
            break;
        }
#endif
        const float referencePdf = delta ? 0.f : rtptVXPGReferencePdf(sd, mi, guide, hasGuide, ray.dir,
            nextValid ? next.posW : float3(0.f), nextValid, mixture);
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
#if ENABLE_SHARC && SHARC_QUERY
        if (mixture && !guideSelected)
        {
            const IMaterialInstance nextMI = gScene.materials.getMaterialInstance(next, ExplicitLodTextureSampler(0.f));
            float3 cached;
            if (rtptTrySharcQuery(next, nextMI, nextMI.getProperties(next), bounce+1, delta, false,
                lobe == uint(LobeType::DiffuseReflection), properties.roughness, length(next.posW - sd.posW), stats, cached))
            {
                radiance += throughput * cached;
                InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_BRDF_CACHE_HITS],1u);
                break;
            }
        }
#endif
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
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_PRIMARY_RAYS],1u);
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
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_PRIMARY_RAYS],1u);
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
    RTPTVXPGContext guide;
    const bool hasGuide = rtptVXPGGetSurfaceContext(sd.computeRayOrigin(), sd.posW, sd.getOrientedFaceNormal(), pixel, sampleIndex, 0, guide);
    const bool mixture = gVXPGParams.estimator == 1;
    SampleGenerator lightSG = SampleGenerator(pixel ^ uint2(0x68bc21ebu, 0x02e5be93u), sampleIndex + 0x601u);
    RTPTLightSample light;
    if (gParams.useNEE != 0 && (lobes & uint(LobeType::NonDeltaReflection)) != 0 && rtptSampleLight(sd, lightSG, light))
    {
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_MAIN_SHADOW],1u);
        if (query.traceVisibilityRay(light.visibilityRay))
        {
            if ((lobes & uint(LobeType::DiffuseReflection)) != 0)
                signals.diffuse = rtptVXPGDirectFromSample(diffuse, mi, guide, hasGuide, light, mixture, lightSG);
            if ((lobes & uint(LobeType::SpecularReflection)) != 0)
                signals.specular = rtptVXPGDirectFromSample(specular, mi, guide, hasGuide, light, mixture, lightSG);
        }
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
