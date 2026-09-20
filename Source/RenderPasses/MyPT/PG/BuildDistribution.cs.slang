/***************************************************************************
 # Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
 # SPDX-License-Identifier: BSD-3-Clause
 ***************************************************************************/
#include "Params.slang"

// A spatial leaf exclusively owns its contiguous directional-node interval.
// Parents precede descendants, so reverse traversal needs no cross-thread
// synchronization. This intentionally simple epoch-boundary pass is not a
// parallel-per-node reduction. CPU publication rechecks/normalizes in double.
[numthreads(64, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint spatialIndex = dispatchThreadID.x;
    if (spatialIndex >= gPGBuildSpatialCount) return;
    PGSpatialNode spatial = gPGBuildSpatial[spatialIndex];
    if (spatial.childBase != kPGInvalidNode) return;
    [loop]
    for (uint i = spatial.directionalEnd; i > spatial.directionalRoot;)
    {
        --i;
        PGDirectionalNode node = gPGBuildDirectional[i];
        [unroll]
        for (uint q = 0u; q < 4u; ++q)
        {
            uint child = node.children[q];
            if (child == kPGInvalidNode) continue;
            float sum = 0.f;
            [unroll]
            for (uint c = 0u; c < 4u; ++c) sum += asfloat(gPGBuildWeightBits[4u * child + c]);
            gPGBuildWeightBits[4u * i + q] = asuint(sum);
        }
    }
}
