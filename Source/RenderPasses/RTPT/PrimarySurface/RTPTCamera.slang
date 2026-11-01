#pragma once
import Scene.Camera.Camera;
import Utils.Sampling.SampleGenerator;

/** Shared by the primary-surface producer and the path integrators.
    The producer replays the camera stream; the integrator independently reaches
    the same state and continues it. NRD camera jitter consumes no RNG, while the
    ordinary path tracer consumes exactly the original two camera dimensions.
*/
Ray rtptGeneratePrimaryCameraRay(Camera cameraModel, uint2 pixel, uint2 frameDim, inout SampleGenerator sg)
{
#if ENABLE_NRD
    return cameraModel.computeRayPinhole(pixel, frameDim);
#else
    const float2 p = (float2(pixel) + sampleNext2D(sg)) / float2(frameDim);
    const float2 ndc = p * float2(2.f, -2.f) + float2(-1.f, 1.f);
    let camera = cameraModel.data;
    const float3 direction = normalize(ndc.x * camera.cameraU + ndc.y * camera.cameraV + camera.cameraW);
    const float inverseCosine = 1.f / dot(normalize(camera.cameraW), direction);
    return Ray(camera.posW, direction, camera.nearZ * inverseCosine, camera.farZ * inverseCosine);
#endif
}
