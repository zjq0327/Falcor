#include "../RTPTLocalLights.h"
#include "RTPTLocalLightDebugLayout.slangh"
#include "Utils/Timing/Profiler.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <sstream>

using namespace Falcor;

namespace RTPTLocalLights
{
struct DebugState
{
    ref<Buffer> inspection;
    std::array<uint4, RTPT_LOCAL_INSPECT_LANES> captured = {};
    FrameToken submitted;
    uint2 pixel = {};
    bool hasCapture = false;
};

namespace
{
float4 floats(uint4 value)
{
    float4 result;
    static_assert(sizeof(result) == sizeof(value));
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

int4 integers(uint4 value)
{
    int4 result;
    static_assert(sizeof(result) == sizeof(value));
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

const char* sourceName(uint32_t source)
{
    return source == RTPT_LIGHT_SOURCE_TILE ? "Tile" : source == RTPT_LIGHT_SOURCE_GRID ? "Grid" : "Global";
}

const char* kindName(uint32_t kind)
{
    switch (kind)
    {
    case RTPT_LIGHT_KIND_ENVIRONMENT: return "Environment";
    case RTPT_LIGHT_KIND_EMISSIVE: return "Emissive triangle";
    case RTPT_LIGHT_KIND_ANALYTIC: return "Analytic";
    default: return "No sample";
    }
}
} // namespace

void Manager::renderDebug(RenderContext* context, const ref<Texture>& output)
{
    // Always invalidate the submitted marker before an early out so Inspector
    // cannot present a previous frame as current after disabling/changing scene.
    if (mpDebug) mpDebug->submitted.prepared = false;
    if (!mSettings.debugEnabled || !mFrame.prepared || !mpScene || !mInputs.primary.isValid())
    {
        if (output) context->clearUAV(output->getUAV().get(), float4(0.f));
        return;
    }
    FALCOR_PROFILE(context, "LocalLightDebug");
    if (!mpDebug) mpDebug = std::make_shared<DebugState>();
    if (!mpDebug->inspection)
        mpDebug->inspection = mpDevice->createStructuredBuffer(sizeof(uint4), RTPT_LOCAL_INSPECT_LANES);

    barrier(context);
    const uint2 pixel = min(mSettings.debugPixel, mInputs.frameDim - uint2(1));
    auto bind = [&](const ref<ComputePass>& pass)
    {
        auto root = pass->getRootVar();
        bindDebug(root);
        auto scene = root.findMember("gScene");
        if (scene.isValid()) mpScene->bindShaderDataForRaytracing(context, scene);
        auto params = root["gLocalDebugParams"];
        if (params.findMember("selectedPixel").isValid()) params["selectedPixel"] = pixel;
        if (params.findMember("opacity").isValid()) params["opacity"] = mSettings.debugOpacity;
        if (root.findMember("gLocalInspection").isValid()) root["gLocalInspection"] = mpDebug->inspection;
        if (root.findMember("gLocalDebugOutput").isValid()) root["gLocalDebugOutput"] = output;
    };
    if (output)
    {
        auto pass = getPass("Debug/RTPTLocalLightDebug.cs.slang", "draw", true);
        bind(pass);
        pass->execute(context, uint3(mInputs.frameDim, 1));
        context->uavBarrier(output.get());
    }
    auto inspect = getPass("Debug/RTPTLocalLightDebug.cs.slang", "inspect", true);
    bind(inspect);
    inspect->execute(context, uint3(1));
    context->uavBarrier(mpDebug->inspection.get());
    mpDebug->submitted = mFrame;
    mpDebug->pixel = pixel;
}

Properties Manager::captureInspection()
{
    Properties result;
    result["debugEnabled"] = mSettings.debugEnabled;
    result["available"] = false;
    result["frameSerial"] = mFrame.frameSerial;
    result["sceneGeneration"] = mSceneGeneration;
    result["proposalGeneration"] = mProposalGeneration;
    result["cdfEnabled"] = mSettings.cdfEnabled;
    result["persistentEnabled"] = mSettings.persistentEnabled;
    if (!mSettings.debugEnabled || !mpDebug || !mpDebug->inspection || !mpDebug->submitted.prepared ||
        mpDebug->submitted.frameSerial != mFrame.frameSerial || mpDebug->submitted.sceneGeneration != mSceneGeneration ||
        mpDebug->submitted.proposalGeneration != mProposalGeneration)
    {
        result["status"] = std::string(mSettings.debugEnabled ? "No current debug frame" : "Debug disabled");
        return result;
    }

    // 1952 bytes, only on a user/Python capture request. Never read the image or
    // scan the complete light/grid/history buffers on the CPU.
    mpDebug->inspection->getBlob(mpDebug->captured.data(), 0, sizeof(mpDebug->captured));
    mpDebug->hasCapture = true;
    const auto& s = mpDebug->captured;
    const auto meta = s[RTPT_LOCAL_INSPECT_METADATA];
    const auto point = s[RTPT_LOCAL_INSPECT_PIXEL];
    const auto identity = s[RTPT_LOCAL_INSPECT_EVENT_IDENTITY];
    const auto generation = s[RTPT_LOCAL_INSPECT_EVENT_GENERATION];
    const bool eventValid = (identity.w & 1u) && generation.x == meta.x && generation.y == meta.y && generation.z == meta.z;
    result["available"] = true;
    result["status"] = std::string(eventValid ? "Actual main-primary NEE sample" : "No main-primary NEE sample at selected pixel");
    result["frameSerial"] = meta.x;
    result["sceneGeneration"] = meta.y;
    result["proposalGeneration"] = meta.z;
    result["frameFlags"] = meta.w;
    result["pixel"] = uint2(point.x, point.y);
    result["primaryValid"] = point.w != 0;
    result["position"] = floats(s[RTPT_LOCAL_INSPECT_PRIMARY_POSITION]).xyz();
    result["normal"] = floats(s[RTPT_LOCAL_INSPECT_PRIMARY_NORMAL]).xyz();
    result["gridCell"] = integers(s[RTPT_LOCAL_INSPECT_GRID_CELL]);
    result["gridCounts"] = s[RTPT_LOCAL_INSPECT_GRID_COUNTS];
    const auto cache = s[RTPT_LOCAL_INSPECT_GRID_STATE];
    const auto config = s[RTPT_LOCAL_INSPECT_GRID_CONFIG];
    const auto statsA = s[RTPT_LOCAL_INSPECT_GRID_STATS_A];
    const auto statsB = s[RTPT_LOCAL_INSPECT_GRID_STATS_B];
    const auto cell = integers(s[RTPT_LOCAL_INSPECT_GRID_CELL]);
    const bool gridReady = cell.w >= 0 && cache.y == config.x;
    const uint64_t observedCells = uint64_t(statsA.x) + statsA.y;
    result["gridState"] = cache;
    result["gridGeneration"] = config.x;
    result["cdfEnabled"] = config.y != 0u;
    result["persistentEnabled"] = config.z != 0u;
    result["gridReady"] = gridReady;
    result["gridBuiltThisFrame"] = gridReady && cache.w == meta.x;
    result["gridBuildAge"] = gridReady ? meta.x - cache.w : RTPT_LOCAL_LIGHT_INVALID;
    result["gridBuiltCells"] = statsA.x;
    result["gridReusedCells"] = statsA.y;
    for(uint32_t query=0u;query<4u;++query)
        result["queryBranchCounts"+std::to_string(query)]=s[RTPT_LOCAL_INSPECT_BRANCH_COUNTS+query];
    result["fullGridSupportAudit"]=s[RTPT_LOCAL_INSPECT_FULL_AUDIT];
    result["gridWeightsAreIntegerBins"]=true;
    result["gridQueryCount"] = statsB.z;
    result["gridQueryMisses"] = statsB.w;
    result["gridCellReuseRatio"] = observedCells ? float(double(statsA.y) / double(observedCells)) : 0.f;
    result["gridCellReuseRatioAvailable"] = observedCells != 0u;
    result["gridQueryMissRatio"] = statsB.z ? float(double(statsB.w) / double(statsB.z)) : 0.f;
    result["gridQueryMissRatioAvailable"] = statsB.z != 0u;
    const auto gridCandidates = s[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_COUNTS];
    result["gridEmissiveTotalCandidates"] = gridCandidates.x;
    result["gridAnalyticTotalCandidates"] = gridCandidates.y;
    result["gridEmissiveCandidateCount"] = gridCandidates.z;
    result["gridAnalyticCandidateCount"] = gridCandidates.w;
    result["gridCandidateCdfAvailable"] = config.y != 0u;
    for (uint32_t category = 0u; category < 2u; ++category)
    {
        const uint32_t count = std::min(category == 0u ? gridCandidates.z : gridCandidates.w,
                                        uint32_t(RTPT_LOCAL_INSPECT_MAX_CANDIDATES));
        for (uint32_t i = 0u; i < count; ++i)
        {
            const uint32_t lane = category * RTPT_LOCAL_INSPECT_MAX_CANDIDATES + i;
            const std::string prefix = std::string(category == 0u ? "gridEmissiveCandidate" : "gridAnalyticCandidate") + std::to_string(i);
            result[prefix + "Key"] = s[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_KEYS + lane];
            result[prefix + "WeightCdfPmf"] = floats(s[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_VALUES + lane]);
        }
    }
    const auto selectedGridValues = floats(s[RTPT_LOCAL_INSPECT_GRID_SELECTED_VALUES]);
    result["selectedGridEntryAvailable"] = eventValid && selectedGridValues.x > 0.f;
    result["selectedGridWeightCdfPmf"] = selectedGridValues;
    result["tile"] = s[RTPT_LOCAL_INSPECT_TILE];
    result["tileState"] = s[RTPT_LOCAL_INSPECT_TILE_STATE];
    result["historyKey"] = s[RTPT_LOCAL_INSPECT_HISTORY_KEY];
    result["historyInfo"] = s[RTPT_LOCAL_INSPECT_HISTORY_INFO];
    result["historyScore"] = floats(s[RTPT_LOCAL_INSPECT_HISTORY_POSITION]).w;
    result["historyWeight"] = floats(s[RTPT_LOCAL_INSPECT_HISTORY_NORMAL]).w;
    result["sampleValid"] = eventValid;
    result["lightKind"] = identity.x;
    result["lightIndex"] = identity.y;
    result["sourceBranch"] = identity.z;
    result["source"] = std::string(sourceName(identity.z));
    result["visibility"] = eventValid && (identity.w & 2u) != 0;
    result["visibilityTested"] = eventValid && (identity.w & 8u) != 0;
    result["delta"] = (identity.w & 4u) != 0;
    result["selectionPmf"] = floats(s[RTPT_LOCAL_INSPECT_EVENT_POSITION]).w;
    result["samplePdf"] = floats(s[RTPT_LOCAL_INSPECT_EVENT_NORMAL]).w;
    result["misReferencePdf"] = floats(s[RTPT_LOCAL_INSPECT_EVENT_TARGET]).w;
    result["rawContribution"] = floats(s[RTPT_LOCAL_INSPECT_EVENT_DIRECTION]).w;
    result["sampleContext"] = s[RTPT_LOCAL_INSPECT_EVENT_CONTEXT];
    result["sampleGeneration"] = generation;
    const uint32_t candidates = std::min(s[RTPT_LOCAL_INSPECT_CANDIDATE_COUNT].x, uint32_t(RTPT_LOCAL_INSPECT_MAX_CANDIDATES));
    result["candidateCount"] = candidates;
    for (uint32_t i = 0; i < candidates; ++i)
    {
        const std::string prefix = "candidate" + std::to_string(i);
        result[prefix + "Key"] = s[RTPT_LOCAL_INSPECT_CANDIDATE_KEYS + i];
        result[prefix + "WeightPmf"] = floats(s[RTPT_LOCAL_INSPECT_CANDIDATE_VALUES + i]);
    }
    return result;
}

Properties Manager::renderDiagnosticsUI(Gui::Widgets& widgets)
{
    Properties changes;
    uint32_t mode = mSettings.debugMode;
    const Gui::DropdownList modes = {
        {0, "Grid candidate count"}, {1, "Adaptive tile boundaries"}, {2, "Actual light key"}, {3, "Actual source branch"},
        {4, "History validity"}, {5, "Actual visibility"}, {6, "Grid cell identity"}, {7, "History age"},
        {8, "Grid cache state"}, {9, "Grid cache build age"}
    };
    if (widgets.dropdown("View", modes, mode)) changes["localLightDebugMode"] = mode;
    uint2 pixel = mSettings.debugPixel;
    const uint2 maximum = max(mInputs.frameDim, uint2(1)) - uint2(1);
    bool changed = widgets.var("Inspector X", pixel.x, 0u, maximum.x);
    changed |= widgets.var("Inspector Y", pixel.y, 0u, maximum.y);
    if (changed) changes["localLightDebugPixel"] = pixel;
    float opacity = mSettings.debugOpacity;
    if (widgets.var("Overlay mask opacity", opacity, 0.f, 1.f, .01f)) changes["localLightDebugOpacity"] = opacity;
    widgets.text("Select RTPT.localLightDebug or LocalLightOverlay.output.\nGray: Global/unavailable; magenta: invalid category; white: boundaries/selected point.\nSource: blue Global, green Grid, orange Tile. Visibility: green visible, red occluded, yellow untested.");
    widgets.text(std::string("Grid sampler: ") + (mSettings.cdfEnabled ? "CDF" : "linear") +
                 "; update: " + (mSettings.persistentEnabled ? "persistent cache" : "rebuild each frame") + ".");
    if (mode == 8u)
        widgets.text("Cache state: orange rebuilt this frame; green reused; gray unavailable.\nMagenta: an invalid category uses Global.");
    else if (mode == 9u)
        widgets.text("Age is frames since the last build, scaled to 256 frames.\nUnchanged world-space cells are reused indefinitely.");
    if (!mSettings.debugEnabled)
    {
        widgets.text("Debug disabled. No event logging, drawing, or Inspector readback.");
        return changes;
    }
    if (!mSettings.gridEnabled)
        widgets.text("Global sampling. Grid is disabled; Tile requires a valid Grid. Actual-event views remain available.");
    else if (!mFrame.prepared)
        widgets.text("No current scene/frame; diagnostic output is transparent.");
    widgets.text("Inspector captures the actual representative primary NEE event.\nCapture reads a small snapshot; it does not sample lights or trace rays.");
    if (widgets.button("Capture selected pixel")) captureInspection();
    if (!mpDebug || !mpDebug->hasCapture)
    {
        widgets.text("No Inspector snapshot captured.");
        return changes;
    }

    const auto& s = mpDebug->captured;
    const auto meta = s[RTPT_LOCAL_INSPECT_METADATA];
    const auto point = s[RTPT_LOCAL_INSPECT_PIXEL];
    const auto identity = s[RTPT_LOCAL_INSPECT_EVENT_IDENTITY];
    const auto generation = s[RTPT_LOCAL_INSPECT_EVENT_GENERATION];
    const uint2 selected = min(mSettings.debugPixel, maximum);
    const bool current = meta.x == mFrame.frameSerial && meta.y == mSceneGeneration && meta.z == mProposalGeneration &&
                         point.x == selected.x && point.y == selected.y;
    const bool eventValid = (identity.w & 1u) && generation.x == meta.x && generation.y == meta.y && generation.z == meta.z;
    std::ostringstream text;
    text << (current ? "Captured current frame" : "Stored snapshot; capture again to refresh") << "\nFrame / scene / proposal: "
         << meta.x << " / " << meta.y << " / " << meta.z << "\nPixel: " << point.x << ", " << point.y;
    const auto cell = integers(s[RTPT_LOCAL_INSPECT_GRID_CELL]);
    const auto grid = s[RTPT_LOCAL_INSPECT_GRID_COUNTS];
    const auto tile = s[RTPT_LOCAL_INSPECT_TILE];
    text << "\nGrid cell: " << cell.x << ", " << cell.y << ", " << cell.z << "; slot " << cell.w
         << "\nGrid mesh / analytic candidates: " << grid.x << " / " << grid.y
         << "\nTile ID / origin / size: " << tile.x << " / " << tile.y << ", " << tile.z << " / " << tile.w;
    const auto cache = s[RTPT_LOCAL_INSPECT_GRID_STATE];
    const auto config = s[RTPT_LOCAL_INSPECT_GRID_CONFIG];
    const auto statsA = s[RTPT_LOCAL_INSPECT_GRID_STATS_A];
    const auto statsB = s[RTPT_LOCAL_INSPECT_GRID_STATS_B];
    const bool gridReady = cell.w >= 0 && cache.y == config.x;
    text << "\nCaptured sampler / update: " << (config.y ? "CDF" : "linear") << " / "
         << (config.z ? "persistent" : "rebuild each frame")
         << "\nGrid generation / slot version: " << config.x << " / " << cache.z;
    if (gridReady)
        text << "\nGrid build age: " << meta.x - cache.w << " frames";
    else text << "\nGrid unavailable at selected point: use Global.";
    text << "\nGPU cells built / reused: " << statsA.x << " / " << statsA.y;
    const uint64_t observedCells = uint64_t(statsA.x) + statsA.y;
    if (observedCells)
        text << "\nCell-level reuse: " << 100.0 * double(statsA.y) / double(observedCells) << "% (not a ray-query hit rate)";
    else text << "\nCell-level reuse: no cells observed in this snapshot";
    text << "\nActual Grid queries / missing-cell queries: " << statsB.z << " / " << statsB.w;
    if (statsB.z)
        text << " (" << 100.0 * double(statsB.w) / double(statsB.z) << "% missing)";
    const auto history = s[RTPT_LOCAL_INSPECT_HISTORY_INFO];
    text << "\nHistory valid / age / observations: " << history.x << " / " << history.y << " / " << history.z;
    if (eventValid)
    {
        text << "\n" << kindName(identity.x) << " #" << identity.y << "; " << sourceName(identity.z)
             << "; " << (!(identity.w & 8u) ? "visibility untested (null sample)" : (identity.w & 2u) ? "visible" : "occluded")
             << ((identity.w & 4u) ? "; delta" : "")
             << "\nSelection PMF: " << floats(s[RTPT_LOCAL_INSPECT_EVENT_POSITION]).w
             << "\nSolid-angle PDF / MIS reference: " << floats(s[RTPT_LOCAL_INSPECT_EVENT_NORMAL]).w
             << " / " << floats(s[RTPT_LOCAL_INSPECT_EVENT_TARGET]).w
             << "\nRaw contribution: " << floats(s[RTPT_LOCAL_INSPECT_EVENT_DIRECTION]).w;
        const auto selectedGrid = floats(s[RTPT_LOCAL_INSPECT_GRID_SELECTED_VALUES]);
        if (selectedGrid.x > 0.f)
        {
            text << "\nSelected light Grid weight / PMF: " << selectedGrid.x << " / " << selectedGrid.w;
            if (config.y) text << "; CDF [" << selectedGrid.y << ", " << selectedGrid.z << ")";
        }
    }
    else text << "\nNo actual main-primary NEE sample at this pixel.";
    const auto gridCandidates = s[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_COUNTS];
    for (uint32_t category = 0u; category < 2u; ++category)
    {
        const uint32_t count = std::min(category == 0u ? gridCandidates.z : gridCandidates.w,
                                        uint32_t(RTPT_LOCAL_INSPECT_MAX_CANDIDATES));
        if (!count) continue;
        text << "\nGrid " << (category == 0u ? "emissive" : "analytic") << " candidates (first " << count
             << "; PMF conditional on Grid branch):";
        for (uint32_t i = 0u; i < count; ++i)
        {
            const uint32_t lane = category * RTPT_LOCAL_INSPECT_MAX_CANDIDATES + i;
            const auto key = s[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_KEYS + lane];
            const auto values = floats(s[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_VALUES + lane]);
            text << "\n  #" << key.y << ": weight " << values.x;
            if (config.y) text << ", CDF [" << values.y << ", " << values.z << ")";
            text << ", Grid PMF " << values.w;
        }
    }
    const uint32_t candidates = std::min(s[RTPT_LOCAL_INSPECT_CANDIDATE_COUNT].x, uint32_t(RTPT_LOCAL_INSPECT_MAX_CANDIDATES));
    if (candidates)
    {
        text << "\nTile candidates (category-conditional mixture PMF):";
        for (uint32_t i = 0; i < candidates; ++i)
        {
            const auto key = s[RTPT_LOCAL_INSPECT_CANDIDATE_KEYS + i];
            const auto weight = floats(s[RTPT_LOCAL_INSPECT_CANDIDATE_VALUES + i]);
            text << "\n  " << kindName(key.x) << " #" << key.y << ": weight " << weight.x << ", PMF " << weight.y;
        }
    }
    widgets.text(text.str());
    return changes;
}
} // namespace RTPTLocalLights
