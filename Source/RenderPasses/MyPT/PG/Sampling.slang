#ifndef MYPT_PG_SAMPLING_SLANG
#define MYPT_PG_SAMPLING_SLANG

#include "Params.slang"

bool pgSupportsMaterial(const ShadingData sd, const IMaterialInstance mi)
{
    // Restrict version one to the verified deterministic Standard BSDF.
    // Coated/layered/hair/measured and transmitting/delta mixtures still render
    // normally, but must not be mixed with this continuous directional density.
    if (gScene.materials.getMaterialType(sd.materialID) != MaterialType::Standard) return false;
    uint lobes = mi.getLobeTypes(sd);
    if ((lobes & uint(LobeType::Transmission)) != 0u) return false;
    if ((lobes & uint(LobeType::Delta)) != 0u) return false;
    return (lobes & uint(LobeType::NonDeltaReflection)) != 0u;
}

float pgEffectiveFraction(const ShadingData sd, const IMaterialInstance mi)
{
    if (gPGUseGuiding == 0u || gPGGuideFraction <= 0.f) return 0.f;
    if (!pgSupportsMaterial(sd, mi)) return 0.f;
    if (!pgHasGuide(sd.posW)) return 0.f;
    // Host validates [0, 1), retaining the BSDF support component.
    return gPGGuideFraction;
}

float evalPGScatterPdf(const ShadingData sd, const IMaterialInstance mi, float3 direction, bool importance)
{
    float bsdfPdf = evalMyPTBSDFPdf(sd, mi, direction, importance);
    float fraction = pgEffectiveFraction(sd, mi);
    if (fraction <= 0.f) return bsdfPdf;
    return (1.f - fraction) * bsdfPdf + fraction * pgGuidePdf(sd.posW, direction);
}

bool samplePGScatter(const ShadingData sd, const IMaterialInstance mi,
    inout SampleGenerator sg, out BSDFSample result, bool importance, bool recordDiagnostics)
{
    result = {};
    float fraction = pgEffectiveFraction(sd, mi);
    if (fraction <= 0.f)
    {
        if (recordDiagnostics) pgDiagnostic(kPGDiagFallback);
        // Critically, do not consume a mixture-selection random number here.
        return sampleMyPTBSDF(sd, mi, sg, result, importance);
    }

    if (sampleNext1D(sg) < fraction)
    {
        if (recordDiagnostics) pgDiagnostic(kPGDiagGuided);
        float guidePdf;
        pgSampleGuide(sd.posW, sampleNext2D(sg), result.wo, guidePdf);
        float bsdfPdf = evalMyPTBSDFPdf(sd, mi, result.wo, importance);
        result.pdf = fraction * guidePdf + (1.f - fraction) * bsdfPdf;
        if (!(result.pdf > 0.f) || !isfinite(result.pdf))
        {
            pgDiagnostic(kPGDiagInvalidPdf);
            return false;
        }
        // Falcor eval() already includes the foreshortening term.
        result.weight = mi.eval(sd, result.wo, sg) / result.pdf;
        result.lobeType = uint(LobeType::NonDeltaReflection);
        // Full sphere: zero-BSDF directions terminate with zero contribution.
        // Never reject/resample them and silently change the density.
        return true;
    }

    if (!sampleMyPTBSDF(sd, mi, sg, result, importance)) return false;
    float bsdfPdf = result.pdf;
    float mixedPdf = (1.f - fraction) * bsdfPdf + fraction * pgGuidePdf(sd.posW, result.wo);
    if (!(mixedPdf > 0.f) || !isfinite(mixedPdf))
    {
        pgDiagnostic(kPGDiagInvalidPdf);
        return false;
    }
    // Retain the material sampler's exact f*cos/pdf convention, including its
    // shading-normal treatment; do not multiply another cosine.
    result.weight *= bsdfPdf / mixedPdf;
    result.pdf = mixedPdf;
    return true;
}

#endif
