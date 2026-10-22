#pragma once

// Clip a triangle against a closed box. A triangle clipped by six planes has
// at most nine vertices. Twelve slots also retain conservative edge contacts.
bool rtptVXPGClipTriangle(float3 a, float3 b, float3 c, float3 lo, float3 hi, out float3 boundMin, out float3 boundMax)
{
    float3 polygon[12];
    float3 next[12];
    polygon[0] = a; polygon[1] = b; polygon[2] = c;
    uint count = 3;
    for (uint plane = 0; plane < 6; ++plane)
    {
        const uint axis = plane / 2;
        const bool lower = (plane & 1) == 0;
        const float boundary = lower ? lo[axis] : hi[axis];
        uint nextCount = 0;
        for (uint i = 0; i < count; ++i)
        {
            const float3 p = polygon[i], q = polygon[(i + 1) % count];
            const float dp = lower ? p[axis] - boundary : boundary - p[axis];
            const float dq = lower ? q[axis] - boundary : boundary - q[axis];
            if (dp >= 0.f && nextCount < 12) next[nextCount++] = p;
            if ((dp >= 0.f) != (dq >= 0.f) && nextCount < 12)
                next[nextCount++] = lerp(p, q, dp / (dp - dq));
        }
        count = nextCount;
        for (uint j = 0; j < count; ++j) polygon[j] = next[j];
        if (count == 0) break;
    }
    boundMin = hi;
    boundMax = lo;
    for (uint k = 0; k < count; ++k)
    {
        boundMin = min(boundMin, polygon[k]);
        boundMax = max(boundMax, polygon[k]);
    }
    return count != 0;
}

float rtptVXPGTriangleSolidAngle(float3 a, float3 b, float3 c)
{
    return 2.f * atan2(abs(dot(a, cross(b, c))), 1.f + dot(a, b) + dot(b, c) + dot(c, a));
}

// Arvo's equal-area mapping of a spherical triangle. Inputs are normalized
// directions; callers remove ill-conditioned triangles before both sampling
// and density evaluation, rather than resampling after an unlucky draw.
float3 rtptVXPGSampleSphericalTriangle(float3 a, float3 b, float3 c, float area, float2 u)
{
    const float3 ab = normalize(cross(b, a));
    const float3 ac = normalize(cross(c, a));
    const float cosAlpha = clamp(dot(ab, ac), -1.f, 1.f);
    const float sinAlpha = length(cross(ab, ac));
    const float alpha = atan2(sinAlpha, cosAlpha);
    const float phi = u.x * area - alpha;
    const float s = sin(phi), t = cos(phi);
    const float uu = t - cosAlpha;
    const float vv = s + sinAlpha * dot(a, b);
    const float denominator = (vv * s + uu * t) * sinAlpha;
    const float q = clamp(((vv * t - uu * s) * cosAlpha - vv) / denominator, -1.f, 1.f);
    const float3 cc = q * a + sqrt(max(0.f, 1.f - q*q)) * normalize(c - dot(c, a) * a);
    const float z = clamp(1.f - u.y * (1.f - dot(cc, b)), -1.f, 1.f);
    return normalize(z * b + sqrt(max(0.f, 1.f - z*z)) * normalize(cc - dot(cc, b) * b));
}

struct RTPTVXPGSphericalBox
{
    float3 directions[24];
    float areas[6];
    float solidAngle;
    bool inside;
    bool cone;
    float3 coneAxis;
    float coneHeight;
};

RTPTVXPGSphericalBox rtptVXPGBoundingCone(float3 origin, float3 lo, float3 hi)
{
    RTPTVXPGSphericalBox result={};
    const float3 delta=0.5f*(lo+hi)-origin;
    const float distance2=dot(delta,delta);
    const float3 extent=0.5f*(hi-lo);
    const float radius2=dot(extent,extent)*1.00001f;
    result.cone=true;
    result.coneAxis=distance2>0.f?delta/sqrt(distance2):float3(0,0,1);
    // Stable 1-cos(theta), including sub-pixel distant boxes. Rejections outside
    // the box retain null probability, with this same cone density in reverse.
    const float sin2=min(1.f,radius2/max(1.e-30f,distance2));
    result.coneHeight=distance2<=radius2?2.f:sin2/(1.f+sqrt(max(0.f,1.f-sin2)));
    result.solidAngle=6.283185307179586f*result.coneHeight;
    return result;
}

