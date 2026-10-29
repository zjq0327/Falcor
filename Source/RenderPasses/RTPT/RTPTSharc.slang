#pragma once

// One record is shared by all samples and NRD continuations of a pixel.
struct RTPTSharcStats
{
    uint cacheTerminations;
    uint radianceRays;
    uint attemptedQueries;
    bool primaryCaptured;
    bool primaryValid;
    float3 primaryPosition;
    float3 primaryNormal;
    float3 primaryCachedRadiance;
    float primarySampleCount;
    uint primaryAge;
};

#if ENABLE_SHARC
#ifndef SHARC_UPDATE
#define SHARC_UPDATE 0
#endif
#ifndef SHARC_QUERY
#define SHARC_QUERY 0
#endif
#include "ThirdParty/SHARC/SharcCommon.h"

struct RTPTSharcSettings
{
    uint2 frameDim;
    uint updateStride;
    uint frameIndex;
    uint updateBounces;
    uint minBounce;
    uint useCache;
    uint debugMode;
    float minRoughness;
    float3 cameraPositionPrev;
    uint accumulationFrames;
    uint staleFrames;
};

ParameterBlock<SharcParameters> gSharc;
#include "RTPTSharcPairCommon.slang"
ConstantBuffer<RTPTSharcSettings> gSharcSettings;

#if SHARC_UPDATE || SHARC_QUERY
float3 rtptSharcMaterialFactor(ShadingData sd, BSDFProperties properties)
{
    const float alpha = properties.roughness * properties.roughness;
    const float NdotV = saturate(dot(properties.guideNormal, sd.V));
    const float3 specular = approxSpecularIntegralGGX(properties.specularReflectionAlbedo, alpha, NdotV);
    // This factor preserves material textures; GGX demodulation remains an
    // approximation and cannot reconstruct lighting lost within a voxel.
    const float3 factor = max(float3(0.01f), clamp(properties.diffuseReflectionAlbedo, float3(0.f), float3(1.f)) +
        clamp(specular, float3(0.f), float3(1.f)));
    return all(isfinite(factor)) ? factor : float3(1.f);
}

SharcHitData rtptMakeSharcHit(ShadingData sd, BSDFProperties properties, float3 emission)
{
    SharcHitData hit = {};
    hit.positionWorld = sd.posW;
    hit.normalWorld = sd.getOrientedFaceNormal();
#if SHARC_MATERIAL_DEMODULATION
    hit.materialDemodulation = rtptSharcMaterialFactor(sd, properties);
#endif
#if SHARC_SEPARATE_EMISSIVE
    hit.emissive = emission;
#endif
    return hit;
}

uint2 rtptSharcUpdatePixel(uint2 tile)
{
    const uint stride = max(gSharcSettings.updateStride, 1u);
    const uint2 origin = tile * stride;
    const uint2 extent = min(uint2(stride), gSharcSettings.frameDim - origin);
    const uint hash = HashGridHashJenkins32(tile.x * 0x9e3779b9u ^ tile.y * 0x85ebca6bu ^ gParams.seed);
    // A randomized phase followed by a full cycle visits every tile pixel.
    const uint offset = (hash + gSharcSettings.frameIndex) % max(extent.x * extent.y, 1u);
    return origin + uint2(offset % max(extent.x, 1u), offset / max(extent.x, 1u));
}
#endif

#if SHARC_QUERY
void rtptCaptureSharcPrimary(ShadingData sd, BSDFProperties properties, inout RTPTSharcStats stats)
{
    if (stats.primaryCaptured) return;
    stats.primaryCaptured = true;
    stats.primaryValid = true;
    stats.primaryPosition = sd.posW;
    stats.primaryNormal = sd.getOrientedFaceNormal();
    const SharcHitData cacheHit = rtptMakeSharcHit(sd, properties, properties.emission);
    HashGridKey key;
    const HashGridIndex index = HashGridFindEntry(gSharc.hashGridData, sd.posW, cacheHit.normalWorld, gSharc.hashGridParameters, key);
    if (index == HASH_GRID_INVALID_CACHE_INDEX) return;
    const SharcVoxelData voxel = SharcGetVoxelData(gSharc.resolvedBuffer, index);
    stats.primarySampleCount = voxel.accumulatedSampleNum;
    stats.primaryAge = voxel.staleFrameNum;
    float3 cachedRadiance;
    if (SharcGetCachedRadiance(gSharc, cacheHit, cachedRadiance, false) && all(isfinite(cachedRadiance)))
        stats.primaryCachedRadiance = cachedRadiance;
}

bool rtptTrySharcQuery(
    ShadingData sd,
    IMaterialInstance mi,
    BSDFProperties properties,
    uint bounce,
    bool previousDelta,
    bool previousDiffuse,
    float previousRoughness,
    float segmentLength,
    inout RTPTSharcStats stats,
    out float3 cachedRadiance
)
{
    cachedRadiance = 0.f;
    if (gSharcSettings.useCache == 0 || bounce == 0 || bounce < gSharcSettings.minBounce ||
        bounce >= gParams.maxBounces || previousDelta || properties.roughness < gSharcSettings.minRoughness ||
        any(properties.emission > 0.f) || (mi.getLobeTypes(sd) & uint(LobeType::DeltaReflection)) != 0)
        return false;

    const uint level = HashGridGetLevel(sd.posW, gSharc.hashGridParameters);
    const float voxelSize = HashGridGetVoxelSize(level, gSharc.hashGridParameters);
    if (!(segmentLength >= voxelSize)) return false;
    if (!previousDiffuse)
    {
        const float alpha = previousRoughness * previousRoughness;
        const float alpha2 = alpha * alpha;
        const float footprint = 2.f * segmentLength * sqrt(0.5f * alpha2 / max(1e-6f, 1.f - alpha2));
        if (!(footprint >= voxelSize)) return false;
    }

    ++stats.attemptedQueries;
    const SharcHitData cacheHit = rtptMakeSharcHit(sd, properties, float3(0.f));
    if (!SharcGetCachedRadiance(gSharc, cacheHit, cachedRadiance, false) ||
        !all(isfinite(cachedRadiance)) || any(cachedRadiance < 0.f))
        return false;
    ++stats.cacheTerminations;
    return true;
}

