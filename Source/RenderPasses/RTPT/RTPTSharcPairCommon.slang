#pragma once
#ifndef RTPT_SHARC_PAIR
#define RTPT_SHARC_PAIR 0
#endif

// Include after SharcCommon.h and the gSharc parameter block declaration.
// This layer is independent of material types so the production cache update
// and resolve can be exercised directly by GPU unit tests.
#if RTPT_SHARC_PAIR
ParameterBlock<SharcParameters> gSharcLocal;
ParameterBlock<SharcParameters> gSharcSuffix;
#endif

#if SHARC_UPDATE
void rtptSharcUpdateMiss(SharcState state, float3 radiance)
{
    SharcUpdateMiss(gSharc, state, radiance);
#if RTPT_SHARC_PAIR
    SharcUpdateMiss(gSharcSuffix, state, radiance);
#endif
}

bool rtptSharcUpdateHit(inout SharcState state, SharcHitData hit, float3 direct, float random)
{
#if RTPT_SHARC_PAIR
    const uint oldLength = state.pathLength;
    HashGridIndex oldestIndex = HASH_GRID_INVALID_CACHE_INDEX;
    SharcSampleWeight oldestWeight = SharcSampleWeight(float3(0.f));
    if (oldLength == SHARC_PROPAGATION_DEPTH)
    {
        oldestIndex = state.cacheIndices[oldLength-1];
        oldestWeight = state.sampleWeights[oldLength-1];
    }
#endif
    const bool result = SharcUpdateHit(gSharc, state, hit, direct, random);
    if (!result) return false;
#if RTPT_SHARC_PAIR
    float3 factor = float3(1.f);
#if SHARC_MATERIAL_DEMODULATION
    factor = rcp(hit.materialDemodulation);
#endif
    const HashGridIndex current = state.cacheIndices[0];
    SharcAddVoxelData(gSharcLocal, current, direct * factor, float3(1.f), float3(0.f,0.f,1.f), 0.f, 1);
    // Count exactly the same current-vertex observation in both sidecars.
    SharcAddVoxelData(gSharcSuffix, current, float3(0.f), float3(1.f), float3(0.f,0.f,1.f), 0.f, 1);
    float3 radiance = direct;
#if SHARC_SEPARATE_EMISSIVE
    radiance += hit.emissive;
#endif
    for (uint i = 1; i < state.pathLength; ++i)
    {
        const HashGridIndex index = state.cacheIndices[i];
        if (index != HASH_GRID_INVALID_CACHE_INDEX)
            SharcAddVoxelData(gSharcSuffix, index, radiance, state.sampleWeights[i], float3(0.f,0.f,1.f), 0.f, 0);
    }
    // The SDK propagated to this entry before shifting it out of the state.
    if (oldestIndex != HASH_GRID_INVALID_CACHE_INDEX)
        SharcAddVoxelData(gSharcSuffix, oldestIndex, radiance, oldestWeight, float3(0.f,0.f,1.f), 0.f, 0);
#endif
    return true;
}
#endif

#if RTPT_SHARC_PAIR && SHARC_QUERY
bool rtptSharcReadPair(SharcHitData hit, out float3 local, out float3 suffix)
{
    local = suffix = 0.f;
    HashGridKey key;
    const HashGridIndex index = HashGridFindEntry(gSharc.hashGridData, hit.positionWorld, hit.normalWorld, gSharc.hashGridParameters, key);
    if (index == HASH_GRID_INVALID_CACHE_INDEX) return false;
    const SharcPackedData full = gSharc.resolvedBuffer[index];
    const SharcPackedData c = gSharcLocal.resolvedBuffer[index];
    const SharcPackedData r = gSharcSuffix.resolvedBuffer[index];
    if (c.sampleData != r.sampleData || c.sampleData != full.sampleData) return false;
    const SharcVoxelData cv = SharcUnpackVoxelData(c), rv = SharcUnpackVoxelData(r);
    const SharcVoxelData fv = SharcUnpackVoxelData(full);
    if (cv.accumulatedSampleNum != rv.accumulatedSampleNum || cv.accumulatedSampleNum != fv.accumulatedSampleNum) return false;
    if (!(cv.accumulatedSampleNum > SHARC_SAMPLE_NUM_THRESHOLD)) return false;
    local = SharcDecodeRadiance(cv.accumulatedRadiance, SharcGetRadianceDirection(hit));
    suffix = SharcDecodeRadiance(rv.accumulatedRadiance, SharcGetRadianceDirection(hit));
#if SHARC_MATERIAL_DEMODULATION
    local *= hit.materialDemodulation;
    suffix *= hit.materialDemodulation;
#endif
    return all(isfinite(local)) && all(isfinite(suffix)) && all(local >= 0.f) && all(suffix >= 0.f);
}
#endif
