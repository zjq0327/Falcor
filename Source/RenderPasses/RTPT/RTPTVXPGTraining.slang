#pragma once
#include "RTPTVXPGTypes.slang"

float3 rtptVXPGTrainingEmission(ShadingData sd, BSDFProperties properties, uint materialID)
{
    float3 emission = properties.emission;
    if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
        emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
    return emission;
}

// Same light sample, material evaluation and visibility query for both targets.
// withMIS=true preserves the original sparse path's RNG and NEE arithmetic.
// Additional terminal observations use a COPY of its RNG, never the path stream.
float3 rtptVXPGTrainingDirect(ShadingData sd, IMaterialInstance mi, bool withMIS,
    inout SampleGenerator sg, out float3 raw, out bool valid)
{
    raw = 0.f;
    valid = true;
    RTPTLightSample ls;
    if (!rtptSampleLight(sd, sg, ls)) return 0.f;
    float misWeight = 1.f;
    if (withMIS && !ls.analytic)
    {
        const float continuationPdf = rtptContinuationPdf(sd, mi, rtptBSDFSamplingContext(), ls.dir);
        if (!isfinite(continuationPdf)) { valid = false; return 0.f; }
        misWeight = rtptPowerHeuristic(ls.pdf, continuationPdf);
    }
    raw = mi.eval(sd, ls.dir, sg) * ls.LiOverPdf;
    const float3 contribution = raw * misWeight;
    valid = all(isfinite(raw));
    const bool sharcNeedsVisibility = all(isfinite(contribution)) && any(contribution > 0.f);
    // Preserve the SHaRC zero/invalid return, but allow a positive raw observation
    // even when its MIS-weighted value underflows. That extra query consumes no RNG.
    if (!sharcNeedsVisibility && (!valid || !any(raw > 0.f))) { raw = 0.f; return 0.f; }
    SceneRayQuery<true> query;
    rtptVXPGCount(RTPT_VXPG_STATE_INJECT_SHADOW);
    const bool visible = query.traceVisibilityRay(ls.visibilityRay);
    if (!visible || !valid) raw = 0.f;
    return visible && sharcNeedsVisibility ? contribution : float3(0.f);
}

void rtptVXPGStoreObservation(ShadingData sd, float3 local)
{
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) return;
    const uint cell = rtptVXPGOwner(sd.posW);
    if (cell == RTPT_VXPG_INVALID || gVXPGBoundMin[cell].w == 0) return;
    if (!all(isfinite(local)))
    {
        InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_INVALID], 1u);
        return;
    }
    InterlockedOr(gVXPGBoundMax[cell].w, 1u);
    // Reference uses maxComponent of positive direct-light observations and
    // their per-voxel average. This is proposal importance, not irradiance.
    const float importance = max(local.x, max(local.y, local.z));
    if (!(importance > 0.f)) return;
    // Bounding model statistics does not clamp final transport radiance.
    const uint64_t fixed = uint64_t(max(1.f, round(min(importance, 1.e6f) * 4096.f)));
    uint64_t previousFlux;
    InterlockedAdd(gVXPGFlux[cell], fixed, previousFlux);
    if (previousFlux > uint64_t(0xffffffffffffffffull) - fixed)
        InterlockedOr(gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW],1u);
    uint old;
    InterlockedAdd(gVXPGCount[cell], 1u, old);
    if (old==0xffffffffu) InterlockedOr(gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW],1u);
    if (old == 0)
    {
        gVXPGRepresentativePosition[cell] = float4(sd.posW, 1.f);
        gVXPGRepresentativeNormal[cell] = float4(sd.getOrientedFaceNormal(), 0.f);
    }
    rtptVXPGCount(RTPT_VXPG_STATE_INJECTED);
}
