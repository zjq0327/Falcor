#pragma once

// These tests remove a light only when it cannot illuminate any point in the
// supplied receiver bounds. Invalid inputs retain the light. Bounds must include
// the receiver cell, its position bias, and the query's sampling jitter.
float rtptReGIRCullingMaxAbs(float3 value)
{
    return max(abs(value.x), max(abs(value.y), abs(value.z)));
}

bool rtptReGIRCullingValidAabb(float3 center, float3 halfExtent)
{
    return all(isfinite(center)) && all(isfinite(halfExtent)) && all(halfExtent >= 0.f);
}

// Lower bound on distance from a point to the complete receiver AABB. Expand
// the box for arithmetic error in addition to the query jitter already present
// in halfExtent. Invalid or overflowing inputs yield zero, retaining the light.
float rtptReGIRPointAabbDistanceSquared(float3 point, float3 center, float3 halfExtent)
{
    if (!all(isfinite(point)) || !rtptReGIRCullingValidAabb(center, halfExtent)) return 0.f;
    const float scale = 1.f + rtptReGIRCullingMaxAbs(point) +
        rtptReGIRCullingMaxAbs(center) + rtptReGIRCullingMaxAbs(halfExtent);
    const float margin = 2e-6f * scale;
    if (!isfinite(margin)) return 0.f;
    const float3 offset = max(abs(point - center) - halfExtent - margin, float3(0.f));
    const float distanceSquared = dot(offset, offset);
    return isfinite(distanceSquared) ? distanceSquared : 0.f;
}

// A sphere touching even one face, edge or corner of the box is retained.
// radius may describe a physical finite range or an explicitly approximate
// brightness cutoff; the geometric overlap test does not choose that policy.
bool rtptReGIRAabbOutsideSphere(float3 center, float3 halfExtent, float3 lightPosition, float radius)
{
    if (!rtptReGIRCullingValidAabb(center, halfExtent) || !all(isfinite(lightPosition)) ||
        !isfinite(radius) || radius < 0.f) return false;
    const float radiusSquared = radius * radius;
    if (!isfinite(radiusSquared)) return false;
    return rtptReGIRPointAabbDistanceSquared(lightPosition, center, halfExtent) > radiusSquared;
}

// For a single-sided triangle, reject only if every point of the receiver box
// is behind every possible sampled emitter position. The maximum over all three
// vertices also covers an independently quantized, slightly tilted normal.
bool rtptReGIRAabbBehindTriangle(float3 center, float3 halfExtent, float3 v0, float3 v1, float3 v2, float3 emitterNormal)
{
    if (!rtptReGIRCullingValidAabb(center, halfExtent) || !all(isfinite(v0)) ||
        !all(isfinite(v1)) || !all(isfinite(v2)) || !all(isfinite(emitterNormal))) return false;
    const float normalLengthSquared = dot(emitterNormal, emitterNormal);
    if (!(normalLengthSquared > 1e-20f) || !isfinite(normalLengthSquared)) return false;
    const float3 normal = emitterNormal * rsqrt(normalLengthSquared);
    const float support = dot(abs(normal), halfExtent);
    const float distance = max(dot(center - v0, normal), max(dot(center - v1, normal), dot(center - v2, normal)));
    const float scale = max(dot(abs(center) + abs(v0), abs(normal)),
        max(dot(abs(center) + abs(v1), abs(normal)), dot(abs(center) + abs(v2), abs(normal)))) + support + 1.f;
    const float cellMargin = 2e-4f * rtptReGIRCullingMaxAbs(halfExtent);
    const float margin = max(cellMargin, 2e-6f * scale);
    return isfinite(distance) && isfinite(support) && isfinite(margin) && distance + support < -margin;
}

bool rtptReGIRSphereBehindEmitter(float3 center, float radius, float3 emitterPosition, float3 emitterNormal)
{
    if (!all(isfinite(center)) || !isfinite(radius) || radius < 0.f ||
        !all(isfinite(emitterPosition)) || !all(isfinite(emitterNormal))) return false;
    const float normalLengthSquared = dot(emitterNormal, emitterNormal);
    if (!(normalLengthSquared > 1e-20f) || !isfinite(normalLengthSquared)) return false;
    const float3 normal = emitterNormal * rsqrt(normalLengthSquared);
    const float distance = dot(center - emitterPosition, normal);
    // Account for cancellation in world-space subtraction as well as the dot
    // product and normalization. A grazing or uncertain sphere stays present.
    const float scale = dot(abs(center) + abs(emitterPosition), abs(normal)) + radius + 1.f;
    const float margin = 2e-6f * scale;
    return isfinite(distance) && isfinite(margin) && distance < -radius - margin;
}

bool rtptReGIRSphereBehindTriangle(float3 center, float radius, float3 v0, float3 v1, float3 v2, float3 emitterNormal)
{
    // Falcor stores a quantized normal independently of the triangle vertices.
    // Its decoded normal need not be perpendicular to either stored edge.
    // Every interpolated light sample lies between the three projected vertex
    // planes, so reject only when the receiver sphere is behind all three.
    return rtptReGIRSphereBehindEmitter(center, radius, v0, emitterNormal) &&
        rtptReGIRSphereBehindEmitter(center, radius, v1, emitterNormal) &&
        rtptReGIRSphereBehindEmitter(center, radius, v2, emitterNormal);
}

bool rtptReGIRSphereOutsideSpot(float3 center, float radius, float3 lightPosition, float3 lightDirection, float cosOpeningAngle)
{
    if (!all(isfinite(center)) || !isfinite(radius) || radius < 0.f ||
        !all(isfinite(lightPosition)) || !all(isfinite(lightDirection)) ||
        !isfinite(cosOpeningAngle) || cosOpeningAngle < -1.f || cosOpeningAngle > 1.f) return false;
    if (cosOpeningAngle <= -1.f) return false;
    const float directionLengthSquared = dot(lightDirection, lightDirection);
    if (!(directionLengthSquared > 1e-20f) || !isfinite(directionLengthSquared)) return false;
    const float3 offset = center - lightPosition;
    const float distanceSquared = dot(offset, offset);
    if (!(distanceSquared > 0.f) || !isfinite(distanceSquared)) return false;
    const float distance = sqrt(distanceSquared);
    const float margin = 2e-6f * (1.f + rtptReGIRCullingMaxAbs(center) + rtptReGIRCullingMaxAbs(lightPosition) + radius);
    const float inflatedRadius = radius + margin;
    if (!isfinite(inflatedRadius) || distance <= inflatedRadius) return false;
    const float3 axis = lightDirection * rsqrt(directionLengthSquared);
    const float3 directionToCenter = offset / distance;
    const float cosTheta = clamp(dot(directionToCenter, axis), -1.f, 1.f);
    // The sphere subtends a cap of half-angle alpha at the light. Its maximum
    // alignment with the spot axis is cos(max(0, theta-alpha)), also for spots
    // wider than a hemisphere. No acos/asin is needed near their singularities.
    const float sinAlpha = saturate(inflatedRadius / distance);
    const float cosAlpha = sqrt(max(0.f, 1.f - sinAlpha * sinAlpha));
    if (cosTheta >= cosAlpha) return false;
    // A cross product remains accurate near parallel/opposite directions;
    // sqrt(1-cosTheta^2) can lose a visible angular interval when cos rounds to 1.
    const float sinTheta = min(1.f, length(cross(directionToCenter, axis)));
    const float maximumCosine = cosTheta * cosAlpha + sinTheta * sinAlpha;
    return isfinite(maximumCosine) && maximumCosine + 2e-6f < cosOpeningAngle;
}
