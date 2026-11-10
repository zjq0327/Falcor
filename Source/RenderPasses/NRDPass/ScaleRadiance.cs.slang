// Preserve the denoiser's RGB units when it is bypassed. Texture loads avoid
// sampler rounding, and scaling precedes the conversion to the FP16 output.
cbuffer PerImageCB
{
    float gRadianceScale;
};

Texture2D<float4> gInput;
RWTexture2D<float4> gOutput;

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint width, height;
    gOutput.GetDimensions(width, height);
    if (any(dispatchThreadId.xy >= uint2(width, height))) return;

    float4 value = gInput[dispatchThreadId.xy];
    value.rgb *= gRadianceScale;
    gOutput[dispatchThreadId.xy] = value;
}
