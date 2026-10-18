#pragma once

// Shared SHaRC logarithmic grid convention, without a dependency on its payload.
uint rtptGridHash32(uint value)
{
    value = (value + 0x7ed55d16u) + (value << 12u);
    value = (value ^ 0xc761c23cu) ^ (value >> 19u);
    value = (value + 0x165667b1u) + (value << 5u);
    value = (value + 0xd3a2646cu) ^ (value << 9u);
    value = (value + 0xfd7046c5u) + (value << 3u);
    return (value ^ 0xb55a4f09u) ^ (value >> 16u);
}

uint rtptGridKeyHash(uint2 key) { return rtptGridHash32(key.x) ^ rtptGridHash32(key.y); }
uint64_t rtptGridPackKey(uint2 key) { return uint64_t(key.x) | (uint64_t(key.y) << 32u); }

uint2 rtptGridKey(float3 position, float3 normal, float3 cameraPosition, float sceneScale, uint coarseLevels)
{
    const float3 biasedPosition = position + float3(1e-4f);
    const float3 offset = cameraPosition - biasedPosition;
    const float distanceSquared = max(dot(offset, offset), 1e-10f);
    uint level = uint(clamp(0.5f * log2(distanceSquared), 1.f, 511.f));
    level = min(511u, level + min(coarseLevels, 510u));
    const float voxelSize = exp2(float(level)) / max(sceneScale, 1e-20f);
    const uint3 cell = uint3(int3(floor(biasedPosition / voxelSize)));
    uint64_t key = uint64_t(cell.x & 0x1ffffu) |
        (uint64_t(cell.y & 0x1ffffu) << 17u) |
        (uint64_t(cell.z & 0x1ffffu) << 34u) |
        (uint64_t(level) << 51u);
    const uint normalBits = (normal.x + 1e-3f >= 0.f ? 0u : 1u) |
        (normal.y + 1e-3f >= 0.f ? 0u : 2u) |
        (normal.z + 1e-3f >= 0.f ? 0u : 4u);
    key |= uint64_t(normalBits) << 60u;
    return uint2(uint(key), uint(key >> 32u));
}
