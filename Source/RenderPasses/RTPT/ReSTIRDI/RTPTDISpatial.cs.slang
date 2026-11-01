/** Independent SDK 1.3 Spatial input/output banks; source UV stays full float. */
#include "Scene/SceneDefines.slangh"
#define RTPT_DI_WRITE_RESERVOIRS 1
#define RTPT_DI_WRITE_SAMPLE_RECORDS 1
#include "RTPTDIReuseSDK.slangh"

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
        const RTXDI_Reservoir center = RTXDI_LoadReservoir(params, pixel, gDIReuseSettings.inputBank);
        gDITemporalMaterialGate = false;
        RTXDI_SpatialResamplingParameters spatial = {};
        spatial.sourceBufferIndex = gDIReuseSettings.inputBank;
        spatial.numSamples = gDIReuseSettings.spatialSamples;
        spatial.numDisocclusionBoostSamples = gDIReuseSettings.spatialSamples;
        spatial.targetHistoryLength = gDIReuseSettings.maxHistoryLength;
        spatial.biasCorrectionMode = RTXDI_BIAS_CORRECTION_RAY_TRACED;
        spatial.samplingRadius = gDIReuseSettings.spatialRadius;
        spatial.depthThreshold = gDIReuseSettings.depthThreshold;
        spatial.normalThreshold = gDIReuseSettings.normalThreshold;
        RAB_RandomSamplerState rng = RAB_InitRandomSampler(pixel, 53u);
        RAB_LightSample selectedSample = RAB_EmptyLightSample();
        reservoir = RTXDI_SpatialResampling(pixel, surface, center, rng, spatial, params, selectedSample);
        rtptDIFilterReuseVisibility(reservoir, surface);
    }
    rtptDIStoreReuseReservoir(pixel, gDIReuseSettings.outputBank, reservoir, prepared);
}
