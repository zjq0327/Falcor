// Buffer conversion only. No acceleration structure, sampling, or ray API.
// Select the SDK's training-record helpers, not a tracing mode or dispatch.
#define NRC_UPDATE 1
#include "Nrc.hlsli"
#include "NrcQueryTrainingData.slang"
cbuffer NrcCB { NrcConstants gNrcConstants; }
RWStructuredBuffer<NrcPackedTrainingPathInfo> gNrcTrainingPathInfo;
RWStructuredBuffer<NrcPackedPathVertex> gNrcTrainingPathVertices;
RWStructuredBuffer<NrcRadianceParams> gNrcQueryRadianceParams;
RWStructuredBuffer<uint> gNrcCountersData;
#if MYPT_HAS_NRC_TRAINING_DEBUG
RWTexture2D<uint4> gNrcTrainingDebug;
#endif
#if MYPT_HAS_NRC_QUERY_TRAINING_DEBUG
RWTexture2D<uint4> gNrcQueryTrainingDebug;
#endif

[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint2 cell = id.xy;
    if (any(cell >= gRecordTrainingDim)) return;
    uint slot = queryTrainingIndex(cell);
    QueryTrainingPath record = gQueryTrainingPaths[slot];
    bool valid = record.vertexCount > 0 && record.vertexCount <= gRecordMaxVertices &&
        (record.reason == kRecordCache || record.reason == kRecordMiss ||
         record.reason == kRecordAbsorbed || record.reason == kRecordRR);
    NrcTrainingPathInfo info = (NrcTrainingPathInfo)0;
    info.queryBufferIndex = 0xffffffffu;
    uint bootstrap = 0;
    if (valid)
    {
        NrcSetVertexCount(info.packedData, record.vertexCount);
        // Absorption/RR have zero terminal transport; the same SDK path flag
        // disables bootstrap. Do not set the SDK's unbiased-training flag.
        if (record.reason != kRecordCache) NrcSetFlag(info.packedData, nrcPathFlagHasExitedScene);
        for (uint i = 0; i < record.vertexCount; ++i)
        {
            uint dst = NrcCalculateTrainingPathVertexIndex(gNrcConstants.trainingDimensions, cell, i, gNrcConstants.maxPathVertices);
            gNrcTrainingPathVertices[dst] = gQueryTrainingVertices[slot * gRecordMaxVertices + i];
        }
        if (record.reason == kRecordCache)
        {
            // Follow SDK NrcWriteFinalPathInfo's terminal-feature packing.
            NrcPackedPathVertex packed = gQueryTrainingVertices[slot * gRecordMaxVertices + record.vertexCount - 1u];
            NrcPathVertex vertex = NrcUnpackPathVertex(packed, float3(0.f), float3(1.f));
            uint query = NrcIncrementCounter(gNrcCountersData, NrcCounter::Queries);
            gNrcQueryRadianceParams[query] = NrcCreateRadianceParams(vertex);
            info.queryBufferIndex = query;
            bootstrap = 1;
        }
    }
    gNrcTrainingPathInfo[NrcCalculateTrainingPathIndex(gNrcConstants.trainingDimensions, cell)] = NrcPackTrainingPathInfo(info);
#if MYPT_HAS_NRC_TRAINING_DEBUG
    gNrcTrainingDebug[record.owner] = uint4(0u, 0u, 0u, valid ? record.vertexCount : 0u);
#endif
#if MYPT_HAS_NRC_QUERY_TRAINING_DEBUG
    // x=termination reason (0 includes empty/background), y=recorded vertices,
    // z=accepted vertices, w=training bootstrap queries. All geometry rays are zero.
    gNrcQueryTrainingDebug[record.owner] = uint4(record.reason, record.vertexCount, valid ? record.vertexCount : 0u, bootstrap);
#endif
}
