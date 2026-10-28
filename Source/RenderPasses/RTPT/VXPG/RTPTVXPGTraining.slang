#pragma once
#include "RTPTVXPGObservation.slang"

// Shared-path training entry: observation writes only; model publication is a build step.

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
float3 rtptVXPGTrainingDirect(ShadingData sd, IMaterialInstance mi, RTPTLightingContext context, bool withMIS,
    inout SampleGenerator sg, out float3 raw, out bool valid)
{
    raw = 0.f;
    valid = true;
    RTPTLightSample ls;
    if (!rtptSampleLight(sd, context, sg, ls))
    {
        rtptLocalRecordFeedback(context, ls, float3(0.f), false);
        return 0.f;
    }
    float misWeight = 1.f;
    if (withMIS && !ls.analytic)
    {
        const float continuationPdf = mi.evalPdf(sd, ls.dir);
        if (!isfinite(continuationPdf)) { valid = false; return 0.f; }
        misWeight = rtptPowerHeuristic(ls.misReferencePdf, continuationPdf);
    }
    raw = mi.eval(sd, ls.dir, sg) * ls.LiOverPdf;
    const float3 contribution = raw * misWeight;
    valid = all(isfinite(raw));
    const bool sharcNeedsVisibility = all(isfinite(contribution)) && any(contribution > 0.f);
    // Preserve the SHaRC zero/invalid return, but allow a positive raw observation
    // even when its MIS-weighted value underflows. That extra query consumes no RNG.
    if (!sharcNeedsVisibility && (!valid || !any(raw > 0.f)))
    {
        if (valid) rtptLocalRecordFeedback(context, ls, float3(0.f), false);
        raw = 0.f;
        return 0.f;
    }
    SceneRayQuery<true> query;
    rtptVXPGCount(RTPT_VXPG_STATE_INJECT_SHADOW);
    const bool visible = query.traceVisibilityRay(ls.visibilityRay);
    if (!visible || !valid) raw = 0.f;
    if (valid) rtptLocalRecordFeedback(context, ls, raw, visible, true);
    return visible && sharcNeedsVisibility ? contribution : float3(0.f);
}

void rtptVXPGStoreCellObservation(uint cell, ShadingData sd, float3 local)
{
    rtptVXPGStoreRawCellObservation(cell,sd.posW,sd.getOrientedFaceNormal(),local);
}

void rtptVXPGStoreObservation(ShadingData sd, float3 local, uint2 pixel, uint bounce)
{
    const uint cell=rtptVXPGOwner(sd.posW);
    rtptVXPGRecordDiscovery(pixel,cell,sd.posW,sd.getOrientedFaceNormal(),local,bounce);
    rtptVXPGStoreCellObservation(cell,sd,local);
}
