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
 *  - mergeReservoir(): generic reservoir resampling merge primitive, used by both
 *    temporal reuse (ReSTIR Algorithm 2) and spatial reuse (Algorithm 4). An
 *    incoming reservoir (previous frame or spatial neighbor) has its selected
 *    sample re-evaluated at the current shading point and merged with weight
 *    M_in * p_hat(y_in) / p(y_in), with M clamped to a maximum.
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
    float4 visReserved;   ///< x = visibility of the selected sample (-1 = unmeasured, 0 = occluded, 1 = visible), yzw = reserved.
};

extension Reservoir
{
    /// True if this reservoir contains a valid selected sample.
    bool isValid() { return asuint(positionM.w) > 0; }

    /// Number of accumulated samples M.
    uint getM() { return asuint(positionM.w); }

    /// Set the number of accumulated samples M (preserves the xyz part).
    [mutating] void setM(uint m) { positionM = float4(positionM.xyz, asfloat(m)); }

    /// Visibility of the selected sample: -1 = unmeasured (RIS new sample), 0 = occluded, 1 = visible.
    float getVisibility() { return visReserved.x; }

    /// Set the visibility of the selected sample (preserves the yzw reserved part).
    [mutating] void setVisibility(float v) { visReserved = float4(v, 0.f, 0.f, 0.f); }

    /// Create an empty (invalid) reservoir.
    static Reservoir createEmpty()
    {
        Reservoir r = {};
        return r;
    }
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
        // Distant light: als.Li is radiance (not divided by pdf). The direction is
        // (effectively) deterministic for the radiance integral — the light's angle
        // only affects penumbra size, not brightness — so the source pdf uses only
        // the discrete type + light selection probabilities, matching the reference
        // path tracer (evalDirectAnalytic uses invPdf = lightCount, ignoring als.pdf).
        c.radiance = als.Li;
        c.pdf = pAnalytic * lightSelectionPdf;
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
    // New RIS samples have no measured visibility yet; mark as unmeasured (-1).
    result.visReserved = float4(-1.f, 0.f, 0.f, 0.f);

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
    float pHatSelected = 0.f;  // p_hat of the RIS-selected candidate (at the current shading point).

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
            result.radianceWsum = float4(c.radiance, 0.f);
            // Store the source pdf of the selected sample (RIS estimator denominator).
            result.normalPdf = float4(result.normalPdf.xyz, c.pdf);
            pHatSelected = p_hat;
        }
    }

    if (Wsum > 0.f)
    {
        // Reference's condense (InitialResampling.cs.slang:219-222):
        //   weight = (weightSum / M) / p_hat_selected
        //   M = 1
        // p_hat_selected is stored in normalPdf.w (repurposed; the source pdf
        // is no longer needed after RIS). The merge then uses the reference's
        // streamingResampleStep + unbiased normalization, and the final shading
        // returns weight * f, matching the reference's Li = weight * geomFactor * emission.
        result.radianceWsum = float4(result.radianceWsum.xyz, (Wsum / float(M)) / pHatSelected);
        result.setM(1);
        result.normalPdf.w = pHatSelected;
    }

    return result;
}

/**
 * Merge an incoming reservoir into the current reservoir (generic resampling merge).
 * This is the shared merge primitive for ReSTIR (Bitterli et al. 2020):
 *   - temporal reuse (Algorithm 2): `incoming` is the previous frame's reservoir.
 *   - spatial reuse  (Algorithm 4): `incoming` is a spatial neighbor's reservoir.
 * The math is identical in both cases:
 *   w_in = M_in * p_hat(y_in) / p(y_in)   (incoming sample re-evaluated at the CURRENT shading point)
 *   r.w_sum += w_in                        (add w_in, NOT the incoming reservoir's w_sum)
 *   select y_in with probability w_in / w_sum
 *   r.M = M_cur + min(M_in, maxHistory)    (cap only the reused history length)
 * @param[in] sd Shading data at the current pixel (primary hit).
 * @param[in] mi Material instance (for re-evaluating the incoming sample's weight).
 * @param[in,out] sg Sample generator.
 * @param[in] cur Current reservoir accumulator (RIS result, or prior merged result).
 * @param[in] incoming Incoming reservoir to merge (previous frame, or a neighbor).
 * @param[in] maxHistory Maximum accumulated sample count M.
 * @param[in] depthThreshold Maximum allowed world-space position difference for reuse.
 * @param[in] normalThreshold Minimum allowed cosine of the angle between normals for reuse.
 * @return Merged reservoir. position/normal always reflect the current frame's geometry.
 */
