#pragma once
#include "RTPTReGIRGrid.slang"
#include "RTPTReGIRCulling.slang"

static const uint kRTPTReGIRInvalidCandidate = 0xffffffffu;
static const uint kRTPTReGIRListUnbuilt = 0u;
static const uint kRTPTReGIRListBuilding = 1u;
static const uint kRTPTReGIRListReady = 2u;

struct RTPTReGIRCellView
{
    float3 center;
    float3 halfExtent;
    uint64_t key;
    uint cell;
    uint offset;
    uint count;
    uint ready;
    uint cached;
};

bool rtptReGIRHasPublishedRIS(RTPTReGIRCellView view)
{
    if (view.ready == 0u || view.cell == kRTPTReGIRInvalidCell) return false;
    return gReGIRCellRISState[view.cell] != kRTPTReGIRRISUnbuilt;
}

// One deterministic predicate defines the stored and procedural forms of the
// same complete cell list. Catalogue iteration here constructs that list; it
// is never an unordered-light proposal or a draw followed by rejection.
bool rtptReGIRLightCanAffectCell(RTPTReGIRLightDescriptor light, float3 center, float3 halfExtent)
{
    if ((light.flags & kRTPTReGIRDescriptorActive) == 0u) return false;
    if (gReGIRSettings.cullingEnabled == 0u) return true;
    if (!rtptReGIRCullingValidAabb(center, halfExtent) || !all(isfinite(light.boundsMin)) ||
        !all(isfinite(light.boundsMax)) || any(light.boundsMax < light.boundsMin)) return true;
    const float3 lightCenter = light.boundsMin * 0.5f + light.boundsMax * 0.5f;
    const float3 lightHalfExtent = max(float3(0.f), light.boundsMax * 0.5f - light.boundsMin * 0.5f);

    if ((light.flags & kRTPTReGIRDescriptorTriangle) != 0u &&
        (light.flags & kRTPTReGIRDescriptorDoubleSided) == 0u)
    {
        const float normalLengthSquared = dot(light.direction, light.direction);
        if (all(isfinite(light.direction)) && normalLengthSquared > 1e-20f && isfinite(normalLengthSquared))
        {
            const float3 normal = light.direction * rsqrt(normalLengthSquared);
            // Emitter AABB support bounds every vertex plane, including the
            // slight tilt of Falcor's independently quantized light normal.
            const float support = dot(abs(normal), halfExtent + lightHalfExtent);
            const float maximumDistance = dot(normal, center - lightCenter) + support;
            const float scale = dot(abs(normal), abs(center) + abs(lightCenter)) + support + 1.f;
            const float margin = max(2e-4f * rtptReGIRCullingMaxAbs(halfExtent), 2e-6f * scale);
            if (isfinite(maximumDistance) && isfinite(margin) && maximumDistance < -margin) return false;
        }
    }
    else if ((light.flags & kRTPTReGIRDescriptorPoint) != 0u)
    {
        const float radius = length(halfExtent);
        // Keep the distance-clamped neighborhood used by Falcor point lights.
        if (isfinite(radius) && length(center - light.position) > radius + 3.2e-5f &&
            rtptReGIRSphereOutsideSpot(center, radius, light.position, light.direction, light.cosOpeningAngle)) return false;
    }

    if (light.power == 0.f) return false;
    const float threshold = gReGIRSettings.brightnessThreshold;
    if (!(threshold > 0.f) || !isfinite(threshold) || !isfinite(light.power) || light.power < 0.f) return true;
    // Source and receiver AABBs are expanded through their Minkowski sum.
    // This is a lower distance bound for the entire emitter and entire cell.
    const float distanceSquared = rtptReGIRPointAabbDistanceSquared(lightCenter, center, halfExtent + lightHalfExtent);
    if (!(distanceSquared > 0.f)) return true;
    return !(light.power < threshold * distanceSquared);
}

