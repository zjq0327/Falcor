#pragma once
#include "RTPTLocalLightTypes.slang"

// The frame proposal is immutable during rendering. Only the distinct current
// feedback and diagnostic event banks are written by NEE.
// The history banks are merged/swapped after rendering, for the next frame.
ConstantBuffer<RTPTLocalLightParams> gLocalLightParams;

Texture2D<float4> gLocalPrimaryPosition;
Texture2D<float4> gLocalPrimaryNormalRoughness;
Texture2D<uint4> gLocalPrimaryHit;
globallycoherent RWStructuredBuffer<int4> gLocalGridKeys;
RWStructuredBuffer<uint4> gLocalGridCount;
RWStructuredBuffer<uint> gLocalFullCdf;
// Immutable hot light descriptors, one per catalog entry rather than per cell.
struct RTPTFullLightDescriptor { float4 centerPower; float4 extentInfinite; };
RWStructuredBuffer<RTPTFullLightDescriptor> gLocalFullCatalog;
// x publication frame, y ready generation, z generation, w build frame.
RWStructuredBuffer<uint4> gLocalGridState;
// built, reserved reuse/retirement/allocation/overflow/cell counters,
// debug-only actual query count, debug-only missing-cell query count.
RWStructuredBuffer<uint> gLocalGridStats;
RWStructuredBuffer<uint4> gLocalTileState;
RWStructuredBuffer<uint2> gLocalTileLights;
RWStructuredBuffer<float> gLocalTileWeights;
RWTexture2D<uint> gLocalPixelToTile;
RWStructuredBuffer<RTPTLocalLightFeedbackRecord> gLocalHistory;
RWStructuredBuffer<RTPTLocalLightFeedbackRecord> gLocalReprojectedHistory;
RWStructuredBuffer<RTPTLocalLightFeedbackRecord> gLocalProjectionRecords;
RWStructuredBuffer<uint> gLocalHistoryWinners;
RWStructuredBuffer<RTPTLocalLightFeedbackRecord> gLocalCurrentFeedback;
RWStructuredBuffer<RTPTLocalLightFeedbackRecord> gLocalHistoryNext;
RWStructuredBuffer<RTPTLocalLightFeedbackRecord> gLocalProbeFeedback;
RWTexture2D<uint4> gLocalDebugEvents;
RWStructuredBuffer<RTPTLocalLightDebugEvent> gLocalDebugSelected;
