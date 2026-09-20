// Include SDK buffer declarations without selecting an update/query mode.
#include "Nrc.hlsli"
#include "NrcQueryTrainingData.slang"
import Utils.Math.HashUtils;

[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint2 cell = id.xy;
    if (any(cell >= gRecordTrainingDim)) return;
    uint2 begin = cell * gRecordFrameDim / gRecordTrainingDim;
    uint2 end = (cell + 1u) * gRecordFrameDim / gRecordTrainingDim;
    uint h = jenkinsHash(queryTrainingIndex(cell));
    uint2 jitter = uint2(jenkinsHash(h ^ gRecordFrameIndex), jenkinsHash(h ^ gRecordFrameIndex ^ 0x9e3779b9u));
    QueryTrainingPath record = {};
    record.owner = begin + jitter % max(uint2(1u), end - begin);
    // Multiply-high maps all 32 random bits without a float rounding to K.
    uint pick = jenkinsHash(h ^ gRecordFrameIndex ^ jenkinsHash(gRecordSeed) ^ 0x85ebca6bu);
    record.ownerCandidate = uint((uint64_t(pick) * uint64_t(max(gRecordCandidateCount, 1u))) >> 32);
    gQueryTrainingPaths[queryTrainingIndex(cell)] = record;
}
