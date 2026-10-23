#pragma once

// Shared camera construction only. Callers own their independent RNG streams.
Ray rtptCameraRay(uint2 pixel, uint2 frameDim, bool useNRD, inout SampleGenerator sg)
{
    if (useNRD) return gScene.camera.computeRayPinhole(pixel, frameDim);
    const float2 p = (float2(pixel) + sampleNext2D(sg)) / float2(frameDim);
    const float2 ndc = p * float2(2.f, -2.f) + float2(-1.f, 1.f);
    let camera = gScene.camera.data;
    const float3 direction = normalize(ndc.x * camera.cameraU + ndc.y * camera.cameraV + camera.cameraW);
    const float inverseCosine = 1.f / dot(normalize(camera.cameraW), direction);
    return Ray(camera.posW, direction, camera.nearZ * inverseCosine, camera.farZ * inverseCosine);
}
