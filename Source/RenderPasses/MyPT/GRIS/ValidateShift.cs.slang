import ReuseHelpers;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    uint index = pixelIndex(pixel);
    PrimaryPathContext primary = gPrimary[index];
    PathSample sample = gFresh[index].sample;
    float4 debug = 0.f;
    if (HitInfo(primary.hit).isValid() && hasShiftIdentity(sample))
    {
        ShiftResult identity = shiftInline(sample, primary, primary, true);
        debug.x = relativeContributionError(identity.sample.F, sample.F);
        debug.y = abs(identity.jacobian - 1.f);
        if (identity.failure > 0 && identity.failure < 24) debug.w = float(1u << identity.failure);
    }
    gShiftDebug[pixel] = debug;
}
