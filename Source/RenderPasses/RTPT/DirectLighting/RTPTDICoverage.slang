#pragma once

/** Establish domain ownership before sampling the original NEE/continuations.
    Prepared is independent of whether the final reservoir is empty, black or
    occluded. No brightness or winner-validity test may select the estimator.
*/
uint rtptLoadPrimaryDICoverage(uint2 pixel, uint sampleIndex, out float3 diffuse, out float3 specular)
{
    diffuse = specular = 0.f;
#if RTPT_USE_RESTIR_DI
    if (gParams.useNEE == 0u) return 0u;
    if (gDISettings.prepared == 0u) return 0u;
    if (any(gDISettings.frameDim != gParams.frameDim)) return 0u;
#if RTPT_USE_PRIMARY_SURFACE
    if (gDISettings.frameStamp != gPrimarySettings.frameStamp) return 0u;
#endif
    if (any(pixel >= gDISettings.frameDim)) return 0u;
    if (sampleIndex != gDISettings.sampleIndex) return 0u;
    uint count, stride;
    gDIResults.GetDimensions(count, stride);
    const uint index = pixel.y * gDISettings.frameDim.x + pixel.x;
    if (index >= count) return 0u;
    const RTPTDIResult result = gDIResults[index];
    if ((result.flags & kRTPTDIResultPrepared) == 0u) return 0u;
    if (result.generation != gDISettings.generation) return 0u;
    if (result.sampleIndex != sampleIndex) return 0u;
    if (result.frameStamp != gDISettings.frameStamp) return 0u;
    if (result.coverageMask != gDISettings.coverageMask) return 0u;
    diffuse = result.diffuse;
    specular = result.specular;
    return result.coverageMask;
#else
    return 0u;
#endif
}
