#pragma once
#include "RTPTReGIRResources.slang"
#include "../RTPTGrid.slang"

static const uint kRTPTReGIRInvalidCell = 0xffffffffu;
static const uint kRTPTReGIRBucketSize = 64u;
static const uint64_t kRTPTReGIRTombstone = ~uint64_t(0u);

// Level 1 is the finest ReGIR level. Keeping it nonzero also reserves key 0
// as the empty hash entry, including for the cell containing the world origin.
uint rtptReGIRLevel(float3 position, float3 cameraPosition, float baseCellSize, float coarsenCellDistance)
{
    if (!all(isfinite(position)) || !all(isfinite(cameraPosition)) ||
        !(baseCellSize > 0.f) || !isfinite(baseCellSize) ||
        !(coarsenCellDistance >= 1.f) || !isfinite(coarsenCellDistance)) return 0u;
    const float firstTransition = baseCellSize * coarsenCellDistance;
    const float3 offset = position - cameraPosition;
    const float largestOffset = max(abs(offset.x), max(abs(offset.y), abs(offset.z)));
    const float distance = largestOffset == 0.f ? 0.f : largestOffset * length(offset / largestOffset);
    if (!(firstTransition > 0.f) || !isfinite(firstTransition) || !isfinite(distance)) return 0u;
    if (distance < firstTransition) return 1u;
    return min(511u, 2u + uint(floor(log2(distance / firstTransition))));
}

float rtptReGIRVoxelSize(uint level, float baseCellSize)
{
    return level == 0u ? 0.f : baseCellSize * exp2(float(level - 1u));
}

bool rtptReGIRGetQueryBounds(float3 position, float3 random, float3 cameraPosition,
    float baseCellSize, float coarsenCellDistance, float samplingJitter,
    out uint64_t key, out float3 center, out float3 halfExtent)
{
    key = 0u;
    center = halfExtent = float3(0.f);
    if (!all(isfinite(random)) || !isfinite(samplingJitter) || samplingJitter < 0.f) return false;
    const uint level = rtptReGIRLevel(position, cameraPosition, baseCellSize, coarsenCellDistance);
    const float size = rtptReGIRVoxelSize(level, baseCellSize);
    if (level == 0u || !(size > 0.f) || !isfinite(size)) return false;
    // The receiver chooses its LOD before jitter. Crossing a LOD boundary with
    // the jitter must not change the key's level or invalidate its bounds.
    const float3 coordinate = floor((position + float3(1e-4f) +
        (clamp(random, 0.f, 1.f) - 0.5f) * (samplingJitter * size)) * rcp(size));
    if (!all(isfinite(coordinate))) return false;
    center = (coordinate + 0.5f) * size - float3(1e-4f);
    const float extent = 0.5f * size * (1.f + samplingJitter);
    const float margin = 1e-5f * (1.f + max(abs(center.x), max(abs(center.y), abs(center.z))) + extent);
    halfExtent = float3(extent + margin);
    if (!all(isfinite(center)) || !all(isfinite(halfExtent))) return false;
    // A cell outside the compact key range is still a valid query volume.
    // key 0 requests a complete procedural cell view instead of aliasing a
    // distant cell or dropping the receiver's light support.
    if (all(coordinate >= -65536.f) && all(coordinate <= 65535.f))
    {
        const uint3 cell = uint3(int3(coordinate));
        key = uint64_t(cell.x & 0x1ffffu) |
            (uint64_t(cell.y & 0x1ffffu) << 17u) |
            (uint64_t(cell.z & 0x1ffffu) << 34u) | (uint64_t(level) << 51u);
    }
    return true;
}

bool rtptReGIRGetQueryBounds(float3 position, float3 random,
    out uint64_t key, out float3 center, out float3 halfExtent)
{
    return rtptReGIRGetQueryBounds(position, random, gReGIRSettings.cameraPosition,
        gReGIRSettings.baseCellSize, gReGIRSettings.coarsenCellDistance,
        gReGIRSettings.samplingJitter, key, center, halfExtent);
}

bool rtptReGIRWorldToCellKey(float3 position, float3 random, float3 cameraPosition,
    float baseCellSize, float coarsenCellDistance, float samplingJitter, out uint64_t key)
{
    float3 center, halfExtent;
    return rtptReGIRGetQueryBounds(position, random, cameraPosition,
        baseCellSize, coarsenCellDistance, samplingJitter, key, center, halfExtent) && key != 0u;
}

bool rtptReGIRCellKey(float3 position, float3 random, out uint64_t key)
{
    return rtptReGIRWorldToCellKey(position, random, gReGIRSettings.cameraPosition,
        gReGIRSettings.baseCellSize, gReGIRSettings.coarsenCellDistance, gReGIRSettings.samplingJitter, key);
}

