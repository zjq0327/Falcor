#pragma once

// A finite miss distance that remains representable in NRD's fp16 resources.
static const float kRTPTNRDMissDistance = 60000.f;

struct RTPTNRDSignals
{
    float3 diffuse;
    float3 specular;
    float3 emission;
    float3 diffuseReflectance;
    float3 specularReflectance;
    float3 residual;
    float diffuseHitDistance;
    float specularHitDistance;
    float4 normalRoughness;
    float viewZ;
    float3 motionW;
};

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
    original mixed reflection estimator, including NEE and symmetric MIS.
*/
float3 rtptTraceNRDContinuation(
    ShadingData primarySD,
    IMaterialInstance primaryMI,
    uint primaryLobes,
    inout SampleGenerator sg,
    out float firstHitDistance
)
{
    firstHitDistance = kRTPTNRDMissDistance;
    primarySD.mtl.setActiveLobes(primaryLobes);
    BSDFSample bs = {};
    if (!primaryMI.sample(primarySD, sg, bs)) return float3(0.f);
    if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) return float3(0.f);

    bool previousDelta = bs.isLobe(LobeType::Delta);
    if (!previousDelta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))) return float3(0.f);
    float3 throughput = bs.weight;
    if (!any(throughput > 0.f)) return float3(0.f);
    float3 radiance = 0.f;
    float3 previousPosition = primarySD.posW;
    float3 previousNormal = primarySD.getOrientedFaceNormal();
    float previousBsdfPdf = bs.pdf;
    bool previousUsedNEE = gParams.useNEE != 0 && !previousDelta;
    Ray ray = Ray(primarySD.computeRayOrigin(), bs.wo);
    SceneRayQuery<true> query;

    // Always trace the first component ray before roulette so the distance is
    // available even when the radiance estimator later terminates.
    for (uint bounce = 1; bounce <= gParams.maxBounces; ++bounce)
    {
        float hitT;
        const HitInfo hit = query.traceRay(ray, hitT);
        if (bounce == 1 && hit.isValid())
            firstHitDistance = min(kRTPTNRDMissDistance, max(1e-5f, hitT));

        if (!hit.isValid())
        {
#if USE_ENV_LIGHT
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousBsdfPdf, rtptEnvironmentLightPdf(ray.dir))
                : 1.f;
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

#if USE_EMISSIVE_LIGHTS
        float3 emission = mi.getProperties(sd).emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (any(emission > 0.f))
        {
            const float misWeight = previousUsedNEE && !previousDelta
                ? rtptPowerHeuristic(previousBsdfPdf, rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd))
                : 1.f;
            const float3 contribution = throughput * emission * misWeight;
            if (all(isfinite(contribution))) radiance += contribution;
        }
#endif
        if (bounce == gParams.maxBounces) break;

        const bool hasNonDeltaLobes = (mi.getLobeTypes(sd) & uint(LobeType::NonDeltaReflection)) != 0;
        previousUsedNEE = gParams.useNEE != 0 && hasNonDeltaLobes;
        if (previousUsedNEE)
        {
            const float3 contribution = throughput * rtptEstimateDirect(sd, mi, sg);
            if (all(isfinite(contribution))) radiance += contribution;
        }

        bs = {};
        if (!mi.sample(sd, sg, bs)) break;
        if (bs.isLobe(LobeType::Transmission) || !all(isfinite(bs.wo)) || !all(isfinite(bs.weight))) break;
        previousDelta = bs.isLobe(LobeType::Delta);
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
        previousBsdfPdf = bs.pdf;
        ray = Ray(sd.computeRayOrigin(), bs.wo);
#else
        break;
#endif
    }
    return all(isfinite(radiance)) ? radiance : float3(0.f);
}

void rtptWriteNRDSignals(uint2 pixel, RTPTNRDSignals signals)
{
    gNRDDiffuseRadianceHitDist[pixel] = float4(signals.diffuse / signals.diffuseReflectance, signals.diffuseHitDistance);
    gNRDSpecularRadianceHitDist[pixel] = float4(signals.specular / signals.specularReflectance, signals.specularHitDistance);
    gNRDEmission[pixel] = float4(signals.emission, 1.f);
    gNRDDiffuseReflectance[pixel] = float4(signals.diffuseReflectance, 1.f);
    gNRDSpecularReflectance[pixel] = float4(signals.specularReflectance, 1.f);
    gNRDResidualRadiance[pixel] = float4(signals.residual, 1.f);
    gNRDNormalRoughness[pixel] = signals.normalRoughness;
    gNRDViewZ[pixel] = signals.viewZ;
    gNRDMotionW[pixel] = float4(signals.motionW, 0.f);
}

float3 rtptTraceNRD(Ray ray, uint2 pixel, inout SampleGenerator sg)
{
    RTPTNRDSignals signals = {};
    signals.diffuseReflectance = 1.f;
    signals.specularReflectance = 1.f;
    signals.normalRoughness = float4(0.5f, 0.5f, 0.f, 0.f);
    signals.viewZ = kRTPTNRDMissDistance;

    SceneRayQuery<true> query;
    float hitT;
    const HitInfo hit = query.traceRay(ray, hitT);
    if (!hit.isValid())
    {
#if USE_ENV_BACKGROUND
        const float3 background = gScene.envMap.eval(ray.dir);
        signals.emission = all(isfinite(background)) ? background : float3(0.f);
#endif
        rtptWriteNRDSignals(pixel, signals);
        return signals.emission;
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
        signals.emission = properties.emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            signals.emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (!all(isfinite(signals.emission))) signals.emission = 0.f;

        signals.diffuseReflectance = max(kNRDMinReflectance, properties.diffuseReflectionAlbedo);
        const float NdotV = saturate(dot(properties.guideNormal, sd.V));
        const float alpha = properties.roughness * properties.roughness;
        signals.specularReflectance = max(kNRDMinReflectance, approxSpecularIntegralGGX(properties.specularReflectionAlbedo, alpha, NdotV));
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

        RTPTLightSample ls;
        if (gParams.useNEE != 0 && (hasDiffuse || hasSpecular) && rtptSampleLight(sd, sg, ls))
        {
            if (query.traceVisibilityRay(ls.visibilityRay))
            {
                if (hasDiffuse) signals.diffuse = rtptEvaluateDirectComponent(diffuseSD, mi, ls, sg);
                if (hasSpecular) signals.specular = rtptEvaluateDirectComponent(specularSD, mi, ls, sg);
            }
        }
        if (hasDiffuse)
            signals.diffuse += rtptTraceNRDContinuation(sd, mi, uint(LobeType::DiffuseReflection), sg, signals.diffuseHitDistance);
        if (hasSpecular)
            signals.specular += rtptTraceNRDContinuation(sd, mi, uint(LobeType::SpecularReflection), sg, signals.specularHitDistance);
        if (hasDeltaSpecular)
        {
            float unusedDistance;
            signals.residual = rtptTraceNRDContinuation(sd, mi, uint(LobeType::DeltaReflection), sg, unusedDistance);
        }
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
    }
#endif

    rtptWriteNRDSignals(pixel, signals);
    return signals.emission + signals.diffuse + signals.specular + signals.residual;
}
