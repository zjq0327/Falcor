__exported import PathState;
__exported import PathReservoir;

cbuffer CB
{
    uint2 gDimensions;
    uint gFrameIndex;
    uint gSeed;
    uint gCandidateCount;
    uint gMaxSurfaceBounces;
    float gRRProbability;
    uint gSpatialNeighborCount;
    uint gSpatialRound;
    float gSpatialRadius;
    float gSpatialDepthThreshold;
    float gSpatialNormalThreshold;
    int2 gSpatialNeighborOffset;
    uint gHistoryValid;
    uint gTemporalReprojection;
    uint gMaxHistoryLength;
    float gTemporalDepthThreshold;
    float gTemporalNormalThreshold;
    float4x4 gPreviousViewProj;
    float3 gPreviousCameraPosition;
};
RWStructuredBuffer<PrimaryPathContext> gPrimary;
RWStructuredBuffer<PathReservoir> gFresh;
RWStructuredBuffer<float4> gReference;
StructuredBuffer<PathReservoir> gCurrent;
StructuredBuffer<PathReservoir> gTemporal;

uint pixelIndex(uint2 pixel) { return pixel.y * gDimensions.x + pixel.x; }
