cbuffer CB
{
    uint2 frameDim;
    float opacity;
};
Texture2D<float4> gColor;
Texture2D<float4> gDebug;
RWTexture2D<float4> gOutput;

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    if (any(tid.xy >= frameDim)) return;
    uint colorWidth, colorHeight, debugWidth, debugHeight;
    gColor.GetDimensions(colorWidth, colorHeight);
    gDebug.GetDimensions(debugWidth, debugHeight);
    uint2 colorPixel = min(uint2(float2(tid.xy) * float2(colorWidth, colorHeight) / float2(frameDim)), uint2(colorWidth, colorHeight) - 1);
    uint2 debugPixel = min(uint2(float2(tid.xy) * float2(debugWidth, debugHeight) / float2(frameDim)), uint2(debugWidth, debugHeight) - 1);
    float4 color = gColor[colorPixel];
    float4 debug = gDebug[debugPixel];
    gOutput[tid.xy] = float4(lerp(color.rgb, debug.rgb, saturate(debug.a * opacity)), color.a);
}
