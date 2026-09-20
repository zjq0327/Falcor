#ifndef MYPT_PG_PATH_RECORD_SLANG
#define MYPT_PG_PATH_RECORD_SLANG

// Explicit 16-byte groups; C++ allocates 32-byte headers and 80-byte vertices.
// E is raw self emission, D is local NEE, T is the local scatter weight including
// survival compensation. hitMIS belongs to the edge arriving at this vertex.
struct PGPathHeader
{
    uint vertexCount;
    uint flags;
    uint ownerPixel;
    uint generation;
    float3 terminalEmission;
    uint terminationReason;
};

struct PGVertexRecord
{
    float3 position;
    uint flags;
    float3 direction;
    float samplePdf;
    float3 emission;
    float hitMIS;
    float3 direct;
    uint padding0;
    float3 transport;
    uint padding1;
};

static const uint kPGInvalid = 0xffffffffu;
static const uint kPGPathComplete = 1u;
static const uint kPGPathOverflow = 2u;
static const uint kPGVertexOutgoing = 1u;
static const uint kPGVertexTrainable = 2u;
static const uint kPGTerminationMiss = 1u;
static const uint kPGTerminationDepth = 2u;
static const uint kPGTerminationRR = 3u;
static const uint kPGTerminationAbsorbed = 4u;
static const uint kPGTerminationEnded = 5u;

// Counters accumulate for an epoch and are reset by the host after publication.
// This avoids a CPU readback/synchronization on every rendered frame.
static const uint kPGDiagSelectedPaths = 0u;
static const uint kPGDiagCompletePaths = 1u;
static const uint kPGDiagRecordedVertices = 2u;
static const uint kPGDiagTrainedSamples = 3u;
static const uint kPGDiagZeroSamples = 4u;
static const uint kPGDiagInvalidPdf = 5u;
static const uint kPGDiagNonfinite = 6u;
static const uint kPGDiagOverflow = 7u;
static const uint kPGDiagUnsupported = 8u;
static const uint kPGDiagGuided = 9u;
static const uint kPGDiagFallback = 10u;
static const uint kPGDiagSecondarySamples = 11u;
static const uint kPGDiagInvalidPath = 12u;
static const uint kPGDiagnosticCount = 16u;

#endif
