#pragma once
#include "Falcor.h"
#include "RTPTVXPGLayout.slangh"
#include "Utils/Properties.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "../PrimarySurface/RTPTPrimarySurface.h"
#include <array>

namespace RTPTVXPG
{
namespace Diagnostics
{
struct Metadata;
struct ObservationStatistics;
struct StatisticsSnapshot;
struct TreeSnapshot;
enum class StatisticsRequest;
} // namespace Diagnostics

enum class GuidingMode : uint32_t
{
    BSDF,
    VXPG
};

struct Settings
{
    bool enabled = false;
    bool useGuiding = true;
    bool freezeUpdates = false;
    bool debugEnabled = false;
    bool detailedDiagnostics = false;
    uint32_t historyFrames = 32;
    uint32_t historyStaleFrames = 128;
    uint32_t discoveryStride = 5;
    uint32_t spatialStaleFrames = 512;
    uint32_t treeRefreshFrames = 16;
    float lodSceneScale = 64.f;
    uint32_t lodHashCapacity = 524288;
    uint32_t lodGeometryCapacity = 262144;
    uint32_t lodBudgetMiB = 384;
    uint32_t debugMode = 0;
    uint32_t maxVoxels = 65536;
    uint32_t clusterCount = 32;
    uint32_t superpixelSize = 32;
};

/** Effects of a settings change, shared by the RTPT adapter and model configuration.
    Frame size and shared-training changes are supplied separately by their owners. */
struct SettingsChanges
{
    bool layout = false;
    bool topology = false;
    bool history = false;
    bool spatialLifetime = false;
    bool topologyInterval = false;
    bool diagnostics = false;
    bool signal = false;
    bool resources() const { return layout || topology; }
};

SettingsChanges compareSettings(const Settings& previous, const Settings& next);
bool parseSetting(const std::string& key, const Falcor::Properties::ConstValue& value, Settings& settings);
void writeSettings(Falcor::Properties& properties, const Settings& settings);

/** Increasing scopes: proposal, lighting history, spatial grid, then allocations.
    Diagnostics are independent and never invalidate a published model. */
enum class Invalidation
{
    Proposal,
    LightingHistory,
    Grid,
    Resources
};

/** Read-only integration state. Diagnostics/UI never depend on the RTPT pass itself. */
struct RuntimeContext
{
    bool enabled = false;
    GuidingMode guidingMode = GuidingMode::BSDF;
    bool sharcQueries = false;
    bool sharedTraining = false;
    bool sharedWithSHARC = false;
    uint32_t trainingStride = 5;
    uint32_t trainingBounces = 8;
    uint64_t pairedCacheBytes = 0;
    uint32_t sharcFrameIndex = 0;
    bool diagnosticFrameAvailable = false;
    uint32_t diagnosticSampleOffset = 0;
    uint32_t diagnosticSamplesPerPixel = 0;
    uint32_t diagnosticGeneration = 0;
};

struct UIState
{
    std::string statisticsText;
    std::string treeText;
};

/** Per-frame sparse-training inputs, valid only between prepare() and finish().
    These describe CPU preparation, not GPU proposal validity. */
struct TrainingInputs
{
    bool writeObservations = false;
    uint32_t frameIndex = 0;
};

/** Owns the sparse grid, importance history and GPU-published proposal.
    RTPT schedules shared training between FrameUpdate::prepare() and finish(). */
class Manager
{
public:
    /** One frame's update scope. Construct before early returns; prepare only
        when VXPG graph resources are available. No GPU work runs on destruction. */
    class FrameUpdate
    {
    public:
        FrameUpdate(const FrameUpdate&) = delete;
        FrameUpdate& operator=(const FrameUpdate&) = delete;
        ~FrameUpdate();
        TrainingInputs prepare(
            Falcor::RenderContext* context,
            const Settings& settings,
            Falcor::uint2 frameDim,
            uint32_t sharedStride,
            uint32_t sharedBounces,
            GuidingMode mode,
            const Falcor::ref<Falcor::Texture>& debugOutput
        );
        void finish(Falcor::RenderContext* context, const RTPTPrimarySurface::View& primary);

