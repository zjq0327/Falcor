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
 * ReSTIR GI (phase 1) reservoir math for MyPT.
 *
 * This file implements the reservoir-side of 1-bounce indirect-light path
 * resampling (Ouyang et al., "ReSTIR GI: Path Resampling for Real-Time Path
 * Tracing", HPG 2021):
 *
 *   - GIPathReservoir: per-pixel reservoir storing a 1-bounce path sample. The
 *     sample is the path's second vertex x2 (any surface), reached from the
 *     primary hit x1 along a direction sampled from the BSDF.
 *   - mergeGIPathReservoir(): temporal/spatial reuse. Reuses a neighbor's (or
 *     the previous frame's) x2 vertex by RECONNECTING it to the current x1,
 *     re-evaluating the path throughput, and converting the source pdf from
 *     solid-angle measure to area measure (the "reconnection Jacobian").
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

/** ReSTIR GI reservoir for a 1-bounce path sample, packed as 5 x float4 (80B). */
struct GIPathReservoir
{
    float4 posX2Dist;     ///< xyz = path vertex x2 (world pos), w = |x2 - x1| distance.
    float4 radianceWsum;  ///< xyz = outgoing radiance L_out(x2) (emission + direct), w = normalized weight.
    float4 posX1M;        ///< xyz = shading point x1 (at sampling time), w = asfloat(M).
    float4 normalX1Pdf;   ///< xyz = x1 oriented normal, w = p_hat of the selected sample at its own context.
    float4 normalX2Vis;   ///< xyz = x2 oriented normal (for reconnection), w = visibility.
    float4 sourcePdfRes;  ///< x = area-measure source pdf of the selected sample, yzw reserved.
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
 * current one. This is the GI analogue of mergeReservoir() in MyPTRestir.slang,
 * with one extra step: the incoming x2 vertex is RECONNECTED to the current x1,
 * and the source pdf is converted to area measure (the reconnection Jacobian).
 *
 * The incoming sample is a path vertex x2, sampled from the incoming pixel's x1
 * via BSDF sampling with solid-angle pdf pOmega. Reusing it at the current x1
 * means treating x2 as if it had been sampled from the current x1 along
 * d_r = normalize(x2 - x1_cur). The source pdf in area measure is
 *
 *     p_source_r = pOmega(d_r) * |cos(phi2_r)| / |x2 - x1_cur|^2
 *
 * where phi2_r is the angle between x2's normal and the direction x2 -> x1_cur.
 * The incoming merge weight is corrected by the reconnection Jacobian
 * |J| = p_source_in / p_source_r, where p_source_in is the area-measure source pdf
 * stored in the incoming reservoir at sampling time.
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
    const float3 d_r = normalize(x2 - sd.posW);
    const float3 Lout = incoming.radianceWsum.xyz;

    // Re-evaluate the path throughput at the current x1 along the reconnected direction.
    const float3 f_r = mi.eval(sd, d_r, sg) * Lout;
    const float p_hat_r = luminance(f_r);
    if (p_hat_r <= 0.f)
        return result;

    // Reconnection Jacobian: convert the incoming sample's area-measure source pdf
    // (stored at sampling time) to the current x1. p_source_r is the probability of
    // sampling x2 from the current x1; |J| = p_source_in / p_source_r corrects the
    // reuse weight for the changed sampling measure.
    const float pOmega = mi.evalPdf(sd, d_r, kGIUseImportanceSampling);
    if (pOmega <= 0.f)
        return result; // Delta lobe: solid-angle pdf is undefined, skip reuse.

    const float3 v_r = x2 - sd.posW;
    const float cosPhi2_r = abs(dot(n2, -d_r)); // = |n2 . normalize(x1_cur - x2)|
    const float distR2 = dot(v_r, v_r);
    const float pSource_r = pOmega * cosPhi2_r / max(distR2, 1e-6f);
    const float jacobian = incoming.sourcePdfRes.x / pSource_r;

    // Cap the reusable sample count carried by the incoming reservoir.
    const uint incomingM = min(incoming.getM(), maxHistory);

    // Streaming resample step, matching mergeReservoir() in MyPTRestir.slang.
    // The incoming weight is additionally corrected by the reconnection Jacobian.
    const float sampleWeight_cur = cur.normalX1Pdf.w * cur.radianceWsum.w * float(cur.getM());
    const float sampleWeight_in = p_hat_r * incoming.radianceWsum.w * float(incomingM) * jacobian;
    const float weightSum = sampleWeight_cur + sampleWeight_in;
    const uint M_new = cur.getM() + incomingM;

    bool selectedCur = true;
    if (weightSum > 0.f && sampleNext1D(sg) * weightSum < sampleWeight_in)
    {
        // Incoming selected: x2, L_out, x2's normal and the source pdf all follow
        // the incoming sample (sourcePdfRes must match x2 for the next merge's Jacobian).
        result.posX2Dist = incoming.posX2Dist;
        result.radianceWsum = float4(incoming.radianceWsum.xyz, result.radianceWsum.w);
        result.normalX2Vis = incoming.normalX2Vis;
        result.sourcePdfRes = incoming.sourcePdfRes;
        selectedCur = false;
    }

    // Unbiased normalization, matching mergeReservoir() in MyPTRestir.slang.
    const float p_hat_at_cur = selectedCur ? cur.normalX1Pdf.w : p_hat_r;
    const float p_hat_at_prev = selectedCur ? cur.normalX1Pdf.w : incoming.normalX1Pdf.w;
    const float denom = float(cur.getM()) * p_hat_at_cur + float(incomingM) * p_hat_at_prev;
    const float newWeight = (denom > 0.f) ? weightSum / denom : 0.f;

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

    const float3 d = normalize(r.posX2Dist.xyz - sd.posW);
    return r.radianceWsum.w * mi.eval(sd, d, sg) * r.radianceWsum.xyz;
}