bool rtptReGIRCandidateAccepted(uint catalogIndex, float3 center, float3 halfExtent)
{
    if (catalogIndex >= gReGIRSettings.lightCount) return false;
    const uint stableID = gReGIRCatalog[catalogIndex].pad0;
    if (stableID >= gReGIRSettings.stableIdCount) return false;
    return rtptReGIRLightCanAffectCell(gReGIRLightDescriptors[stableID], center, halfExtent);
}

bool rtptReGIRMembershipChanged(RTPTReGIRLightDescriptor previous, RTPTReGIRLightDescriptor current,
    float3 center, float3 halfExtent)
{
    return rtptReGIRLightCanAffectCell(previous, center, halfExtent) !=
        rtptReGIRLightCanAffectCell(current, center, halfExtent);
}

uint rtptReGIRCountCellCandidates(float3 center, float3 halfExtent)
{
    uint count = 0u;
    for (uint rank = 0u; rank < gReGIRSettings.lightCount; ++rank)
        if (rtptReGIRCandidateAccepted(rank, center, halfExtent)) ++count;
    return count;
}

// Bounded allocation never advances or wraps the persistent cursor on failure.
uint rtptReGIRAllocateCandidates(uint count)
{
    uint cursor;
    InterlockedAdd(gReGIRState[0], 0u, cursor);
    for (;;)
    {
        if (cursor > gReGIRSettings.candidateCapacity || count > gReGIRSettings.candidateCapacity - cursor)
        {
            InterlockedAdd(gReGIRState[4], 1u);
            return kRTPTReGIRInvalidCandidate;
        }
        uint previous;
        InterlockedCompareExchange(gReGIRState[0], cursor, cursor + count, previous);
        if (previous == cursor) return cursor;
        cursor = previous;
    }
}

RTPTReGIRCellView rtptReGIRGetStoredCellView(uint cell)
{
    RTPTReGIRCellView view = {};
    view.cell = cell;
    view.offset = kRTPTReGIRInvalidCandidate;
    if (cell >= gReGIRSettings.cellCapacity) return view;
    view.key = gReGIRCells[cell];
    if (!rtptReGIRCellBounds(view.key, view.center, view.halfExtent)) return view;
    uint state;
    InterlockedCompareExchange(gReGIRCellMeta[cell].w, kRTPTReGIRListReady, kRTPTReGIRListReady, state);
    if (state != kRTPTReGIRListReady) return view;
    // Cross-wave publication for cells built in this consumer dispatch. Cells
    // with current RIS already crossed the host's build-to-consumer UAV barrier.
    if (gReGIRCellRISState[cell] == kRTPTReGIRRISUnbuilt) DeviceMemoryBarrier();
    if (gReGIRCellEpoch[cell] != gReGIRSettings.listEpoch) return view;
    const uint4 meta = gReGIRCellMeta[cell];
    view.offset = meta.x;
    view.count = meta.y;
    view.ready = 1u;
    view.cached = meta.y == 0u || (meta.y <= meta.z && meta.x <= gReGIRSettings.candidateCapacity &&
        meta.y <= gReGIRSettings.candidateCapacity - meta.x) ? 1u : 0u;
    return view;
}

// Caller owns this cell (or dispatches exactly one thread per stored cell).
// No other query waits for the owner: they construct the same list procedurally.
RTPTReGIRCellView rtptReGIRBuildCellList(uint cell, float3 center, float3 halfExtent)
{
    RTPTReGIRCellView view = {};
    view.cell = cell;
    view.center = center;
    view.halfExtent = halfExtent;
    view.key = cell < gReGIRSettings.cellCapacity ? gReGIRCells[cell] : uint64_t(0u);
    view.offset = kRTPTReGIRInvalidCandidate;
    view.count = rtptReGIRCountCellCandidates(center, halfExtent);
    view.ready = 1u;
    if (cell >= gReGIRSettings.cellCapacity) return view;

    uint4 meta = gReGIRCellMeta[cell];
    uint offset = meta.x;
    uint capacity = meta.z;
    if (view.count > capacity)
    {
        const uint allocated = rtptReGIRAllocateCandidates(view.count);
        if (allocated != kRTPTReGIRInvalidCandidate)
        {
            offset = allocated;
            capacity = view.count;
        }
    }
    if (view.count <= capacity)
    {
        uint written = 0u;
        for (uint rank = 0u; rank < gReGIRSettings.lightCount; ++rank)
            if (rtptReGIRCandidateAccepted(rank, center, halfExtent))
                gReGIRCandidateIDs[offset + written++] = gReGIRCatalog[rank].pad0;
        view.offset = offset;
        view.cached = 1u;
    }
    // Retain the old allocation if a larger replacement did not fit. Its
    // capacity is below count, so readers use the complete procedural list;
    // the segment can be reused if a later update shrinks the list again.
    gReGIRCellMeta[cell].xyz = uint3(offset, view.count, capacity);
    gReGIRCellEpoch[cell] = gReGIRSettings.listEpoch;
    gReGIRCellRISState[cell] = kRTPTReGIRRISUnbuilt;
    DeviceMemoryBarrier();
    uint previousState;
    InterlockedExchange(gReGIRCellMeta[cell].w, kRTPTReGIRListReady, previousState);
    InterlockedAdd(gReGIRState[2], 1u);
    return view;
}

