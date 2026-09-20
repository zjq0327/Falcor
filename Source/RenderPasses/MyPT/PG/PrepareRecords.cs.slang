#include "Params.slang"

[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    if (tid.x < gPGPathCapacity) gPGPathHeaders[tid.x] = (PGPathHeader)0;
    // Vertex storage is not cleared; only complete headers authorize reads.
    // Epoch tree statistics/diagnostics are not cleared by this per-frame pass.
}
