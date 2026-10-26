#include "RTPTVXPG.h"
#include <cmath>

using namespace Falcor;
namespace RTPTVXPG
{
bool parseSetting(const std::string& key, const Properties::ConstValue& value, Settings& settings)
{
    if (key == "vxpgEstimator")
    {
        const std::string mode = value;
        // Accept old ShortBranch graphs, but never silently substitute for B.
        FALCOR_CHECK(mode == "ShortBranch", "VXPG supports only ShortBranch; estimator '{}' is no longer supported.", mode);
    }
    else if (key == "vxpgEnabled")
        settings.enabled = value;
    else if (key == "vxpgUseGuiding")
        settings.useGuiding = value;
    else if (key == "vxpgFreezeUpdates")
        settings.freezeUpdates = value;
    else if (key == "vxpgPGUseCache")
        settings.pgUseCache = value;
    else if (key == "vxpgDebugEnabled")
        settings.debugEnabled = value;
    else if (key == "vxpgDetailedDiagnostics")
        settings.detailedDiagnostics = value;
    else if (key == "vxpgDiscoveryStride")
        settings.discoveryStride = value;
    else if (key == "vxpgSpatialStaleFrames")
        settings.spatialStaleFrames = value;
    else if (key == "vxpgTreeRefreshFrames")
        settings.treeRefreshFrames = value;
    else if (key == "vxpgHistoryFrames")
        settings.historyFrames = value;
    else if (key == "vxpgHistoryStaleFrames")
        settings.historyStaleFrames = value;
    else if (key == "vxpgLodSceneScale")
        settings.lodSceneScale = value;
    else if (key == "vxpgLodHashCapacity")
        settings.lodHashCapacity = value;
    else if (key == "vxpgLodGeometryCapacity")
        settings.lodGeometryCapacity = value;
    else if (key == "vxpgLodBudgetMB")
        settings.lodBudgetMiB = value;
    else if (key == "vxpgDebugMode")
        settings.debugMode = value;
    else if (key == "vxpgGuideFraction")
        logWarning("RTPT: vxpgGuideFraction is obsolete and ignored; VXPG uses ShortBranch only.");
    else if (key == "vxpgMaxVoxels")
        settings.maxVoxels = value;
    else if (key == "vxpgClusterCount")
        settings.clusterCount = value;
    else if (key == "vxpgSuperpixelSize")
        settings.superpixelSize = value;
    else
        return false;
    return true;
}

void writeSettings(Properties& props, const Settings& settings)
{
    props["vxpgEnabled"] = settings.enabled;
    props["vxpgUseGuiding"] = settings.useGuiding;
    props["vxpgFreezeUpdates"] = settings.freezeUpdates;
    props["vxpgPGUseCache"] = settings.pgUseCache;
    props["vxpgDebugEnabled"] = settings.debugEnabled;
    props["vxpgDetailedDiagnostics"] = settings.detailedDiagnostics;
    props["vxpgDiscoveryStride"] = settings.discoveryStride;
    props["vxpgSpatialStaleFrames"] = settings.spatialStaleFrames;
    props["vxpgTreeRefreshFrames"] = settings.treeRefreshFrames;
    props["vxpgHistoryFrames"] = settings.historyFrames;
    props["vxpgHistoryStaleFrames"] = settings.historyStaleFrames;
    props["vxpgLodSceneScale"] = settings.lodSceneScale;
    props["vxpgLodHashCapacity"] = settings.lodHashCapacity;
    props["vxpgLodGeometryCapacity"] = settings.lodGeometryCapacity;
    props["vxpgLodBudgetMB"] = settings.lodBudgetMiB;
    props["vxpgDebugMode"] = settings.debugMode;
    props["vxpgMaxVoxels"] = settings.maxVoxels;
    props["vxpgClusterCount"] = settings.clusterCount;
    props["vxpgSuperpixelSize"] = settings.superpixelSize;
}

void Manager::validate(const Settings& s)
{
    FALCOR_CHECK(
        s.discoveryStride >= 1 && s.discoveryStride <= 32 && s.spatialStaleFrames >= 1 && s.spatialStaleFrames <= 16384,
        "Invalid incremental grid stride or lifetime."
    );
    FALCOR_CHECK(s.treeRefreshFrames >= 1 && s.treeRefreshFrames <= 1024, "VXPG tree refresh interval must be in [1,1024].");
    FALCOR_CHECK(
        s.historyFrames >= 1 && s.historyFrames <= 1024 && s.historyStaleFrames >= 1 && s.historyStaleFrames <= 4096,
        "VXPG history frames must be in [1,1024] and lifetime in [1,4096]."
    );
    FALCOR_CHECK(std::isfinite(s.lodSceneScale) && s.lodSceneScale > 0.f, "Invalid VXPG LOD scale.");
    FALCOR_CHECK(
        s.lodHashCapacity >= 256 && s.lodHashCapacity <= (1u << 22) && (s.lodHashCapacity & (s.lodHashCapacity - 1)) == 0,
        "Invalid VXPG hash capacity."
    );
    FALCOR_CHECK(
        s.lodGeometryCapacity >= 256 && s.lodGeometryCapacity <= (1u << 21) && s.lodGeometryCapacity <= s.lodHashCapacity,
        "Invalid VXPG geometry capacity."
    );
    FALCOR_CHECK(s.lodBudgetMiB >= 32 && s.lodBudgetMiB <= 2048, "Invalid VXPG budget.");
    FALCOR_CHECK(s.maxVoxels >= 256 && s.maxVoxels <= 262144, "VXPG active voxel capacity must be in [256,262144].");
    FALCOR_CHECK(s.clusterCount >= 1 && s.clusterCount <= 32, "VXPG cluster count must be in [1,32].");
    FALCOR_CHECK(s.superpixelSize >= 8 && s.superpixelSize <= 64, "VXPG superpixel size must be in [8,64].");
    FALCOR_CHECK(s.debugMode <= 4, "VXPG debug mode must be in [0,4].");
}

SettingsChanges compareSettings(const Settings& previous, const Settings& next)
{
    SettingsChanges change;
    change.layout = next.discoveryStride != previous.discoveryStride || next.lodSceneScale != previous.lodSceneScale ||
                    next.lodHashCapacity != previous.lodHashCapacity || next.lodGeometryCapacity != previous.lodGeometryCapacity ||
                    next.lodBudgetMiB != previous.lodBudgetMiB;
    change.topology = next.maxVoxels != previous.maxVoxels || next.clusterCount != previous.clusterCount ||
                      next.superpixelSize != previous.superpixelSize;
    change.history = next.historyFrames != previous.historyFrames || next.historyStaleFrames != previous.historyStaleFrames ||
                     next.enabled != previous.enabled;
    change.spatialLifetime = next.spatialStaleFrames != previous.spatialStaleFrames;
    change.topologyInterval = next.treeRefreshFrames != previous.treeRefreshFrames;
    change.diagnostics = next.detailedDiagnostics != previous.detailedDiagnostics;
    // Freeze and visualization do not change the transport signal.
    change.signal = change.resources() || change.history || change.spatialLifetime || change.topologyInterval ||
                    next.useGuiding != previous.useGuiding || next.pgUseCache != previous.pgUseCache;
    return change;
}

Properties Manager::renderSettingsUI(Gui::Widgets& vx, const Settings& settings, const RuntimeContext& runtime, UIState& ui) const
{
    Properties props;
    bool flag = settings.enabled;
    if (vx.checkbox("Enabled", flag))
        props["vxpgEnabled"] = flag;
    flag = settings.useGuiding;
    if (vx.checkbox("Use guiding", flag))
        props["vxpgUseGuiding"] = flag;
    flag = settings.freezeUpdates;
    if (vx.checkbox("Freeze updates", flag))
        props["vxpgFreezeUpdates"] = flag;
    vx.text("Always active: incremental sparse hash grid, distance LOD, camera reuse,");
    vx.text("lighting history, history confidence, adjacent LOD history and local tree updates.");
    if (auto local = vx.group("Local tree update"))
    {
        local.text("Always enabled.");
        uint32_t frames = settings.treeRefreshFrames;
        if (local.var("Topology refresh frames", frames, 1u, 1024u))
            props["vxpgTreeRefreshFrames"] = frames;
        local.tooltip(
            "Update changed weights and ancestors when membership is unchanged. Rebuild on membership changes or the refresh interval; the "
            "screen top tree updates every frame.",
            true
        );
    }
    if (auto grid = vx.group("Incremental spatial grid"))
    {
        grid.text("Always enabled; world-space entries persist individually.");
        uint32_t stride = settings.discoveryStride, lifetime = settings.spatialStaleFrames;
        if (grid.var("Discovery tile size", stride, 1u, 32u))
            props["vxpgDiscoveryStride"] = stride;
        if (grid.var("Spatial stale lifetime", lifetime, 1u, 16384u))
            props["vxpgSpatialStaleFrames"] = lifetime;
        grid.tooltip(
            "Insert regions discovered by camera/training hits and retire stale entries. New entries may be rejected at capacity; existing "
            "entries remain usable. Proposals use full cell bounds.",
            true
        );
    }
    if (auto history = vx.group("Lighting history"))
    {
        history.text("Always enabled, including confidence weighting and adjacent LOD initialization.");
        uint32_t frames = settings.historyFrames, lifetime = settings.historyStaleFrames;
        if (history.var("History frames", frames, 1u, 1024u))
            props["vxpgHistoryFrames"] = frames;
        if (history.var("Stale lifetime", lifetime, 1u, 4096u))
            props["vxpgHistoryStaleFrames"] = lifetime;
        history.tooltip(
            "Retain importance observations across update frames. Valid zero-light observations update history; missing/low-confidence "
            "histories receive less sampling weight. Grid resets and lighting changes clear history. Freeze pauses aging.",
            true
        );
    }
    vx.text("Estimator: ShortBranch (A)");
    vx.text("VXPG applies at physical bounce 0 and 1 only.");
    auto injection = vx.group("Shared injection");
    if (injection)
    {
        injection.text("Always enabled while VXPG training is active.");
        injection.text("Uses SHaRC Update stride (default 5x5), starting at the second surface.");
        injection.text("Always observes every reached bounce through SHaRC Update bounces.");
        injection.text(
            runtime.sharedWithSHARC  ? "Sharing the active SHaRC training paths."
            : runtime.sharedTraining ? "VXPG-only multi-bounce paths; SHaRC updates are disabled/frozen."
                                     : "Shared injection inactive."
        );
        injection.tooltip(
            "Keeps full-screen primary data. Shares raw direct-light observations at every reached continuation vertex, including the "
            "terminal vertex. Uses the configured SHaRC stride/depth even when SHaRC updates are disabled or frozen, without writing "
            "SHaRC. Resets VXPG lighting history, NRD and final accumulation when the training source changes.",
            true
        );
    }
    auto cache = vx.group("PG SHaRC");
    if (cache)
    {
        flag = settings.pgUseCache;
        if (cache.checkbox("Enabled", flag))
            props["vxpgPGUseCache"] = flag;
        if (!runtime.sharcQueries)
            cache.text("Inactive: SHaRC cache queries are disabled.");
        cache.tooltip(
            "Use full SHaRC on eligible PG hits; otherwise evaluate local lighting and end the branch. Resets NRD and final accumulation.",
            true
        );
    }
    if (auto lod = vx.group("Multi LOD sparse grid"))
    {
        lod.text("Always enabled. SHaRC distance rule; independent VXPG data.");
        float scale = settings.lodSceneScale;
        if (lod.var("Scene scale", scale, 1.e-4f, 1.e6f))
            props["vxpgLodSceneScale"] = scale;
        lod.tooltip(
            "Larger scale means finer cells. The V entry uses scale 8 and 8192 geometry records; raise capacity when increasing scale. New "
            "entries may be rejected at capacity.",
            true
        );
        uint32_t capacity = settings.lodHashCapacity;
        Gui::DropdownList hashes;
        for (uint32_t slots = 256; slots <= (1u << 22); slots *= 2)
            if (slots >= settings.lodGeometryCapacity)
                hashes.push_back({slots, std::to_string(slots)});
        if (lod.dropdown("Hash slots", hashes, capacity))
            props["vxpgLodHashCapacity"] = capacity;
        capacity = settings.lodGeometryCapacity;
        if (lod.var("Geometry capacity", capacity, 256u, std::min(1u << 21, settings.lodHashCapacity)))
            props["vxpgLodGeometryCapacity"] = capacity;
        capacity = settings.lodBudgetMiB;
        if (lod.var("Model budget (MiB)", capacity, 32u, 2048u))
            props["vxpgLodBudgetMB"] = capacity;
        lod.text("Geometry rebuilds: " + std::to_string(getGeometryRebuilds()) + ", level limit: " + std::to_string(getLodLevels()));
    }
    uint32_t number = settings.maxVoxels;
    if (vx.var("Active voxel capacity", number, 256u, 262144u))
        props["vxpgMaxVoxels"] = number;
    number = settings.clusterCount;
    if (vx.var("Clusters", number, 1u, 32u))
        props["vxpgClusterCount"] = number;
    number = settings.superpixelSize;
    if (vx.var("Superpixel size", number, 8u, 64u))
        props["vxpgSuperpixelSize"] = number;
    vx.text("Visibility: always enabled.");
    flag = settings.debugEnabled;
    if (vx.checkbox("Debug Enabled", flag))
        props["vxpgDebugEnabled"] = flag;
    auto diagnostics = vx.group("Detailed diagnostics");
    if (diagnostics)
    {
        flag = settings.detailedDiagnostics;
        if (diagnostics.checkbox("Enabled", flag))
            props["vxpgDetailedDiagnostics"] = flag;
        diagnostics.text("Activity counters cover one rendered frame; model counters require an update.");
        diagnostics.tooltip(
            "Compile out activity atomics when disabled. Error and algorithm state remain enabled. Does not reset the model or image "
            "history.",
            true
        );
        if (diagnostics.button("Read Morton / tree snapshot"))
        {
            const auto snapshot = getTreeSnapshot(settings, runtime);
            if (snapshot.get<bool>("available", false))
            {
                const auto totals = snapshot.get<Properties>("totals");
                ui.treeText = "Snapshot generation " + std::to_string(snapshot.get<uint32_t>("generation")) + ": active " +
                              std::to_string(snapshot.get<uint32_t>("activeCount")) + ", leaves in duplicate Morton groups " +
                              std::to_string(totals.get<uint32_t>("duplicateLeaves")) + ", excess duplicate keys " +
                              std::to_string(totals.get<uint32_t>("duplicateExcess")) +
                              "\nLeaf depth mean/p95/max: " + std::to_string(totals.get<double>("meanDepth")) + "/" +
                              std::to_string(totals.get<uint32_t>("p95Depth")) + "/" + std::to_string(totals.get<uint32_t>("maxDepth"));
            }
            else
                ui.treeText = "Tree snapshot unavailable: " + snapshot.get<std::string>("status", "unknown");
        }
        diagnostics.tooltip(
            "Requires Enabled and a published clustered proposal. Reads the current model only on request; this can pause rendering. "
            "Duplicate Morton groups are counted within each Cluster.",
            true
        );
        if (!ui.treeText.empty())
            diagnostics.text(ui.treeText);
    }
    uint32_t debugMode = settings.debugMode;
    const Gui::DropdownList debugModes = {
        {0, "Voxel bounds"}, {1, "Superpixel ID"}, {2, "Voxel cluster ID"}, {3, "Visibility descriptor"}, {4, "Distance LOD"}};
    if (vx.dropdown("Debug view", debugModes, debugMode))
        props["vxpgDebugMode"] = debugMode;
    return props;
}
} // namespace RTPTVXPG
