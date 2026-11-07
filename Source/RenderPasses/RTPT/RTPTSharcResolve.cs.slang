/** One compute thread per cache entry; no scene or ray-tracing pipeline. */
#include "RTPTSharc.slang"

RWStructuredBuffer<uint> gSHARCMotionStats;

bool rtptSharcRefreshChangedEntry(uint entryIndex)
{
    const HashGridKey key = BUFFER_AT_OFFSET(gSharc.hashGridData.hashEntriesBuffer, entryIndex);
    if (key == HASH_GRID_INVALID_HASH_KEY) return false;

    const SharcAccumulationData accumulated = BUFFER_AT_OFFSET(gSharc.accumulationBuffer, entryIndex);
    const float sampleNum = SharcGetAccumulatedSampleNum(accumulated);
    const SharcVoxelData previous = SharcGetVoxelData(gSharc.resolvedBuffer, entryIndex);
    // No observation is different from an observed black result. In
    // particular, door closing must be allowed to replace old bright data.
    if (!(sampleNum > 0.f) || !(previous.accumulatedSampleNum > 0.f)) return false;

    const SharcRadianceData current = SharcGetAccumulatedRadianceData(accumulated, gSharc.radianceScale, sampleNum);
    const float3 currentRGB = SharcDecodeRadiance(current, float3(0.f, 0.f, 1.f));
    const float3 previousRGB = SharcDecodeRadiance(previous.accumulatedRadiance, float3(0.f, 0.f, 1.f));
    if (!all(isfinite(currentRGB)) || !all(isfinite(previousRGB))) return false;
    const float3 difference = abs(currentRGB - previousRGB);
    const float3 scale = max(abs(currentRGB), abs(previousRGB));
    const float absoluteThreshold = max(1e-3f, 2.f / gSharc.radianceScale);
    if (!any(difference > absoluteThreshold + 0.5f * scale)) return false;

    // Adaptive approximation for observed lighting changes outside the moved
    // geometry bounds. It does not certify unobserved voxels as unchanged.
    // Publish directly so duplicate lookup or adjacent-LOD history in the SDK
    // cannot reintroduce the old signal after we have detected a change.
    BUFFER_AT_OFFSET(gSharc.resolvedBuffer, entryIndex) =
        SharcPackVoxelData(current, sampleNum, 1u, 0u, 0u);
    BUFFER_AT_OFFSET(gSharc.accumulationBuffer, entryIndex) = SharcZeroAccumulationData();
    uint ignored;
    InterlockedAdd(gSHARCMotionStats[3], 1u, ignored);
    return true;
}

[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint entryIndex = dispatchThreadID.x;
    if (entryIndex >= gSharc.hashGridData.capacity) return;
    if (gSharcSettings.motionResponsive != 0u && rtptSharcRefreshChangedEntry(entryIndex)) return;

    SharcResolveParameters resolve = {};
    resolve.cameraPositionPrev = gSharcSettings.cameraPositionPrev;
    resolve.accumulationFrameNum = gSharcSettings.accumulationFrames;
    resolve.responsiveFrameNum = 1u;
    resolve.staleFrameNumMax = gSharcSettings.staleFrames;
    resolve.frameIndex = gSharcSettings.frameIndex;
    SharcResolveEntry(entryIndex, gSharc, resolve);
}
