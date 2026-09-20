// Include after the pinned SDK declarations. These buffers contain no ray or scene resources.
#ifndef MYPT_QUERY_TRAINING_DATA
#define MYPT_QUERY_TRAINING_DATA
static const uint kRecordActive = 0;
static const uint kRecordCache = 1;
static const uint kRecordMiss = 2;
static const uint kRecordAbsorbed = 3;
static const uint kRecordRR = 4;
static const uint kRecordDepth = 5;
static const uint kRecordOverflow = 6;
static const uint kRecordProbeLimit = 7;
static const uint kRecordNumeric = 8;

struct QueryTrainingPath
{
    uint2 owner;
    uint ownerCandidate;
    uint vertexCount;
    uint reason;
};
RWStructuredBuffer<QueryTrainingPath> gQueryTrainingPaths;
RWStructuredBuffer<NrcPackedPathVertex> gQueryTrainingVertices;

cbuffer QueryTrainingCB
{
    uint2 gRecordFrameDim;
    uint2 gRecordTrainingDim;
    uint gRecordFrameIndex;
    uint gRecordMaxVertices;
    uint gRecordCandidateCount;
    uint gRecordSeed;
}

// Exact inverse of floor(cell * frame / training), also for odd resolutions.
uint2 queryTrainingCell(uint2 pixel)
{
    return ((pixel + 1u) * gRecordTrainingDim - 1u) / gRecordFrameDim;
}
uint queryTrainingIndex(uint2 cell) { return cell.y * gRecordTrainingDim.x + cell.x; }
#endif