RTPTVXPGSphericalBox rtptVXPGSphericalBox(float3 origin, float3 lo, float3 hi)
{
    RTPTVXPGSphericalBox result = {};
    if (!all(hi > lo) || !all(isfinite(origin)) || !all(isfinite(lo)) || !all(isfinite(hi))) return result;
    result.inside = all(origin >= lo) && all(origin <= hi);
    if (result.inside)
    {
        result.solidAngle = 12.56637061435917f;
        return result;
    }
    for (uint axis = 0; axis < 3; ++axis)
    {
        if (origin[axis] >= lo[axis] && origin[axis] <= hi[axis]) continue;
        const uint j = (axis + 1) % 3, k = (axis + 2) % 3;
        float3 corners[4];
        for (uint v = 0; v < 4; ++v)
        {
            float3 p;
            p[axis] = origin[axis] < lo[axis] ? lo[axis] : hi[axis];
            p[j] = (v == 1 || v == 2) ? hi[j] : lo[j];
            p[k] = v >= 2 ? hi[k] : lo[k];
            corners[v] = normalize(p - origin);
        }
        for (uint triangle = 0; triangle < 2; ++triangle)
        {
            const uint index = axis * 2 + triangle;
            const float3 a = corners[0], b = corners[triangle + 1], c = corners[triangle + 2];
            const float area = rtptVXPGTriangleSolidAngle(a, b, c);
            const float3 ab = cross(a, b), ac = cross(a, c);
            const float conditioning = length(cross(normalize(ab), normalize(ac)));
            // Reject the entire box in this context. Dropping just one triangle
            // would require a directional support test in the reverse PDF.
            if (!(area > 1.e-7f) || !(conditioning > 1.e-5f) || length(ab) < 1.e-4f || length(ac) < 1.e-4f || !isfinite(area))
            {
                return rtptVXPGBoundingCone(origin,lo,hi);
            }
            result.directions[index * 4] = a;
            result.directions[index * 4 + 1] = b;
            result.directions[index * 4 + 2] = c;
            result.areas[index] = area;
            result.solidAngle += area;
        }
    }
    return result;
}

bool rtptVXPGSampleBox(RTPTVXPGSphericalBox box, float3 u, out float3 direction)
{
    direction = float3(0.f);
    if (!(box.solidAngle > 0.f)) return false;
    if (box.cone)
    {
        const float h=u.y*box.coneHeight, z=1.f-h, phi=6.283185307179586f*u.z;
        const float r=sqrt(max(0.f,h*(2.f-h)));
        const float3 up=abs(box.coneAxis.z)<0.9f?float3(0,0,1):float3(1,0,0);
        const float3 tangent=normalize(cross(up,box.coneAxis));
        direction=normalize(z*box.coneAxis+r*(cos(phi)*tangent+sin(phi)*cross(box.coneAxis,tangent)));
        return all(isfinite(direction));
    }
    if (box.inside)
    {
        const float z = 1.f - 2.f * u.y, phi = 6.283185307179586f * u.z;
        const float r = sqrt(max(0.f, 1.f - z*z));
        direction = float3(r*cos(phi), r*sin(phi), z);
        return true;
    }
    float v = min(u.x, 0.99999994f) * box.solidAngle;
    for (uint i = 0; i < 6; ++i)
    {
        const float area = box.areas[i];
        if (area > 0.f && v < area)
        {
            direction = rtptVXPGSampleSphericalTriangle(box.directions[i*4], box.directions[i*4+1], box.directions[i*4+2], area,
                u.yz);
            return all(isfinite(direction));
        }
        v -= area;
    }
    return false;
}
