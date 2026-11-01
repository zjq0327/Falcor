#pragma once
#include "RTPTDITypes.slang"

#ifndef RTPT_DI_REUSE_ENABLED
#define RTPT_DI_REUSE_ENABLED 0
#endif

#ifndef RTPT_DI_WRITE_CATALOG
#define RTPT_DI_WRITE_CATALOG 0
#endif
#ifndef RTPT_DI_WRITE_SAMPLE_RECORDS
#define RTPT_DI_WRITE_SAMPLE_RECORDS 0
#endif
#ifndef RTPT_DI_WRITE_RESULTS
#define RTPT_DI_WRITE_RESULTS 0
#endif

ConstantBuffer<RTPTDISettings> gDISettings;
#if RTPT_DI_REUSE_ENABLED
ConstantBuffer<RTPTDIReuseSettings> gDIReuseSettings;
#endif

#if RTPT_DI_WRITE_CATALOG
RWStructuredBuffer<RTPTDILightInfo> gDILightCatalog;
#else
StructuredBuffer<RTPTDILightInfo> gDILightCatalog;
#endif

StructuredBuffer<uint> gDIUncoveredAnalyticIndices;

#if RTPT_DI_WRITE_SAMPLE_RECORDS
RWStructuredBuffer<RTPTDISampleRecord> gDISampleRecords;
#else
StructuredBuffer<RTPTDISampleRecord> gDISampleRecords;
#endif

#if RTPT_DI_WRITE_RESULTS
RWStructuredBuffer<RTPTDIResult> gDIResults;
#else
StructuredBuffer<RTPTDIResult> gDIResults;
#endif
