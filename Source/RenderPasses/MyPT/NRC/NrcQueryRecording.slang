#include "NrcQueryTrainingData.slang"

struct NrcQueryRecording
{
    uint slot;
    uint count;
    uint reason;
    float3 beta;
    float3 radiance;
};

NrcQueryRecording nrcRecordInit(uint2 pixel, uint candidate = 0u)
{
    NrcQueryRecording result = (NrcQueryRecording)0;
    result.slot = 0xffffffffu;
    result.beta = 1.f;
    uint slot = queryTrainingIndex(queryTrainingCell(pixel));
    if (all(gQueryTrainingPaths[slot].owner == pixel) && gQueryTrainingPaths[slot].ownerCandidate == candidate) result.slot = slot;
    return result;
}

void nrcRecordEnd(inout NrcQueryRecording state, uint reason)
{
    // Preserve rejection reasons; a probe-limit failure overrides Cache.
    if (state.reason < kRecordDepth) state.reason = reason;
}

void nrcRecordRadiance(inout NrcQueryRecording state, float3 local)
{
    if (state.slot == 0xffffffffu || state.count == 0) return;
    state.radiance += state.beta * local;
}

void nrcRecordFlush(inout NrcQueryRecording state)
{
    if (state.slot == 0xffffffffu || state.count == 0 || state.count > gRecordMaxVertices) return;
    if (any(!isfinite(state.beta)) || any(!isfinite(state.radiance)))
    {
        state.reason = kRecordNumeric;
        return;
    }
    uint index = state.slot * gRecordMaxVertices + state.count - 1u;
    gQueryTrainingVertices[index] = NrcUpdateTrainingPathVertex(gQueryTrainingVertices[index], state.radiance, state.beta);
}

void nrcRecordHit(inout NrcQueryRecording state, NrcSurfaceAttributes surface)
{
    if (state.slot == 0xffffffffu || state.reason >= kRecordDepth || surface.isDeltaLobe) return;
    nrcRecordFlush(state);
    if (state.count >= gRecordMaxVertices)
    {
        state.reason = kRecordOverflow;
        return;
    }
    uint index = state.slot * gRecordMaxVertices + state.count;
    gQueryTrainingVertices[index] = NrcInitializePackedPathVertex(surface.roughness,
        surface.shadingNormal, surface.viewVector, surface.diffuseReflectance,
        surface.specularF0, surface.encodedPosition);
    state.count++;
    state.beta = 1.f;
    state.radiance = 0.f;
}

void nrcRecordFinish(inout NrcQueryRecording state)
{
    if (state.slot == 0xffffffffu) return;
    // The direct probe is a separate local estimator. It must not change the
    // terminal bootstrap multiplier, just as QueryPT restores its throughput.
    if (state.reason == kRecordCache) state.beta = 1.f;
    nrcRecordFlush(state);
    QueryTrainingPath record = gQueryTrainingPaths[state.slot];
    record.vertexCount = state.count;
    record.reason = state.reason;
    gQueryTrainingPaths[state.slot] = record;
}
