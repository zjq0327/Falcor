#pragma once

#ifndef RTPT_GRIS_CACHE_TAIL
#define RTPT_GRIS_CACHE_TAIL 0
#endif
#ifndef RTPT_GRIS_SHARC_REPLAY
#define RTPT_GRIS_SHARC_REPLAY 0
#endif

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
    uint motionResponsive;
};

ParameterBlock<SharcParameters> gSharc;
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
#if RTPT_GRIS_SHARC_REPLAY
struct RTPTSharcTailQuery
{
    uint2 key;
    float3 rawRadiance;
    float3 materialFactor;
};

bool rtptReadSharcTailRadianceFrom(SharcParameters cache, uint2 key, out float3 rawRadiance)
{
    rawRadiance = 0.f;
    const HashGridKey hashKey = HashGridKey(uint64_t(key.x) | (uint64_t(key.y) << 32u));
    if (gSharcSettings.useCache == 0u || hashKey == HASH_GRID_INVALID_HASH_KEY) return false;

    // RTPT uses non-directional radiance and folds the hit material factor
    // into the tail gain. A reusable SHaRC terminal has no emission.
    SharcHitData hit = {};
#if SHARC_MATERIAL_DEMODULATION
    hit.materialDemodulation = 1.f;
#endif
    if (SharcGetCachedRadianceFromHash(cache, hit, hashKey, rawRadiance, false) &&
        all(isfinite(rawRadiance)) && all(rawRadiance >= 0.f))
        return true;
    rawRadiance = 0.f;
    return false;
}

bool rtptReadSharcTailRadiance(uint2 key, out float3 rawRadiance)
{
    return rtptReadSharcTailRadianceFrom(gSharc, key, rawRadiance);
}
#endif

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

bool rtptTrySharcQueryOnEdgeFrom(
    SharcParameters cache,
    ShadingData sd,
    IMaterialInstance mi,
    BSDFProperties properties,
    uint bounce,
    bool previousDelta,
    bool previousGuideSelected,
    bool previousDiffuse,
    float previousRoughness,
    float segmentLength,
    RTPTSamplingContext previousSampling,
    float3 direction,
    inout RTPTSharcStats stats,
    out float3 cachedRadiance
#if RTPT_GRIS_SHARC_REPLAY
    , out RTPTSharcTailQuery tailQuery
#endif
#ifdef RTPT_GRIS_SHARC_X1_BLEND
    , bool probeX1 = false
#endif
)
{
    cachedRadiance = 0.f;
#if RTPT_GRIS_SHARC_REPLAY
    tailQuery = {};
#endif
#if RTPT_GRIS_CACHE_TAIL
    // x2 uses the full mixed BSDF, so its selected-lobe label cannot gate a
    // reusable cache endpoint at x3. From x4 the ordinary fixed tail owns
    // the incoming diffuse label, independently of the reconnected prefix.
    if (bounce < 4u || !previousDiffuse) return false;
    const uint lobes = mi.getLobeTypes(sd);
    const uint continuous = uint(LobeType::NonDeltaReflection);
    const MaterialType material = sd.mtl.getMaterialType();
    if (!sd.frontFacing || (material != MaterialType::PBRTDiffuse && material != MaterialType::Standard) ||
        lobes == 0u || (lobes & ~continuous) != 0u) return false;
#endif
    if (gSharcSettings.useCache == 0 || bounce == 0 ||
#ifdef RTPT_GRIS_SHARC_X1_BLEND
        (bounce < gSharcSettings.minBounce && !probeX1) ||
#else
        bounce < gSharcSettings.minBounce ||
#endif
        bounce >= gParams.maxBounces || previousDelta || properties.roughness < gSharcSettings.minRoughness ||
        any(properties.emission > 0.f) || (mi.getLobeTypes(sd) & uint(LobeType::DeltaReflection)) != 0)
        return false;

    // A guide can be narrower than the previous BSDF. The BSDF roughness
    // footprint below therefore does not justify a cached termination on
    // a guide-selected edge. Keep tracing that edge; later BSDF edges may
    // still terminate in SHaRC under its existing rules.
    if (previousGuideSelected)
    {
#if ENABLE_PG
        rtptPGCount(RTPT_PG_DIAG_CACHE_SKIP);
#endif
        return false;
    }

    const uint level = HashGridGetLevel(sd.posW, cache.hashGridParameters);
    const float voxelSize = HashGridGetVoxelSize(level, cache.hashGridParameters);
    if (!(segmentLength >= voxelSize)) return false;
    if (!previousDiffuse)
    {
        const float alpha = previousRoughness * previousRoughness;
        const float alpha2 = alpha * alpha;
        const float footprint = 2.f * segmentLength * sqrt(0.5f * alpha2 / max(1e-6f, 1.f - alpha2));
        if (!(footprint >= voxelSize)) return false;
    }
#if ENABLE_PG
    if (previousSampling.alpha > 0.f &&
        !rtptPGAllowsCacheFootprint(previousSampling.guide, direction, 0.5f * voxelSize / segmentLength))
    {
        rtptPGCount(RTPT_PG_DIAG_CACHE_SKIP);
        return false;
    }
#endif

    ++stats.attemptedQueries;
    const SharcHitData cacheHit = rtptMakeSharcHit(sd, properties, float3(0.f));
#if RTPT_GRIS_SHARC_REPLAY
    const uint64_t key = uint64_t(HashGridComputeSpatialHash(cacheHit.positionWorld, cacheHit.normalWorld, cache.hashGridParameters));
    tailQuery.key = uint2(uint(key), uint(key >> 32u));
#if SHARC_MATERIAL_DEMODULATION
    tailQuery.materialFactor = cacheHit.materialDemodulation;
#else
    tailQuery.materialFactor = 1.f;
#endif
    if (!rtptReadSharcTailRadianceFrom(cache, tailQuery.key, tailQuery.rawRadiance)) return false;
    cachedRadiance = tailQuery.rawRadiance * tailQuery.materialFactor;
    if (!all(isfinite(cachedRadiance))) return false;
#else
    if (!SharcGetCachedRadiance(cache, cacheHit, cachedRadiance, false) ||
        !all(isfinite(cachedRadiance)) || any(cachedRadiance < 0.f))
        return false;
#endif
#ifdef RTPT_GRIS_SHARC_X1_BLEND
    if (probeX1) return true;
#endif
    ++stats.cacheTerminations;
    return true;
}

