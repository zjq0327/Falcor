import ReuseHelpers;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    uint index = pixelIndex(pixel);
    PrimaryPathContext primary = gPrimary[index];
    for (uint i = 0; i < gSpatialNeighborCount; ++i)
    {
        HybridPair pair = {};
        pair.neighborIndex = 0xffffffff;
        int2 neighbor = neighborPixel(pixel, primary.seed, i);
        if (HitInfo(primary.hit).isValid() && all(neighbor >= 0) && all(neighbor < int2(gDimensions)))
        {
            pair.neighborIndex = pixelIndex(uint2(neighbor));
            PrimaryPathContext other = gPrimary[pair.neighborIndex];
            if (HitInfo(other.hit).isValid())
            {
                ShadingData a = loadShadingData(HitInfo(primary.hit), primary.direction);
                ShadingData b = loadShadingData(HitInfo(other.hit), other.direction);
                if (validGeometry(a, b))
                {
                    pair.status = 5;
                    pair.toNeighbor = replayPrefixForPair(other, gSpatialInput[index].sample);
                    pair.toCenter = replayPrefixForPair(primary, gSpatialInput[pair.neighborIndex].sample);
                }
            }
        }
        // Original neighbor ordinal, including rejected and duplicate proposals.
        gHybridPairs[index * gSpatialNeighborCount + i] = pair;
    }
}
