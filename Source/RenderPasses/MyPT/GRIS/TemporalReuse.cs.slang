// Talbot resampling MIS, following ReSTIRPTPass/TemporalReuse.cs.slang.
import ReuseHelpers;
import Shift;
import RenderPasses.MyPT.MyPTCommon;
import Utils.Math.HashUtils;

RWStructuredBuffer<PathReservoir> gTemporalOutput;
RWTexture2D<float4> gTemporalDebug;

void writeTemporalDebug(uint2 pixel, float status, float historyM = 0.f,
    float incomingAccepted = 0.f, float roundTripError = 0.f)
{
#if GRIS_HAS_TEMPORAL_DEBUG
    gTemporalDebug[pixel] = float4(status, historyM, incomingAccepted, roundTripError);
#endif
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= gDimensions)) return;
    uint index = pixelIndex(pixel);
    PathReservoir current = gFresh[index];
    PrimaryPathContext currentPrimary = gPrimary[index];
    gTemporalOutput[index] = current;
    writeTemporalDebug(pixel, 0.f);
    HybridPair pair = {};
#if GRIS_SHIFT_STRATEGY == 2
    pair = gHybridPairs[index];
#else
    pair.status = temporalNeighbor(pixel, pair.neighborIndex);
#endif
    if (pair.status != 5) { writeTemporalDebug(pixel, float(pair.status)); return; }
    uint previousIndex = pair.neighborIndex;
    PrimaryPathContext previousPrimary = gHistoryPrimary[previousIndex];

    PathReservoir history = gHistoryReservoir[previousIndex];
    // Reference caps confidence only; the normalized estimator weight stays intact.
    history.M = min(float(gMaxHistoryLength) * current.M, history.M);

    // Equal screen coordinates do not imply equal domains when the camera moves.
    // Exact contexts do support the identity even for direct/delta/local-only paths.
    bool identicalContext = all(currentPrimary.hit == previousPrimary.hit) &&
        all(currentPrimary.direction == previousPrimary.direction);
    ShiftResult currentToHistory = {};
    ShiftResult historyToCurrent = {};
    if (identicalContext)
    {
        currentToHistory.sample = current.sample;
        currentToHistory.jacobian = 1.f;
        historyToCurrent.sample = history.sample;
        historyToCurrent.jacobian = 1.f;
    }
    else
    {
        currentToHistory = shiftForPair(current.sample, currentPrimary, previousPrimary, pair.toNeighbor);
        historyToCurrent = shiftForPair(history.sample, previousPrimary, currentPrimary, pair.toCenter);
        recordShiftCheck(pixel, current.sample, currentPrimary, previousPrimary, currentToHistory);
        recordShiftCheck(pixel, history.sample, previousPrimary, currentPrimary, historyToCurrent);
    }

    float currentMIS = balanceProductMass(float3(pathTarget(current.sample.F), current.M, 1.f),
        float3(pathTarget(currentToHistory.sample.F), currentToHistory.jacobian, history.M), 0.f);
    // Algebraically equivalent to reference p(F_history)/J, without a small-J divide.
    float historyMIS = balanceProductMass(float3(pathTarget(history.sample.F), history.M, 1.f),
        float3(pathTarget(historyToCurrent.sample.F), historyToCurrent.jacobian, current.M), 0.f);
    PathReservoir output = {};
    SampleGenerator selection = SampleGenerator(jenkinsHash(currentPrimary.seed ^ 0x9fb21c65u));
    output.mergeWithResamplingMIS(current.sample, 1.f, current, currentMIS, selection);
    output.mergeWithResamplingMIS(historyToCurrent.sample, historyToCurrent.jacobian, history, historyMIS, selection);
    // Talbot already partitions the two proposals. Unlike spatial Pairwise, there
    // is no final averaging by proposal count, nor a second division by confidence.
    output.finalizeGRIS(0);
    gTemporalOutput[index] = output;

    float incomingAccepted = historyToCurrent.jacobian > 0.f && any(historyToCurrent.sample.F > 0.f) ? 1.f : 0.f;
    float roundTripError = 0.f;
#if GRIS_HAS_TEMPORAL_DEBUG
    if (!identicalContext)
    {
        if (currentToHistory.jacobian > 0.f && any(currentToHistory.sample.F > 0.f))
        {
            ShiftResult back = shiftInline(currentToHistory.sample, previousPrimary, currentPrimary);
            recordShiftFailure(pixel, back.failure);
            roundTripError = max(relativeContributionError(back.sample.F, current.sample.F),
                abs(back.jacobian * currentToHistory.jacobian - 1.f));
        }
        if (incomingAccepted > 0.f)
        {
            ShiftResult back = shiftInline(historyToCurrent.sample, currentPrimary, previousPrimary);
            recordShiftFailure(pixel, back.failure);
            roundTripError = max(roundTripError, max(relativeContributionError(back.sample.F, history.sample.F),
                abs(back.jacobian * historyToCurrent.jacobian - 1.f)));
        }
    }
#endif
    writeTemporalDebug(pixel, 5.f, history.M, incomingAccepted, roundTripError);
}