bool rtptReGIRCellBounds(uint64_t key, float baseCellSize, float samplingJitter,
    out float3 center, out float3 halfExtent)
{
    if (key == uint64_t(0u) || key == kRTPTReGIRTombstone)
    {
        center = halfExtent = float3(0.f);
        return false;
    }
    const uint level = uint((key >> 51u) & 511u);
    const float size = rtptReGIRVoxelSize(level, baseCellSize);
    const int3 cell = int3(int(key & 0x1ffffu), int((key >> 17u) & 0x1ffffu), int((key >> 34u) & 0x1ffffu));
    const int3 signedCell = (cell << 15) >> 15;
    center = (float3(signedCell) + 0.5f) * size - float3(1e-4f);
    // Cover every receiver selecting this cell, including jitter and roundoff.
    const float extent = 0.5f * size * (1.f + max(samplingJitter, 0.f));
    const float margin = 1e-5f * (1.f + max(abs(center.x), max(abs(center.y), abs(center.z))) + extent);
    halfExtent = float3(extent + margin);
    return key != 0u && level != 0u && baseCellSize > 0.f && isfinite(baseCellSize) &&
        samplingJitter >= 0.f && isfinite(samplingJitter) && size > 0.f && isfinite(size) &&
        all(isfinite(center)) && all(isfinite(halfExtent));
}

bool rtptReGIRCellBounds(uint64_t key, out float3 center, out float3 halfExtent)
{
    return rtptReGIRCellBounds(key, gReGIRSettings.baseCellSize, gReGIRSettings.samplingJitter, center, halfExtent);
}

bool rtptReGIRCellVolume(uint64_t key, out float3 center, out float radius)
{
    float3 halfExtent;
    const bool valid = rtptReGIRCellBounds(key, center, halfExtent);
    radius = length(halfExtent);
    return valid && isfinite(radius);
}

uint rtptReGIRFindOrInsertCell(uint64_t key)
{
    if (key == 0u || key == kRTPTReGIRTombstone) return kRTPTReGIRInvalidCell;
    const bool frozen = gReGIRSettings.freezeSnapshot != 0u;
    const uint capacity = gReGIRSettings.cellCapacity;
    if (capacity >= kRTPTReGIRBucketSize)
    {
        const uint2 words = uint2(uint(key), uint(key >> 32u));
        const uint base = rtptGridKeyHash(words) % (capacity - kRTPTReGIRBucketSize + 1u);
        for (uint attempt = 0u; attempt < kRTPTReGIRBucketSize; ++attempt)
        {
            uint available = kRTPTReGIRInvalidCell;
            uint64_t availableValue = uint64_t(0u);
            // A tombstone cannot terminate lookup. Find an existing key before
            // claiming a free slot, or a recycled prefix could duplicate it.
            for (uint probe = 0u; probe < kRTPTReGIRBucketSize; ++probe)
            {
                const uint index = base + probe;
                uint64_t stored;
                if (frozen) stored = gReGIRCells[index];
                else InterlockedCompareExchange(gReGIRCells[index], uint64_t(0u), uint64_t(0u), stored);
                if (stored == key) return index;
                if (available == kRTPTReGIRInvalidCell && (stored == uint64_t(0u) || stored == kRTPTReGIRTombstone))
                {
                    available = index;
                    availableValue = stored;
                }
            }
            if (frozen) return kRTPTReGIRInvalidCell;
            if (available == kRTPTReGIRInvalidCell) break;
            uint64_t original;
            InterlockedCompareExchange(gReGIRCells[available], availableValue, key, original);
            if (original == availableValue || original == key) return available;
            // Another insertion made progress. Rescan instead of waiting for
            // its owner; even maximum contention has a fixed retry bound.
        }
    }
    // Bounded probing never waits for another wave. The caller can build an
    // uncached complete view of this same cell if no hash slot is available.
    uint ignored;
    InterlockedAdd(gReGIRState[5], 1u, ignored);
    return kRTPTReGIRInvalidCell;
}

// Maintenance runs before consumers. Retain this slot's allocated ID segment
// for its next key, while reserving a tombstone so later probe keys stay valid.
bool rtptReGIRTryEvictCell(uint cell)
{
    if (cell >= gReGIRSettings.cellCapacity) return false;
    const uint64_t key = gReGIRCells[cell];
    if (key == uint64_t(0u) || key == kRTPTReGIRTombstone) return false;
    const uint lastUsed = gReGIRCellLastUsed[cell];
    if (lastUsed == 0u || gReGIRSettings.frameStamp - lastUsed <= 120u) return false;
    gReGIRCellMeta[cell].y = 0u;
    gReGIRCellMeta[cell].w = 0u;
    gReGIRCellEpoch[cell] = 0u;
    gReGIRCellRISFrame[cell] = 0u;
    gReGIRCellLastUsed[cell] = 0u;
    gReGIRCells[cell] = kRTPTReGIRTombstone;
    InterlockedAdd(gReGIRState[9], 1u);
    return true;
}
