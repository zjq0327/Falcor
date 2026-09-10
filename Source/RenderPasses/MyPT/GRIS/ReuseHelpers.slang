__exported import Params;
__exported import Shift;
__exported import PathTracer;
__exported import RenderPasses.MyPT.MyPTCommon;
import Utils.Math.HashUtils;

StructuredBuffer<PrimaryPathContext> gHistoryPrimary;
StructuredBuffer<PathReservoir> gHistoryReservoir;
StructuredBuffer<PathReservoir> gSpatialInput;
Texture2D<float2> gMotionVector;
RWTexture2D<float4> gShiftDebug;

bool validTemporalGeometry(ShadingData current, ShadingData previous)
{
    // Compare both surfaces in the previous camera's coordinate system. Comparing
    // current and previous camera distances would reject ordinary camera motion.
    float currentDepth = length(current.posW - gPreviousCameraPosition);
    float previousDepth = length(previous.posW - gPreviousCameraPosition);
    return current.materialID == previous.materialID &&
        dot(current.frame.N, previous.frame.N) >= gTemporalNormalThreshold &&
        abs(currentDepth - previousDepth) <= gTemporalDepthThreshold * min(currentDepth, previousDepth);
}

bool findHistoryPixel(uint2 pixel, ShadingData current, uint seed, out uint2 previousPixel)
{
    previousPixel = pixel;
    if (gTemporalReprojection == 0) return true;

    SampleGenerator reprojection = SampleGenerator(jenkinsHash(seed ^ 0xa24baed5u));
    float2 offset = sampleNext2D(reprojection);
    float2 location;
#if GRIS_HAS_MOTION
    // Falcor mvec points from current to previous in normalized screen coordinates.
    // Its camera jitter has already been removed by VBufferRT.
    location = float2(pixel) + gMotionVector[pixel] * float2(gDimensions) + offset;
#else
    float4 previousClip = mul(gPreviousViewProj, float4(current.posW, 1.f));
    if (any(!isfinite(previousClip)) || previousClip.w <= 0.f) return false;
    float2 previousUV = previousClip.xy / previousClip.w;
#ifdef FALCOR_FLIP_Y
    previousUV *= float2(0.5f, 0.5f);
#else
    previousUV *= float2(0.5f, -0.5f);
#endif
    previousUV += 0.5f;
    location = previousUV * float2(gDimensions) - 0.5f + offset;
#endif
    // Check the floating-point position before conversion: negative coordinates
    // truncated to int would otherwise incorrectly reuse the screen border.
    if (any(!isfinite(location)) || any(location < 0.f) || any(location >= float2(gDimensions))) return false;
    previousPixel = uint2(floor(location));
    return true;
}

bool validGeometry(ShadingData center, ShadingData neighbor)
{
    float centerDepth = length(center.posW - gScene.camera.getPosition());
    float neighborDepth = length(neighbor.posW - gScene.camera.getPosition());
    return dot(center.frame.N, neighbor.frame.N) >= gSpatialNormalThreshold &&
        abs(centerDepth - neighborDepth) <= gSpatialDepthThreshold * min(centerDepth, neighborDepth);
}

int2 neighborPixel(uint2 pixel, uint seed, uint neighbor)
{
    // A nonzero offset is a script-only deterministic test hook; duplicates remain separate proposals.
    if (any(gSpatialNeighborOffset != 0)) return int2(pixel) + gSpatialNeighborOffset;
    SampleGenerator offsets = SampleGenerator(jenkinsHash(seed ^ jenkinsHash(gSpatialRound + 0x9e3779b9u) ^
        jenkinsHash(neighbor + 0x85ebca6bu)));
    float2 u = sampleNext2D(offsets);
    float radius = gSpatialRadius * sqrt(u.x);
    float angle = 6.28318530718f * u.y;
    return int2(pixel) + int2(round(radius * float2(cos(angle), sin(angle))));
}

