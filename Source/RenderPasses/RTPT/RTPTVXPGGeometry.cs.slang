#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;
#include "RTPTVXPGTypes.slang"
#include "RTPTVXPGGeometry.slang"

StructuredBuffer<uint2> gVXPGTriangles;
RWStructuredBuffer<uint4> gVXPGTriangleRanges;
RWStructuredBuffer<uint2> gVXPGJobs;
RWStructuredBuffer<uint> gVXPGDispatchArgs;
RWTexture2D<float4> gVXPGDebug;

uint rtptVXPGPackCell(uint3 cell) { return cell.x | (cell.y << 8) | (cell.z << 16); }
uint3 rtptVXPGUnpackCell(uint packed) { return uint3(packed & 255u, (packed >> 8) & 255u, (packed >> 16) & 255u); }

[numthreads(256, 1, 1)]
void clearGeometry(uint3 tid : SV_DispatchThreadID)
{
    if (tid.x < 32) gVXPGState[tid.x] = 0;
    if (tid.x >= gVXPGParams.cellCount) return;
    gVXPGBoundMin[tid.x] = uint4(asuint(float3(gVXPGParams.resolution)), 0);
    gVXPGBoundMax[tid.x] = uint4(0);
    gVXPGInverse[tid.x] = RTPT_VXPG_INVALID;
}

[numthreads(64, 1, 1)]
void makeGeometryJobs(uint3 tid : SV_DispatchThreadID)
{
    const uint triangleIndex=tid.x+tid.y*(65535u*64u);
    if (triangleIndex >= gVXPGParams.triangleCount) return;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    const uint2 triangle = gVXPGTriangles[triangleIndex];
    float3 p[3];
    gScene.getVertexPositionsW(GeometryInstanceID(triangle.x, 0), triangle.y, p);
    const float3 a = (p[0] - gVXPGParams.gridMin) / gVXPGParams.cellSize;
    const float3 b = (p[1] - gVXPGParams.gridMin) / gVXPGParams.cellSize;
    const float3 c = (p[2] - gVXPGParams.gridMin) / gVXPGParams.cellSize;
    if (!all(isfinite(a)) || !all(isfinite(b)) || !all(isfinite(c)))
    {
        InterlockedOr(gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW], 2u);
        return;
    }
    const float3 lo = min(a, min(b, c)), hi = max(a, max(b, c));
    if (any(hi < 0.f) || any(lo > float(gVXPGParams.resolution))) return;
    const uint3 first = uint3(clamp(floor(lo - 1.e-4f), 0.f, float(gVXPGParams.resolution - 1)));
    const uint3 last = uint3(clamp(floor(hi + 1.e-4f), 0.f, float(gVXPGParams.resolution - 1)));
    const uint3 extent = last - first + 1u;
    const uint cells = extent.x * extent.y * extent.z;
    const uint jobs = (cells + 63) / 64;
    gVXPGTriangleRanges[triangleIndex] = uint4(rtptVXPGPackCell(first), rtptVXPGPackCell(extent), cells, 0);
    uint offset;
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_JOBS], jobs, offset);
    if (offset > gVXPGParams.jobCapacity || jobs > gVXPGParams.jobCapacity - min(offset, gVXPGParams.jobCapacity))
    {
        InterlockedOr(gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW], 1u);
        return;
    }
    // Bounded by resolution^3/64 (32768 at the largest supported grid).
    // Expensive clipping is distributed over independent 64-cell jobs.
    for (uint j = 0; j < jobs; ++j) gVXPGJobs[offset+j] = uint2(triangleIndex, j*64);
#endif
}

