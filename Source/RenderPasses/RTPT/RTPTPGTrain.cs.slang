#include "RTPTPGTypes.slang"
#include "RTPTGrid.slang"

void rtptPGRequest(uint2 key)
{
    const uint capacity = gPGSettings.requestCapacity;
    if (capacity == 0u) { rtptPGCount(RTPT_PG_DIAG_REQUEST_OVERFLOW); return; }
    const uint64_t packed = rtptGridPackKey(key);
    const uint first = rtptGridKeyHash(key) % capacity;
    for (uint probe = 0u; probe < min(capacity, 32u); ++probe)
    {
        uint64_t previous;
        InterlockedCompareExchange(gPGRequests[2u * ((first + probe) % capacity)], uint64_t(0), packed, previous);
        if (previous == packed) return;
        if (previous == uint64_t(0)) { rtptPGCount(RTPT_PG_DIAG_REQUEST); return; }
    }
    rtptPGCount(RTPT_PG_DIAG_REQUEST_OVERFLOW);
}

uint rtptPGFindBuild(uint2 key)
{
    const uint capacity = gPGSettings.buildMapCapacity;
    if (capacity == 0u) return RTPT_PG_INVALID;
    const uint first = rtptGridKeyHash(key) % capacity;
    for (uint probe = 0u; probe < capacity; ++probe)
    {
        const RTPTPGMapEntry entry = gPGBuildMap[(first + probe) % capacity];
        if (all(entry.key == uint2(0u))) break;
        if (!all(entry.key == key)) continue;
        if (entry.regionId >= gPGSettings.buildRegionCount) break;
        const RTPTPGRegion region = gPGBuildRegions[entry.regionId];
        if (all(region.key == key) && region.generation == entry.generation) return entry.regionId;
        break;
    }
    return RTPT_PG_INVALID;
}

// Separate CAS additions avoid requiring float atomics on supported D3D12 GPUs.
bool rtptPGAddWeight(uint index, uint quadrant, float value, bool square)
{
    uint previous = square ? gPGBuildStats[index].squareBits[quadrant] : gPGBuildStats[index].weightBits[quadrant];
    for (;;)
    {
        const float sum = asfloat(previous) + value;
        if (!isfinite(sum)) { rtptPGCount(RTPT_PG_DIAG_ACCUM_OVERFLOW); return false; }
        uint observed;
        if (square) InterlockedCompareExchange(gPGBuildStats[index].squareBits[quadrant], previous, asuint(sum), observed);
        else InterlockedCompareExchange(gPGBuildStats[index].weightBits[quadrant], previous, asuint(sum), observed);
        if (observed == previous) return true;
        previous = observed;
    }
}

void rtptPGTrainVertex(RTPTPGVertex vertex, float3 incident)
{
    if (!(vertex.samplePdf > 0.f) || !isfinite(vertex.samplePdf) ||
        !(vertex.sampleSurvival > 0.f) || !(vertex.sampleSurvival <= 1.f))
    { rtptPGCount(RTPT_PG_DIAG_INVALID_PDF); return; }
    const float weight = dot(max(incident, float3(0.f)), float3(1.f / 3.f)) /
        (vertex.samplePdf * vertex.sampleSurvival) * gPGSettings.weightScale;
    const float square = weight * weight;
    if (!(weight >= 0.f) || !isfinite(weight) || !isfinite(square))
    { rtptPGCount(RTPT_PG_DIAG_ACCUM_OVERFLOW); return; }
    const uint regionId = rtptPGFindBuild(vertex.key);
    if (regionId == RTPT_PG_INVALID) { rtptPGRequest(vertex.key); return; }
    const RTPTPGRegion region = gPGBuildRegions[regionId];
    float2 uv = rtptPGDirectionToSquare(vertex.direction);
    uint index = region.root;
    for (uint depth = 0u; depth < 16u; ++depth)
    {
        if (index < region.root || index - region.root >= region.nodeCount || index >= gPGSettings.buildNodeCount)
        { rtptPGCount(RTPT_PG_DIAG_INVALID); return; }
        const uint quadrant = rtptPGQuadrant(uv);
        const uint child = rtptPGChild(gPGBuildNodes[index].topology, quadrant);
        if (child == RTPT_PG_INVALID)
        {
            if (!rtptPGAddWeight(index, quadrant, weight, false) || !rtptPGAddWeight(index, quadrant, square, true)) return;
            uint previousCount;
            InterlockedAdd(gPGBuildStats[index].count[quadrant], 1u, previousCount);
            if (previousCount == 0xffffffffu) { rtptPGCount(RTPT_PG_DIAG_ACCUM_OVERFLOW); return; }
            rtptPGCount(RTPT_PG_DIAG_TRAINED);
            if (weight == 0.f) rtptPGCount(RTPT_PG_DIAG_ZERO);
            return;
        }
        index = child;
    }
    rtptPGCount(RTPT_PG_DIAG_INVALID);
}

