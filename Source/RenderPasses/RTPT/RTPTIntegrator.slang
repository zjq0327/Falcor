#pragma once
#include "RTPTCamera.slang"

Ray rtptGenerateCameraRay(uint2 pixel, inout SampleGenerator sg)
{
    return rtptCameraRay(pixel, gParams.frameDim, ENABLE_NRD != 0, sg);
}

float3 rtptTracePath(Ray ray, uint2 pixel, uint sampleIndex, inout SampleGenerator sg, inout RTPTSharcStats sharcStats)
{
    float3 radiance = 0.f;
    float3 throughput = 1.f;
    float3 previousPosition = 0.f;
    float3 previousNormal = 0.f;
    float previousContinuationPdf = 0.f;
    bool previousDelta = true;
    bool previousUsedNEE = false;
#if ENABLE_SHARC && SHARC_QUERY
    bool previousDiffuse = false;
    float previousRoughness = 0.f;
#endif
    SceneRayQuery<true> query;

    // bounce is the number of completed BSDF scatters. At maxBounces we
    // still evaluate the emitter reached by the last scatter, but do no NEE.
    // Both techniques therefore estimate exactly the same path lengths.
    for (uint bounce = 0; bounce <= gParams.maxBounces; ++bounce)
    {
        HitInfo hit;
#if RTPT_HAS_PRIMARY_HIT_INPUT
        bool sharedPrimaryHit = false;
        if (bounce == 0) sharedPrimaryHit = rtptLoadSharedPrimaryHit(pixel, sampleIndex, hit);
        if (!sharedPrimaryHit)
#endif
        {
            float hitT;
#if ENABLE_SHARC && SHARC_QUERY
            ++sharcStats.radianceRays;
#endif
            hit = query.traceRay(ray, hitT);
        }
        if (!hit.isValid())
        {
            bool evaluateEnvironment = false;
#if USE_ENV_BACKGROUND
            evaluateEnvironment = bounce == 0;
#endif
#if USE_ENV_LIGHT
            evaluateEnvironment = evaluateEnvironment || bounce > 0;
#endif
            if (evaluateEnvironment)
            {
                float misWeight = 1.f;
                if (previousUsedNEE && !previousDelta)
                    misWeight = rtptPowerHeuristic(previousContinuationPdf, rtptEnvironmentLightPdf(ray.dir));
                const float3 contribution = throughput * gScene.envMap.eval(ray.dir) * misWeight;
                if (all(isfinite(contribution))) radiance += contribution;
            }
            break;
        }

        // The first RTPT implementation supports triangle surfaces only.
        // Host-side checks reject unsupported geometry rather than hiding it.
        if (hit.getType() != HitType::Triangle) break;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const TriangleHit triangleHit = hit.getTriangleHit();
        const VertexData vertex = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -ray.dir);

        // No dielectric medium stack in this first version. Explicitly limit
        // the integrator to reflection rather than tracing incorrect refraction.
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        const BSDFProperties properties = mi.getProperties(sd);
#if ENABLE_SHARC && SHARC_QUERY
        if (bounce == 0) rtptCaptureSharcPrimary(sd, properties, sharcStats);
        float3 cachedRadiance;
        if (rtptTrySharcQuery(sd, mi, properties, bounce, previousDelta, previousDiffuse, previousRoughness,
            length(sd.posW - previousPosition), sharcStats, cachedRadiance))
        {
            const float3 contribution = throughput * cachedRadiance;
            if (all(isfinite(contribution))) radiance += contribution;
            break;
        }
#endif
        float3 emission = properties.emission;
        // Match sampleTriangle(): profile angle uses the outward geometric
        // normal and direction from emitter to receiver. StandardMaterial
        // already returns zero emission for back-facing hits.
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));

        // Primary emission stays visible even if emissive lighting is disabled.
        if ((bounce == 0 || USE_EMISSIVE_LIGHTS != 0) && any(emission > 0.f))
        {
            float misWeight = 1.f;
            if (previousUsedNEE && !previousDelta)
            {
                const float lightPdf = rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd);
                misWeight = rtptPowerHeuristic(previousContinuationPdf, lightPdf);
            }
            const float3 contribution = throughput * emission * misWeight;
            if (all(isfinite(contribution))) radiance += contribution;
        }

        if (bounce == gParams.maxBounces) break;
        const bool hasNonDeltaLobes = (mi.getLobeTypes(sd) & uint(LobeType::NonDeltaReflection)) != 0;
        previousUsedNEE = gParams.useNEE != 0 && hasNonDeltaLobes;
        if (previousUsedNEE)
        {
            const RTPTLightingContext lightContext = rtptSurfaceLightContext(sd, pixel, sampleIndex, bounce,
                bounce == 0 ? RTPT_LIGHT_QUERY_MAIN_PRIMARY : RTPT_LIGHT_QUERY_SECONDARY);
            const float3 contribution = throughput * rtptEstimateDirect(sd, mi, lightContext, sg);
            if (all(isfinite(contribution))) radiance += contribution;
        }

        BSDFSample bs = {};
        if (!mi.sample(sd, sg, bs)) break;
        if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) break;
        previousDelta = bs.isLobe(LobeType::Delta);
#if ENABLE_SHARC && SHARC_QUERY
        previousDiffuse = bs.isLobe(LobeType::DiffuseReflection);
        previousRoughness = properties.roughness;
#endif
        // A delta sample has a discrete probability; it does not compete in MIS.
        if (!previousDelta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))) break;
        throughput *= bs.weight; // Already f * cos / pdf; do not divide again.
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

    // Invalid input or arithmetic must not poison the persistent accumulation.
    // Finite samples, including fireflies, are never energy-clamped.
    return all(isfinite(radiance)) ? radiance : float3(0.f);
}
