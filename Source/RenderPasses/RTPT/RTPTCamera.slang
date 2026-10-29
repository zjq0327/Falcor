#pragma once

inline float rtptCameraScalarDot(float3 a, float3 b)
{
    precise float x = a.x * b.x;
    precise float y = a.y * b.y;
    precise float z = a.z * b.z;
    precise float xy = x + y;
    precise float result = xy + z;
    return result;
}

inline float3 rtptCameraNormalize(float3 value)
{
    precise float lengthSquared = rtptCameraScalarDot(value, value);
    precise float inverseLength = rsqrt(lengthSquared);
    precise float3 result = value * inverseLength;
    return result;
}

// Shared camera construction only. Callers own their independent RNG streams.
Ray rtptCameraRay(uint2 pixel, uint2 frameDim, bool useNRD, inout SampleGenerator sg)
{
    let camera = gScene.camera.data;
    // Keep the camera arithmetic invariant across the separate primary producer
    // and integrator programs. A few ulps here change hit barycentrics and can
    // send otherwise identical downstream path samples in different directions.
    precise float2 p;
    precise float2 ndc;
    if (useNRD)
    {
        // Match Camera.computeRayPinhole(): pixel center, jitter, then NDC.
        p = (float2(pixel) + float2(0.5f, 0.5f)) / float2(frameDim);
        p += float2(-camera.jitterX, camera.jitterY);
        ndc = float2(2.f, -2.f) * p + float2(-1.f, 1.f);
    }
    else
    {
        // Preserve the original PT camera formula and its single RNG draw.
        p = (float2(pixel) + sampleNext2D(sg)) / float2(frameDim);
        ndc = p * float2(2.f, -2.f) + float2(-1.f, 1.f);
    }
    precise float3 unnormalizedDirection = ndc.x * camera.cameraU + ndc.y * camera.cameraV + camera.cameraW;
    precise float3 direction = rtptCameraNormalize(unnormalizedDirection);
    precise float3 cameraForward = rtptCameraNormalize(camera.cameraW);
    precise float inverseCosine = 1.f / rtptCameraScalarDot(cameraForward, direction);
    precise float nearDistance = camera.nearZ * inverseCosine;
    precise float farDistance = camera.farZ * inverseCosine;
    return Ray(camera.posW, direction, nearDistance, farDistance);
}
