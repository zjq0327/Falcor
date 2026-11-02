/** Build current-light RIS slots using only a cell's complete candidate list. */
#include "Scene/SceneDefines.slangh"
#ifndef RTPT_REGIR_ENABLED
#define RTPT_REGIR_ENABLED 1
#endif
#include "../ReSTIRDI/RTPTDISDK.slangh"
#include "RTPTReGIRCellLists.slang"

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
    if (slot >= gReGIRSettings.slotCount) return;
    gReGIRRIS[slot] = uint2(0u);
    const uint cell = slot / gReGIRSettings.lightsPerCell;
    const RTPTReGIRCellView view = rtptReGIRGetStoredCellView(cell);
    if (view.ready == 0u) return;
    if (slot % gReGIRSettings.lightsPerCell == 0u)
        gReGIRCellRISFrame[cell] = gReGIRSettings.frameStamp;
    if (view.count == 0u || gReGIRSettings.buildSamples == 0u) return;

    RAB_RandomSamplerState proposals = RAB_InitRandomSampler(uint2(slot & 0xfffu, slot >> 12u), 31u);
    RAB_RandomSamplerState selection = RAB_InitRandomSampler(uint2(slot & 0xfffu, slot >> 12u), 32u);
    RAB_RandomSamplerState uniform = RAB_InitRandomSampler(uint2(slot & 0xfffu, slot >> 12u), 33u);
    uint surviving = 0u, uniformLight = 0u, selectedLight = 0u;
    float selectedTarget = 0.f, weightSum = 0.f;
    float minimumTarget = asfloat(0x7f7fffffu), maximumTarget = 0.f;
    bool unsafe = false;
    for (uint i = 0u; i < gReGIRSettings.buildSamples; ++i)
    {
        const uint rank = rtptReGIRUniformOccurrence(proposals, view.count);
        const uint lightIndex = rtptReGIRLoadCandidate(view, rank);
        if (lightIndex >= gReGIRSettings.lightCount) continue;
        const RAB_LightInfo light = RAB_LoadLightInfo(lightIndex, false);
        ++surviving;
        if (rtptReGIRUniformOccurrence(uniform, surviving) == 0u) uniformLight = lightIndex;
        const float target = RAB_GetLightTargetPdfForVolume(light, view.center, length(view.halfExtent));
        if (!(target > 0.f) || !isfinite(target)) { unsafe = true; continue; }
        minimumTarget = min(minimumTarget, target);
        maximumTarget = max(maximumTarget, target);
        weightSum += target;
        if (RAB_GetNextRandom(selection) * weightSum < target)
        {
            selectedLight = lightIndex;
            selectedTarget = target;
        }
    }
    if (surviving == 0u) return;
    unsafe |= maximumTarget > minimumTarget * 4096.f || !isfinite(weightSum);
    // N is the number of candidates in THIS CELL, never the global catalogue size.
    const float sourceWeight = float(view.count) / float(gReGIRSettings.buildSamples);
    if (unsafe)
        gReGIRRIS[slot] = uint2(uniformLight, asuint(sourceWeight * float(surviving)));
    else if (selectedTarget > 0.f)
        gReGIRRIS[slot] = uint2(selectedLight, asuint(sourceWeight * (weightSum / selectedTarget)));
}
