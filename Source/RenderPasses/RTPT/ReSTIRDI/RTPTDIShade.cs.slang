/** Reconstruct one final light, trace one current shadow, evaluate true D/S. */
#include "Scene/SceneDefines.slangh"
#define RTPT_DI_WRITE_RESULTS 1
#if RTPT_DI_REUSE_ENABLED
#define RTPT_DI_WRITE_RESERVOIRS 1
#define RTPT_DI_WRITE_SAMPLE_RECORDS 1
#include "RTPTDIReuseSDK.slangh"
#else
#include "RTPTDISDK.slangh"
#endif

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDISettings.frameDim)) return;
    const uint pixelIndex = pixel.y * gDISettings.frameDim.x + pixel.x;
    uint index = pixelIndex;
#if RTPT_DI_REUSE_ENABLED
    index += gDIReuseSettings.finalInputBank * gDISettings.frameDim.x * gDISettings.frameDim.y;
#endif
    RTPTDIResult result = {};
    result.generation = gDISettings.generation;
    result.sampleIndex = gDISettings.sampleIndex;
    result.frameStamp = gDISettings.frameStamp;
    result.coverageMask = gDISettings.coverageMask;

    const RTPTDISampleRecord record = gDISampleRecords[index];
    RAB_Surface surface;
    const bool primaryPrepared = rtptDILoadSurface(pixel, surface);
    bool prepared = primaryPrepared;
    if (record.sampleIndex != gDISettings.sampleIndex) prepared = false;
    if (record.frameStamp != gDISettings.frameStamp) prepared = false;
    // sample.generation belongs to the selected light identity, not the bank's
    // preparation metadata. A stale selected identity must retain DI ownership
    // and reach rtptDIMatchesSampleRef(), rather than retry the old root NEE.
    if (record.coverageMask != gDISettings.coverageMask) prepared = false;
    if ((record.flags & kRTPTDIResultPrepared) == 0u) prepared = false;
    if (prepared) result.flags = kRTPTDIResultPrepared;

    RTXDI_Reservoir reservoir = RTXDI_UnpackReservoir(gDIReservoirs[index]);
#if RTPT_DI_REUSE_ENABLED
    // A temporary token is needed only when materializing the history sidecar.
    if (RTXDI_IsValidReservoir(reservoir)) reservoir.uvData = index;
#endif
    if (prepared && surface.valid && RTXDI_IsValidReservoir(reservoir))
    {
        const uint lightIndex = RTXDI_GetReservoirLightIndex(reservoir);
        if (lightIndex < gDISettings.lightCount)
        {
            const RTPTDILightInfo light = RAB_LoadLightInfo(lightIndex, false);
            if (rtptDIMatchesSampleRef(light, record.sample))
            {
                // Keep the Initial winner's full float2 UV sidecar. SDK's
                // packed 16-bit uvData is left intact but not re-quantized here.
                const RAB_LightSample sample = RAB_SamplePolymorphicLight(light, surface, record.sample.sampleUV);
                if (sample.valid)
                {
                    result.flags |= kRTPTDIResultSampleValid;
                    result.lightDistance = sample.distance;
                    const float inversePdf = RTXDI_GetReservoirInvPdf(reservoir);
                    const float3 weightedLi = sample.Li * inversePdf;
                    if (inversePdf > 0.f && isfinite(inversePdf) && all(isfinite(weightedLi)))
                    {
                        // Both lobes use this one current visibility query.
                        if (RAB_GetConservativeVisibility(surface, sample))
                        {
                            result.flags |= kRTPTDIResultVisible;
                            SampleGenerator sg = RAB_InitRandomSampler(pixel, 29u);
                            rtptDIEvaluateComponents(surface, sample, weightedLi, sg, result.diffuse, result.specular);
                            if (!all(isfinite(result.diffuse))) result.diffuse = 0.f;
                            if (!all(isfinite(result.specular))) result.specular = 0.f;
                        }
                    }
                }
            }
            else result.flags |= kRTPTDIResultInvalidIdentity;
        }
        else result.flags |= kRTPTDIResultInvalidIdentity;
    }
    // Empty, black, occluded, or invalid selected samples keep Prepared. Only
    // preparation metadata can restore the old estimator's contribution domain.
    gDIResults[pixelIndex] = result;
#if RTPT_DI_REUSE_ENABLED
    const uint historyInput = gDIReuseSettings.historyInputBank;
    bool historyPrepared = primaryPrepared && historyInput != gDIReuseSettings.historyBank;
    if (historyPrepared) historyPrepared = rtptDIIsBankPrepared(pixel, historyInput);
    RTXDI_Reservoir historyReservoir = RTXDI_EmptyReservoir();
    if (historyInput == gDIReuseSettings.finalInputBank)
    {
        // Keep the original single-source publication path for Temporal-only
        // and explicit Spatial-history regression tests, including visibility.
        historyPrepared = historyPrepared && prepared;
        if (historyPrepared) historyReservoir = reservoir;
        if (RTXDI_IsValidReservoir(historyReservoir))
        {
            const bool visible = (result.flags & kRTPTDIResultVisible) != 0u;
            RTXDI_StoreVisibilityInReservoir(historyReservoir, visible ? float3(1.f) : float3(0.f), true);
        }
    }
    else if (historyPrepared)
    {
        // The independently prepared Temporal bank has already tested current
        // visibility. Its winner may be a different light from Spatial's, so
        // Spatial's shading/visibility flags cannot validate or discard it.
        historyReservoir = RTXDI_LoadReservoir(rtptDIReuseRuntimeParameters(), pixel, historyInput);
        if (!surface.valid && RTXDI_IsValidReservoir(historyReservoir))
            RTXDI_StoreVisibilityInReservoir(historyReservoir, float3(0.f), true);
    }
    // Temporal has finished reading history. Current banks contain their own
    // copied full-UV references, so publication cannot overwrite a source UV.
    rtptDIStoreReuseReservoir(pixel, gDIReuseSettings.historyBank, historyReservoir, historyPrepared);
#endif
}
