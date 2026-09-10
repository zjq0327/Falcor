import ReuseHelpers;
import Shift;
import RenderPasses.MyPT.MyPTCommon;
import Utils.Math.HashUtils;

RWStructuredBuffer<PathReservoir> gSpatialOutput;
RWTexture2D<float4> gSpatialDebug;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    uint index = pixelIndex(pixel);
    PrimaryPathContext primary = gPrimary[index];
    PathReservoir center = gSpatialInput[index]; // Frozen canonical sample for the entire round.
    gSpatialOutput[index] = center;
#if GRIS_HAS_SPATIAL_DEBUG
    float2 previousErrors = gSpatialDebug[pixel].zw;
    gSpatialDebug[pixel] = float4(0.f, 0.f, previousErrors);
#endif
    if (!HitInfo(primary.hit).isValid() || gSpatialNeighborCount == 0) return;
    ShadingData centerSd = loadShadingData(HitInfo(primary.hit), primary.direction);
    PathReservoir output = {};
    SampleGenerator selection = SampleGenerator(jenkinsHash(primary.seed ^ 0xd1b54a35u ^ jenkinsHash(gSpatialRound)));
    float canonical = 1.f;
    uint validCount = 0;
    uint acceptedCount = 0;
    float identityError = 0.f;
    float roundTripError = 0.f;
#if GRIS_HAS_SPATIAL_DEBUG
    if (hasShiftIdentity(center.sample))
    {
        ShiftResult identity = shiftInline(center.sample, primary, primary, true);
        identityError = max(relativeContributionError(identity.sample.F, center.sample.F), abs(identity.jacobian - 1.f));
    }
#endif
    for (uint i = 0; i < gSpatialNeighborCount; ++i)
    {
        HybridPair pair = {};
#if GRIS_SHIFT_STRATEGY == 2
        pair = gHybridPairs[index * gSpatialNeighborCount + i];
        if (pair.status != 5) continue;
        uint neighborIndex = pair.neighborIndex;
#else
        int2 neighbor = neighborPixel(pixel, primary.seed, i);
        if (any(neighbor < 0) || any(neighbor >= int2(gDimensions))) continue;
        uint neighborIndex = pixelIndex(uint2(neighbor));
#endif
        PrimaryPathContext neighborPrimary = gPrimary[neighborIndex];
        if (!HitInfo(neighborPrimary.hit).isValid()) continue;
        ShadingData neighborSd = loadShadingData(HitInfo(neighborPrimary.hit), neighborPrimary.direction);
        if (!validGeometry(centerSd, neighborSd)) continue;
        PathReservoir source = gSpatialInput[neighborIndex];
        ++validCount; // Count before testing contribution/support/visibility, as in the reference.

        ShiftResult reverse = shiftForPair(center.sample, primary, neighborPrimary, pair.toNeighbor);
        recordShiftCheck(pixel, center.sample, primary, neighborPrimary, reverse);
        if (neighborIndex == index)
        {
            // Same pixel is the exact identity map, including local-only terminal types.
            // Avoid perturbing its PDF by reconstructing a direction from float hit positions.
            reverse.sample = center.sample;
            reverse.jacobian = 1.f;
        }
        float centerConfidence = center.M / float(gSpatialNeighborCount);
        canonical += balanceProductMass(float3(pathTarget(center.sample.F), centerConfidence, 1.f),
            float3(pathTarget(reverse.sample.F), reverse.jacobian, source.M), 1.f);

        ShiftResult shifted = shiftForPair(source.sample, neighborPrimary, primary, pair.toCenter);
        recordShiftCheck(pixel, source.sample, neighborPrimary, primary, shifted);
        if (neighborIndex == index) shifted = reverse;
        // Algebraically equivalent to reference pHat(Fsrc)/J, without dividing by a small J.
        float neighborMIS = balanceProductMass(float3(pathTarget(source.sample.F), source.M, 1.f),
            float3(pathTarget(shifted.sample.F), shifted.jacobian, centerConfidence), 0.f);
        output.mergeWithResamplingMIS(shifted.sample, shifted.jacobian, source, neighborMIS, selection);
        if (shifted.jacobian > 0.f && any(shifted.sample.F > 0.f))
        {
            ++acceptedCount;
#if GRIS_HAS_SPATIAL_DEBUG
            if (neighborIndex != index)
            {
                ShiftResult back = shiftInline(shifted.sample, primary, neighborPrimary);
                recordShiftFailure(pixel, back.failure);
                float error = max(relativeContributionError(back.sample.F, source.sample.F), abs(back.jacobian * shifted.jacobian - 1.f));
                roundTripError = max(roundTripError, error);
            }
#endif
        }
    }
    // Preserve exact bits when all geometric proposals were invalid.
    if (validCount > 0)
    {
        output.mergeWithResamplingMIS(center.sample, 1.f, center, canonical, selection);
        output.finalizeGRIS(validCount);
        gSpatialOutput[index] = output;
    }
#if GRIS_HAS_SPATIAL_DEBUG
    gSpatialDebug[pixel] = float4(float(validCount), float(acceptedCount), max(previousErrors, float2(identityError, roundTripError)));
#endif
}
