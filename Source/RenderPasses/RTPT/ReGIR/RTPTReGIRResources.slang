#pragma once

// World-space logarithmic cells use ReGIR-owned spatial and resource settings.
struct RTPTReGIRSettings
{
    float3 cameraPosition;
    float baseCellSize;
    float coarsenCellDistance;
    float brightnessThreshold;
    uint cellCapacity;
    uint lightsPerCell;
    uint slotCount;
    uint buildSamples;
    float samplingJitter;
    uint active;
    uint lightCount;
    uint cullingEnabled;
    uint generation;
    uint coverageMask;
    uint uncoveredAnalyticCount;
    uint secondaryEnabled;
    uint trainingEnabled;
    uint stableIdCount;
    uint candidateCapacity;
    uint listEpoch;
    uint frameStamp;
};

ConstantBuffer<RTPTReGIRSettings> gReGIRSettings;

// Each 64-byte descriptor is keyed by stable light ID, not catalogue rank.
// Infinite power means that no finite brightness bound is available: retain
// distance support (e.g. emissive textures / light profiles without a max bound).
struct RTPTReGIRLightDescriptor
{
    float3 boundsMin;
    float power;
    float3 boundsMax;
    uint flags;
    float3 direction;
    float cosOpeningAngle;
    float3 position;
    uint pad;
};

static const uint kRTPTReGIRDescriptorActive = 1u;
static const uint kRTPTReGIRDescriptorTriangle = 2u;
static const uint kRTPTReGIRDescriptorPoint = 4u;
static const uint kRTPTReGIRDescriptorDoubleSided = 8u;

globallycoherent RWStructuredBuffer<uint64_t> gReGIRCells;
// x=pool offset, y=complete candidate count, z=allocated capacity, w=state.
// A ready record with count > capacity is a complete procedural cell list.
globallycoherent RWStructuredBuffer<uint4> gReGIRCellMeta;
globallycoherent RWStructuredBuffer<uint> gReGIRCellEpoch;
globallycoherent RWStructuredBuffer<uint> gReGIRCandidateIDs;
RWStructuredBuffer<uint> gReGIRCellRISFrame;
RWStructuredBuffer<uint> gReGIRCellLastUsed;
RWStructuredBuffer<uint> gReGIRState;
RWStructuredBuffer<RTPTReGIRLightDescriptor> gReGIRLightDescriptors;
StructuredBuffer<RTPTReGIRLightDescriptor> gReGIRPreviousLightDescriptors;
RWStructuredBuffer<uint> gReGIRDirtyLightIDs;

#include "../DirectLighting/RTPTDITypes.slang"
StructuredBuffer<RTPTDILightInfo> gReGIRCatalog;
StructuredBuffer<uint> gReGIRIdToCatalog;

// SDK presampling helpers require RW even in a read-only consumer.
RWStructuredBuffer<uint2> gReGIRRIS;
