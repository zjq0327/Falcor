#pragma once

#ifndef RTPT_HAS_PRIMARY_HIT_INPUT
#define RTPT_HAS_PRIMARY_HIT_INPUT 0
#endif

#if RTPT_HAS_PRIMARY_HIT_INPUT
struct RTPTPrimaryHitParams
{
    uint viewValid;
    uint sampleIndex;
};
ConstantBuffer<RTPTPrimaryHitParams> gPrimaryHitParams;
Texture2D<uint4> gSharedPrimaryHit;

// The host validates the current-frame view; the exact sample index keeps a
// representative s=0 hit from replacing other subpixel samples in multi-spp PT.
// Returning true includes a cached miss, which must never trigger another ray.
bool rtptLoadSharedPrimaryHit(uint2 pixel, uint sampleIndex, out HitInfo hit)
{
    hit = {};
    if (gPrimaryHitParams.viewValid == 0u || gPrimaryHitParams.sampleIndex != sampleIndex) return false;
    const uint4 packedHit = gSharedPrimaryHit[pixel];
#if HIT_INFO_USE_COMPRESSION
    hit = HitInfo(packedHit.xy);
#else
    hit = HitInfo(packedHit);
#endif
    return true;
}
#endif