    private:
        friend class Manager;
        explicit FrameUpdate(Manager& manager);
        Manager& mManager;
        bool mSelected = false;
        Falcor::ref<Falcor::Texture> mpDebugOutput;
    };

    explicit Manager(Falcor::ref<Falcor::Device> device) : mpDevice(device) {}
    FrameUpdate beginUpdate() { return FrameUpdate(*this); }
    static void validate(const Settings& settings);
    Falcor::Properties renderSettingsUI(Falcor::Gui::Widgets& widget, const Settings& settings, const RuntimeContext& runtime, UIState& ui)
        const;
    void renderDiagnosticsUI(Falcor::Gui::Widgets& widget, const Settings& settings, const RuntimeContext& runtime, UIState& ui) const;
    Falcor::Properties getStatistics(const Settings& settings, const RuntimeContext& runtime) const;
    Falcor::Properties getTreeSnapshot(const Settings& settings, const RuntimeContext& runtime) const;
    void invalidate(Invalidation scope = Invalidation::Grid, const std::string& reason = {});
    void cameraChanged(bool projectionChanged, bool freezeUpdates);
    void lightingChanged();
    void setScene(const Falcor::ref<Falcor::Scene>& scene);
    void barrierInjection(Falcor::RenderContext* context) const;
    // Sparse shared paths write observations using the model's training frame index.
    void bindTraining(const Falcor::ShaderVar& root, bool writeObservations) const;
    // Bind the submitted proposal; Shader consumers validate GPU READY/generation.
    void bindRendering(const Falcor::ShaderVar& root, uint32_t sampleOffset, bool useSubmittedModel) const;
    void invalidateDiagnosticSnapshot() { mModelDiagnosticsAvailable = false; }
    uint32_t getGeneration() const { return mGeneration; }
    // CPU publication commands were submitted; this does not confirm GPU completion
    // or validity. Shader consumers still check GPU READY against the generation.
    bool hasSubmittedModel() const { return mModelSubmitted; }

private:
    void clearTrainingPreparation() { mLightingPrepared = false; }
    void configure(const Settings& settings, Falcor::uint2 frameDim, uint32_t sharedStride, uint32_t sharedBounces);
    void buildGeometry(Falcor::RenderContext* context);
    void prepareLighting(Falcor::RenderContext* context);
    void updateLighting(Falcor::RenderContext* context, const RTPTPrimarySurface::View& primary);
    void renderDebug(Falcor::RenderContext* context, const Falcor::ref<Falcor::Texture>& output);
    // Internal diagnostics and resource metadata; all readbacks remain explicit.
    std::array<uint32_t, RTPT_VXPG_HISTORY_WORDS> readHistoryCounters() const;
    std::array<uint32_t, RTPT_VXPG_QUERY_WORDS> readQueryCounters() const;
    std::array<uint32_t, RTPT_VXPG_TREE_WORDS> readTreeCounters() const;
    std::array<uint32_t, RTPT_VXPG_GRID_WORDS> readGridCounters() const;
    uint64_t getDiscoveryRecordCount() const;
    std::array<uint32_t, 32> readSharedObservationCounts() const;
    std::array<uint32_t, RTPT_VXPG_STATE_WORDS> readCounters() const;
    std::array<uint32_t, 128> readLodCounts(uint32_t geometryCount, uint32_t activeCount) const;
    std::array<Diagnostics::ObservationStatistics, 64> readObservationStatistics(uint32_t geometryCount, uint32_t activeCount) const;
    std::array<uint32_t, RTPT_VXPG_CLUSTER_WORDS> readClusterCounters() const;
    Diagnostics::Metadata captureDiagnosticMetadata(const Settings& requested, const RuntimeContext& runtime) const;
    Diagnostics::StatisticsSnapshot readStatisticsSnapshot(
        const Settings& requested,
        const RuntimeContext& runtime,
        Diagnostics::StatisticsRequest request
    ) const;
    Diagnostics::TreeSnapshot readTreeSnapshot(const Settings& requested, const RuntimeContext& runtime) const;
    std::string getTreeSnapshotText(const Settings& settings, const RuntimeContext& runtime) const;
    bool hasModelDiagnostics() const { return mSettings.detailedDiagnostics && mModelDiagnosticsAvailable; }
    uint32_t getModelDiagnosticsFrameIndex() const { return mModelDiagnosticsFrameIndex; }
    uint64_t getEstimatedBytes() const { return mEstimatedBytes; }
    uint64_t getPayloadBytes() const;
    Falcor::float3 getGridOrigin() const { return mGridMin; }
    float getCellSize() const { return mCellSize; }
    uint32_t getHashCapacity() const { return mSettings.lodHashCapacity; }
    uint32_t getGeometryCapacity() const { return cellCapacity(); }
    uint32_t getBudgetMiB() const { return mSettings.lodBudgetMiB; }
    uint32_t getGeometryGeneration() const { return mGeometryGeneration; }
    uint32_t getGeometryRebuilds() const { return mGeometryRebuilds; }
    uint32_t getLodLevels() const { return mLodLevels; }
    const std::string& getFallbackReason() const { return mFallbackReason; }

