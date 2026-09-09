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
};
RWStructuredBuffer<PrimaryPathContext> gPrimary;
RWStructuredBuffer<PathReservoir> gFresh;
RWStructuredBuffer<float4> gReference;
StructuredBuffer<PathReservoir> gCurrent;

uint pixelIndex(uint2 pixel) { return pixel.y * gDimensions.x + pixel.x; }
