/** Invalidate existing cache voxels that overlap changed geometry bounds. */
#include "RTPTSharc.slang"

struct RTPTSharcMotionSettings
{
    uint boundsCount;
};

// Two float4 records per world-space AABB: minimum followed by maximum.
StructuredBuffer<float4> gSHARCMotionBounds;
ConstantBuffer<RTPTSharcMotionSettings> gSHARCMotionSettings;
RWStructuredBuffer<uint> gSHARCMotionStats;

[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    if (gSharcSettings.motionResponsive == 0u) return;
    const uint entryIndex = dispatchThreadID.x;
    if (entryIndex >= gSharc.hashGridData.capacity) return;

    const HashGridKey key = BUFFER_AT_OFFSET(gSharc.hashGridData.hashEntriesBuffer, entryIndex);
    if (key == HASH_GRID_INVALID_HASH_KEY) return;

    const SharcVoxelData previous = SharcGetVoxelData(gSharc.resolvedBuffer, entryIndex);
    const bool occupied = previous.accumulatedSampleNum > 0.f;
    uint ignored;
    if (occupied) InterlockedAdd(gSHARCMotionStats[0], 1u, ignored);

    const uint level = uint((key >> HASH_GRID_LEVEL_BIT_OFFSET) & HASH_GRID_LEVEL_BIT_MASK);
    const float halfSize = 0.5f * HashGridGetVoxelSize(level, gSharc.hashGridParameters);
    const float3 center = HashGridGetPositionFromKey(key, gSharc.hashGridParameters);
    const float3 voxelMin = center - halfSize;
    const float3 voxelMax = center + halfSize;
    bool overlaps = false;
    for (uint i = 0u; i < gSHARCMotionSettings.boundsCount; ++i)
    {
        const float3 boundsMin = gSHARCMotionBounds[2u * i].xyz;
        const float3 boundsMax = gSHARCMotionBounds[2u * i + 1u].xyz;
        if (all(voxelMax >= boundsMin) && all(voxelMin <= boundsMax))
        {
            overlaps = true;
            break;
        }
    }

    if (overlaps)
    {
        // Preserve the hash key/slot. Empty data rejects queries until current
        // observations refill this voxel; the SDK's normal aging can evict it.
        BUFFER_AT_OFFSET(gSharc.accumulationBuffer, entryIndex) = SharcZeroAccumulationData();
        BUFFER_AT_OFFSET(gSharc.resolvedBuffer, entryIndex) = SharcZeroPackedData();
        if (occupied) InterlockedAdd(gSHARCMotionStats[1], 1u, ignored);
    }
    else if (occupied)
        InterlockedAdd(gSHARCMotionStats[2], 1u, ignored);
}
