#pragma once

static const uint kRTPTDILightEmissive = 1u;
static const uint kRTPTDILightPoint = 2u;
static const uint kRTPTDICoverEmissive = 1u;
static const uint kRTPTDICoverPoint = 2u;

static const uint kRTPTDIResultPrepared = 1u;
static const uint kRTPTDIResultSampleValid = 2u;
static const uint kRTPTDIResultVisible = 4u;
static const uint kRTPTDIResultInvalidIdentity = 8u;

/** One current-frame catalogue entry (32 B). sourceIndex is a fast current
    scene lookup; kind/stable0/stable1 plus generation identify the light.
    sourcePMF is the canonical global-mode PMF/identity metadata, not the ReGIR
    cell proposal or a direction PDF. ReGIR uses its actual cell candidate count.
    pad0 is the stable ReGIR ID mapped separately to the current catalogue rank.
*/
struct RTPTDILightInfo
{
    uint kind;
    uint sourceIndex;
    uint stable0;
    uint stable1;
    uint generation;
    float sourcePMF;
    uint pad0;
    uint pad1;
};

/** Persistent sample identity (32 B). Keep full-precision UV for this Initial
    implementation; SDK uvData remains intact but is not the reconstruction UV.
*/
struct RTPTLightSampleRef
{
    uint kind;
    uint stable0;
    uint stable1;
    uint generation;
    float2 sampleUV;
    float sourcePMF;
    uint sourceIndex;
};

struct RTPTDISampleRecord
{
    RTPTLightSampleRef sample;
    uint sampleIndex;
    uint frameStamp;
    uint flags;
    uint coverageMask;
};

/** Materialized current-surface direct light (48 B). Prepared is independent
    of whether the reservoir has a winner, its RGB, and its final visibility.
*/
struct RTPTDIResult
{
    float3 diffuse;
    uint flags;
    float3 specular;
    float lightDistance;
    uint generation;
    uint sampleIndex;
    uint frameStamp;
    uint coverageMask;
};

struct RTPTDISettings
{
    uint2 frameDim;
    uint sampleIndex;
    uint frameStamp;
    uint lightCount;
    uint generation;
    uint candidateCount;
    uint coverageMask;
    uint prepared;
    uint uncoveredAnalyticCount;
};

/** Reuse-only control block. The old Initial-only settings/layout stay intact.
    All banks are row-major, with one standard packed reservoir and one full-UV
    sample record per pixel. History is published only after its input is read.
*/
struct RTPTDIReuseSettings
{
    uint enabled;
    uint historyValid;
    uint inputBank;
    uint outputBank;
    uint historyBank;
    uint historyFrameStamp;
    uint historySampleIndex;
    uint historyGeneration;
    uint maxHistoryLength;
    uint spatialSamples;
    float spatialRadius;
    float depthThreshold;
    float normalThreshold;
    uint bankCount;
    uint finalInputBank;
    uint historyInputBank;
    float4x4 previousViewProj;
};

RTPTLightSampleRef rtptDIMakeSampleRef(RTPTDILightInfo light, float2 uv)
{
    RTPTLightSampleRef result = {};
    result.kind = light.kind;
    result.stable0 = light.stable0;
    result.stable1 = light.stable1;
    result.generation = light.generation;
    result.sampleUV = uv;
    result.sourcePMF = light.sourcePMF;
    result.sourceIndex = light.sourceIndex;
    return result;
}

bool rtptDIMatchesSampleRef(RTPTDILightInfo light, RTPTLightSampleRef sample)
{
    return light.kind == sample.kind && light.stable0 == sample.stable0 && light.stable1 == sample.stable1 &&
        light.generation == sample.generation && light.sourceIndex == sample.sourceIndex && light.sourcePMF == sample.sourcePMF;
}
