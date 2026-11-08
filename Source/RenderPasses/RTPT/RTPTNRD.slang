#pragma once

#include "DirectLighting/RTPTDICoverage.slang"
#include "RTPTContinuation.slang"
#include "Signal/RTPTSignalResolve.slang"

#if RTPT_USE_GRIS
#include "GRIS/RTPTGRISIndirect.slang"
#endif

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

float3 rtptTraceNRD(uint2 pixel, uint sampleIndex, inout SampleGenerator sg, inout RTPTSharcStats sharcStats)
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
    HitInfo hit;
    float3 rayDirection;
#if ENABLE_SHARC && SHARC_QUERY
    ++sharcStats.radianceRays;
#endif
#if RTPT_USE_PRIMARY_SURFACE
    RTPTPrimarySurface primarySurface;
    const bool primaryLoaded = rtptTryLoadPrimary(pixel, sampleIndex, primarySurface);
    if (primaryLoaded)
    {
        hit = HitInfo(primarySurface.packedHit);
        rayDirection = primarySurface.rayDirection;
    }
    else
#endif
    {
        const Ray ray = rtptGenerateCameraRay(pixel, sg);
        float hitT;
        hit = query.traceRay(ray, hitT);
        rayDirection = ray.dir;
    }
    if (!hit.isValid())
    {
#if USE_ENV_BACKGROUND
        const float3 background = gScene.envMap.eval(rayDirection);
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
        ShadingData sd = gScene.materials.prepareShadingData(vertex, materialID, -rayDirection);
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
        // Keep primary specular NEE and continuation on the BSDF-only density.

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

#if RTPT_REGIR_TRANSPORT
        // A rejected/missing primary record requires a fresh traced surface,
        // not a global-light proposal. ReGIR retains the same local domain.
        if (rootCoverage == 0u && gParams.useNEE != 0u && (hasDiffuse || hasSpecular))
            rootCoverage = rtptEstimateReGIRRootDirect(sd, mi, sg, signals.diffuse, signals.specular);
#endif

#if !RTPT_REGIR_ONLY
        RTPTLightSample ls;
#if RTPT_USE_RESTIR_DI || RTPT_REGIR_TRANSPORT
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
#endif
#if RTPT_SEPARATE_SIGNAL_RESOLVE
#if RTPT_USE_GRIS && RTPT_GRIS_ALTERNATING
        GrisDualShadedIndirect gris = {};
        if (primaryLoaded) gris = gGRISShadedIndirect[pixel.y * gParams.frameDim.x + pixel.x];
        const bool grisDiffusePrepared = (gris.preparedMask & 1u) != 0u;
        const bool grisSpecularPrepared = (gris.preparedMask & 2u) != 0u;
        if (grisDiffusePrepared)
        {
            indirectDiffuse = gris.radiance[0];
            signals.diffuseHitDistance = gris.firstHit[0].hitT;
            diffuseDistanceState = gris.firstHit[0].distanceState;
        }
        if (grisSpecularPrepared)
        {
            indirectSpecular = gris.radiance[1];
            signals.specularHitDistance = gris.firstHit[1].hitT;
            specularDistanceState = gris.firstHit[1].distanceState;
        }
        if (hasDiffuse && !grisDiffusePrepared)
            indirectDiffuse = rtptTraceContinuation(sd, mi, uint(LobeType::DiffuseReflection), diffuseSampling, sg,
                signals.diffuseHitDistance, diffuseDistanceState, sharcStats, rootCoverage);
        if (hasSpecular && !grisSpecularPrepared)
            indirectSpecular = rtptTraceContinuation(sd, mi, uint(LobeType::SpecularReflection), specularSampling, sg,
                signals.specularHitDistance, specularDistanceState, sharcStats, rootCoverage);
#else
#if RTPT_USE_GRIS
        bool grisPrepared = false;
        if (primaryLoaded)
        {
            const GrisShadedIndirect gris = gGRISShadedIndirect[pixel.y * gParams.frameDim.x + pixel.x];
            grisPrepared = gris.state != uint(GrisRecordState::GrisUnprepared);
            if (grisPrepared)
            {
                if (gris.rootLobe == uint(GrisRootComponent::GrisDiffuse)) indirectDiffuse = gris.radiance;
                if (gris.rootLobe == uint(GrisRootComponent::GrisSpecular)) indirectSpecular = gris.radiance;
                indirectDiffuse += gris.localDiffuse;
                indirectSpecular += gris.localSpecular;

                // Keep distance-only probes out of the transport random stream.
                SampleGenerator distanceRng = SampleGenerator(pixel, sampleIndex ^ 0xe3723fd1u);
                const bool traceMissing = signals.viewZ < kNRDDepthRange;
                if (hasDiffuse)
                {
                    const GrisFirstHit firstHit = rtptResolveGrisFirstHit(gris, uint(GrisRootComponent::GrisDiffuse),
                        diffuseSD, mi, traceMissing, distanceRng);
                    signals.diffuseHitDistance = firstHit.hitT;
                    diffuseDistanceState = firstHit.distanceState;
                }
                if (hasSpecular)
                {
                    const GrisFirstHit firstHit = rtptResolveGrisFirstHit(gris, uint(GrisRootComponent::GrisSpecular),
                        specularSD, mi, traceMissing, distanceRng);
                    signals.specularHitDistance = firstHit.hitT;
                    specularDistanceState = firstHit.distanceState;
                }
            }
        }
        if (!grisPrepared)
        {
#endif
            if (hasDiffuse)
                indirectDiffuse = rtptTraceContinuation(sd, mi, uint(LobeType::DiffuseReflection), diffuseSampling, sg,
                    signals.diffuseHitDistance, diffuseDistanceState, sharcStats, rootCoverage);
            if (hasSpecular)
                indirectSpecular = rtptTraceContinuation(sd, mi, uint(LobeType::SpecularReflection), specularSampling, sg,
                    signals.specularHitDistance, specularDistanceState, sharcStats, rootCoverage);
#if RTPT_USE_GRIS
        }
#endif
#endif
#else
        uint unusedDiffuseState, unusedSpecularState;
        if (hasDiffuse)
            signals.diffuse += rtptTraceContinuation(sd, mi, uint(LobeType::DiffuseReflection), diffuseSampling, sg,
                signals.diffuseHitDistance, unusedDiffuseState, sharcStats, rootCoverage);
        if (hasSpecular)
            signals.specular += rtptTraceContinuation(sd, mi, uint(LobeType::SpecularReflection), specularSampling, sg,
                signals.specularHitDistance, unusedSpecularState, sharcStats, rootCoverage);
#endif
        if (hasDeltaSpecular)
        {
            float unusedDistance;
            signals.residual = rtptTraceContinuation(sd, mi, uint(LobeType::DeltaReflection), rtptBSDFSamplingContext(), sg, unusedDistance, sharcStats);
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
