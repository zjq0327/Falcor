/***************************************************************************
 # Copyright (c) 2015-24, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/

/**
 * ReSTIR DI implementation for MyPT.
 *
 * This file implements the first stage of ReSTIR DI: pure RIS initial
 * sampling (no temporal/spatial reuse). At the primary hit, M candidate
 * light samples are drawn from all light sources (emissive triangles +
 * analytic lights) and one is selected via resampled importance sampling.
 *
 * The result is consumed by evalDirectReSTIR() in MyPT.rt.slang, which traces
 * a single shadow ray and evaluates the final contribution. The indirect
 * (scatter) recursion is handled entirely by MyPT.rt.slang and is identical to
 * the plain path tracer.
 */

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Scene.Lights.LightData;

// Static configuration. These are replicated here (instead of reusing the
// kUseXxx consts in MyPT.rt.slang) because static consts have internal linkage
// and are not visible across module boundaries. The preprocessor defines set by
// the host are globally visible.
static const bool kRestirUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kRestirUseAnalyticLights = USE_ANALYTIC_LIGHTS;

/** Result of ReSTIR DI RIS. */
struct ReSTIRLightSample
{
    float3 dir;       ///< Normalized direction to the selected light.
    float3 radiance;  ///< Unoccluded incident radiance (not divided by pdf).
    float  distance;  ///< Distance to the selected light.
    float  weight;    ///< Reservoir weight W_sum / M.
    float  p_hat;     ///< luminance(f) of the selected sample.
    bool   valid;     ///< True if a valid sample was selected.
};

/** A single light candidate used by RIS. */
struct ReSTIRLightCandidate
{
    float3 dir;       ///< Normalized direction to the light.
    float3 radiance;  ///< Unoccluded incident radiance (not divided by pdf).
    float  distance;  ///< Distance to the light.
    float  pdf;       ///< Total source pdf (type selection + light selection + continuous).
};

/** Sample a candidate on the emissive triangles. */
bool sampleEmissiveCandidate(const ShadingData sd, inout SampleGenerator sg, const float pEmissive, out ReSTIRLightCandidate c)
{
    c = {};

    // Instantiate the stateless emissive light sampler locally (same approach as MyPT.rt.slang).
    EmissiveLightSampler emissiveSampler = {};

    TriangleLightSample tls;
    if (!emissiveSampler.sampleLight(sd.posW, sd.getOrientedFaceNormal(), false, sg, tls))
        return false;
    if (tls.pdf <= 0.f)
        return false;

    c.dir = tls.dir;
    c.radiance = tls.Le;
    c.distance = tls.distance;
    c.pdf = pEmissive * tls.pdf;
    return true;
}

/** Sample a candidate on the analytic lights. */
bool sampleAnalyticCandidate(const ShadingData sd, inout SampleGenerator sg, const float pAnalytic, out ReSTIRLightCandidate c)
{
    c = {};

    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return false;

    // Select one analytic light uniformly.
    const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    const LightData light = gScene.getLight(lightIndex);
    const float lightSelectionPdf = 1.f / float(lightCount);

    AnalyticLightSample als;
    if (!sampleLight(sd.posW, light, sg, als))
        return false;

    c.dir = als.dir;
    c.distance = als.distance;

    switch (LightType(light.type))
    {
    case LightType::Rect:
    case LightType::Sphere:
    case LightType::Disc:
        // Area lights: als.Li is radiance / pdf, so multiply back to get radiance.
        c.radiance = als.Li * als.pdf;
        c.pdf = pAnalytic * lightSelectionPdf * als.pdf;
        break;
    case LightType::Distant:
        // Distant light: als.Li is radiance (not divided by pdf).
        c.radiance = als.Li;
        c.pdf = pAnalytic * lightSelectionPdf * als.pdf;
        break;
    case LightType::Point:
    case LightType::Directional:
    default:
        // Delta lights: the direction is deterministic, so the source pdf is only the discrete selection pdf.
        c.radiance = als.Li;
        c.pdf = pAnalytic * lightSelectionPdf;
        break;
    }

    return c.pdf > 0.f;
}

/**
 * Generate M initial light candidates and select one via RIS (resampled importance sampling).
 * @param[in] sd Shading data at the primary hit.
 * @param[in] mi Material instance.
 * @param[in,out] sg Sample generator.
 * @param[in] M Number of candidate samples.
 * @return Selected light sample with reservoir weight.
 */
ReSTIRLightSample sampleLightRIS(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, const uint M)
{
    ReSTIRLightSample result = {};

    const bool hasEmissive = kRestirUseEmissiveLights && (gScene.lightCollection.getActiveTriangleCount() > 0);
    const bool hasAnalytic = kRestirUseAnalyticLights && (gScene.getLightCount() > 0);

    if (!hasEmissive && !hasAnalytic)
        return result;

    // Type selection probabilities (first version: equal split when both are present).
    float pEmissive;
    float pAnalytic;
    if (hasEmissive && hasAnalytic)
    {
        pEmissive = 0.5f;
        pAnalytic = 0.5f;
    }
    else if (hasEmissive)
    {
        pEmissive = 1.f;
        pAnalytic = 0.f;
    }
    else
    {
        pEmissive = 0.f;
        pAnalytic = 1.f;
    }

    float Wsum = 0.f;

    for (uint i = 0; i < M; i++)
    {
        ReSTIRLightCandidate c;
        bool ok = false;

        if (hasEmissive && hasAnalytic)
        {
            ok = (sampleNext1D(sg) < pEmissive)
                ? sampleEmissiveCandidate(sd, sg, pEmissive, c)
                : sampleAnalyticCandidate(sd, sg, pAnalytic, c);
        }
        else if (hasEmissive)
        {
            ok = sampleEmissiveCandidate(sd, sg, pEmissive, c);
        }
        else
        {
            ok = sampleAnalyticCandidate(sd, sg, pAnalytic, c);
        }

        if (!ok || c.pdf <= 0.f)
            continue;

        const float3 f = mi.eval(sd, c.dir, sg) * c.radiance;
        const float p_hat = luminance(f);
        if (p_hat <= 0.f)
            continue;

        const float w = p_hat / c.pdf;
        Wsum += w;

        // Reservoir select with probability w / Wsum.
        if (Wsum > 0.f && sampleNext1D(sg) * Wsum < w)
        {
            result.dir = c.dir;
            result.radiance = c.radiance;
            result.distance = c.distance;
            result.p_hat = p_hat;
            result.valid = true;
        }
    }

    if (result.valid && Wsum > 0.f)
        result.weight = Wsum / float(M);

    return result;
}
