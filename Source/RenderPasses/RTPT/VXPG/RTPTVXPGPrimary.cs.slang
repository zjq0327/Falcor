/** Copy the shared primary view into the current VXPG model snapshot.
    This adapter preserves VXPG overflow/counter semantics without tracing rays.
    Frozen models never dispatch it and retain their own primary textures. */
#include "RTPTVXPGDiagnostics.slang"


Texture2D<float4> gPrimarySourcePosition;
Texture2D<float4> gPrimarySourceNormalRoughness;
Texture2D<uint4> gPrimarySourceHit;

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    if (any(tid.xy >= gVXPGParams.frameDim)) return;
    const uint2 pixel = tid.xy;
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0)
    {
        gVXPGPrimaryPosition[pixel] = 0.f;
        gVXPGPrimaryNormal[pixel] = 0.f;
        gVXPGPrimaryHit[pixel] = 0u;
        return;
    }
    rtptVXPGCount(RTPT_VXPG_STATE_INJECT_PRIMARY);
    gVXPGPrimaryPosition[pixel] = gPrimarySourcePosition[pixel];
    gVXPGPrimaryNormal[pixel] = gPrimarySourceNormalRoughness[pixel];
    gVXPGPrimaryHit[pixel] = gPrimarySourceHit[pixel];
}
