#pragma once
#include "RTPTVXPGDiagnostics.slang"

// Spatial convention matches SHaRC's uncompressed position/level calculation.
// This module has no SHaRC state, normal buckets, or cache lifetime dependency.
static const float RTPT_VXPG_POSITION_BIAS = 1.e-4f;

uint rtptVXPGDistanceLevel(float3 position, float3 camera)
{
    const float3 offset = camera - (position + RTPT_VXPG_POSITION_BIAS);
    return uint(clamp(0.5f * log2(max(dot(offset, offset), 1.e-10f)), 1.f, 511.f));
}

float rtptVXPGLevelSize(uint level, float sceneScale)
{
    return exp2(float(level)) * rcp(sceneScale);
}

bool rtptVXPGDistanceKey(float3 position, float3 camera, float sceneScale, out int4 key)
{
    key = 0;
    const float3 p = position + RTPT_VXPG_POSITION_BIAS;
    const float3 delta = camera - p;
    if (!all(isfinite(p)) || !all(isfinite(delta)) || !isfinite(dot(delta,delta))) return false;
    const uint level = rtptVXPGDistanceLevel(position, camera);
    const float size = rtptVXPGLevelSize(level, sceneScale);
    if (!(size > 0.f) || !isfinite(size)) return false;
    const float3 xyz = floor(p * rcp(size));
    if (!all(isfinite(xyz)) || any(xyz < -8388608.f) || any(xyz >= 8388608.f)) return false;
    key = int4(int3(xyz), int(level));
    return true;
}


// Sparse grid identity and lookup. The position/LOD rules above share no SHaRC state.
uint rtptVXPGHash(uint x)
{
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}
float rtptVXPGUniform(uint x) { return float(rtptVXPGHash(x) >> 8) * (1.f / 16777216.f); }

bool rtptVXPGTryOwnerKey(float3 position, out int4 key)
{
    return rtptVXPGDistanceKey(position, gVXPGParams.lodCamera, gVXPGParams.lodSceneScale, key);
}

uint rtptVXPGKeyHash(int4 key)
{
    return rtptVXPGHash(asuint(key.x) ^ rtptVXPGHash(asuint(key.y) ^
        rtptVXPGHash(asuint(key.z) ^ rtptVXPGHash(uint(key.w)))));
}

int3 rtptVXPGCellKey(uint cell)
{
    return gVXPGCellKeys[cell].xyz;
}
int4 rtptVXPGCellIdentity(uint cell)
{
    return gVXPGCellKeys[cell];
}
float rtptVXPGCellSize(uint cell)
{
    return rtptVXPGLevelSize(uint(rtptVXPGCellIdentity(cell).w), gVXPGParams.lodSceneScale);
}
float rtptVXPGSurfaceSize(float3 position)
{
    return rtptVXPGLevelSize(rtptVXPGDistanceLevel(position, gVXPGParams.lodCamera), gVXPGParams.lodSceneScale);
}
uint rtptVXPGGeometryCount()
{
    return min(gVXPGState[RTPT_VXPG_STATE_OCCUPIED],gVXPGParams.cellCount);
}
uint rtptVXPGFindKey(int4 key)
{
    const uint first = rtptVXPGKeyHash(key);
    rtptVXPGCount(RTPT_VXPG_STATE_OWNER_QUERIES);
    for (uint probe=0;probe<128;++probe)
    {
        rtptVXPGCount(RTPT_VXPG_STATE_OWNER_PROBES);
#if RTPT_VXPG_DETAILED_DIAGNOSTICS
        InterlockedMax(gVXPGState[RTPT_VXPG_STATE_OWNER_MAX_PROBES],probe+1u);
#endif
        const uint slot=(first+probe)&(gVXPGParams.hashCapacity-1);
        const uint entry=gVXPGHashSlots[slot];
        if (entry==0) return RTPT_VXPG_INVALID;
        const uint cell=entry-1;
        if (cell>=rtptVXPGGeometryCount())continue;
        if (gVXPGBoundMin[cell].w!=0 && all(gVXPGCellKeys[cell]==key)) return cell;
    }
    return RTPT_VXPG_INVALID;
}
uint rtptVXPGOwner(float3 position)
{
    int4 key;
    if(gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW]!=0 || !rtptVXPGTryOwnerKey(position,key))return RTPT_VXPG_INVALID;
    return rtptVXPGFindKey(key);
}
float3 rtptVXPGWorldMin(uint cell)
{
    return gVXPGParams.gridMin + (float3(rtptVXPGCellKey(cell))+asfloat(gVXPGBoundMin[cell].xyz)) * rtptVXPGCellSize(cell);
}
float3 rtptVXPGWorldMax(uint cell)
{
    return gVXPGParams.gridMin + (float3(rtptVXPGCellKey(cell))+asfloat(gVXPGBoundMax[cell].xyz)) * rtptVXPGCellSize(cell);
}
