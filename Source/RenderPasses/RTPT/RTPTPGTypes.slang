#pragma once

static const uint RTPT_PG_INVALID = 0xffffffffu;
static const uint RTPT_PG_REGION_READY = 1u;
static const uint RTPT_PG_REGION_ZERO = 2u;
static const uint RTPT_PG_PATH_COMPLETE = 1u;
static const uint RTPT_PG_PATH_INVALID = 2u;
static const uint RTPT_PG_VERTEX_OUTGOING = 1u;
static const uint RTPT_PG_VERTEX_TRAINABLE = 2u;
static const uint RTPT_PG_DIAG_REQUEST_OVERFLOW = 0u;
static const uint RTPT_PG_DIAG_RECORD_OVERFLOW = 1u;
static const uint RTPT_PG_DIAG_INVALID = 2u;
static const uint RTPT_PG_DIAG_ACCUM_OVERFLOW = 3u;
static const uint RTPT_PG_DIAG_QUERY = 4u;
static const uint RTPT_PG_DIAG_GUIDED = 5u;
static const uint RTPT_PG_DIAG_FALLBACK = 6u;
static const uint RTPT_PG_DIAG_CACHE_SKIP = 7u;
static const uint RTPT_PG_DIAG_TRAINED = 8u;
static const uint RTPT_PG_DIAG_ZERO = 9u;
static const uint RTPT_PG_DIAG_REQUEST = 10u;
static const uint RTPT_PG_DIAG_COMPLETE = 11u;
static const uint RTPT_PG_DIAG_INVALID_PDF = 12u;

struct RTPTPGSettings
{
    uint2 frameDim;
    uint recordStride;
    uint frameIndex;
    uint pathCapacity;
    uint verticesPerPath;
    uint sceneGeneration;
    uint recordGeneration;
    uint readMapCapacity;
    uint buildMapCapacity;
    uint requestCapacity;
    uint coarseLevels;
    uint enabled;
    uint trainingEnabled;
    float guideFraction;
    float weightScale;
    float3 cameraPosition;
    float sceneScale;
    uint readRegionCount;
    uint buildRegionCount;
    uint readNodeCount;
    uint buildNodeCount;
    uint detailedDiagnostics;
};

// Compact directional topology: high 28 bits child base, low 4 bits child mask.
struct RTPTPGNode { uint topology; float4 mass; }; // 20 B
struct RTPTPGStats { uint4 weightBits; uint4 squareBits; uint4 count; }; // 48 B
struct RTPTPGMapEntry { uint2 key; uint regionId; uint generation; }; // 16 B
struct RTPTPGRegion // 32 B
{
    uint2 key;
    uint root;
    uint nodeCount;
    uint generation;
    uint flags;
    uint observationCount;
    float reserved;
};
struct RTPTPGPathHeader // 32 B
{
    uint vertexCount;
    uint flags;
    uint ownerPixel;
    uint generation;
    float3 terminalEmission;
    uint sceneGeneration;
};
struct RTPTPGVertex // 80 B; keys preserve the capture-frame spatial LOD.
{
    uint2 key;
    uint flags;
    uint padding0;
    float3 direction;
    float samplePdf;
    float3 emission;
    float hitMIS;
    float3 direct;
    // Inclusion probability of this actually traced edge after roulette.
    float sampleSurvival;
    float3 transport;
    uint padding2;
};
struct RTPTPGGuide
{
    uint regionId;
    uint root;
    uint nodeCount;
    uint generation;
    float alpha;
};

#if ENABLE_PG
ConstantBuffer<RTPTPGSettings> gPGSettings;
StructuredBuffer<RTPTPGMapEntry> gPGReadMap;
StructuredBuffer<RTPTPGRegion> gPGReadRegions;
StructuredBuffer<RTPTPGNode> gPGReadNodes;
StructuredBuffer<RTPTPGMapEntry> gPGBuildMap;
StructuredBuffer<RTPTPGRegion> gPGBuildRegions;
StructuredBuffer<RTPTPGNode> gPGBuildNodes;
RWStructuredBuffer<RTPTPGStats> gPGBuildStats;
// Two uint64 elements per request: packed key followed by an unused zero word.
RWStructuredBuffer<uint64_t> gPGRequests;
RWStructuredBuffer<uint> gPGDiagnostics;
RWStructuredBuffer<RTPTPGPathHeader> gPGPathHeaders;
RWStructuredBuffer<RTPTPGVertex> gPGVertices;

void rtptPGCount(uint counter)
{
    // Successful hot-path events are optional instrumentation. Errors remain
    // live even when detailed counting is disabled; model statistics and the
    // region-request buffer are independent of this diagnostic switch.
    if (counter >= RTPT_PG_DIAG_QUERY && counter <= RTPT_PG_DIAG_COMPLETE && gPGSettings.detailedDiagnostics == 0u)
        return;
    InterlockedAdd(gPGDiagnostics[counter], 1u);
}
#else
void rtptPGCount(uint counter) {}
#endif

uint rtptPGChild(uint topology, uint quadrant)
{
    if ((topology & (1u << quadrant)) == 0) return RTPT_PG_INVALID;
    return (topology >> 4) + countbits(topology & ((1u << quadrant) - 1u));
}

float2 rtptPGDirectionToSquare(float3 direction)
{
    const float u = saturate((direction.z + 1.f) * 0.5f);
    float v = atan2(direction.y, direction.x) * (1.f / 6.283185307179586f);
    v -= floor(v);
    return min(float2(u, v), float2(asfloat(0x3f7fffffu)));
}

float3 rtptPGSquareToDirection(float2 uv)
{
    const float z = 2.f * uv.x - 1.f;
    const float r = sqrt(max(0.f, 1.f - z * z));
    float sine, cosine;
    sincos(6.283185307179586f * uv.y, sine, cosine);
    return float3(r * cosine, r * sine, z);
}

uint rtptPGQuadrant(inout float2 uv)
{
    const uint2 quadrant = min(uint2(uv * 2.f), uint2(1u));
    uv = min(uv * 2.f - float2(quadrant), float2(asfloat(0x3f7fffffu)));
    return quadrant.x | (quadrant.y << 1u);
}
