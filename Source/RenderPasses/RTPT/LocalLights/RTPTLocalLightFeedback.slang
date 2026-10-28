#pragma once
#include "RTPTLocalLightModel.slang"

void rtptLocalRecordFeedback(RTPTLightingContext context, RTPTLightSample light, float3 rawAfterVisibility, bool visible, bool visibilityTested=false)
{
    if (context.kind != RTPT_LIGHT_QUERY_MAIN_PRIMARY || context.pathDepth != 0u ||
        any(context.pixel >= gLocalLightParams.frameDim) || gLocalLightParams.useNEE == 0u) return;
    const uint firstSample = gLocalLightParams.sampleOffset + gLocalLightParams.seed * 0x9e3779b9u;
    if (context.sampleIndex != firstSample) return;
    if (light.key.kind == RTPT_LIGHT_KIND_INVALID || light.key.kind == RTPT_LIGHT_KIND_ENVIRONMENT ||
        light.key.index == RTPT_LOCAL_LIGHT_INVALID || !all(isfinite(rawAfterVisibility)) ||
        !isfinite(light.selectionPmf) || !isfinite(light.samplePdf) || !isfinite(light.misReferencePdf) ||
        light.key.sceneGeneration != gLocalLightParams.sceneGeneration ||
        light.snapshotGeneration != gLocalLightParams.proposalGeneration) return;
    const float score = visible ? max(0.f,max(rawAfterVisibility.x,max(rawAfterVisibility.y,rawAfterVisibility.z))) : 0.f;
    if (gLocalLightParams.debugEnabled != 0u)
    {
        const uint flags = 1u | (visible ? 2u : 0u) | (light.delta ? 4u : 0u) | (visibilityTested ? 8u : 0u);
        gLocalDebugEvents[context.pixel] = uint4(light.key.kind, light.key.index, light.sourceBranch, flags);
        if (all(context.pixel == gLocalLightParams.debugPixel))
        {
            RTPTLocalLightDebugEvent event = {};
            event.positionPmf = float4(context.positionW, light.selectionPmf);
            event.normalPdf = float4(context.normalW, light.samplePdf);
            event.targetReference = float4(light.targetPosition, light.misReferencePdf);
            event.directionRaw = float4(light.dir, score);
            event.identity = uint4(light.key.kind, light.key.index, light.sourceBranch, flags);
            event.context = uint4(context.pixel, context.sampleIndex, context.kind);
            event.generation = uint4(gLocalLightParams.frameSerial,gLocalLightParams.sceneGeneration,gLocalLightParams.proposalGeneration,context.pathDepth);
            gLocalDebugSelected[0] = event;
        }
    }
    if (gLocalLightParams.tileEnabled == 0u) return;
    const uint stride = gLocalLightParams.feedbackStride;
    const uint2 tile = context.pixel / stride, origin = tile * stride;
    const uint index = tile.x + tile.y * gLocalLightParams.feedbackDim.x;
    const uint2 extent = min(uint2(stride), gLocalLightParams.frameDim - origin);
    const uint phase = (rtptLocalHash(index ^ gLocalLightParams.seed) + gLocalLightParams.frameSerial) % (extent.x * extent.y);
    const uint2 chosen = origin + uint2(phase % extent.x,phase / extent.x);
    if (any(chosen != context.pixel)) return;
    RTPTLocalLightFeedbackRecord record = {};
    record.positionScore = float4(context.positionW, min(score,1.e6f));
    record.normalWeight = float4(context.normalW,1.f);
    record.key = uint4(light.key.kind,light.key.index,gLocalLightParams.sceneGeneration,gLocalLightParams.frameSerial);
    record.pixelInfo = uint4(context.pixel,1u,1u);
    gLocalCurrentFeedback[index] = record;
}
