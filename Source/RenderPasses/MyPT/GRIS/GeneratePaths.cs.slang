import Scene.Shading;
import Utils.Math.HashUtils;
import Params;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    PrimaryPathContext primary;
    primary.hit = gVBuffer[pixel];
#if GRIS_HAS_VIEW
    primary.direction = -gViewW[pixel].xyz;
#else
    primary.direction = gScene.camera.computeRayPinhole(pixel, gDimensions).dir;
#endif
    primary.seed = jenkinsHash(pixelIndex(pixel) ^ jenkinsHash(gFrameIndex) ^ jenkinsHash(gSeed + 0x9e3779b9u));
    uint index = pixelIndex(pixel);
    gPrimary[index] = primary;
    gFresh[index] = {};
    gReference[index] = 0.f;
}
