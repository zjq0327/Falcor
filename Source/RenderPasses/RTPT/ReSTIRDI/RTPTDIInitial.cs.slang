/** Global uniform Initial RIS using the installed SDK, without visibility. */
#include "Scene/SceneDefines.slangh"
#define RTPT_DI_WRITE_RESERVOIRS 1
#define RTPT_DI_WRITE_SAMPLE_RECORDS 1
#include "RTPTDISDK.slangh"

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDISettings.frameDim)) return;
    const uint index = pixel.y * gDISettings.frameDim.x + pixel.x;
    RTXDI_Reservoir reservoir = RTXDI_EmptyReservoir();
    RTPTDISampleRecord record = {};
    record.sample.generation = gDISettings.generation;
    record.sampleIndex = gDISettings.sampleIndex;
    record.frameStamp = gDISettings.frameStamp;
    record.coverageMask = gDISettings.coverageMask;

    RAB_Surface surface;
    const bool primaryPrepared = rtptDILoadSurface(pixel, surface);
    if (primaryPrepared && gDISettings.candidateCount > 0u)
    {
        record.flags = kRTPTDIResultPrepared;
        if (surface.valid)
        {
            RAB_RandomSamplerState rng = RAB_InitRandomSampler(pixel, 2u);
            RAB_RandomSamplerState coherentRng = RAB_InitRandomSampler(pixel / 16u, 3u);
            const RTXDI_SampleParameters samples = RTXDI_InitSampleParameters(
                0u, gDISettings.candidateCount, 0u, 0u, 0u);
            RAB_LightSample selectedSample;
            reservoir = RTXDI_SampleLightsForSurface(rng, coherentRng, surface,
                samples, rtptDIInitialRuntimeParameters(), selectedSample);
            // The high-level SDK function already finalized and set M=1.
            // Do not normalize again or reinterpret streaming weightSum here.
#if RTPT_DI_REUSE_ENABLED
            // Source visibility filtering matches the RayTraced correction's
            // support convention. A failed shadow remains a counted trial.
            if (gDIReuseSettings.enabled != 0u && RTXDI_IsValidReservoir(reservoir))
            {
                const bool visible = RAB_GetConservativeVisibility(surface, selectedSample);
                RTXDI_StoreVisibilityInReservoir(reservoir, visible ? float3(1.f) : float3(0.f), true);
            }
#endif
            if (RTXDI_IsValidReservoir(reservoir))
            {
                const uint lightIndex = RTXDI_GetReservoirLightIndex(reservoir);
                if (lightIndex < gDISettings.lightCount)
                {
                    const RTPTDILightInfo light = RAB_LoadLightInfo(lightIndex, false);
                    record.sample = rtptDIMakeSampleRef(light, selectedSample.sampleUV);
                    record.flags |= kRTPTDIResultSampleValid;
                }
            }
        }
    }
    // Always overwrite sky, empty and preparation-failed pixels. This bank is
    // row-major for Initial-only use; SDK block-linear history is not enabled.
    gDIReservoirs[index] = RTXDI_PackReservoir(reservoir);
    gDISampleRecords[index] = record;
}
