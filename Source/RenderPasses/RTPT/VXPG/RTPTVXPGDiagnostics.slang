#pragma once
#include "RTPTVXPGResources.slang"

// Activity observations only. Algorithm state, capacity/overflow checks and
// invalid-data counters must keep their unconditional writes.
void rtptVXPGCount(uint index, uint amount = 1u)
{
#if RTPT_VXPG_DETAILED_DIAGNOSTICS
    InterlockedAdd(gVXPGState[index], amount);
#endif
}

void rtptVXPGCountVisibility(uint index, uint amount = 1u)
{
#if RTPT_VXPG_DETAILED_DIAGNOSTICS
    InterlockedAdd(gVXPGClusterState[index], amount);
#endif
}

