#pragma once

Ray rtptGenerateCameraRay(uint2 pixel, inout SampleGenerator sg)
{
#if ENABLE_NRD
    // Radiance, first-hit guides and NRD reprojection share camera jitter.
    return gScene.camera.computeRayPinhole(pixel, gParams.frameDim);
#else
    // Own subpixel jitter so accumulating a stationary camera remains valid.
    // External camera jitter is deliberately ignored; this version is pinhole.
    const float2 p = (float2(pixel) + sampleNext2D(sg)) / float2(gParams.frameDim);
    const float2 ndc = p * float2(2.f, -2.f) + float2(-1.f, 1.f);
    let camera = gScene.camera.data;
    const float3 direction = normalize(ndc.x * camera.cameraU + ndc.y * camera.cameraV + camera.cameraW);
    const float inverseCosine = 1.f / dot(normalize(camera.cameraW), direction);
    return Ray(camera.posW, direction, camera.nearZ * inverseCosine, camera.farZ * inverseCosine);
#endif
}

float3 rtptTracePath(Ray ray, inout SampleGenerator sg)
{
    float3 radiance = 0.f;
    float3 throughput = 1.f;
    float3 previousPosition = 0.f;
    float3 previousNormal = 0.f;
    float previousBsdfPdf = 0.f;
    bool previousDelta = true;
    bool previousUsedNEE = false;
    SceneRayQuery<true> query;

    // bounce is the number of completed BSDF scatters. At maxBounces we
    // still evaluate the emitter reached by the last scatter, but do no NEE.
    // Both techniques therefore estimate exactly the same path lengths.
    for (uint bounce = 0; bounce <= gParams.maxBounces; ++bounce)
    {
        float hitT;
        const HitInfo hit = query.traceRay(ray, hitT);
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
                    misWeight = rtptPowerHeuristic(previousBsdfPdf, rtptEnvironmentLightPdf(ray.dir));
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
                misWeight = rtptPowerHeuristic(previousBsdfPdf, lightPdf);
            }
            const float3 contribution = throughput * emission * misWeight;
            if (all(isfinite(contribution))) radiance += contribution;
        }

        if (bounce == gParams.maxBounces) break;
        const bool hasNonDeltaLobes = (mi.getLobeTypes(sd) & uint(LobeType::NonDeltaReflection)) != 0;
        previousUsedNEE = gParams.useNEE != 0 && hasNonDeltaLobes;
        if (previousUsedNEE)
        {
            const float3 contribution = throughput * rtptEstimateDirect(sd, mi, sg);
            if (all(isfinite(contribution))) radiance += contribution;
        }

        BSDFSample bs = {};
        if (!mi.sample(sd, sg, bs)) break;
        if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) break;
        previousDelta = bs.isLobe(LobeType::Delta);
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
        previousBsdfPdf = bs.pdf;
        ray = Ray(sd.computeRayOrigin(), bs.wo);
#else
        break;
#endif
    }

    // Invalid input or arithmetic must not poison the persistent accumulation.
    // Finite samples, including fireflies, are never energy-clamped.
    return all(isfinite(radiance)) ? radiance : float3(0.f);
}
