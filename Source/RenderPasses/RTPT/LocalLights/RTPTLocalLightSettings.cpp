#include "RTPTLocalLights.h"
#include <cmath>

using namespace Falcor;

namespace RTPTLocalLights
{
bool parseSetting(const std::string& key, const Properties::ConstValue& value, Settings& settings)
{
    if (key == "localLightGridEnabled") settings.gridEnabled = value;
    else if (key == "localLightGridResolution") settings.gridResolution = value;
    else if (key == "localLightGridCdfEnabled") settings.cdfEnabled = value;
    else if (key == "localLightGridPersistentEnabled") settings.persistentEnabled = value;
    else if (key == "localLightTileEnabled") settings.tileEnabled = value;
    else if (key == "localLightAdaptiveEnabled") settings.adaptiveEnabled = value;
    else if (key == "localLightDebugEnabled") settings.debugEnabled = value;
    else if (key == "localLightTileCandidates") settings.tileCandidates = value;
    else if (key == "localLightHistoryFrames") settings.historyFrames = value;
    else if (key == "localLightHistoryStaleFrames") settings.historyStaleFrames = value;
    else if (key == "localLightMergeFrames") settings.mergeFrames = value;
    else if (key == "localLightFeedbackRecords") settings.feedbackRecords = value;
    else if (key == "localLightDepthThreshold") settings.depthThreshold = value;
    else if (key == "localLightNormalThresholdDegrees") settings.normalThresholdDegrees = value;
    else if (key == "localLightBudgetMiB") settings.budgetMiB = value;
    else if (key == "localLightDebugMode") settings.debugMode = value;
    else if (key == "localLightDebugPixel") settings.debugPixel = value;
    else if (key == "localLightDebugOpacity") settings.debugOpacity = value;
    else return false;
    return true;
}

void writeSettings(Properties& props, const Settings& settings)
{
    props["localLightGridEnabled"] = settings.gridEnabled;
    props["localLightGridCdfEnabled"] = settings.cdfEnabled;
    props["localLightGridResolution"] = settings.gridResolution;
    props["localLightGridPersistentEnabled"] = settings.persistentEnabled;
    props["localLightTileEnabled"] = settings.tileEnabled;
    props["localLightAdaptiveEnabled"] = settings.adaptiveEnabled;
    props["localLightDebugEnabled"] = settings.debugEnabled;
    props["localLightTileCandidates"] = settings.tileCandidates;
    props["localLightHistoryFrames"] = settings.historyFrames;
    props["localLightHistoryStaleFrames"] = settings.historyStaleFrames;
    props["localLightMergeFrames"] = settings.mergeFrames;
    props["localLightFeedbackRecords"] = settings.feedbackRecords;
    props["localLightDepthThreshold"] = settings.depthThreshold;
    props["localLightNormalThresholdDegrees"] = settings.normalThresholdDegrees;
    props["localLightBudgetMiB"] = settings.budgetMiB;
    props["localLightDebugMode"] = settings.debugMode;
    props["localLightDebugPixel"] = settings.debugPixel;
    props["localLightDebugOpacity"] = settings.debugOpacity;
}

void Manager::validate(const Settings& s)
{
    FALCOR_CHECK(s.gridResolution >= 1u && s.gridResolution <= 64u, "Full-CDF maximum axis must be in [1,64].");
    FALCOR_CHECK(s.tileCandidates >= 1u && s.tileCandidates <= RTPT_LOCAL_MAX_TILE_LIGHTS, "Local light tile candidates must be in [1,16].");
    FALCOR_CHECK(s.historyFrames >= 1u && s.historyFrames <= 1024u, "Local light history frames must be in [1,1024].");
    FALCOR_CHECK(s.historyStaleFrames >= 1u && s.historyStaleFrames <= 4096u, "Local light history lifetime must be in [1,4096].");
    FALCOR_CHECK(s.mergeFrames >= 1u && s.mergeFrames <= 1024u, "Local light tile merge frames must be in [1,1024].");
    FALCOR_CHECK(s.feedbackRecords >= 1u && s.feedbackRecords <= (1u << 20u), "Local light feedback capacity must be in [1,1048576].");
    FALCOR_CHECK(std::isfinite(s.depthThreshold) && s.depthThreshold > 0.f, "Local light depth threshold must be positive and finite.");
    FALCOR_CHECK(std::isfinite(s.normalThresholdDegrees) && s.normalThresholdDegrees >= 0.f && s.normalThresholdDegrees <= 90.f,
                 "Local light normal threshold must be in [0,90] degrees.");
    FALCOR_CHECK(s.budgetMiB >= 16u && s.budgetMiB <= 2048u, "Local light model budget must be in [16,2048] MiB.");
    FALCOR_CHECK(s.debugMode <= 9u, "Local light debug mode must be in [0,9].");
    FALCOR_CHECK(std::isfinite(s.debugOpacity) && s.debugOpacity >= 0.f && s.debugOpacity <= 1.f,
                 "Local light debug opacity must be in [0,1].");
}

SettingsChanges compareSettings(const Settings& previous, const Settings& next)
{
    SettingsChanges change;
    const bool storage = next.gridResolution != previous.gridResolution ||
                         next.tileCandidates != previous.tileCandidates || next.feedbackRecords != previous.feedbackRecords ||
                         next.budgetMiB != previous.budgetMiB;
    const bool switches = next.gridEnabled != previous.gridEnabled || next.tileEnabled != previous.tileEnabled;
    const bool topology = next.adaptiveEnabled != previous.adaptiveEnabled ||
                          next.cdfEnabled != previous.cdfEnabled || next.persistentEnabled != previous.persistentEnabled;
    const bool history = next.historyFrames != previous.historyFrames || next.historyStaleFrames != previous.historyStaleFrames ||
                         next.mergeFrames != previous.mergeFrames || next.depthThreshold != previous.depthThreshold ||
                         next.normalThresholdDegrees != previous.normalThresholdDegrees;
    change.resources = storage || switches || next.debugEnabled != previous.debugEnabled;
    change.history = storage || switches || topology || history;
    change.signal = change.history;
    change.diagnostics = next.debugEnabled != previous.debugEnabled || next.debugMode != previous.debugMode ||
                         any(next.debugPixel != previous.debugPixel) || next.debugOpacity != previous.debugOpacity;
    return change;
}

Properties Manager::renderSettingsUI(Gui::Widgets& widgets) const
{
    Properties props;
    widgets.text("Complete Grid: primary Grid + Tile; other surfaces Grid. Disabled or invalid Grid uses Global.");
    if (auto grid = widgets.group("Light Grid"))
    {
        bool flag = mSettings.gridEnabled;
        if (grid.checkbox("Enabled", flag)) props["localLightGridEnabled"] = flag;
        uint32_t resolution = mSettings.gridResolution;
        if (grid.var("Maximum grid axis", resolution, 1u, 64u)) props["localLightGridResolution"] = resolution;
        grid.text("Every light has at least one of 2^24 probability bins. Budget reduces cells, never lights.");
        if (auto cdf = grid.group("CDF sampling"))
        {
            flag = mSettings.cdfEnabled;
            if (cdf.checkbox("Enabled", flag)) props["localLightGridCdfEnabled"] = flag;
            cdf.tooltip("Uses a per-cell CDF for light selection and PDF evaluation. Disabled uses the linear sampler. Requires Light Grid enabled.", true);
        }
        if (auto persistent = grid.group("Persistent cache"))
        {
            flag = mSettings.persistentEnabled;
            if (persistent.checkbox("Enabled", flag)) props["localLightGridPersistentEnabled"] = flag;
            persistent.tooltip("Reuses valid world-space cells across frames. Disabled rebuilds every frame. Works with CDF or linear sampling; requires Light Grid enabled.", true);
        }
        grid.tooltip("The Grid covers all supported lights without radius or per-cell truncation. Invalid or unavailable models fall back to Global.", true);
    }
    if (auto tile = widgets.group("Tile feedback"))
    {
        bool flag = mSettings.tileEnabled;
        if (tile.checkbox("Enabled", flag)) props["localLightTileEnabled"] = flag;
        flag = mSettings.adaptiveEnabled;
        if (tile.checkbox("Adaptive subdivision enabled", flag)) props["localLightAdaptiveEnabled"] = flag;
        tile.text("Tiles: 32, 16 or 8 pixels. Feedback uses actual primary NEE events.");
        uint32_t count = mSettings.tileCandidates;
        if (tile.var("Candidate lights", count, 1u, uint32_t(RTPT_LOCAL_MAX_TILE_LIGHTS))) props["localLightTileCandidates"] = count;
        count = mSettings.historyFrames;
        if (tile.var("History frames", count, 1u, 1024u)) props["localLightHistoryFrames"] = count;
        count = mSettings.historyStaleFrames;
        if (tile.var("History lifetime", count, 1u, 4096u)) props["localLightHistoryStaleFrames"] = count;
        count = mSettings.mergeFrames;
        if (tile.var("Stable frames before merge", count, 1u, 1024u)) props["localLightMergeFrames"] = count;
        float depth = mSettings.depthThreshold;
        if (tile.var("Relative depth threshold", depth, 1.e-4f, 10.f)) props["localLightDepthThreshold"] = depth;
        float angle = mSettings.normalThresholdDegrees;
        if (tile.var("Normal threshold (degrees)", angle, 0.f, 90.f)) props["localLightNormalThresholdDegrees"] = angle;
        tile.tooltip("Tile feedback requires a valid Light Grid and is restricted to primary surfaces. Secondary, training and probe queries never read Tile candidates.", true);
    }
    if (auto capacity = widgets.group("Capacity"))
    {
        uint32_t count = mSettings.feedbackRecords;
        if (capacity.var("Feedback records", count, 1u, 1u << 20u)) props["localLightFeedbackRecords"] = count;
        count = mSettings.budgetMiB;
        if (capacity.var("Model budget (MiB)", count, 16u, 2048u)) props["localLightBudgetMiB"] = count;
    }
    bool debug = mSettings.debugEnabled;
    if (widgets.checkbox("Debug enabled", debug)) props["localLightDebugEnabled"] = debug;
    return props;
}
} // namespace RTPTLocalLights
