#pragma once

#if ENABLE_PG
#include "RTPTPG.slang"
#endif

// This context is frozen for both NEE and the continuation at one vertex.
// Every PDF exposed here is measured per unit solid angle.
struct RTPTSamplingContext
{
    float alpha;
#if ENABLE_PG
    RTPTPGGuide guide;
#endif
};

RTPTSamplingContext rtptBSDFSamplingContext()
{
    RTPTSamplingContext result = {};
    return result;
}

#if ENABLE_PG
bool rtptIsGuideEligible(ShadingData sd, IMaterialInstance mi)
{
    const uint lobes = mi.getLobeTypes(sd) & sd.mtl.getActiveLobes();
    // Keep qualification per active BSDF component. A combined reflection
    // mask may contain delta lobes while an isolated component is continuous.
    return (lobes & uint(LobeType::NonDeltaReflection)) != 0 &&
        (lobes & ~uint(LobeType::NonDeltaReflection)) == 0;
}

RTPTSamplingContext rtptSamplingContextFromGuide(RTPTPGGuide guide)
{
    RTPTSamplingContext result = {};
    result.guide = guide;
    result.alpha = isfinite(guide.alpha) && guide.alpha > 0.f && guide.alpha < 1.f ? guide.alpha : 0.f;
    return result;
}
#endif

RTPTSamplingContext rtptMakeSamplingContext(ShadingData sd, IMaterialInstance mi)
{
    RTPTSamplingContext result = {};
#if ENABLE_PG
    // Delta-containing active BSDFs retain the original discrete lobe
    // selection probability and sample stream.
    if (rtptIsGuideEligible(sd, mi) && rtptPGGetGuide(sd, result.guide))
        return rtptSamplingContextFromGuide(result.guide);
#endif
    return result;
}

float rtptContinuationPdf(ShadingData sd, IMaterialInstance mi, RTPTSamplingContext context, float3 direction)
{
    const float bsdfPdf = mi.evalPdf(sd, direction);
#if ENABLE_PG
    if (context.alpha > 0.f)
        return (1.f - context.alpha) * bsdfPdf + context.alpha * rtptPGGuidePdf(context.guide, direction);
#endif
    return bsdfPdf;
}

bool rtptSampleContinuation(
    ShadingData sd,
    IMaterialInstance mi,
    RTPTSamplingContext context,
    inout SampleGenerator sg,
    out BSDFSample sample,
    out bool guideSelected
)
{
    sample = {};
    guideSelected = false;
#if ENABLE_PG
    if (context.alpha > 0.f)
    {
        guideSelected = sampleNext1D(sg) < context.alpha;
        if (guideSelected)
        {
            rtptPGCount(RTPT_PG_DIAG_GUIDED);
            // Sampling already visited this direction's leaf. Reuse its PDF;
            // the sampler retains the general evaluator on exceptional paths.
            float guidePdf;
            sample.wo = rtptPGSampleGuide(context.guide, sampleNext2D(sg), guidePdf);
            if (guidePdf < 0.f) guidePdf = rtptPGGuidePdf(context.guide, sample.wo);
            const float bsdfPdf = mi.evalPdf(sd, sample.wo);
            sample.pdf = (1.f - context.alpha) * bsdfPdf + context.alpha * guidePdf;
            if (!(sample.pdf > 0.f) || !isfinite(sample.pdf) || !all(isfinite(sample.wo))) return false;
            // StandardMaterial::eval() already includes the cosine. A guide
            // direction has no BSDF-selected lobe; callers retain its source.
            sample.weight = mi.eval(sd, sample.wo, sg) / sample.pdf;
            sample.lobeType = uint(LobeType::NonDeltaReflection);
            return all(isfinite(sample.weight));
        }
        if (!mi.sample(sd, sg, sample)) return false;
        const float bsdfPdf = sample.pdf;
        const float mixturePdf = rtptContinuationPdf(sd, mi, context, sample.wo);
        if (!(bsdfPdf > 0.f) || !isfinite(bsdfPdf) || !(mixturePdf > 0.f) || !isfinite(mixturePdf)) return false;
        // Preserve Falcor's selected-lobe estimator. Its sample weight need
        // not equal the full BSDF eval divided by its marginal direction PDF.
        sample.weight *= bsdfPdf / mixturePdf;
        sample.pdf = mixturePdf;
        return true;
    }
#endif
    // No valid guide means exactly the original BSDF RNG consumption.
    return mi.sample(sd, sg, sample);
}