bool rtptTrySharcQueryOnEdge(
    ShadingData sd, IMaterialInstance mi, BSDFProperties properties, uint bounce, bool previousDelta,
    bool previousGuideSelected, bool previousDiffuse, float previousRoughness, float segmentLength,
    RTPTSamplingContext previousSampling, float3 direction, inout RTPTSharcStats stats, out float3 cachedRadiance
#if RTPT_GRIS_SHARC_REPLAY
    , out RTPTSharcTailQuery tailQuery
#endif
#ifdef RTPT_GRIS_SHARC_X1_BLEND
    , bool probeX1 = false
#endif
)
{
    return rtptTrySharcQueryOnEdgeFrom(gSharc, sd, mi, properties, bounce, previousDelta, previousGuideSelected,
        previousDiffuse, previousRoughness, segmentLength, previousSampling, direction, stats, cachedRadiance
#if RTPT_GRIS_SHARC_REPLAY
        , tailQuery
#endif
#ifdef RTPT_GRIS_SHARC_X1_BLEND
        , probeX1
#endif
    );
}

bool rtptTrySharcQuery(ShadingData sd, IMaterialInstance mi, BSDFProperties properties, uint bounce,
    bool previousDelta, bool previousGuideSelected, bool previousDiffuse, float previousRoughness, float segmentLength,
    inout RTPTSharcStats stats, out float3 cachedRadiance)
{
#if RTPT_GRIS_SHARC_REPLAY
    RTPTSharcTailQuery unusedTailQuery;
#endif
    return rtptTrySharcQueryOnEdge(sd, mi, properties, bounce, previousDelta, previousGuideSelected, previousDiffuse,
        previousRoughness, segmentLength, rtptBSDFSamplingContext(), float3(0.f), stats, cachedRadiance
#if RTPT_GRIS_SHARC_REPLAY
        , unusedTailQuery
#endif
        );
}

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
