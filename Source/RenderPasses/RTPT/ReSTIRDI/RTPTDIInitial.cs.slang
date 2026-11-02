/** Global Initial when ReGIR is disabled; otherwise cell-only Initial RIS. */
#include "Scene/SceneDefines.slangh"
#define RTPT_DI_WRITE_RESERVOIRS 1
#define RTPT_DI_WRITE_SAMPLE_RECORDS 1
#include "RTPTDISDK.slangh"
#if RTPT_REGIR_ENABLED
#include "../ReGIR/RTPTReGIRCellLists.slang"

uint rtptDIUniformCellRank(inout RAB_RandomSamplerState rng, uint count)
{
    const uint threshold = (0u - count) % count;
    uint value;
    do { value = rng.next(); } while (value < threshold);
    return value % count;
}

RTXDI_Reservoir rtptDISampleCellCandidates(inout RAB_RandomSamplerState rng,
    RAB_Surface surface, RTPTReGIRCellView view, out RAB_LightSample selectedSample)
{
    RTXDI_Reservoir reservoir = RTXDI_EmptyReservoir();
    selectedSample = RAB_EmptyLightSample();
    if (view.ready == 0u || view.count == 0u) return reservoir;
    for (uint i = 0u; i < gDISettings.candidateCount; ++i)
    {
        const uint lightIndex = rtptReGIRLoadCandidate(view, rtptDIUniformCellRank(rng, view.count));
        const float2 uv = float2(RAB_GetNextRandom(rng), RAB_GetNextRandom(rng));
        const RAB_LightSample sample = RAB_SamplePolymorphicLight(RAB_LoadLightInfo(lightIndex, false), surface, uv);
        const float target = RAB_GetLightSampleTargetPdfForSurface(sample, surface);
        if (RTXDI_StreamSample(reservoir, lightIndex, uv, RAB_GetNextRandom(rng), target, float(view.count)))
            selectedSample = sample;
    }
    RTXDI_FinalizeResampling(reservoir, 1.f, float(gDISettings.candidateCount));
    reservoir.M = 1.f;
    return reservoir;
}
#endif

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
#if RTPT_REGIR_ENABLED
            const float3 jitter = float3(RAB_GetNextRandom(rng), RAB_GetNextRandom(rng), RAB_GetNextRandom(rng));
            const RTPTReGIRCellView view = rtptReGIRGetCellView(surface.sd.posW, jitter);
            bool currentRIS = false;
            // Falcor's shader settings do not guarantee short-circuit loads.
            if (view.ready != 0u && view.cell != kRTPTReGIRInvalidCell)
                currentRIS = gReGIRCellRISFrame[view.cell] == gReGIRSettings.frameStamp;
            if (currentRIS)
                reservoir = RTXDI_SampleLocalLightsInternal(rng, surface, samples,
                    rtptDIInitialRuntimeParameters(), true, view.cell * gReGIRSettings.lightsPerCell,
                    gReGIRSettings.lightsPerCell, selectedSample);
            else
                // First use establishes a complete cell list before drawing a
                // local rank. No unordered/global-light proposal is available.
                reservoir = rtptDISampleCellCandidates(rng, surface, view, selectedSample);
#else
            reservoir = RTXDI_SampleLightsForSurface(rng, coherentRng, surface,
                samples, rtptDIInitialRuntimeParameters(), selectedSample);
#endif
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
