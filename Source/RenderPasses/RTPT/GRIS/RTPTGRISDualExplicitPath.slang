#pragma once

uint rtptGrisDualExplicitLateCount(uint maxBounces)
{
    // NEE at x4..x(max-1), plus BSDF endpoints at x4..x(max).
    return maxBounces > 3u ? 2u * (maxBounces - 3u) - 1u : 0u;
}

uint2 rtptGrisDualExplicitBeginPath()
{
    return uint2(2166136261u, 2246822519u);
}

uint2 rtptGrisDualExplicitAppendHit(uint2 pathID, PackedHitInfo hit)
{
    const TriangleHit triangle = HitInfo(hit).getTriangleHit();
    // The fixed x2 and RNG reconstruct the coordinates. The signature
    // checks the primitive sequence without relying on bit-exact hit UVs.
    pathID = (pathID ^ triangle.instanceID.index) * uint2(16777619u, 3266489917u);
    return (pathID ^ triangle.primitiveIndex) * uint2(16777619u, 668265263u);
}

uint2 rtptGrisDualExplicitAppendMiss(uint2 pathID)
{
    return (pathID ^ uint2(0x85ebca6bu, 0xc2b2ae35u)) * uint2(16777619u, 3266489917u);
}

#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
bool rtptGrisDualExplicitInfiniteRayClear(Ray ray, uint count)
{
    if (count == 0u) return false;
    // Restrict the certificate to the distance spanned by moved bounds.
    // Using FLT_MAX for its padding would cover the whole scene.
    const float3 absoluteDirection = abs(ray.dir);
    const float largest = max(absoluteDirection.x, max(absoluteDirection.y, absoluteDirection.z));
    if (!(largest > 0.f) || !isfinite(largest)) return false;
    const uint axis = largest == absoluteDirection.x ? 0u : (largest == absoluteDirection.y ? 1u : 2u);
    float farT = ray.tMin;
    [loop] for (uint i = 0u; i < count; ++i)
    {
        const GrisReplayMovedBounds bounds = gGRISReplayMovedBounds[i];
        const float extent = max(abs(bounds.minPoint[axis] - ray.origin[axis]),
            abs(bounds.maxPoint[axis] - ray.origin[axis]));
        farT = max(farT, extent / largest);
    }
    const float padding = max(1.f, max(abs(ray.origin[axis]) / largest, farT)) * 1.52587890625e-5f;
    ray.tMax = min(ray.tMax, farT + padding);
    return rtptGrisReplayRayClear(ray, count);
}
#endif
