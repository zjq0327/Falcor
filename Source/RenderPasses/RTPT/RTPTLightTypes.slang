#pragma once
#include "LocalLights/RTPTLocalLightLayout.slangh"
import Utils.Math.Ray;

// Indices refer to the scene light table or the full emissive-triangle table,
// never the transient position of an item in a filtered candidate list.
struct RTPTLightKey
{
    uint kind;
    uint index;
    uint sceneGeneration;
};

// kind is explicit: a short branch's local bounce zero is still Secondary.
struct RTPTLightingContext
{
    float3 positionW;
    float3 normalW;
    uint2 pixel;
    uint sampleIndex;
    uint pathDepth;
    uint kind;
    uint snapshotGeneration;
};

RTPTLightingContext rtptMakeLightContext(
    float3 positionW, float3 normalW, uint2 pixel, uint sampleIndex, uint pathDepth, uint kind)
{
    RTPTLightingContext context = {};
    context.positionW = positionW;
    context.normalW = normalW;
    context.pixel = pixel;
    context.sampleIndex = sampleIndex;
    context.pathDepth = pathDepth;
    context.kind = kind;
    return context;
}

RTPTLightingContext rtptMakeLightContext(uint2 pixel, uint sampleIndex, uint pathDepth, uint kind)
{
    return rtptMakeLightContext(float3(0.f), float3(0.f), pixel, sampleIndex, pathDepth, kind);
}

// All continuous directional densities use the solid-angle measure.
// LiOverPdf uses the actual sampling density including category selection.
// misReferencePdf is a separate partitioning density used by both NEE and
// emitter-hit MIS. Delta analytic lights legitimately have zero directional
// density; their selectionPmf and analytic flag retain the discrete semantics.
struct RTPTLightSample
{
    float3 dir;
    float3 LiOverPdf;
    float samplePdf;
    float misReferencePdf;
    float selectionPmf;
    float referenceSelectionPmf;
    RTPTLightKey key;
    uint sourceBranch;
    uint snapshotGeneration;
    bool analytic;
    bool delta;
    float3 targetPosition;
    bool finiteTarget;
    Ray visibilityRay;
};
