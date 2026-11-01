/** Build one current-frame RIS light slot per thread, using RTXDI 1.3 Grid. */
#include "Scene/SceneDefines.slangh"
#ifndef RTPT_REGIR_ENABLED
#define RTPT_REGIR_ENABLED 1
#endif
#include "../ReSTIRDI/RTPTDISDK.slangh"

/** Exact uniform occurrence index, including non-power-of-two build counts.
    This uses an independent stream; a proposal-selection random word must not
    also choose which occurrence survives the uniform fallback.
*/
uint rtptReGIRUniformOccurrence(inout RAB_RandomSamplerState rng, uint count)
{
    const uint threshold = (0u - count) % count;
    uint random;
    do { random = rng.next(); } while (random < threshold);
    return random % count;
}

[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint slot = dispatchThreadID.x;
    if (slot >= gReGIRBuildSettings.slotCount) return;
    const RTXDI_ResamplingRuntimeParameters runtime = gReGIRRuntime;
    uint count, stride;
    gReGIRRIS.GetDimensions(count, stride);
    // Guard the whole buffer as well as the ReGIR interval. The SDK's invalid
    // cell path writes a zero and therefore cannot guard rounded dispatch tails.
    if (runtime.regirCommon.risBufferOffset >= count ||
        slot >= count - runtime.regirCommon.risBufferOffset) return;
    const uint address = runtime.regirCommon.risBufferOffset + slot;
    if (gDISettings.prepared == 0u || runtime.numLocalLights == 0u ||
        runtime.regirCommon.lightsPerCell == 0u || runtime.regirCommon.enable == 0u ||
        gReGIRBuildSettings.buildSamples == 0u)
    {
        // Do not enter SDK uniform sampling with a zero light count: its
        // numLocalLights-1 expression would underflow before loading a light.
        gReGIRRIS[address] = uint2(0u);
        return;
    }
    // The private guard replays the host's uniform catalogue proposals. It is
    // not an adapter for importance tiles: their per-proposal weights differ.
    // Host preparation rejects that unsupported mode before publishing a grid;
    // keep this shader fail-closed if called outside that host contract.
    if (runtime.enableLocalLightImportanceSampling != 0u)
    {
        gReGIRRIS[address] = uint2(0u);
        return;
    }
    RAB_RandomSamplerState rng = RAB_InitRandomSampler(uint2(slot & 0xfffu, slot >> 12u), 31u);
    RAB_RandomSamplerState coherentRng = RAB_InitRandomSampler(uint2(slot >> 8u, 0u), 32u);
    RAB_RandomSamplerState replayRng = rng;
    RAB_RandomSamplerState replayCoherentRng = coherentRng;
    RTXDI_PresampleLocalLightsForReGIR(rng, coherentRng, slot,
        gReGIRBuildSettings.buildSamples, runtime);

    float3 center;
    float radius;
    if (!RTXDI_ReGIR_CellIndexToWorldPos(runtime, int(slot / runtime.regirCommon.lightsPerCell), center, radius)) return;
    radius *= runtime.regirCommon.samplingJitter + 1.f;
    // Match the SDK's coherent tile draw, even though uniform source sampling
    // does not consume the selected tile. Copies leave the normal SDK stream
    // and its already written result unchanged.
    RAB_GetNextRandom(replayCoherentRng);
    RAB_RandomSamplerState choiceRng = RAB_InitRandomSampler(uint2(slot & 0xfffu, slot >> 12u), 33u);
    const uint occurrence = rtptReGIRUniformOccurrence(choiceRng, gReGIRBuildSettings.buildSamples);
    uint uniformLight = 0u;
    float minimumTarget = asfloat(0x7f7fffffu);
    float maximumTarget = 0.f;
    bool unsafe = false;
    for (uint i = 0u; i < gReGIRBuildSettings.buildSamples; ++i)
    {
        const float random = RAB_GetNextRandom(replayRng);
        const uint lightIndex = uint(min(random * runtime.numLocalLights, runtime.numLocalLights - 1u)) + runtime.firstLocalLight;
        const RAB_LightInfo light = RAB_LoadLightInfo(lightIndex, false);
        const float target = RAB_GetLightTargetPdfForVolume(light, center, radius);
        // The SDK consumes one selection random after each proposal target.
        RAB_GetNextRandom(replayRng);
        if (i == occurrence) uniformLight = lightIndex;
        if (!(target > 0.f) || !isfinite(target)) unsafe = true;
        else
        {
            minimumTarget = min(minimumTarget, target);
            maximumTarget = max(maximumTarget, target);
        }
    }
    unsafe |= maximumTarget > minimumTarget * 4096.f;
    if (unsafe)
    {
        // Reuse an independent uniform OCCURRENCE from these exact K source
        // proposals. Given the candidate set, N*f(selected) has expectation
        // (N/K)*sum(f(candidate)); therefore a set-dependent guard is valid.
        // A fresh global draw after detecting an unsafe set would not preserve
        // that conditional expectation. Positive/nonfinite target anomalies use
        // the same fallback; there is no brightness-based second light trial.
        gReGIRRIS[address] = uint2(uniformLight, asuint(float(runtime.numLocalLights)));
    }
}
