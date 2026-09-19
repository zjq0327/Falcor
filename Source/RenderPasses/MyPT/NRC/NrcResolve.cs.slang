// Resolve the real SDK inference output using its public packing contract.
#define NRC_RW_STRUCTURED_BUFFER(T) RWStructuredBuffer<T>
#include "NrcHelpers.hlsli"

cbuffer NrcCB { NrcConstants gNrcConstants; }
StructuredBuffer<NrcPackedQueryPathInfo> gNrcQueryPathInfo;
StructuredBuffer<float3> gNrcQueryRadiance;
Texture2D<float4> gNrcExplicit;
RWTexture2D<float4> gOutputColor;
#ifndef MYPT_HAS_NRC_CACHED
#define MYPT_HAS_NRC_CACHED 0
#endif
#if MYPT_HAS_NRC_CACHED
RWTexture2D<float4> gNrcCached;
#endif

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gNrcConstants.frameDimensions)) return;
    uint index = pixel.y * gNrcConstants.frameDimensions.x + pixel.x;
    NrcQueryPathInfo path = NrcUnpackQueryPathInfo(gNrcQueryPathInfo[index]);
    float3 cached = 0.f;
    if (path.queryBufferIndex != 0xffffffffu)
        cached = path.prefixThroughput * NrcUnpackQueryRadiance(gNrcConstants, gNrcQueryRadiance[path.queryBufferIndex]);
    float3 color = gNrcExplicit[pixel].rgb + cached;
    gOutputColor[pixel] = float4(color, 1.f);
#if MYPT_HAS_NRC_CACHED
    gNrcCached[pixel] = float4(cached, 1.f);
#endif
}
