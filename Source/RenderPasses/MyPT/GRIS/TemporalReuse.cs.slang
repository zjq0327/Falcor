// Talbot resampling MIS, following ReSTIRPTPass/TemporalReuse.cs.slang.
import Params;
import Shift;
import RenderPasses.MyPT.MyPTCommon;
import Utils.Math.HashUtils;

StructuredBuffer<PrimaryPathContext> gHistoryPrimary;
StructuredBuffer<PathReservoir> gHistoryReservoir;
RWStructuredBuffer<PathReservoir> gTemporalOutput;
Texture2D<float2> gMotionVector;
RWTexture2D<float4> gTemporalDebug;

void writeTemporalDebug(uint2 pixel, float status, float historyM = 0.f,
    float incomingAccepted = 0.f, float roundTripError = 0.f)
{
#if GRIS_HAS_TEMPORAL_DEBUG
    gTemporalDebug[pixel] = float4(status, historyM, incomingAccepted, roundTripError);
#endif
}

bool validTemporalGeometry(ShadingData current, ShadingData previous)
{
    // Compare both surfaces in the previous camera's coordinate system. Comparing
    // current and previous camera distances would reject ordinary camera motion.
    float currentDepth = length(current.posW - gPreviousCameraPosition);
    float previousDepth = length(previous.posW - gPreviousCameraPosition);
    return current.materialID == previous.materialID &&
        dot(current.frame.N, previous.frame.N) >= gTemporalNormalThreshold &&
        abs(currentDepth - previousDepth) <= gTemporalDepthThreshold * min(currentDepth, previousDepth);
}

bool findHistoryPixel(uint2 pixel, ShadingData current, uint seed, out uint2 previousPixel)
{
    previousPixel = pixel;
    if (gTemporalReprojection == 0) return true;

    SampleGenerator reprojection = SampleGenerator(jenkinsHash(seed ^ 0xa24baed5u));
    float2 offset = sampleNext2D(reprojection);
    float2 location;
#if GRIS_HAS_MOTION
    // Falcor mvec points from current to previous in normalized screen coordinates.
    // Its camera jitter has already been removed by VBufferRT.
    location = float2(pixel) + gMotionVector[pixel] * float2(gDimensions) + offset;
#else
    float4 previousClip = mul(gPreviousViewProj, float4(current.posW, 1.f));
    if (any(!isfinite(previousClip)) || previousClip.w <= 0.f) return false;
    float2 previousUV = previousClip.xy / previousClip.w;
#ifdef FALCOR_FLIP_Y
    previousUV *= float2(0.5f, 0.5f);
#else
    previousUV *= float2(0.5f, -0.5f);
#endif
    previousUV += 0.5f;
    location = previousUV * float2(gDimensions) - 0.5f + offset;
#endif
    // Check the floating-point position before conversion: negative coordinates
    // truncated to int would otherwise incorrectly reuse the screen border.
    if (any(!isfinite(location)) || any(location < 0.f) || any(location >= float2(gDimensions))) return false;
    previousPixel = uint2(floor(location));
    return true;
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
    if (gHistoryValid == 0) return;
    if (!HitInfo(currentPrimary.hit).isValid()) { writeTemporalDebug(pixel, 1.f); return; }

    ShadingData currentSd = loadShadingData(HitInfo(currentPrimary.hit), currentPrimary.direction);
    uint2 previousPixel;
    if (!findHistoryPixel(pixel, currentSd, currentPrimary.seed, previousPixel))
    {
        writeTemporalDebug(pixel, 2.f);
        return;
    }
    uint previousIndex = pixelIndex(previousPixel);
    PrimaryPathContext previousPrimary = gHistoryPrimary[previousIndex];
    if (!HitInfo(previousPrimary.hit).isValid()) { writeTemporalDebug(pixel, 3.f); return; }

    PathReservoir history = gHistoryReservoir[previousIndex];
    // Reference caps confidence only; the normalized estimator weight stays intact.
    history.M = min(float(gMaxHistoryLength) * current.M, history.M);
    ShadingData previousSd = loadShadingData(HitInfo(previousPrimary.hit), previousPrimary.direction);
    if (!validTemporalGeometry(currentSd, previousSd))
    {
        writeTemporalDebug(pixel, 4.f);
        return;
    }

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
        currentToHistory = reconnectPath(current.sample, currentSd, previousSd);
        historyToCurrent = reconnectPath(history.sample, previousSd, currentSd);
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
            ShiftResult back = reconnectPath(currentToHistory.sample, previousSd, currentSd);
            roundTripError = max(relativeContributionError(back.sample.F, current.sample.F),
                abs(back.jacobian * currentToHistory.jacobian - 1.f));
        }
        if (incomingAccepted > 0.f)
        {
            ShiftResult back = reconnectPath(historyToCurrent.sample, currentSd, previousSd);
            roundTripError = max(roundTripError, max(relativeContributionError(back.sample.F, history.sample.F),
                abs(back.jacobian * historyToCurrent.jacobian - 1.f)));
        }
    }
#endif
    writeTemporalDebug(pixel, 5.f, history.M, incomingAccepted, roundTripError);
}
