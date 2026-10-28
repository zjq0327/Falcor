#pragma once
#include "RTPTLocalLightResources.slang"

uint rtptLocalHash(uint x)
{
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}
float rtptLocalUniform(uint x) { return float(rtptLocalHash(x) >> 8) * (1.f / 16777216.f); }
int3 rtptLocalCellKey(float3 positionW)
{
    return int3(clamp(floor((positionW-gLocalLightParams.fullOrigin)/gLocalLightParams.fullCellExtent), float3(0), float3(gLocalLightParams.fullDim-1u)));
}
uint rtptLocalFindCell(float3 positionW)
{
    if (gLocalLightParams.gridEnabled == 0 || !all(isfinite(positionW))) return RTPT_LOCAL_LIGHT_INVALID;
    const int3 key = rtptLocalCellKey(positionW);
    const uint cell = uint(key.x) + gLocalLightParams.fullDim.x*(uint(key.y)+gLocalLightParams.fullDim.y*uint(key.z));
    return gLocalGridState[cell].y == gLocalLightParams.gridGeneration ? cell : RTPT_LOCAL_LIGHT_INVALID;
}
