#ifndef MYPT_PG_PARAMS_SLANG
#define MYPT_PG_PARAMS_SLANG

#include "SDTree.slang"
#include "PathRecord.slang"

cbuffer PGTreeCB
{
    float3 gPGSceneMin;
    uint gPGReadSpatialCount;
    float3 gPGSceneMax;
    uint gPGReadDirectionalCount;
    uint gPGBuildSpatialCount;
    uint gPGBuildDirectionalCount;
    uint gPGTreeGeneration;
    uint gPGTreePadding;
}

cbuffer PGFrameCB
{
    uint2 gPGFrameDim;
    uint gPGTrain;
    uint gPGUseGuiding;
    float gPGGuideFraction;
    uint gPGOwnerTileSize;
    uint gPGPathCapacity;
    uint gPGRecordsPerPath;
    uint gPGOwnerSeed;
    uint gPGFrameIndex;
    uint gPGFramePadding0;
    uint gPGFramePadding1;
}

StructuredBuffer<PGSpatialNode> gPGReadSpatial;
StructuredBuffer<PGDirectionalNode> gPGReadDirectional;
StructuredBuffer<PGSpatialNode> gPGBuildSpatial;
StructuredBuffer<PGDirectionalNode> gPGBuildDirectional;
RWStructuredBuffer<uint> gPGBuildWeightBits;
RWStructuredBuffer<uint> gPGBuildSpatialCounts;
RWStructuredBuffer<PGPathHeader> gPGPathHeaders;
RWStructuredBuffer<PGVertexRecord> gPGVertexRecords;
RWStructuredBuffer<uint> gPGDiagnostics;

void pgDiagnostic(uint counter)
{
    if (gPGTrain != 0u) InterlockedAdd(gPGDiagnostics[counter], 1u);
}

bool pgHasGuide(float3 position)
{
    if (gPGReadSpatialCount == 0u || gPGReadDirectionalCount == 0u) return false;
    uint spatial = pgLookupSpatial(gPGReadSpatial, gPGSceneMin, gPGSceneMax, position);
    if (spatial >= gPGReadSpatialCount) return false;
    uint root = gPGReadSpatial[spatial].directionalRoot;
    if (root >= gPGReadDirectionalCount) return false;
    return pgDirectionalMass(gPGReadDirectional, root) > 0.f;
}

float pgGuidePdf(float3 position, float3 direction)
{
    uint spatial = pgLookupSpatial(gPGReadSpatial, gPGSceneMin, gPGSceneMax, position);
    if (spatial >= gPGReadSpatialCount) return 0.f;
    return pgDirectionalPdf(gPGReadDirectional, gPGReadSpatial[spatial].directionalRoot, direction);
}

void pgSampleGuide(float3 position, float2 random, out float3 direction, out float pdf)
{
    uint spatial = pgLookupSpatial(gPGReadSpatial, gPGSceneMin, gPGSceneMax, position);
    pgSampleDirectional(gPGReadDirectional, gPGReadSpatial[spatial].directionalRoot, random, direction, pdf);
}

bool pgRecordGuide(float3 position, float3 direction, float weight)
{
    if (gPGBuildSpatialCount == 0u || gPGBuildDirectionalCount == 0u) return false;
    uint spatial = pgLookupSpatial(gPGBuildSpatial, gPGSceneMin, gPGSceneMax, position);
    if (spatial >= gPGBuildSpatialCount) return false;
    uint slot = pgLookupDirectionalSlot(gPGBuildDirectional, gPGBuildSpatial[spatial].directionalRoot, direction);
    if (slot >= 4u * gPGBuildDirectionalCount) return false;
    if (!pgAtomicAddWeight(gPGBuildWeightBits, slot, weight)) return false;
    // Zero-radiance observations are still spatial visits.
    InterlockedAdd(gPGBuildSpatialCounts[spatial], 1u);
    return true;
}

#endif
