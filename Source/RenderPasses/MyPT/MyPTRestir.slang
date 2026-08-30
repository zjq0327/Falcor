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
 * This file implements ReSTIR DI direct illumination:
 *  - sampleLightRIS(): RIS initial sampling. At the primary hit, M candidate
 *    light samples are drawn from all light sources (emissive triangles +
 *    analytic lights) and one is selected via resampled importance sampling.
 *  - temporalResample(): temporal reuse. The current frame's reservoir is
 *    merged with the previous frame's reservoir (reprojected with motion
 *    vectors and validated with depth/normal thresholds) to accumulate history.
 *
 * The result is consumed by evalDirectReSTIR() in MyPT.rt.slang, which traces a
 * single shadow ray and evaluates the final contribution. The indirect
 * (scatter) recursion is handled entirely by MyPT.rt.slang and is identical to
 * the plain path tracer.
 *
 * Note: Slang does not allow swizzle l-value assignment on struct members of
 * type float4 (e.g. `r.positionM.w = x;` or `r.radianceWsum.xyz = v;` are
 * rejected with "left of '=' is not an l-value"). All partial updates of
 * float4 members use full-vector reconstruction (`member = float4(...)`).
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

/** ReSTIR reservoir, stored per-pixel across frames.
    Packed as float4 to keep the host/shader struct layout unambiguous (64B). */
struct Reservoir
{
    float4 dirDistance;   ///< xyz = selected light direction (normalized), w = distance to light.
    float4 radianceWsum;  ///< xyz = unoccluded incident radiance, w = accumulated weight Wsum.
    float4 positionM;     ///< xyz = shading point position (for next-frame depth validation), w = asfloat(M).
    float4 normalPdf;     ///< xyz = shading normal (for next-frame normal validation), w = source pdf of the selected sample.
};

extension Reservoir
{
    /// True if this reservoir contains a valid selected sample.
    bool isValid() { return asuint(positionM.w) > 0; }

    /// Number of accumulated samples M.
    uint getM() { return asuint(positionM.w); }

    /// Set the number of accumulated samples M (preserves the xyz part).
    [mutating] void setM(uint m) { positionM = float4(positionM.xyz, asfloat(m)); }
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
 * @return Reservoir containing the selected sample (invalid if no valid candidate).
 */
Reservoir sampleLightRIS(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, const uint M)
{
    Reservoir result = {};

    // Always store the current-frame geometry for next-frame temporal validation (xyz only; w is M=0 / pdf=0).
    result.positionM = float4(sd.posW, 0.f);
    result.normalPdf = float4(sd.getOrientedFaceNormal(), 0.f);

    const bool hasEmissive = kRestirUseEmissiveLights && (gScene.lightCollection.getActiveTriangleCount() > 0);
    const bool hasAnalytic = kRestirUseAnalyticLights && (gScene.getLightCount() > 0);

    if (!hasEmissive && !hasAnalytic)
        return result;

    // Type selection probabilities (equal split when both are present).
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
            result.dirDistance = float4(c.dir, c.distance);
            // Preserve the current w (0 at this point) when rewriting xyz.
            result.radianceWsum = float4(c.radiance, result.radianceWsum.w);
            // Store the source pdf of the selected sample (RIS estimator denominator).
            result.normalPdf = float4(result.normalPdf.xyz, c.pdf);
        }
    }

    if (Wsum > 0.f)
    {
        // Finalize Wsum and M.
        result.radianceWsum = float4(result.radianceWsum.xyz, Wsum);
        result.setM(M);
    }

    return result;
}

/**
 * Merge the current frame's reservoir with the previous frame's reservoir (temporal reuse).
 * Follows ReSTIR (Bitterli et al. 2020), Algorithm 2:
 *   w_p = M_p * p_hat(y_p) / p(y_p)   (history sample re-evaluated at the current shading point)
 *   r.w_sum += w_p                     (add w_p, NOT the previous reservoir's w_sum)
 *   select y_p with probability w_p / w_sum
 *   r.M = min(M_cur + M_prev, maxHistory)
 * @param[in] sd Shading data at the current pixel (primary hit).
 * @param[in] mi Material instance (for re-evaluating the history sample's weight).
 * @param[in,out] sg Sample generator.
 * @param[in] cur Current frame reservoir (from RIS).
 * @param[in] prev Previous frame reservoir (reprojected).
 * @param[in] maxHistory Maximum accumulated sample count M.
 * @param[in] depthThreshold Maximum allowed world-space position difference for reuse.
 * @param[in] normalThreshold Minimum allowed cosine of the angle between normals for reuse.
 * @return Merged reservoir. position/normal always reflect the current frame's geometry.
 */
Reservoir temporalResample(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, const Reservoir cur, const Reservoir prev, const uint maxHistory, const float depthThreshold, const float normalThreshold)
{
    // Default to the current frame reservoir (position/normal already reflect current geometry).
    Reservoir result = cur;

    if (!prev.isValid())
        return result;

    // Validate the previous frame's surface against the current frame's.
    if (distance(prev.positionM.xyz, sd.posW) >= depthThreshold)
        return result;
    if (dot(prev.normalPdf.xyz, sd.getOrientedFaceNormal()) <= normalThreshold)
        return result;

    // Re-evaluate the history sample's target function at the CURRENT shading point.
    const float3 f_p = mi.eval(sd, prev.dirDistance.xyz, sg) * prev.radianceWsum.xyz;
    const float p_hat_p = luminance(f_p);
    const float pdf_p = prev.normalPdf.w;
    if (p_hat_p <= 0.f || pdf_p <= 0.f)
        return result; // History sample is invalid at this shading point.

    // ReSTIR Algorithm 2: weight the history sample by M_p * p_hat(y_p) / p(y_p).
    const float w_p = float(prev.getM()) * p_hat_p / pdf_p;
    const float w_c = cur.radianceWsum.w;
    const float w_sum = w_c + w_p;

    // Select the history sample with probability w_p / w_sum.
    if (w_sum > 0.f && sampleNext1D(sg) * w_sum < w_p)
    {
        result.dirDistance = prev.dirDistance;
        result.radianceWsum = float4(prev.radianceWsum.xyz, result.radianceWsum.w);
        result.normalPdf = float4(result.normalPdf.xyz, prev.normalPdf.w);
        // Keep current-frame position/normal.
    }

    // Finalize w_sum and M.
    result.radianceWsum = float4(result.radianceWsum.xyz, w_sum);
    result.setM(min(cur.getM() + prev.getM(), maxHistory));

    return result;
}
