#pragma once

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

