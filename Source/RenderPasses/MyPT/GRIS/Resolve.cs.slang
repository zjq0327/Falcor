import Params;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gPTReference;
RWTexture2D<float4> gReservoirF;
RWTexture2D<float4> gReservoirDebug;
RWTexture2D<float4> gInitialColor;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    uint index = pixelIndex(pixel);
    PathReservoir reservoir = gCurrent[index];
    float3 color = reservoir.sample.F * reservoir.W;
    gColor[pixel] = float4(color, 1.f);
#if GRIS_HAS_INITIAL
    PathReservoir fresh = gFresh[index];
    gInitialColor[pixel] = float4(fresh.sample.F * fresh.W, 1.f);
#endif
#if GRIS_HAS_REFERENCE
    gPTReference[pixel] = gReference[index];
#endif
#if GRIS_HAS_F
    gReservoirF[pixel] = float4(reservoir.sample.F, float(reservoir.sample.terminal));
#endif
#if GRIS_HAS_DEBUG
    gReservoirDebug[pixel] = float4(reservoir.W, float(reservoir.M), float(reservoir.sample.surfaceScatters), float(reservoir.invalidCount));
#endif
}
