#pragma once
#include "RTPTPrimarySurfaceTypes.slang"

#ifndef RTPT_USE_PRIMARY_SURFACE
#define RTPT_USE_PRIMARY_SURFACE 0
#endif

#if RTPT_USE_PRIMARY_SURFACE
ConstantBuffer<RTPTPrimarySettings> gPrimarySettings;
StructuredBuffer<RTPTPrimarySurface> gPrimarySurfaces;
#endif

/** A prepared miss is a valid reusable result. Only preparation or metadata
    failures request a new RayQuery. Explicit guards avoid evaluating a buffer
    load when the producer was not prepared (Falcor disables short circuiting).
*/
bool rtptTryLoadPrimary(uint2 pixel, uint sampleIndex, out RTPTPrimarySurface surface)
{
    surface = {};
#if RTPT_USE_PRIMARY_SURFACE
    if (gPrimarySettings.prepared == 0u) return false;
    if (any(gPrimarySettings.frameDim != gParams.frameDim)) return false;
    if (any(pixel >= gPrimarySettings.frameDim)) return false;
    if (sampleIndex != gPrimarySettings.sampleIndex) return false;
    uint count, stride;
    gPrimarySurfaces.GetDimensions(count, stride);
    const uint index = pixel.y * gPrimarySettings.frameDim.x + pixel.x;
    if (index >= count) return false;
    const RTPTPrimarySurface candidate = gPrimarySurfaces[index];
    if ((candidate.flags & kRTPTPrimaryRecordReady) == 0u) return false;
    if (candidate.sampleIndex != sampleIndex) return false;
    if (candidate.frameStamp != gPrimarySettings.frameStamp) return false;
    surface = candidate;
    return true;
#else
    return false;
#endif
}

// The non-NRD integrator still supplies its own camera ray and uses its
// original exact-ray check before sharing the primary intersection.
bool rtptTryLoadPrimary(uint2 pixel, uint sampleIndex, Ray ray, out RTPTPrimarySurface surface)
{
    surface = {};
    RTPTPrimarySurface candidate;
    if (!rtptTryLoadPrimary(pixel, sampleIndex, candidate)) return false;
    if (any(asuint(candidate.rayOrigin) != asuint(ray.origin))) return false;
    if (any(asuint(candidate.rayDirection) != asuint(ray.dir))) return false;
    if (asuint(candidate.rayTMin) != asuint(ray.tMin)) return false;
    if (asuint(candidate.rayTMax) != asuint(ray.tMax)) return false;
    surface = candidate;
    return true;
}
