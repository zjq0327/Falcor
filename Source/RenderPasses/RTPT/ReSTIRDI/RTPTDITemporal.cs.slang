/** SDK 1.3 Temporal with full-precision sample references and real visibility. */
#include "Scene/SceneDefines.slangh"
#define RTPT_DI_WRITE_RESERVOIRS 1
#define RTPT_DI_WRITE_SAMPLE_RECORDS 1
#include "RTPTDIReuseSDK.slangh"
#include "RTPTDIReprojection.slangh"

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDISettings.frameDim)) return;
    if (gDIReuseSettings.outputBank == gDIReuseSettings.inputBank) return;
    if (gDIReuseSettings.outputBank == gDIReuseSettings.historyBank) return;
    RAB_Surface surface;
    bool prepared = rtptDILoadSurface(pixel, surface);
    if (!rtptDIIsBankPrepared(pixel, gDIReuseSettings.inputBank)) prepared = false;
    const RTXDI_ResamplingRuntimeParameters params = rtptDIReuseRuntimeParameters();
    RTXDI_Reservoir reservoir = RTXDI_EmptyReservoir();
    if (prepared && surface.valid)
    {
        reservoir = RTXDI_LoadReservoir(params, pixel, gDIReuseSettings.inputBank);
        float3 motion = 0.f;
        bool reuse = gDIReuseSettings.enabled != 0u && gDIReuseSettings.historyValid != 0u;
        if (reuse)
        {
            const uint index = pixel.y * gDISettings.frameDim.x + pixel.x;
            reuse = rtptDIComputeMotion(gDIPrimarySurfaces[index], pixel, gDISettings.frameDim,
                gDIReuseSettings.previousViewProj, motion);
        }
        if (reuse)
        {
            gDITemporalMaterialID = surface.materialID;
            gDITemporalMaterialGate = true;
            RTXDI_TemporalResamplingParameters temporal = {};
            temporal.screenSpaceMotion = motion;
            temporal.sourceBufferIndex = gDIReuseSettings.historyBank;
            temporal.maxHistoryLength = gDIReuseSettings.maxHistoryLength;
            temporal.biasCorrectionMode = RTXDI_BIAS_CORRECTION_RAY_TRACED;
            temporal.depthThreshold = gDIReuseSettings.depthThreshold;
            temporal.normalThreshold = gDIReuseSettings.normalThreshold;
            temporal.enableVisibilityShortcut = false;
            temporal.enablePermutationSampling = false;
            RAB_RandomSamplerState rng = RAB_InitRandomSampler(pixel, 41u);
            RAB_LightSample selectedSample = RAB_EmptyLightSample();
            int2 previousPixel;
            reservoir = RTXDI_TemporalResampling(pixel, surface, reservoir, rng,
                temporal, params, previousPixel, selectedSample);
            rtptDIFilterReuseVisibility(reservoir, surface);
        }
    }
    rtptDIStoreReuseReservoir(pixel, gDIReuseSettings.outputBank, reservoir, prepared);
}
