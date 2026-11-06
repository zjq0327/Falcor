#pragma once

#include "RTPTGRISTypes.slang"

#if RTPT_GRIS_ALTERNATING
StructuredBuffer<GrisDualShadedIndirect> gGRISShadedIndirect;
#else
StructuredBuffer<GrisShadedIndirect> gGRISShadedIndirect;

GrisFirstHit rtptResolveGrisFirstHit(GrisShadedIndirect gris, uint rootLobe, ShadingData sd,
    IMaterialInstance mi, bool traceMissing, inout SampleGenerator rng)
{
    GrisFirstHit result = {};
    result.distanceState = kRTPTDistanceNotSelected;
    if (gris.state != uint(GrisRecordState::GrisUnprepared) && gris.rootLobe == rootLobe)
    {
        result = gris.firstHit;
        if (result.distanceState == kRTPTDistanceHit || result.distanceState == kRTPTDistanceMiss) return result;
    }
    if (!traceMissing) return result;

    // The caller has enabled only this lobe. Probe geometry independently of
    // the radiance sample, including valid rays with a black BSDF weight.
    // Retry rejected directions before issuing the single ray. RELAX 3.1
    // cannot reconstruct a missing specular distance on its own.
    for (uint attempt = 0; attempt < 4; ++attempt)
    {
        BSDFSample bs = {};
        if (!mi.sample(sd, rng, bs) || !(bs.pdf > 0.f) || !isfinite(bs.pdf) ||
            !all(isfinite(bs.wo)) || bs.isLobe(LobeType::Delta) || bs.isLobe(LobeType::Transmission))
            continue;

        SceneRayQuery<true> query;
        float hitT;
        const HitInfo hit = query.traceRay(Ray(sd.computeRayOrigin(), bs.wo), hitT);
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        if (hit.getType() == HitType::Triangle)
            hitT = length(gScene.getVertexData(hit.getTriangleHit()).posW - sd.posW);
#endif
        result.hitT = hit.isValid() ? min(kRTPTNRDMissDistance, max(1e-5f, hitT)) : kRTPTNRDMissDistance;
        result.distanceState = hit.isValid() ? kRTPTDistanceHit : kRTPTDistanceMiss;
        return result;
    }

    result.hitT = 0.f;
    result.distanceState = kRTPTDistanceSampleRejected;
    return result;
}
#endif
