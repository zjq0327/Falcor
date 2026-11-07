#include "RTPTGRISReuse.slang"
#include "../PrimarySurface/RTPTReprojection.slangh"
#if RTPT_GRIS_SHARC_REPLAY
#include "RTPTGRISCapture.slang"
#endif

struct GrisTemporalSettings
{
    float4x4 previousViewProj;
    uint2 previousFrameDim;
    uint historyValid;
#if RTPT_GRIS_SHARC_REPLAY
    uint replayHistory;
#endif
};

ConstantBuffer<GrisTemporalSettings> gGRISTemporalSettings;
StructuredBuffer<GrisTemporalFreshHistory> gGRISHistory;
#if RTPT_GRIS_ALTERNATING
RWStructuredBuffer<GrisDualWinner> gGRISSpatialOutput;
#else
StructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
StructuredBuffer<GrisLocalPrefix> gGRISLocalPrefixes;
RWStructuredBuffer<GrisCandidate> gGRISSpatialOutput;
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
bool rtptGrisLoadHistory(uint2 pixel, out GrisTemporalFreshHistory history)
{
    history = {};
    if (gGRISTemporalSettings.historyValid == 0u) return false;

    RTPTPrimarySurface primary;
    if (!rtptTryLoadPrimary(pixel, gPrimarySettings.sampleIndex, primary)) return false;
    const uint2 previousDim = gGRISTemporalSettings.previousFrameDim;
    float2 previousPixel;
    float previousDepth;
    if (!rtptProjectPreviousPixel(primary.position + primary.motionW, previousDim,
        gGRISTemporalSettings.previousViewProj, previousPixel, previousDepth)) return false;
    const int2 previousIndex = int2(round(previousPixel));
    if (any(previousIndex < 0) || any(uint2(previousIndex) >= previousDim)) return false;

    history = gGRISHistory[uint(previousIndex.y) * previousDim.x + uint(previousIndex.x)];
    return HitInfo(history.sourceX1).isValid();
}

void rtptGrisDecodeHistory(GrisTemporalFreshHistory history, out GrisLocalPrefix sourcePrefix, out GrisSpatialRecord source)
{
    sourcePrefix = {};
    sourcePrefix.x1Hit = history.sourceX1;
    sourcePrefix.firstDirW = history.sourceFirstDir;
    source = {};
    source.candidate.terminalKind = history.terminalAndFlags & ~kGrisHistoryAnalytic;
    source.reconnectHit = history.reconnectHit;
    source.areaPdf = history.sourceAreaPdf;
    source.suffixDirection = history.suffixDirection;
    source.suffixLight = history.suffixLight;
    source.lightPdfOrStableID = history.lightPdfOrStableID;
    source.lightIsAnalytic = (history.terminalAndFlags & kGrisHistoryAnalytic) != 0u;
}

#if RTPT_GRIS_ALTERNATING
#if RTPT_GRIS_SHARC_REPLAY
void rtptGrisReplayHistory(GrisLocalPrefix sourcePrefix, inout GrisSpatialRecord source, inout SampleGenerator rng)
{
    source.candidate.terminalKind = uint(GrisTerminalKind::GrisNoTerminal);
    GrisConnection connection;
    if (!rtptGrisConnectEdge(sourcePrefix, source, rng, connection)) return;

    if (connection.cacheTerminates)
    {
        source.candidate.terminalKind = uint(GrisTerminalKind::GrisCacheTerminal);
        return;
    }

    GrisDirectLightSample sample;
    if (!rtptGRISSampleDirectLight(connection.x2, rng, sample) || !sample.reusable) return;
    SceneRayQuery<true> query;
    if (!query.traceVisibilityRay(sample.light.visibilityRay)) return;
    rtptGRISStoreDirectTerminal(sample, source);
}
#endif

GrisDualWinner rtptGrisReuseAlternatingHistory(uint2 pixel, GrisAlternatingFresh fresh)
{
    if (fresh.preparedMask == 0u) return {};
    GrisTemporalFreshHistory history;
    GrisAlternatingProposal source = {};
    if (rtptGrisLoadHistory(pixel, history))
    {
        rtptGrisDecodeHistory(history, source.prefix, source.raw);
#if RTPT_GRIS_SHARC_REPLAY
        if (gGRISTemporalSettings.replayHistory != 0u)
        {
            SampleGenerator replayRng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0x78f48121u);
            rtptGrisReplayHistory(source.prefix, source.raw, replayRng);
        }
#endif
    }

    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0xc2b2ae35u);
    return rtptGrisMergeAlternating(pixel, fresh, source, rng);
}
#else
GrisCandidate rtptGrisReuseHistory(uint2 pixel, uint index, GrisSpatialRecord canonical)
{
    const GrisCandidate local = canonical.candidate;
    if (gGRISTemporalSettings.historyValid == 0u || !local.prepared) return local;
    const GrisLocalPrefix targetPrefix = gGRISLocalPrefixes[index];
    if (!HitInfo(targetPrefix.x1Hit).isValid()) return local;
    GrisTemporalFreshHistory history;
    if (!rtptGrisLoadHistory(pixel, history) || history.rootLobe != local.rootLobe) return local;

    GrisLocalPrefix sourcePrefix;
    GrisSpatialRecord source;
    rtptGrisDecodeHistory(history, sourcePrefix, source);
    // Both inputs are raw proposals conditioned on their original prefixes.
    // A zero source.areaPdf still leaves the reverse cross-PDF in the MIS.
    SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0xc2b2ae35u);
    return rtptGrisMerge(canonical, source, targetPrefix, sourcePrefix, rng);
}
#endif
#endif

[numthreads(8, 8, 1)]
void main(uint3 threadID : SV_DispatchThreadID)
{
    const uint2 pixel = threadID.xy;
    if (any(pixel >= gParams.frameDim)) return;
    const uint index = pixel.y * gParams.frameDim.x + pixel.x;
#if RTPT_GRIS_ALTERNATING
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    gGRISSpatialOutput[index] = rtptGrisReuseAlternatingHistory(pixel, gGRISFresh[index]);
#else
    gGRISSpatialOutput[index] = {};
#endif
#else
    const GrisSpatialRecord canonical = gGRISSpatialInput[index];
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    gGRISSpatialOutput[index] = rtptGrisReuseHistory(pixel, index, canonical);
#else
    gGRISSpatialOutput[index] = canonical.candidate;
#endif
#endif
}
