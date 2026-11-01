#pragma once

// The runtime block comes from the installed RTXDI 1.3 Context. In particular,
// RIS offsets and Grid dimensions are never inferred from a sample's light ID.
// Include this after rtxdi/RtxdiParameters.h.
struct RTPTReGIRBuildSettings
{
    uint slotCount;
    uint buildSamples;
    uint pad0;
    uint pad1;
};

ConstantBuffer<RTXDI_ResamplingRuntimeParameters> gReGIRRuntime;
ConstantBuffer<RTPTReGIRBuildSettings> gReGIRBuildSettings;

// The SDK parses its store helpers in the Initial shader as well as the build
// shader, so its resource declaration must be RW. Initial never writes it. The
// host publishes a completed grid with a UAV barrier before any consumer runs.
RWStructuredBuffer<uint2> gReGIRRIS;
