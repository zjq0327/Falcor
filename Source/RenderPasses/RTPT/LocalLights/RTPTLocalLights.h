#pragma once
#include "Falcor.h"
#include "Utils/Properties.h"
#include "RTPTLocalLightLayout.slangh"
#include "../PrimarySurface/RTPTPrimarySurface.h"
#include <map>

namespace RTPTLocalLights
{
struct Settings
{
    bool gridEnabled = false;
    bool cdfEnabled = true;
    uint32_t gridResolution = 16;
    bool persistentEnabled = true;
    bool tileEnabled = false;
    bool adaptiveEnabled = true;
    bool debugEnabled = false;
    uint32_t tileCandidates = 16;
    uint32_t historyFrames = 16;
    uint32_t historyStaleFrames = 64;
    uint32_t mergeFrames = 8;
    uint32_t feedbackRecords = 65536;
    float depthThreshold = 0.05f;
    float normalThresholdDegrees = 15.f;
    uint32_t budgetMiB = 128;
    uint32_t debugMode = 0;
    Falcor::uint2 debugPixel = Falcor::uint2(0);
    float debugOpacity = 0.65f;
};

struct SettingsChanges
{
    bool resources = false;
    bool history = false;
    bool signal = false;
    bool diagnostics = false;
};

bool parseSetting(const std::string& key, const Falcor::Properties::ConstValue& value, Settings& settings);
void writeSettings(Falcor::Properties& properties, const Settings& settings);
SettingsChanges compareSettings(const Settings& previous, const Settings& next);

enum class QueryKind : uint32_t
{
    MainPrimary = RTPT_LIGHT_QUERY_MAIN_PRIMARY,
    Secondary = RTPT_LIGHT_QUERY_SECONDARY,
    SharedTraining = RTPT_LIGHT_QUERY_TRAINING,
    Probe = RTPT_LIGHT_QUERY_PROBE,
};

enum class Invalidation
{
    Proposal,
    History,
    Grid,
    Catalog,
    Resources,
};

struct FrameInputs
{
    Falcor::uint2 frameDim = Falcor::uint2(0);
    uint32_t sampleOffset = 0;
    uint32_t seed = 0;
    RTPTPrimarySurface::View primary;
    bool useNEE = true;
};

// CPU preparation metadata. This is not a GPU-completion or model-ready flag.
struct FrameToken
{
    uint32_t frameSerial = 0;
    uint32_t sceneGeneration = 0;
    uint32_t proposalGeneration = 0;
    bool prepared = false;
};

struct DebugState;

class Manager
{
public:
    explicit Manager(Falcor::ref<Falcor::Device> device) : mpDevice(device) {}
    void setScene(const Falcor::ref<Falcor::Scene>& scene);
    void configure(const Settings& settings);
    static void validate(const Settings& settings);
    bool needsPrimarySurface() const { return (mSettings.gridEnabled && mSettings.tileEnabled) || mSettings.debugEnabled; }
    void invalidate(Invalidation scope = Invalidation::Catalog);
    FrameToken prepareFrame(Falcor::RenderContext* context, const FrameInputs& inputs);
    void bindSampling(const Falcor::ShaderVar& root, QueryKind kind = QueryKind::Secondary) const;
    void bindFeedback(const Falcor::ShaderVar& root, QueryKind kind = QueryKind::MainPrimary) const;
    void bindDebug(const Falcor::ShaderVar& root) const;
    void renderDebug(Falcor::RenderContext* context, const Falcor::ref<Falcor::Texture>& output);
    // Refresh diagnostics for a held accumulated image without rebuilding or
    // advancing the proposal/history. An optional matching primary view can
    // supply geometry when diagnostics were enabled after rendering stopped.
    void renderHeldDebug(Falcor::RenderContext* context, const Falcor::ref<Falcor::Texture>& output,
                         const RTPTPrimarySurface::View& primary = {});
    Falcor::Properties captureInspection();
    Falcor::Properties renderDiagnosticsUI(Falcor::Gui::Widgets& widget);
    Falcor::Properties renderSettingsUI(Falcor::Gui::Widgets& widget) const;
    void finishFrame(Falcor::RenderContext* context);
    const FrameToken& getFrameToken() const { return mFrame; }
    Falcor::Properties getStatistics() const;

private:
    struct Resources
    {
        Falcor::ref<Falcor::Buffer> gridKeys, gridCount, gridState, gridStats;
        Falcor::ref<Falcor::Buffer> fullCdf, fullCatalog;
        Falcor::ref<Falcor::Buffer> tileState, tileLights, tileWeights;
        Falcor::ref<Falcor::Buffer> history, reprojectedHistory, projectionRecords, historyWinners;
        Falcor::ref<Falcor::Buffer> currentFeedback, historyNext, probeFeedback, debugSelected;
        Falcor::ref<Falcor::Texture> pixelToTile, debugEvents, dummyPosition, dummyNormal, dummyHit;
    };
    void ensureResources(Falcor::RenderContext* context, bool full);
    Falcor::ref<Falcor::ComputePass> getPass(const std::string& file, const std::string& entry, bool lighting = false);
    void bindCommon(const Falcor::ShaderVar& root, QueryKind kind) const;
    void dispatch(Falcor::RenderContext* context, const std::string& file, const std::string& entry,
                  Falcor::uint3 dimensions, bool lighting = false);
    void barrier(Falcor::RenderContext* context) const;
    uint64_t getPayloadBytes() const;
    static void advanceGeneration(uint32_t& generation);
    Falcor::ref<Falcor::Device> mpDevice;
    Falcor::ref<Falcor::Scene> mpScene;
    Settings mSettings;
    FrameInputs mInputs;
    FrameToken mFrame;
    uint32_t mFrameSerial = 0;
    uint32_t mSceneGeneration = 1;
    uint32_t mProposalGeneration = 1;
    Resources mResources;
    std::map<std::string, Falcor::ref<Falcor::ComputePass>> mPasses;
    std::shared_ptr<DebugState> mpDebug;
    Falcor::ref<Falcor::SampleGenerator> mpSampleGenerator;
    Falcor::uint2 mBaseTileDim = Falcor::uint2(1);
    Falcor::uint2 mFeedbackDim = Falcor::uint2(1);
    uint32_t mTileNodeCount = 1;
    uint32_t mFeedbackStride = 4;
    uint32_t mFeedbackCount = 1;
    bool mResourcesFull = false;
    bool mHistoryValid = false;
    bool mFrameModelValid = false;
    bool mResetHistory = true;
    bool mResetGrid = true;
    uint32_t mGridGeneration = 1;
    uint32_t mGridResetCount = 0;
    uint64_t mResourceKey = 0;
    bool mBudgetFallback = false;
    Falcor::uint2 mDebugFrameDim = Falcor::uint2(0);
    Falcor::uint3 mFullDim = Falcor::uint3(1);
    Falcor::float3 mFullOrigin = Falcor::float3(0), mFullCellExtent = Falcor::float3(1);
    uint32_t mFullEmissiveCapacity = 0, mFullAnalyticCapacity = 0, mFullCells = 1;
    bool mFullBudgetReduced = false;
    Falcor::float4x4 mPreviousViewProjNoJitter = Falcor::float4x4::identity();
};
} // namespace RTPTLocalLights
