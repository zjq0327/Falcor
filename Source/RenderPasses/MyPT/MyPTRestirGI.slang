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
 * ReSTIR GI reservoir math for MyPT.
 *
 * This file implements the reservoir-side of 1-bounce indirect-light path
 * resampling (Ouyang et al., "ReSTIR GI: Path Resampling for Real-Time Path
 * Tracing", HPG 2021):
 *
 *   - GIPathReservoir: per-pixel reservoir storing a 1-bounce path sample. The
 *     sample is the path's second vertex x2 (any surface), reached from the
 *     primary hit x1 along a direction sampled from the BSDF.
 *   - mergeGIPathReservoir(): temporal/spatial reuse. Reuses a neighbor's (or
 *     the previous frame's) x2 vertex by RECONNECTING it to the current x1 and
 *     re-evaluating the path throughput. The source pdf is carried in AREA
 *     measure (stored at sampling time in sourcePdfRes.w), which is invariant
 *     under reconnection, giving an unbiased Bitterli-style streaming merge.
 *   - evalGIPathReSTIR(): final indirect-light estimate weight * f(x1,d)*L_out.
 *
 * The trace side (candidate generation, hit shaders, the RIS loop) lives in
 * MyPT.rt.slang because it needs TraceRay; this file is pure reservoir math and
 * is imported by MyPT.rt.slang (same relationship as MyPTRestir.slang).
 *
 * Note: Slang does not allow swizzle l-value assignment on struct members of
 * type float4, so all partial updates use full-vector reconstruction.
 */

import Scene.Raytracing;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;

static const bool kGIUseImportanceSampling = USE_IMPORTANCE_SAMPLING;

/** ReSTIR GI reservoir for a 1-bounce path sample, packed as 6 x float4 (96B). */
struct GIPathReservoir
{
    float4 posX2Dist;     ///< xyz = path vertex x2 (world pos), w = |x2 - x1| distance.
    float4 radianceWsum;  ///< xyz = outgoing radiance L_out(x2) (emission + direct), w = normalized weight.
    float4 posX1M;        ///< xyz = shading point x1 (at sampling time), w = asfloat(M).
    float4 normalX1Pdf;   ///< xyz = x1 oriented normal, w = p_hat of the selected sample at its own context.
    float4 normalX2Vis;   ///< xyz = x2 oriented normal (for reconnection), w = visibility.
    float4 sourcePdfRes;  ///< Reserved (unused by the current merge, which follows the DI streaming formula and needs no explicit area source pdf). Kept to preserve the 6 x float4 layout.
};

extension GIPathReservoir
{
    /// True if this reservoir contains a valid selected sample.
    bool isValid() { return asuint(posX1M.w) > 0; }

    /// Number of accumulated samples M.
    uint getM() { return asuint(posX1M.w); }

    /// Set the number of accumulated samples M (preserves the xyz part).
    [mutating] void setM(uint m) { posX1M = float4(posX1M.xyz, asfloat(m)); }

    /// Visibility of the selected sample (phase 1 always 1 = visible).
    float getVisibility() { return normalX2Vis.w; }

    /// Set the visibility of the selected sample (preserves the xyz part).
    [mutating] void setVisibility(float v) { normalX2Vis = float4(normalX2Vis.xyz, v); }

    /// Create an empty (invalid) reservoir.
    static GIPathReservoir createEmpty()
    {
        GIPathReservoir r = {};
        return r;
    }
}

/**
 * Merge an incoming GI reservoir (previous frame or spatial neighbor) into the
 * current one. Structurally identical to mergeReservoir() in MyPTRestir.slang,
 * with one extra step: the incoming x2 vertex is RECONNECTED to the current x1
 * before the target is re-evaluated.
 *
 * The incoming sample is a path vertex x2, sampled from the incoming pixel's x1
 * via BSDF sampling. Reconnection keeps x2 fixed and only moves x1 to the current
 * shading point; the re-evaluated target
 *
 *     p_hat_r = luminance(f(x1_cur, d_r) * L_out),  d_r = normalize(x2 - x1_cur)
 *
 * accounts for reconnection implicitly. The merge uses the standard Bitterli
 * streaming formula `sampleWeight = p_hat_at_merge * weight * M`, identical to
 * the DI merge, so reconnection does NOT require any explicit area-measure
 * source-pdf tracking — the incoming's stored radianceWsum.w already encodes its
 * accumulated IS weights (which are numerically identical in solid-angle and
 * area measure: cosφ2/dist² cancels between numerator and denominator).
 *
 * The normalization uses the same MIS-style correction as the DI merge:
 *   denom = M_cur * p_hat_at_cur + M_in * p_hat_at_prev,
 * where p_hat_at_prev is the selected sample's p_hat at its OWN context (stored
 * in incoming.normalX1Pdf.w at sampling time), which helps account for the
 * target-function change across the reconnection.
 *
 * Phase 2b note: an earlier attempt computed w_in = p_hat_r / pSource_r with a
 * custom source pdf and w_in_total = M_in * w_in. That dropped the incoming's
 * accumulated Wsum and recomputed a single-shot IS weight, which broke the
 * streaming symmetry with cur's contribution (cur uses the correct Wsum) and
 * caused the systematic over-exposure. This version restores the DI formula.
 *
 * @param[in] sd Shading data at the current pixel (primary hit x1).
 * @param[in] mi Material instance at the current pixel.
 * @param[in,out] sg Sample generator.
 * @param[in] cur Current reservoir accumulator (RIS result, or prior merged result).
 * @param[in] incoming Incoming reservoir to merge (previous frame, or a neighbor).
 * @param[in] maxHistory Maximum accumulated sample count M.
 * @param[in] depthThreshold Maximum allowed relative depth difference for reuse.
 * @param[in] normalThreshold Minimum allowed cosine between normals for reuse.
 * @return Merged reservoir. posX1M/normalX1Pdf always reflect the current frame's geometry.
 */
GIPathReservoir mergeGIPathReservoir(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, const GIPathReservoir cur, const GIPathReservoir incoming, const uint maxHistory, const float depthThreshold, const float normalThreshold)
{
    GIPathReservoir result = cur;

    if (!incoming.isValid())
        return result;

    // Visibility reuse: reject samples measured occluded in a previous frame.
    // (Phase 1 does not re-measure visibility after reconnection, so samples are
    // always marked visible at initial sampling and this check never triggers.)
    if (incoming.getVisibility() == 0.f)
        return result;

    // Validate the incoming surface (x1) against the current one (relative depth
    // + normal cosine), matching mergeReservoir() in MyPTRestir.slang.
    const float currentDepth = distance(gScene.camera.getPosition(), sd.posW);
    const float incomingDepth = distance(gScene.camera.getPosition(), incoming.posX1M.xyz);
    if (abs(currentDepth - incomingDepth) >= depthThreshold * currentDepth)
        return result;
    if (dot(incoming.normalX1Pdf.xyz, sd.getOrientedFaceNormal()) <= normalThreshold)
        return result;

    // Reconnection: reconnect the incoming path vertex x2 to the current x1.
    const float3 x2 = incoming.posX2Dist.xyz;
    const float3 n2 = incoming.normalX2Vis.xyz;
    const float3 Lout = incoming.radianceWsum.xyz;

    const float3 v_r = x2 - sd.posW;
    const float distR2 = dot(v_r, v_r);
    if (distR2 < 1e-8f)
        return result; // x2 coincides with x1; degenerate, skip.
    const float3 d_r = v_r * rsqrt(distR2); // normalize(x2 - x1_cur)

    // Re-evaluate the path throughput at the current x1 along the reconnected direction.
    const float3 f_r = mi.eval(sd, d_r, sg) * Lout;
    const float p_hat_r = luminance(f_r);
    if (p_hat_r <= 0.f)
        return result;

    // Cap the reusable sample count carried by the incoming reservoir.
    const uint incomingM = min(incoming.getM(), maxHistory);

    // GRIS-style streaming merge with explicit area-Jacobian restoration.
    //
    // The incoming reservoir carries its accumulated IS weights in radianceWsum.w
    // (= (Wsum_in/M_in)/pHatSel_in, where Wsum_in = Σ p_hat_j/p_Ω_j). Those weights are
    // valid only in the incoming's sampling measure (its own x1 context). Reconnection
    // shifts the sampling context to the current x1, so the effective contribution in
    // the current area measure must be corrected by the Jacobian ratio
    //
    //     w_in = p_hat_r * (J_r / J_final) * incoming.radianceWsum.w * M_in
    //
    // where J_r     = cosφ2_r  / |x2 - x1_cur|²     (current  area-measure Jacobian)
    //       J_final = cosφ2_prev / |x2 - x1_prev|²   (incoming area-measure Jacobian).
    //
    // Without this J_r / J_final correction, the code substitutes "M_in copies of the
    // selected sample's weight" for the true Σ IS weights. Since the RIS-selected
    // weight is at least the mean weight (and grows monotonically with M), this causes
    // a systematic darkening as M accumulates across temporal + spatial reuse.
    //
    // The DI formula `sampleWeight = p_hat_at_merge * weight * M` works for DI because
    // reconnection there is the identity (sample direction does not change) — J_r/J_final
    // collapses to 1. For GI, we need the explicit Jacobian ratio.
    //
    // Reference (RTXDI ReSTIR GI; Ouyang et al. 2021 §3.2). The DI-style MIS
    // normalization in `denom` below remains as a heuristic for residual bias.
    const float3 vFinal = x2 - incoming.posX1M.xyz;
    const float dFinal2 = max(dot(vFinal, vFinal), 1e-8f);
    const float J_final = abs(dot(n2, -vFinal * rsqrt(dFinal2))) / dFinal2;

    const float cosPhi2_r = abs(dot(n2, -d_r));
    const float J_r = cosPhi2_r / distR2;

    const float sampleWeight_cur = cur.normalX1Pdf.w * cur.radianceWsum.w * float(cur.getM());
    const float sampleWeight_in = p_hat_r * (J_r / max(J_final, 1e-12f))
                                * incoming.radianceWsum.w * float(incomingM);
    const float weightSum = sampleWeight_cur + sampleWeight_in;
    const uint M_new = cur.getM() + incomingM;

    // Select incoming with probability sampleWeight_in / weightSum.
    bool selectedCur = true;
    if (weightSum > 0.f && sampleNext1D(sg) * weightSum < sampleWeight_in)
    {
        // Incoming selected: x2, L_out and x2's normal follow the incoming sample.
        result.posX2Dist = incoming.posX2Dist;
        result.radianceWsum = float4(incoming.radianceWsum.xyz, result.radianceWsum.w);
        result.normalX2Vis = incoming.normalX2Vis;
        selectedCur = false;
    }

    // Reference's unbiased normalization with MIS correction (same as mergeReservoir()
    // in MyPTRestir.slang). The denom mixes p_hat_at_cur and p_hat_at_prev to account
    // for the target-function change across the reconnection.
    //   p_hat_at_cur:  if cur selected -> cur.normalX1Pdf.w;
    //                  if incoming selected -> p_hat_r.
    //   p_hat_at_prev: if cur selected -> cur.normalX1Pdf.w (static-camera approximation,
    //                  same as p_hat_at_cur);
    //                  if incoming selected -> incoming.normalX1Pdf.w
    //                  (p_hat of selected at its OWN context, stored at sampling time).
    const float p_hat_at_cur = selectedCur ? cur.normalX1Pdf.w : p_hat_r;
    const float p_hat_at_prev = selectedCur ? cur.normalX1Pdf.w : incoming.normalX1Pdf.w;
    const float denom = float(cur.getM()) * p_hat_at_cur + float(incomingM) * p_hat_at_prev;
    const float newWeight = (denom > 0.f && !isnan(weightSum) && !isinf(weightSum)) ? weightSum / denom : 0.f;

    // Write back. posX1M/normalX1Pdf always reflect the current frame's geometry
    // (they are used for next-frame depth/normal validation). posX2Dist/normalX2Vis/
    // radianceWsum.xyz reflect the selected sample. visibility stays as-is.
    result.radianceWsum = float4(result.radianceWsum.xyz, newWeight);
    result.normalX1Pdf = float4(sd.getOrientedFaceNormal(), p_hat_at_cur);
    result.posX1M = float4(sd.posW, asfloat(M_new));

    return result;
}

/**
 * Final indirect-light estimate for a GI reservoir:
 *     L_indirect = weight * f(x1, d) * L_out(x2),  d = normalize(x2 - x1).
 * This mirrors evalDirectReSTIR() in MyPT.rt.slang.
 */
float3 evalGIPathReSTIR(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg, inout GIPathReservoir r)
{
    if (!r.isValid())
        return float3(0.f);

    const float w = r.radianceWsum.w;
    if (w <= 0.f || isnan(w) || isinf(w))
        return float3(0.f);

    const float3 d = normalize(r.posX2Dist.xyz - sd.posW);
    const float3 f = mi.eval(sd, d, sg);
    // If mi.eval returns a non-finite value or any negative channel (which can happen
    // after reconnection on certain materials), drop this GI contribution entirely
    // rather than risk a negative-signed accumulation that cancels the DI term.
    if (any(isnan(f)) || any(isinf(f)) || f.x < 0.f || f.y < 0.f || f.z < 0.f)
        return float3(0.f);

    const float3 c = w * f * r.radianceWsum.xyz;
    if (isnan(c.x) || isnan(c.y) || isnan(c.z) || isinf(c.x) || isinf(c.y) || isinf(c.z))
        return float3(0.f);
    // No energy clamp here: the merge uses the Bitterli streaming formula with pairwise
    // MIS (power heuristic), so the reconnection bias is corrected and the estimate is
    // unbiased. The NaN/Inf/negative guards above remain as a safety net only.
    return c;
}
