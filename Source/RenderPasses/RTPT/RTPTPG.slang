#pragma once
#include "RTPTPGTypes.slang"
#include "RTPTGrid.slang"

float rtptPGGuidePdf(RTPTPGGuide guide, float3 direction)
{
    float2 uv = rtptPGDirectionToSquare(direction);
    float pdf = 0.07957747154594767f;
    uint index = guide.root;
    for (uint depth = 0u; depth < 16u; ++depth)
    {
        if (index < guide.root || index - guide.root >= guide.nodeCount || index >= gPGSettings.readNodeCount) return 0.f;
        const RTPTPGNode node = gPGReadNodes[index];
        const float total = dot(node.mass, float4(1.f));
        if (!(total > 0.f) || !isfinite(total)) return 0.f;
        const uint quadrant = rtptPGQuadrant(uv);
        pdf *= 4.f * node.mass[quadrant] / total;
        const uint child = rtptPGChild(node.topology, quadrant);
        if (child == RTPT_PG_INVALID) return isfinite(pdf) ? pdf : 0.f;
        index = child;
    }
    return 0.f;
}

// A PDF of -1 requests the original general evaluation at the caller. Keeping
// that evaluation outside the producer avoids folding a float round trip back
// to its pre-rounded square coordinate at cell boundaries.
float3 rtptPGSampleGuide(RTPTPGGuide guide, float2 randoms, out float guidePdf)
{
    float2 random = clamp(randoms, float2(0.f), float2(asfloat(0x3f7fffffu)));
    float2 lower = 0.f;
    float extent = 1.f;
    guidePdf = 0.07957747154594767f;
    uint index = guide.root;
    for (uint depth = 0u; depth < 16u; ++depth)
    {
        if (index < guide.root || index - guide.root >= guide.nodeCount || index >= gPGSettings.readNodeCount) break;
        const RTPTPGNode node = gPGReadNodes[index];
        const float total = dot(node.mass, float4(1.f));
        if (!(total > 0.f) || !isfinite(total)) break;
        const float target = random.x * total;
        float preceding = 0.f;
        uint quadrant = 0u;
        for (; quadrant < 3u; ++quadrant)
        {
            if (target < preceding + node.mass[quadrant]) break;
            preceding += node.mass[quadrant];
        }
        // Rounding may put target at total. Select the last nonzero cell.
        if (!(node.mass[quadrant] > 0.f))
        {
            quadrant = 3u;
            while (quadrant > 0u && !(node.mass[quadrant] > 0.f)) --quadrant;
            preceding = 0.f;
            for (uint q = 0u; q < quadrant; ++q) preceding += node.mass[q];
        }
        random.x = min(saturate((target - preceding) / node.mass[quadrant]), asfloat(0x3f7fffffu));
        // Match GuidePdf's arithmetic and preserve the selected cell's density.
        guidePdf *= 4.f * node.mass[quadrant] / total;
        extent *= 0.5f;
        lower += extent * float2(quadrant & 1u, quadrant >> 1u);
        const uint child = rtptPGChild(node.topology, quadrant);
        if (child == RTPT_PG_INVALID)
        {
            float3 direction = rtptPGSquareToDirection(lower + extent * random);
            const float2 actual = rtptPGDirectionToSquare(direction);
            if (any(actual < lower) || any(actual >= lower + extent))
            {
                direction = rtptPGSquareToDirection(lower + extent * 0.5f);
                guidePdf = -1.f;
            }
            else
            {
                // A float direction can round onto a neighboring cell even
                // when an inlined square->direction->square expression stays
                // inside this cell. Guard all four edges in absolute UV units:
                // 2^-18 is 64 ULPs at UV in [0.5,1), independent of tree depth.
                const float boundaryMargin = 0x1p-18f;
                const bool safelyInterior = all(actual - lower > boundaryMargin) &&
                    all(lower + extent - actual > boundaryMargin);
                if (safelyInterior) guidePdf = isfinite(guidePdf) ? guidePdf : 0.f;
                else guidePdf = -1.f;
            }
            return direction;
        }
        index = child;
    }
    // Invalid nodes/totals or an exhausted depth limit retain the old center
    // fallback. A partial traversal density is not the PDF of that direction.
    const float3 direction = rtptPGSquareToDirection(lower + extent * 0.5f);
    guidePdf = -1.f;
    return direction;
}

float3 rtptPGSampleGuide(RTPTPGGuide guide, float2 randoms)
{
    float unusedPdf;
    return rtptPGSampleGuide(guide, randoms, unusedPdf);
}

#ifndef RTPT_PG_DIRECTIONS_ONLY
bool rtptPGGetGuide(ShadingData sd, out RTPTPGGuide guide)
{
    guide = {};
    if (gPGSettings.enabled == 0u || !(gPGSettings.guideFraction > 0.f)) return false;
    rtptPGCount(RTPT_PG_DIAG_QUERY);
    const uint2 key = rtptGridKey(sd.posW, sd.getOrientedFaceNormal(), gPGSettings.cameraPosition,
        gPGSettings.sceneScale, gPGSettings.coarseLevels);
    const uint capacity = gPGSettings.readMapCapacity;
    if (capacity > 0u)
    {
        const uint first = rtptGridKeyHash(key) % capacity;
        for (uint probe = 0u; probe < capacity; ++probe)
        {
            const RTPTPGMapEntry entry = gPGReadMap[(first + probe) % capacity];
            if (all(entry.key == uint2(0u))) break;
            if (!all(entry.key == key)) continue;
            if (entry.regionId >= gPGSettings.readRegionCount) break;
            const RTPTPGRegion region = gPGReadRegions[entry.regionId];
            if (!all(region.key == key) || region.generation != entry.generation ||
                (region.flags & RTPT_PG_REGION_READY) == 0u || (region.flags & RTPT_PG_REGION_ZERO) != 0u ||
                region.nodeCount == 0u || region.root >= gPGSettings.readNodeCount) break;
            const float total = dot(gPGReadNodes[region.root].mass, float4(1.f));
            if (!(total > 0.f) || !isfinite(total)) break;
            guide.regionId = entry.regionId;
            guide.root = region.root;
            guide.nodeCount = region.nodeCount;
            guide.generation = region.generation;
            guide.alpha = gPGSettings.guideFraction;
            return true;
        }
    }
    rtptPGCount(RTPT_PG_DIAG_FALLBACK);
    return false;
}
#endif
