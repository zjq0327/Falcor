#define RTPT_GRIS_GENERATE 1
#include "../RTPTTransport.slangh"
#include "../DirectLighting/RTPTDICoverage.slang"
#include "../RTPTContinuation.slang"
#include "RTPTGRISReference.slang"

RWStructuredBuffer<GrisStoredRecord> gGRISSpatialInput;
RWStructuredBuffer<GrisLocalContributions> gGRISLocalPrefixes;
#if RTPT_GRIS_SPATIAL_DEEP_INCIDENT
RWStructuredBuffer<float4> gGRISSpatialDeepIncident;
#endif

#include "RTPTGRISGenerateSplit.slang"
