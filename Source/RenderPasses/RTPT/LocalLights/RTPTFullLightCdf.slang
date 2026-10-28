#pragma once

// Exactly the domain of the uniform generator's upper 24 bits. One mandatory
// bin per catalog light prevents zero intervals, including after quantization.
static const uint RTPT_FULL_CDF_BINS = 1u << 24u;
float rtptFullSanitizeWeight(float weight) { return isfinite(weight) ? max(0.f, weight) : 0.f; }
uint rtptFullCdfPrefix(uint entry, uint count, float cumulative, float total, uint previous)
{
    if (entry + 1u == count) return RTPT_FULL_CDF_BINS;
    const uint residual = RTPT_FULL_CDF_BINS - count;
    const float fraction = total > 0.f ? saturate(cumulative / total) : float(entry + 1u) / float(count);
    // Reserve one bin for every remaining light. Clamping also bounds floating
    // point summation/rounding error without reducing any light's support.
    const uint desired = entry + 1u + uint(floor(float(residual) * fraction));
    return clamp(desired, previous + 1u, RTPT_FULL_CDF_BINS - (count - entry - 1u));
}
uint rtptFullCdfUpperBound(RWStructuredBuffer<uint> cdf, uint base, uint count, uint sample)
{
    uint lo = 0u, hi = count;
    while (lo < hi)
    {
        const uint mid = lo + (hi-lo)/2u;
        if (cdf[base+mid] <= sample) lo = mid+1u;
        else hi = mid;
    }
    return lo;
}
uint rtptFullCdfLinear(RWStructuredBuffer<uint> values, uint base, uint count, uint sample, bool cdf)
{
    uint prefix = 0u;
    for (uint i=0u; i<count; ++i)
    {
        prefix = cdf ? values[base+i] : prefix+values[base+i];
        if (sample < prefix) return i;
    }
    return count;
}
uint rtptFullCdfMass(RWStructuredBuffer<uint> values, uint base, uint entry, bool cdf)
{
    return cdf ? values[base+entry] - (entry == 0u ? 0u : values[base+entry-1u]) : values[base+entry];
}
