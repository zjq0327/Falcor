#include "RTPTVXPGTypes.slang"

cbuffer VXPGTreeLevel { uint nodeOffset; uint nodeCount; uint leafCapacity; };

[numthreads(32, 1, 1)]
void clearDiagnostics(uint3 tid : SV_DispatchThreadID)
{
    // A frozen proposal still gets fresh render activity. Preserve its model
    // structure (including gathered points at 26); construction activity is
    // explicitly unavailable on frames with no construction dispatch.
    if ((tid.x >= 6 && tid.x <= 25) || tid.x == RTPT_VXPG_STATE_SHARED_PATHS)
        gVXPGState[tid.x] = 0;
}

[numthreads(256, 1, 1)]
void clearFrame(uint3 tid : SV_DispatchThreadID)
{
    if (tid.x >= 3 && tid.x < 32) gVXPGState[tid.x] = 0;
    if (tid.x >= gVXPGParams.cellCount) return;
    gVXPGFlux[tid.x] = uint64_t(0);
    gVXPGCount[tid.x] = 0;
    gVXPGInverse[tid.x] = RTPT_VXPG_INVALID;
    gVXPGBoundMax[tid.x].w = 0;
}

[numthreads(256, 1, 1)]
void compact(uint3 tid : SV_DispatchThreadID)
{
    const uint cell = tid.x;
    if (cell >= gVXPGParams.cellCount || gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) return;
    const uint count = gVXPGCount[cell];
    if (gVXPGBoundMin[cell].w == 0 || count == 0 || gVXPGFlux[cell] == uint64_t(0)) return;
    const float3 extent=rtptVXPGWorldMax(cell)-rtptVXPGWorldMin(cell);
    const float area=max(extent.x*extent.y,max(extent.y*extent.z,extent.z*extent.x));
    // Reference premultiplies the mean observation by the largest box-face
    // area, estimating voxel power rather than selecting by irradiance alone.
    const float mass=float(gVXPGFlux[cell])/(4096.f*float(count))*area;
    if (!isfinite(mass)) { InterlockedAdd(gVXPGState[11],1u); return; }
    if (!(mass>0.f)) return;
    uint index;
    InterlockedAdd(gVXPGState[RTPT_VXPG_STATE_ACTIVE], 1u, index);
    if (index >= gVXPGParams.activeCapacity)
    {
        InterlockedOr(gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW], 1u);
        return;
    }
    gVXPGCompact[index] = cell;
    gVXPGInverse[cell] = index;
    gVXPGMass[index] = mass;
}

[numthreads(256, 1, 1)]
void globalLeaves(uint3 tid : SV_DispatchThreadID)
{
    if (tid.x >= leafCapacity) return;
    const uint count = min(gVXPGState[RTPT_VXPG_STATE_ACTIVE], gVXPGParams.activeCapacity);
    gVXPGGlobalTree[leafCapacity + tid.x] = tid.x < count ? gVXPGMass[tid.x] : 0.f;
}

[numthreads(256, 1, 1)]
void globalLevel(uint3 tid : SV_DispatchThreadID)
{
    if (tid.x >= nodeCount) return;
    const uint node = nodeOffset + tid.x;
    gVXPGGlobalTree[node] = gVXPGGlobalTree[node*2] + gVXPGGlobalTree[node*2+1];
}

[numthreads(1, 1, 1)]
void publish(uint3 tid : SV_DispatchThreadID)
{
    const bool valid = gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] == 0 &&
        gVXPGState[RTPT_VXPG_STATE_DISTRIBUTION_OVERFLOW] == 0 &&
        gVXPGState[RTPT_VXPG_STATE_INVALID] == 0 &&
        gVXPGState[RTPT_VXPG_STATE_ACTIVE] > 0 && gVXPGGlobalTree[1] > 0.f && isfinite(gVXPGGlobalTree[1]);
    gVXPGState[RTPT_VXPG_STATE_READY] = valid ? gVXPGParams.generation : 0;
}