RTPTReGIRCellView rtptReGIRGetCellView(float3 position, float3 random)
{
    RTPTReGIRCellView view = {};
    view.cell = kRTPTReGIRInvalidCell;
    view.offset = kRTPTReGIRInvalidCandidate;
    if (gReGIRSettings.active == 0u ||
        !rtptReGIRGetQueryBounds(position, random, view.key, view.center, view.halfExtent)) return view;
    view.cell = rtptReGIRFindOrInsertCell(view.key);
    if (view.cell != kRTPTReGIRInvalidCell)
    {
        if (gReGIRCellLastUsed[view.cell] != gReGIRSettings.frameStamp)
        {
            uint previousUse;
            // Consumer dispatches are frame-ordered, and all lanes write the
            // same current stamp. Exchange also advances correctly at wrap.
            InterlockedExchange(gReGIRCellLastUsed[view.cell], gReGIRSettings.frameStamp, previousUse);
        }
        const RTPTReGIRCellView stored = rtptReGIRGetStoredCellView(view.cell);
        if (stored.ready != 0u)
        {
            if (stored.cached == 0u) InterlockedAdd(gReGIRState[1], 1u);
            return stored;
        }
        uint previous;
        InterlockedCompareExchange(gReGIRCellMeta[view.cell].w, kRTPTReGIRListUnbuilt, kRTPTReGIRListBuilding, previous);
        if (previous == kRTPTReGIRListUnbuilt)
        {
            InterlockedAdd(gReGIRState[8], 1u);
            const RTPTReGIRCellView built = rtptReGIRBuildCellList(view.cell, view.center, view.halfExtent);
            if (built.cached == 0u) InterlockedAdd(gReGIRState[1], 1u);
            return built;
        }
    }
    // Hash/ID-pool pressure and a concurrently building owner change caching
    // only. A complete cell-specific count is established before any random
    // rank is drawn; there is no global-light proposal or retry loop.
    view.cell = kRTPTReGIRInvalidCell;
    view.count = rtptReGIRCountCellCandidates(view.center, view.halfExtent);
    view.ready = 1u;
    view.cached = 0u;
    InterlockedAdd(gReGIRState[1], 1u);
    return view;
}

uint rtptReGIRLoadCandidate(RTPTReGIRCellView view, uint localRank)
{
    if (view.ready == 0u || localRank >= view.count) return kRTPTReGIRInvalidCandidate;
    if (view.cached != 0u)
    {
        const uint stableID = gReGIRCandidateIDs[view.offset + localRank];
        if (stableID >= gReGIRSettings.stableIdCount) return kRTPTReGIRInvalidCandidate;
        return gReGIRIdToCatalog[stableID];
    }
    uint accepted = 0u;
    for (uint rank = 0u; rank < gReGIRSettings.lightCount; ++rank)
        if (rtptReGIRCandidateAccepted(rank, view.center, view.halfExtent))
        {
            if (accepted == localRank) return rank;
            ++accepted;
        }
    return kRTPTReGIRInvalidCandidate;
}