Reservoir mergeReservoir(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, const Reservoir cur, const Reservoir incoming, const uint maxHistory, const float depthThreshold, const float normalThreshold)
{
    // Default to the current reservoir (position/normal already reflect current geometry).
    Reservoir result = cur;

    if (!incoming.isValid())
        return result;

    // Visibility reuse: a sample measured occluded (V = 0) in the previous frame contributes
    // nothing. Discard it entirely — not only from selection but also from M accumulation —
    // otherwise its M would inflate the (W/M) denominator and bias the final estimate downward.
    // Unmeasured samples (V = -1, e.g. fresh RIS samples) fall through and are treated as visible.
    if (incoming.getVisibility() == 0.f)
        return result;

    // Validate the incoming reservoir's surface against the current one.
    // Use relative depth (matching the reference EvalContext::isValidNeighbor):
    // allow larger world-space offsets at larger depth, so distant geometry can
    // still be reused. Absolute depth thresholds (e.g. 0.01-0.02 m) reject almost
    // all spatial neighbors on large/planar surfaces.
    const float currentDepth = distance(gScene.camera.getPosition(), sd.posW);
    const float incomingDepth = distance(gScene.camera.getPosition(), incoming.positionM.xyz);
    if (abs(currentDepth - incomingDepth) >= depthThreshold * currentDepth)
        return result;
    if (dot(incoming.normalPdf.xyz, sd.getOrientedFaceNormal()) <= normalThreshold)
        return result;

    // Re-evaluate the incoming sample's target function at the CURRENT shading point.
    const float3 f_p = mi.eval(sd, incoming.dirDistance.xyz, sg) * incoming.radianceWsum.xyz;
    const float p_hat_p = luminance(f_p);
    if (p_hat_p <= 0.f)
        return result; // Incoming sample is invalid at this shading point.

    // Cap the number of reusable samples carried by the incoming reservoir.
    // Mirrors the reference (TemporalResampling.cs.slang: prevReservoir.M = min(prev.M, cur.M * maxHistory)).
    const uint incomingM = min(incoming.getM(), maxHistory);

    // Reference's streamingResampleStep equivalent (Resampling.slang:90-106).
    //   sampleWeight = p_hat_at_merge * weight * M
    // For cur: p_hat_at_merge = p_hat of cur's selected at cur context = cur.normalPdf.w
    //   (stored in sampleLightRIS or a previous merge). With cur.radianceWsum.w =
    //   (Wsum_cur/M_cur)/p_hat_cur_selected, sampleWeight_cur simplifies to Wsum_cur.
    // For incoming: p_hat_at_merge = p_hat_p (p_hat of incoming's sample at cur context).
    //   sampleWeight_in = p_hat_p * incoming.radianceWsum.w * incomingM.
    const float sampleWeight_cur = cur.normalPdf.w * cur.radianceWsum.w * float(cur.getM());
    const float sampleWeight_in = p_hat_p * incoming.radianceWsum.w * float(incomingM);
    const float weightSum = sampleWeight_cur + sampleWeight_in;
    const uint M_new = cur.getM() + incomingM;

    // Select incoming with probability sampleWeight_in / weightSum.
    bool selectedCur = true;
    if (weightSum > 0.f && sampleNext1D(sg) * weightSum < sampleWeight_in)
    {
        // Incoming selected.
        result.dirDistance = incoming.dirDistance;
        result.radianceWsum = float4(incoming.radianceWsum.xyz, result.radianceWsum.w);
        result.visReserved = incoming.visReserved;
        // result.normalPdf.xyz stays as cur's (current frame's normal).
        selectedCur = false;
    }

    // Reference's unbiased normalization (TemporalResampling.cs.slang non-MIS branch).
    //   denom = M_cur * p_hat_at_cur + M_prev * p_hat_at_prev
    //   new weight = weightSum / denom
    // p_hat_at_cur_of_selected: if cur selected, p_hat of cur's sample at cur context
    //   (= cur.normalPdf.w); if incoming selected, p_hat of incoming's sample at cur
    //   context (= p_hat_p).
    // p_hat_at_prev_of_selected: if cur selected, ≈ p_hat at cur context (static camera
    //   approximation); if incoming selected, p_hat at incoming's own context
    //   (= incoming.normalPdf.w).
    const float p_hat_at_cur = selectedCur ? cur.normalPdf.w : p_hat_p;
    const float p_hat_at_prev = selectedCur ? cur.normalPdf.w : incoming.normalPdf.w;
    const float denom = float(cur.getM()) * p_hat_at_cur + float(incomingM) * p_hat_at_prev;
    const float newWeight = (denom > 0.f) ? weightSum / denom : 0.f;

    // Store: radianceWsum.w = newWeight (the reference's normalized weight).
    // normalPdf.w = p_hat_at_cur_of_selected (for the next merge).
    //
    // IMPORTANT: position/normal must ALWAYS reflect the CURRENT frame's geometry. They are
    // used for next-frame temporal/spatial depth+normal validation. If `cur` was an empty
    // reservoir (e.g. the RIS sample was rejected by the initial visibility test in restirGen,
    // which zeroes the whole struct), its position/normal are (0,0,0) and would otherwise
    // pollute the merged result, causing the history to be rejected every following frame.
    result.radianceWsum = float4(result.radianceWsum.xyz, newWeight);
    result.normalPdf = float4(sd.getOrientedFaceNormal(), p_hat_at_cur);
    result.positionM = float4(sd.posW, asfloat(M_new));

    return result;
}
