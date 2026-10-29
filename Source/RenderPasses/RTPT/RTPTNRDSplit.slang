#pragma once


// A writes the unchanged material guide normal and motion directly to their
// final textures. B only carries the FP32 signals it still reads or modifies.
struct RTPTNRDSplitSignals
{
    float3 diffuse;
    float3 specular;
    float3 emission;
    float3 diffuseReflectance;
    float3 specularReflectance;
    float3 residual;
    float diffuseHitDistance;
    float specularHitDistance;
    float viewZ;
};

// The producer and consumer share one fixed record per pixel. Keep the primary
// hit's existing packed bits and every intermediate radiance value at FP32.
// No ShadingData or interface-bearing material instance crosses the dispatch.
struct RTPTNRDSplitRecord
{
    uint4 packedHit;
    float3 rayDirection;
    uint lobes;
    uint pending;
    uint hasSurface;
    RTPTNRDSplitSignals signals;
    RTPTSharcStats stats;
};
RWStructuredBuffer<RTPTNRDSplitRecord> gNRDSplitRecords;

uint rtptNRDSplitIndex(uint2 pixel)
{
    return pixel.x + pixel.y * gParams.frameDim.x;
}

#if RTPT_NRD_SPLIT_STAGE == 1
void rtptNRDSplitStoreSignals(inout RTPTNRDSplitRecord record, uint2 pixel, RTPTNRDSignals signals)
{
    // Both valid surfaces and misses write these outputs exactly once. No B
    // stage reads them, so they need no cross-stage reconstruction or rounding.
    gNRDNormalRoughness[pixel] = signals.normalRoughness;
    gNRDMotionW[pixel] = float4(signals.motionW, 0.f);
    record.signals.diffuse = signals.diffuse;
    record.signals.specular = signals.specular;
    record.signals.emission = signals.emission;
    record.signals.diffuseReflectance = signals.diffuseReflectance;
    record.signals.specularReflectance = signals.specularReflectance;
    record.signals.residual = signals.residual;
    record.signals.diffuseHitDistance = signals.diffuseHitDistance;
    record.signals.specularHitDistance = signals.specularHitDistance;
    record.signals.viewZ = signals.viewZ;
}

RTPTNRDSplitRecord rtptVXPGTraceNRDSplitA(Ray ray, uint2 pixel, uint sampleIndex, inout RTPTSharcStats stats)
{
    RTPTNRDSplitRecord record = {};
    record.pending = 1u;
    record.rayDirection = ray.dir;
    RTPTNRDSignals signals = {};
    signals.diffuseReflectance = signals.specularReflectance = 1.f;
    signals.normalRoughness = float4(0.5f, 0.5f, 0.f, 0.f);
    signals.viewZ = 60000.f;
    SceneRayQuery<true> query;
    HitInfo hit;
#if RTPT_HAS_PRIMARY_HIT_INPUT
    if (!rtptLoadSharedPrimaryHit(pixel, sampleIndex, hit))
#endif
    {
        float t;
        rtptVXPGCountRadianceRay(stats);
        rtptVXPGCount(RTPT_VXPG_STATE_PRIMARY_RAYS);
        hit = query.traceRay(ray, t);
    }
#if HIT_INFO_USE_COMPRESSION
    record.packedHit = uint4(hit.pack(), 0u, 0u);
#else
    record.packedHit = hit.pack();
#endif
    ShadingData sd;
    uint materialID;
    if (!rtptVXPGPrepareHit(hit, ray, sd, materialID))
    {
#if USE_ENV_BACKGROUND
        if (!hit.isValid()) signals.emission = gScene.envMap.eval(ray.dir);
#endif
        rtptNRDSplitStoreSignals(record, pixel, signals);
        record.stats = stats;
        return record;
    }
    record.hasSurface = 1u;
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
    record.lobes = lobes;
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
    rtptNRDSplitStoreSignals(record, pixel, signals);
    record.stats = stats;
    return record;
}
#endif

#if RTPT_NRD_SPLIT_STAGE == 2
void rtptWriteNRDSplitLateSignals(uint2 pixel, RTPTNRDSignals signals)
{
    // Preserve the original FP32 operations and output order for every signal
    // still owned by B. A already wrote the normal and motion without packing
    // either one into this intermediate record.
    gNRDDiffuseRadianceHitDist[pixel] = float4(signals.diffuse / signals.diffuseReflectance, signals.diffuseHitDistance);
    gNRDSpecularRadianceHitDist[pixel] = float4(signals.specular / signals.specularReflectance, signals.specularHitDistance);
    gNRDEmission[pixel] = float4(signals.emission, 1.f);
    gNRDDiffuseReflectance[pixel] = float4(signals.diffuseReflectance, 1.f);
    gNRDSpecularReflectance[pixel] = float4(signals.specularReflectance, 1.f);
    gNRDResidualRadiance[pixel] = float4(signals.residual, 1.f);
    gNRDViewZ[pixel] = signals.viewZ;
}

float3 rtptVXPGTraceNRDSplitB(RTPTNRDSplitRecord record, uint2 pixel, uint sampleIndex, inout RTPTSharcStats stats)
{
    RTPTNRDSignals signals = {};
    signals.diffuse = record.signals.diffuse;
    signals.specular = record.signals.specular;
    signals.emission = record.signals.emission;
    signals.diffuseReflectance = record.signals.diffuseReflectance;
    signals.specularReflectance = record.signals.specularReflectance;
    signals.residual = record.signals.residual;
    signals.diffuseHitDistance = record.signals.diffuseHitDistance;
    signals.specularHitDistance = record.signals.specularHitDistance;
    signals.viewZ = record.signals.viewZ;
    if (record.hasSurface != 0u)
    {
#if HIT_INFO_USE_COMPRESSION
        const HitInfo hit = HitInfo(record.packedHit.xy);
#else
        const HitInfo hit = HitInfo(record.packedHit);
#endif
        // prepareHit uses the ray direction and the stored hit, never the ray
        // origin. Reconstruct the original material from those unchanged bits.
        const Ray ray = Ray(float3(0.f), record.rayDirection);
        ShadingData sd;
        uint materialID;
        rtptVXPGPrepareHit(hit, ray, sd, materialID);
        const uint lobes = record.lobes;
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
    }
    rtptWriteNRDSplitLateSignals(pixel, signals);
    return signals.emission + signals.diffuse + signals.specular + signals.residual;
}
#endif