[numthreads(64, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint path = dispatchThreadID.x;
    if (path >= gPGSettings.pathCapacity || gPGSettings.trainingEnabled == 0u) return;
    const RTPTPGPathHeader header = gPGPathHeaders[path];
    if ((header.flags & RTPT_PG_PATH_COMPLETE) == 0u) return;
    if ((header.flags & RTPT_PG_PATH_INVALID) != 0u || header.vertexCount == 0u ||
        header.vertexCount > gPGSettings.verticesPerPath || header.generation != gPGSettings.recordGeneration ||
        header.sceneGeneration != gPGSettings.sceneGeneration)
    { rtptPGCount(RTPT_PG_DIAG_INVALID); return; }
    // Validate the entire suffix before any atomic write. A nonfinite ancestor
    // must not turn one nominally complete path into a partially trained path.
    float3 checkReflected = 0.f;
    float3 checkEmission = header.terminalEmission;
    float checkMIS = 1.f;
    for (uint remaining = header.vertexCount; remaining > 0u; --remaining)
    {
        const RTPTPGVertex vertex = gPGVertices[path * gPGSettings.verticesPerPath + remaining - 1u];
        if (!all(isfinite(checkEmission + checkReflected)))
        { rtptPGCount(RTPT_PG_DIAG_INVALID); return; }
        if ((vertex.flags & (RTPT_PG_VERTEX_OUTGOING | RTPT_PG_VERTEX_TRAINABLE)) ==
            (RTPT_PG_VERTEX_OUTGOING | RTPT_PG_VERTEX_TRAINABLE) &&
            (!(vertex.samplePdf > 0.f) || !isfinite(vertex.samplePdf) ||
             !(vertex.sampleSurvival > 0.f) || !(vertex.sampleSurvival <= 1.f) ||
             !all(isfinite(vertex.direction))))
        { rtptPGCount(RTPT_PG_DIAG_INVALID_PDF); return; }
        checkReflected = vertex.direct + vertex.transport * (checkMIS * checkEmission + checkReflected);
        if (!all(isfinite(checkReflected)) || !all(isfinite(vertex.emission)) || !isfinite(vertex.hitMIS))
        { rtptPGCount(RTPT_PG_DIAG_INVALID); return; }
        checkEmission = vertex.emission;
        checkMIS = vertex.hitMIS;
    }
    float3 reflected = 0.f;
    float3 nextEmission = header.terminalEmission;
    float nextHitMIS = 1.f;
    for (uint remaining = header.vertexCount; remaining > 0u; --remaining)
    {
        const RTPTPGVertex vertex = gPGVertices[path * gPGSettings.verticesPerPath + remaining - 1u];
        const float3 incident = nextEmission + reflected;
        if (!all(isfinite(incident))) { rtptPGCount(RTPT_PG_DIAG_INVALID); return; }
        if ((vertex.flags & (RTPT_PG_VERTEX_OUTGOING | RTPT_PG_VERTEX_TRAINABLE)) ==
            (RTPT_PG_VERTEX_OUTGOING | RTPT_PG_VERTEX_TRAINABLE)) rtptPGTrainVertex(vertex, incident);
        reflected = vertex.direct + vertex.transport * (nextHitMIS * nextEmission + reflected);
        nextEmission = vertex.emission;
        nextHitMIS = vertex.hitMIS;
    }
    rtptPGCount(RTPT_PG_DIAG_COMPLETE);
}