#if RTPT_SHARC_PAIR
// No counters or side effects: also used at a BRDF hit to answer the
// hypothetical VXPG eligibility question in the same path-event space.
bool rtptSharcPairEligible(ShadingData sd, IMaterialInstance mi, BSDFProperties properties, uint bounce,
    bool previousDelta, bool previousDiffuse, float previousRoughness, float segmentLength)
{
    if (gSharcSettings.useCache == 0 || bounce == 0 || bounce < gSharcSettings.minBounce ||
        bounce >= gParams.maxBounces || previousDelta || properties.roughness < gSharcSettings.minRoughness ||
        any(properties.emission > 0.f) || (mi.getLobeTypes(sd) & uint(LobeType::DeltaReflection)) != 0) return false;
    const uint level = HashGridGetLevel(sd.posW, gSharc.hashGridParameters);
    const float voxelSize = HashGridGetVoxelSize(level, gSharc.hashGridParameters);
    if (!(segmentLength >= voxelSize)) return false;
    if (!previousDiffuse)
    {
        const float alpha = previousRoughness * previousRoughness;
        const float alpha2 = alpha * alpha;
        const float footprint = 2.f * segmentLength * sqrt(0.5f * alpha2 / max(1.e-6f, 1.f-alpha2));
        if (!(footprint >= voxelSize)) return false;
    }
    return true;
}
#endif

float3 rtptSharcOccupancy(uint2 pixel)
{
    const uint capacity = gSharc.hashGridData.capacity;
    const uint64_t pixelCount = uint64_t(gSharcSettings.frameDim.x) * uint64_t(gSharcSettings.frameDim.y);
    if (capacity == 0 || pixelCount == 0) return float3(0.f);
    const uint64_t pixelIndex = uint64_t(pixel.y) * uint64_t(gSharcSettings.frameDim.x) + uint64_t(pixel.x);
    // Partition the entire hash table, rather than displaying its first slots.
    // When pixels outnumber slots, repeat one valid slot per pixel. All index
    // products are 64-bit; debug-only reads total max(capacity, pixelCount).
    const uint first = uint(pixelIndex * uint64_t(capacity) / pixelCount);
    const uint last = max(first + 1u, uint((pixelIndex + 1u) * uint64_t(capacity) / pixelCount));
    uint occupied = 0;
    [loop]
    for (uint index = first; index < last; ++index)
        occupied += gSharc.hashGridData.hashEntriesBuffer[index] != HASH_GRID_INVALID_HASH_KEY ? 1u : 0u;
    const float density = float(occupied) / float(last - first);
    return float3(0.f, saturate(sqrt(density) * 8.f), 0.f);
}

void rtptWriteSharcDebug(uint2 pixel, RTPTSharcStats stats)
{
    float3 debug = 0.f;
    switch (gSharcSettings.debugMode)
    {
    case 0:
        if (stats.primaryValid)
            debug = HashGridDebugColoredHash(stats.primaryPosition, stats.primaryNormal, gSharc.hashGridParameters);
        break;
    case 1:
        debug = stats.primaryCachedRadiance / (1.f + stats.primaryCachedRadiance);
        break;
    case 2:
        debug = float3(0.1f, 0.6f, 1.f) * saturate(log2(1.f + stats.primarySampleCount) / 12.f);
        break;
    case 3:
        if (stats.primarySampleCount > 0.f)
        {
            const float age = saturate(float(stats.primaryAge) / float(max(gSharcSettings.staleFrames, 1u)));
            debug = lerp(float3(0.f, 1.f, 0.f), float3(1.f, 0.f, 0.f), age);
        }
        break;
    case 4:
        debug = stats.cacheTerminations > 0 ? float3(0.f, 1.f, 0.f) : float3(0.15f, 0.f, 0.f);
        break;
    case 5:
    {
#if ENABLE_NRD
        const uint rayBudget = gParams.samplesPerPixel * (2u * gParams.maxBounces + 1u);
#else
        const uint rayBudget = gParams.samplesPerPixel * (gParams.maxBounces + 1u);
#endif
        const float rays = saturate(float(stats.radianceRays) / float(max(rayBudget, 1u)));
        debug = lerp(float3(0.f, 0.2f, 1.f), float3(1.f, 0.1f, 0.f), rays);
        break;
    }
    case 6:
        debug = all(pixel == rtptSharcUpdatePixel(pixel / max(gSharcSettings.updateStride, 1u))) ? float3(1.f) : float3(0.f);
        break;
    case 7:
        debug = rtptSharcOccupancy(pixel);
        break;
    }
    gSharcDebug[pixel] = float4(debug, 1.f);
    gSharcCacheRadiance[pixel] = float4(stats.primaryCachedRadiance, 1.f);
    gSharcStats[pixel] = float4(float(stats.cacheTerminations), float(stats.radianceRays), float(stats.attemptedQueries), stats.primarySampleCount);
}
#endif
#endif
