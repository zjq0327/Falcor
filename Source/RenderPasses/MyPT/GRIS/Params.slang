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
};
RWStructuredBuffer<PrimaryPathContext> gPrimary;
RWStructuredBuffer<PathReservoir> gFresh;
RWStructuredBuffer<float4> gReference;

uint pixelIndex(uint2 pixel) { return pixel.y * gDimensions.x + pixel.x; }
