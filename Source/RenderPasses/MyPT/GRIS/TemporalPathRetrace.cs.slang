import ReuseHelpers;

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    uint index = pixelIndex(pixel);
    HybridPair pair = {};
    pair.status = temporalNeighbor(pixel, pair.neighborIndex);
    if (pair.status == 5)
    {
        PrimaryPathContext current = gPrimary[index];
        PrimaryPathContext previous = gHistoryPrimary[pair.neighborIndex];
        pair.toNeighbor = replayPrefixForPair(previous, gFresh[index].sample);
        pair.toCenter = replayPrefixForPair(current, gHistoryReservoir[pair.neighborIndex].sample);
    }
    gHybridPairs[index] = pair; // Write invalid entries too; no stale cache reads.
}