    void updateScreenAllocation(Falcor::uint2 frameDim);
    // Requested dimensions, derived without allocating or changing model validity.
    struct ResourceDimensions
    {
        uint32_t cells;
        uint32_t hashSlots;
        uint32_t activeVoxels;
        uint32_t leafCapacity;
        uint32_t forestNodes;
        uint32_t dirtyNodes;
        Falcor::uint2 frameDim;
        Falcor::uint2 superpixelDim;
        uint64_t pixels;
        uint64_t superpixelRows;
        uint64_t discoveryRecords;
        uint64_t pendingSlots;
    };
    ResourceDimensions getResourceDimensions() const;
    Falcor::uint2 superpixelDimensions() const;
    void ensureGridResources();
    void ensureObservationResources();
    void ensureTrainingResources(Falcor::RenderContext* context);
    void ensureVisibilityResources(const ResourceDimensions& dimensions);
    void createGridBuffers(const ResourceDimensions& dimensions);
    void createProposalGridBuffers(const ResourceDimensions& dimensions);
    void createGridPasses();
    void createLightingBuffers(Falcor::RenderContext* context, const ResourceDimensions& dimensions);
    void createProposalBuffers(const ResourceDimensions& dimensions);
    void createPrimaryTextures(const ResourceDimensions& dimensions);
    void ensureLightingHistory(Falcor::RenderContext* context, const ResourceDimensions& dimensions);
    void ensureLocalTreeResources(Falcor::RenderContext* context, const ResourceDimensions& dimensions);
    void ensureTrainingPasses();
    void createClusterBuffers(const ResourceDimensions& dimensions);
    void createScreenBuffers(const ResourceDimensions& dimensions);
    void createClusterPasses();
    void createScreenPasses();
    enum class PassScene
    {
        None,
        SceneOnly,
        SceneAndSampler
    };
    enum class PassCounters
    {
        None,
        Configured
    };
    Falcor::ref<Falcor::ComputePass> createPass(
        const char* library,
        const char* entry,
        PassScene scene = PassScene::None,
        PassCounters counters = PassCounters::None,
        const Falcor::DefineList& extraDefines = {}
    ) const;
    void bindParameters(const Falcor::ShaderVar& root, uint32_t frameIndex, bool active) const;
    void bindResources(const Falcor::ShaderVar& root) const;
    void bindBuildPass(Falcor::RenderContext* context, const Falcor::ref<Falcor::ComputePass>& pass) const;
    void dispatchUpdate(Falcor::RenderContext* context, const Falcor::ref<Falcor::ComputePass>& pass, Falcor::uint3 size);
    void dispatchIndirectUpdate(
        Falcor::RenderContext* context,
        const Falcor::ref<Falcor::ComputePass>& pass,
        const Falcor::ref<Falcor::Buffer>& arguments,
        uint64_t byteOffset = 0
    );
    void updatePrimaryData(Falcor::RenderContext* context, const RTPTPrimarySurface::View& primary);
    void resolveHistoryAndBuildGlobalTree(Falcor::RenderContext* context);
    void updateLocalTrees(Falcor::RenderContext* context);
    void publishAndRetire(Falcor::RenderContext* context);
    void advanceGeneration(uint32_t& generation);
    uint64_t estimateModelBytes() const;
    uint64_t primaryDiscoveryCount() const;
    uint64_t discoveryRequestCount() const { return primaryDiscoveryCount() + getDiscoveryRecordCount(); }
    void resetClusterPasses();
    void resetTrainingPasses();
    void resetScenePasses();
    void releaseModelResources();
    void updateVisibility(Falcor::RenderContext* context);
    void updateVisibilityClusters(Falcor::RenderContext* context);
    Falcor::ref<Falcor::Buffer> sortClusterVoxels(Falcor::RenderContext* context);
    void buildClusterForest(Falcor::RenderContext* context, const Falcor::ref<Falcor::Buffer>& sorted);
    void updateScreenDistribution(Falcor::RenderContext* context, uint32_t rows);
    void buildIncrementalGeometry(Falcor::RenderContext* context);
    void prepareIncrementalGrid(Falcor::RenderContext* context);
    void finishIncrementalGrid(Falcor::RenderContext* context);
    uint32_t cellCapacity() const { return mSettings.lodGeometryCapacity; }
    Falcor::ref<Falcor::Device> mpDevice;
    Settings mSettings;
    Falcor::uint2 mFrameDim = Falcor::uint2(0);
    uint32_t mSharedTrainingStride = 5;
    uint32_t mSharedTrainingBounces = 8;
    uint32_t mGeneration = 1;
    uint32_t mGeometryGeneration = 1;
    uint32_t mGeometryRebuilds = 0;
    uint32_t mLodLevels = 1;
    Falcor::float3 mLodCamera = Falcor::float3(0.f);
    uint64_t mEstimatedBytes = 0;
    bool mLightingPrepared = false;
    bool mResetHistory = true;
    bool mModelSubmitted = false;
    bool mGeometryValid = false;
    bool mDistributionValid = false;
    bool mModelDiagnosticsAvailable = false;
    uint32_t mModelDiagnosticsFrameIndex = 0;
    Falcor::ref<Falcor::Scene> mpScene;
    Falcor::ref<Falcor::SampleGenerator> mpSampleGenerator;
    Falcor::float3 mPreviousLodCamera = Falcor::float3(0.f);
    struct GridResources
    {
        void release() { *this = {}; }
        void bind(const Falcor::ShaderVar& root) const;
        uint64_t getPayloadBytes() const;
        template<typename Visitor>
        void forEachResource(Visitor&& visit) const;
        Falcor::ref<Falcor::Buffer> pBoundMin;
        Falcor::ref<Falcor::Buffer> pBoundMax;
        Falcor::ref<Falcor::Buffer> pHash;
        Falcor::ref<Falcor::Buffer> pCellKeys;
        Falcor::ref<Falcor::Buffer> pGridState;
        Falcor::ref<Falcor::Buffer> pCellLifetime;
        Falcor::ref<Falcor::Buffer> pFreeCells;
        Falcor::ref<Falcor::Buffer> pRetiredCells;
        Falcor::ref<Falcor::Buffer> pDiscovery;
        Falcor::ref<Falcor::Buffer> pPendingHash;
        Falcor::ref<Falcor::Buffer> pPendingSlots;
        Falcor::ref<Falcor::ComputePass> pGridClear;
        Falcor::ref<Falcor::ComputePass> pGridBegin;
        Falcor::ref<Falcor::ComputePass> pGridEvict;
        Falcor::ref<Falcor::ComputePass> pGridDiscover;
        Falcor::ref<Falcor::ComputePass> pGridInsert;
        Falcor::ref<Falcor::ComputePass> pGridReplay;
        Falcor::ref<Falcor::ComputePass> pGridRetire;
    } mGrid;
    struct LightingResources
    {
        void release() { *this = {}; }
        void bind(const Falcor::ShaderVar& root) const;
        uint64_t getPayloadBytes() const;
        template<typename Visitor>
        void forEachResource(Visitor&& visit) const;
        Falcor::ref<Falcor::ComputePass> pClearFrame;
        Falcor::ref<Falcor::Buffer> pFlux;
        Falcor::ref<Falcor::Buffer> pCount;
        Falcor::ref<Falcor::Buffer> pRepresentativePosition;
        Falcor::ref<Falcor::Buffer> pRepresentativeNormal;
        Falcor::ref<Falcor::Buffer> pHistory;
        Falcor::ref<Falcor::Buffer> pHistoryStats;
        Falcor::ref<Falcor::Buffer> pHistoryPrevious;
        Falcor::ref<Falcor::Buffer> pNormalPrevious;
    } mLighting;
    struct ProposalResources
    {
        void release() { *this = {}; }
        void bind(const Falcor::ShaderVar& root) const;
        uint64_t getPayloadBytes() const;
        template<typename Visitor>
        void forEachResource(Visitor&& visit) const;
        Falcor::ref<Falcor::Buffer> pState;
        Falcor::ref<Falcor::Buffer> pInverse;
        Falcor::ref<Falcor::Buffer> pWorkArgs;
        Falcor::ref<Falcor::Buffer> pWorkDispatch;
        Falcor::ref<Falcor::ComputePass> pGeometryWork;
        Falcor::ref<Falcor::ComputePass> pActiveWork;
        Falcor::ref<Falcor::ComputePass> pForestWork;
        Falcor::ref<Falcor::ComputePass> pGlobalLeaves;
        Falcor::ref<Falcor::ComputePass> pGlobalLevel;
        Falcor::ref<Falcor::ComputePass> pPublish;
        Falcor::ref<Falcor::ComputePass> pClearDiagnostics;
        Falcor::ref<Falcor::Buffer> pCompactIndices;
        Falcor::ref<Falcor::Buffer> pMass;
        Falcor::ref<Falcor::Buffer> pGlobalTree;
        Falcor::ref<Falcor::Buffer> pQueryStats;
        Falcor::ref<Falcor::Buffer> pCellMass;
        Falcor::ref<Falcor::Buffer> pTreeState;
        Falcor::ref<Falcor::Buffer> pDirtyLeaves;
        Falcor::ref<Falcor::Buffer> pDirtyNodes;
        Falcor::ref<Falcor::Buffer> pLocalArgs;
        Falcor::ref<Falcor::Buffer> pLocalDispatch;
        Falcor::ref<Falcor::ComputePass> pBeginLocal;
        Falcor::ref<Falcor::ComputePass> pResolveLocal;
        Falcor::ref<Falcor::ComputePass> pSelectLocal;
        Falcor::ref<Falcor::ComputePass> pCompactLocal;
        Falcor::ref<Falcor::ComputePass> pLocalWork;
        Falcor::ref<Falcor::ComputePass> pLocalLeaves;
        Falcor::ref<Falcor::ComputePass> pLocalLevel;
        Falcor::ref<Falcor::Buffer> pVisibility;
        Falcor::ref<Falcor::Buffer> pSeeds;
        Falcor::ref<Falcor::Buffer> pCluster;
        Falcor::ref<Falcor::Buffer> pClusterInfo;
        Falcor::ref<Falcor::Buffer> pForest;
        Falcor::ref<Falcor::Buffer> pCompactToLeaf;
        Falcor::ref<Falcor::Buffer> pClusterState;
        Falcor::ref<Falcor::Buffer> pClusterArgs;
        Falcor::ref<Falcor::Buffer> pSortA;
        Falcor::ref<Falcor::Buffer> pSortB;
        Falcor::ref<Falcor::Buffer> pHistogram;
        Falcor::ref<Falcor::Buffer> pBinOffsets;
        Falcor::ref<Falcor::ComputePass> pPrepareClusters;
        Falcor::ref<Falcor::ComputePass> pRows;
        Falcor::ref<Falcor::ComputePass> pRowVisibility;
        Falcor::ref<Falcor::ComputePass> pSeedsPass;
        Falcor::ref<Falcor::ComputePass> pAssignClusters;
        Falcor::ref<Falcor::ComputePass> pEncode;
        Falcor::ref<Falcor::ComputePass> pHistogramPass;
        Falcor::ref<Falcor::ComputePass> pPrefixPass;
        Falcor::ref<Falcor::ComputePass> pScatter;
        Falcor::ref<Falcor::ComputePass> pAllocateForest;
        Falcor::ref<Falcor::ComputePass> pInitializeForest;
        Falcor::ref<Falcor::ComputePass> pForestLeaves;
        Falcor::ref<Falcor::ComputePass> pForestLevel;
        Falcor::ref<Falcor::ComputePass> pPublishClusters;
        uint32_t leafCapacity = 0;
        uint32_t allocatedCapacity = 0;
    } mProposal;
    struct ViewResources
    {
        void release(); // Retains the driver allocation estimate for the current frame size.
        void bind(const Falcor::ShaderVar& root) const;
        uint64_t getPayloadBytes() const;
        template<typename Visitor>
        void forEachResource(Visitor&& visit) const;
        Falcor::ref<Falcor::ComputePass> pDebug;
        Falcor::ref<Falcor::ComputePass> pPrimary;
        Falcor::ref<Falcor::Texture> pPrimaryPosition;
        Falcor::ref<Falcor::Texture> pPrimaryNormal;
        Falcor::ref<Falcor::Texture> pPrimaryHit;
        Falcor::ref<Falcor::Buffer> pRowPosition;
        Falcor::ref<Falcor::Buffer> pRowNormal;
        Falcor::ref<Falcor::Buffer> pSuperpixelPosition;
        Falcor::ref<Falcor::Buffer> pSuperpixelNormal;
        Falcor::ref<Falcor::Buffer> pTopTree;
        Falcor::ref<Falcor::Texture> pFuzzyIds;
        Falcor::ref<Falcor::Texture> pFuzzyWeights;
        Falcor::ref<Falcor::Buffer> pSuperpixelCount;
        Falcor::ref<Falcor::Buffer> pSuperpixelRange;
        Falcor::ref<Falcor::Buffer> pSuperpixelBlocks;
        Falcor::ref<Falcor::Buffer> pSuperpixelPoints;
        Falcor::ref<Falcor::ComputePass> pCenters;
        Falcor::ref<Falcor::ComputePass> pAssociate;
        Falcor::ref<Falcor::ComputePass> pTopLeaves;
        Falcor::ref<Falcor::ComputePass> pTopParents;
        Falcor::ref<Falcor::ComputePass> pDistributionDebug;
        Falcor::ref<Falcor::ComputePass> pSuperpixelPrefix;
        Falcor::ref<Falcor::ComputePass> pSuperpixelBlockPrefix;
        Falcor::ref<Falcor::ComputePass> pSuperpixelRanges;
        Falcor::ref<Falcor::ComputePass> pSuperpixelScatter;
        uint32_t allocatedSuperpixelSize = 0;
        Falcor::uint2 allocatedFrameDim = Falcor::uint2(0);
        uint64_t allocationBytes = 0;
    } mView;
    uint32_t mLightingFrameIndex = 0;
    Falcor::float3 mGridMin = Falcor::float3(0.f);
    float mCellSize = 1.f;
    std::string mFallbackReason = "Voxel proposal has not been built";
};
} // namespace RTPTVXPG
