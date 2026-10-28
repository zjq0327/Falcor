#pragma once
#include "../RTPTLightTypes.slang"

struct RTPTLocalLightParams
{
    uint2 frameDim;
    uint frameSerial;
    uint sceneGeneration;
    uint proposalGeneration;
    uint sampleOffset;
    uint seed;
    uint queryKind;
    uint gridEnabled;
    uint fullEmissiveCapacity;
    uint fullAnalyticCapacity;
    uint3 fullDim;
    float3 fullOrigin;
    float3 fullCellExtent;
    uint cdfEnabled;
    uint persistentEnabled;
    uint gridGeneration;
    uint tileEnabled;
    uint adaptiveEnabled;
    uint debugEnabled;
    uint gridCellCount;
    uint tileCandidates;
    uint historyFrames;
    uint historyStaleFrames;
    uint mergeFrames;
    uint feedbackStride;
    uint feedbackCount;
    uint2 feedbackDim;
    uint2 baseTileDim;
    uint tileNodeCount;
    uint primaryValid;
    uint historyValid;
    uint debugMode;
    uint2 debugPixel;
    float depthThreshold;
    float normalCosThreshold;
    uint useNEE;
    float3 cameraPosition;
    float4x4 viewProjNoJitter;
    float4x4 previousViewProjNoJitter;
};

// Four 16-byte lanes: the same record is used for sparse observations and
// persistent/reprojected history. positionScore.w may be zero for a valid event.
struct RTPTLocalLightFeedbackRecord
{
    float4 positionScore;
    float4 normalWeight;
    uint4 key;       // kind, scene index, scene generation, last observation frame
    uint4 pixelInfo; // source/current pixel xy, valid, observation count
};

// Captured from the actual NEE event, never by rerunning its random stream.
struct RTPTLocalLightDebugEvent
{
    float4 positionPmf;
    float4 normalPdf;
    float4 targetReference;
    float4 directionRaw;
    uint4 identity;   // kind, index, source branch, flags(valid/visible/delta)
    uint4 context;    // pixel xy, absolute sample index, query kind
    uint4 generation; // frame, scene, proposal, path depth
};

// PMFs are conditional on an already selected light category. The public
// lighting adapter applies the category probability and geometry density.
struct RTPTLocalLightSelection
{
    RTPTLightKey key;
    float selectionPmf;
    float referenceSelectionPmf;
    uint sourceBranch;
    uint snapshotGeneration;
};
