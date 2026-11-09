#pragma once

#ifndef RTPT_DELTA_NRD
#define RTPT_DELTA_NRD 0
#endif

// Invocation-local metadata only. No path/RNG/history is added to GRIS records.
struct RTPTDeltaGuide
{
    bool enabled;
    uint state; // 0=no lobe, 1=valid, 2=miss/rejected, 3=unsupported mirror/chain.
    float3 mirrorPosition;
    float3 mirrorNormal;
    float3 mirrorPreviousPosition;
    float3 normal;
    float roughness;
    float3 reflectance;
    float3 emission;
    float viewZ;
    float3 motion;
};

#if RTPT_DELTA_NRD && !RTPT_GRIS_GENERATE
import RenderPasses.Shared.Denoising.NRDHelpers;
import RenderPasses.Shared.Denoising.NRDConstants;

void rtptCaptureDeltaGuide(ShadingData sd, IMaterialInstance mi, BSDFProperties properties,
    TriangleHit hit, float3 throughput, inout RTPTDeltaGuide guide)
{
    // First version supports a stationary, flat reflector and a finite first
    // reflected surface. Unsupported cases keep their entire original residual.
    const uint lobes = mi.getLobeTypes(sd);
    if ((lobes & uint(LobeType::NonDeltaReflection)) == 0u)
    { guide.state = 3u; return; }
    const float3 n = guide.mirrorNormal;
    const float3 virtualPosition = sd.posW - 2.f * dot(sd.posW - guide.mirrorPosition, n) * n;
    const float3 previousPosition = gScene.getPrevPosW(hit);
    const float3 previousVirtual = previousPosition - 2.f * dot(previousPosition - guide.mirrorPreviousPosition, n) * n;
    const float4 clip = mul(gScene.camera.data.viewProjMatNoJitter, float4(virtualPosition, 1.f));
    if (!(clip.w > 0.f && clip.w < kNRDDepthRange) || !all(isfinite(previousVirtual)))
    { guide.state = 2u; return; }
    guide.viewZ = clip.w;
    guide.motion = previousVirtual - virtualPosition;
    guide.normal = reflect(properties.guideNormal, n);
    guide.roughness = properties.roughness;
    guide.reflectance = getMaterialReflectanceForDeltaPaths(sd.mtl.getMaterialType(),
        (lobes & uint(LobeType::Delta)) != 0u, sd, properties);
    float3 emission = 0.f;
#if USE_EMISSIVE_LIGHTS
    emission = properties.emission;
    const uint materialID = gScene.getMaterialID(hit.instanceID);
    if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
        emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
#endif
    guide.emission = throughput * emission;
    guide.state = all(isfinite(guide.reflectance)) && all(isfinite(guide.motion)) &&
        all(isfinite(guide.normal)) && all(isfinite(guide.emission)) ? 1u : 2u;
}
#endif