[numthreads(1, 1, 1)]
void finalizeGeometryJobs(uint3 tid : SV_DispatchThreadID)
{
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW]!=0)
    {
        gVXPGDispatchArgs[0]=gVXPGDispatchArgs[1]=gVXPGDispatchArgs[2]=1;
        return;
    }
    const uint jobs = min(gVXPGState[RTPT_VXPG_STATE_JOBS], gVXPGParams.jobCapacity);
    gVXPGDispatchArgs[0] = max(1u, min(1024u, jobs));
    gVXPGDispatchArgs[1] = max(1u, (jobs + 1023) / 1024);
    gVXPGDispatchArgs[2] = 1;
}

[numthreads(64, 1, 1)]
void voxelizeGeometry(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID)
{
    const uint jobIndex = group.x + group.y * 1024;
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0 || jobIndex >= gVXPGState[RTPT_VXPG_STATE_JOBS]) return;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    const uint2 job = gVXPGJobs[jobIndex];
    const uint4 range = gVXPGTriangleRanges[job.x];
    const uint index = job.y + lane.x;
    if (index >= range.z) return;
    const uint3 extent = rtptVXPGUnpackCell(range.y);
    const uint3 cell = rtptVXPGUnpackCell(range.x) + uint3(index % extent.x, (index / extent.x) % extent.y, index / (extent.x * extent.y));
    const uint2 triangle = gVXPGTriangles[job.x];
    float3 vertices[3];
    gScene.getVertexPositionsW(GeometryInstanceID(triangle.x, 0), triangle.y, vertices);
    for (uint v = 0; v < 3; ++v) vertices[v] = (vertices[v] - gVXPGParams.gridMin) / gVXPGParams.cellSize;
    float3 lo, hi;
    const float epsilon = 1.e-4f;
    if (!rtptVXPGClipTriangle(vertices[0], vertices[1], vertices[2], float3(cell)-epsilon, float3(cell+1u)+epsilon, lo, hi)) return;
    // Expand for roundoff and planar triangles, preserving a usable 3D box.
    lo = max(0.f, lo - epsilon);
    hi = min(float(gVXPGParams.resolution), hi + epsilon);
    const uint flat = rtptVXPGFlatten(cell);
    InterlockedMin(gVXPGBoundMin[flat].x, asuint(lo.x));
    InterlockedMin(gVXPGBoundMin[flat].y, asuint(lo.y));
    InterlockedMin(gVXPGBoundMin[flat].z, asuint(lo.z));
    InterlockedMax(gVXPGBoundMax[flat].x, asuint(hi.x));
    InterlockedMax(gVXPGBoundMax[flat].y, asuint(hi.y));
    InterlockedMax(gVXPGBoundMax[flat].z, asuint(hi.z));
    uint old;
    InterlockedExchange(gVXPGBoundMin[flat].w, 1u, old);
    if (old == 0) InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_OCCUPIED], 1u);
#endif
}

[numthreads(8, 8, 1)]
void debugGeometry(uint3 tid : SV_DispatchThreadID)
{
    if (any(tid.xy >= gVXPGParams.frameDim)) return;
    const Ray ray = gScene.camera.computeRayPinhole(tid.xy, gVXPGParams.frameDim);
    SceneRayQuery<true> query;
    float hitT;
    const HitInfo hit = query.traceRay(ray, hitT);
    float3 color = 0.f;
    if (hit.isValid())
    {
        const float3 position = ray.origin + hitT * ray.dir;
        const uint cell = rtptVXPGOwner(position);
        if (cell != RTPT_VXPG_INVALID && gVXPGBoundMin[cell].w != 0)
        {
            const uint3 xyz = rtptVXPGUnflatten(cell);
            color = frac(float3(xyz) * float3(0.61803399f, 0.41421356f, 0.73205081f) + 0.2f);
            const float3 local = frac((position - gVXPGParams.gridMin) / gVXPGParams.cellSize);
            if (min(local.x, min(local.y, local.z)) < 0.015f) color = 1.f;
        }
    }
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) color = float3(1.f, 0.f, 1.f);
    gVXPGDebug[tid.xy] = float4(color, 1.f);
}