uint temporalNeighbor(uint2 pixel, out uint previousIndex)
{
    previousIndex = 0xffffffff;
    if (gHistoryValid == 0) return 0;
    PrimaryPathContext primary = gPrimary[pixelIndex(pixel)];
    if (!HitInfo(primary.hit).isValid()) return 1;
    ShadingData current = loadShadingData(HitInfo(primary.hit), primary.direction);
    uint2 previousPixel;
    if (!findHistoryPixel(pixel, current, primary.seed, previousPixel)) return 2;
    previousIndex = pixelIndex(previousPixel);
    PrimaryPathContext previous = gHistoryPrimary[previousIndex];
    if (!HitInfo(previous.hit).isValid()) return 3;
    if (!validTemporalGeometry(current, loadShadingData(HitInfo(previous.hit), previous.direction))) return 4;
    return 5;
}

HybridPrefix replayPrefixForPair(PrimaryPathContext destination, PathSample sample)
{
    HybridPrefix prefix = {};
    prefix.hit = HitInfo().pack();
    if (!any(sample.F > 0.f)) { prefix.failure = 17; return prefix; }
    return traceHybridPrefix(destination, sample, gMaxSurfaceBounces, gRRProbability, gRoughnessThreshold, gNearFieldDistance);
}

ShiftResult shiftForPair(PathSample sample, PrimaryPathContext source, PrimaryPathContext destination,
    HybridPrefix prefix, bool identity = false)
{
#if GRIS_SHIFT_STRATEGY == 2
    return shiftPathCached(sample, source, destination, gMaxSurfaceBounces, gRRProbability,
        gRoughnessThreshold, gNearFieldDistance, prefix, identity);
#else
    return shiftPath(sample, source, destination, gMaxSurfaceBounces, gRRProbability,
        gRoughnessThreshold, gNearFieldDistance, identity);
#endif
}

ShiftResult shiftInline(PathSample sample, PrimaryPathContext source, PrimaryPathContext destination, bool identity = false)
{
    return shiftPath(sample, source, destination, gMaxSurfaceBounces, gRRProbability,
        gRoughnessThreshold, gNearFieldDistance, identity);
}

void recordShiftCheck(uint2 pixel, PathSample sample, PrimaryPathContext source,
    PrimaryPathContext destination, ShiftResult cached)
{
#if GRIS_HAS_SHIFT_DEBUG
    float4 debug = gShiftDebug[pixel];
    if (cached.failure > 0 && cached.failure < 24) debug.w = float(uint(debug.w) | (1u << cached.failure));
#if GRIS_SHIFT_STRATEGY == 2
    ShiftResult inlineResult = shiftInline(sample, source, destination);
    float error = max(relativeContributionError(cached.sample.F, inlineResult.sample.F),
        abs(cached.jacobian - inlineResult.jacobian) / max(inlineResult.jacobian, 1e-8f));
    if (cached.failure != inlineResult.failure) error = max(error, 1.f);
    debug.z = max(debug.z, error);
#endif
    gShiftDebug[pixel] = debug;
#endif
}

void recordShiftFailure(uint2 pixel, uint failure)
{
#if GRIS_HAS_SHIFT_DEBUG
    if (failure > 0 && failure < 24)
    {
        float4 debug = gShiftDebug[pixel];
        debug.w = float(uint(debug.w) | (1u << failure));
        gShiftDebug[pixel] = debug;
    }
#endif
}

// Identity diagnostics run the actual replay/reconnection code. Paths outside
// the reconnection support retain the local canonical proposal instead.
bool hasShiftIdentity(PathSample sample)
{
    if (!any(sample.F > 0.f)) return false;
#if GRIS_SHIFT_STRATEGY == 1
    return true;
#elif GRIS_SHIFT_STRATEGY == 2
    return sample.rcIndex == 0xffffffff || supportsReconnection(sample);
#else
    return supportsReconnection(sample);
#endif
}

