#pragma once
#include "Falcor.h"
#include "Utils/Properties.h"
#include "Utils/Sampling/SampleGenerator.h"
#include <array>

namespace RTPTVXPG
{
enum class GuidingMode : uint32_t { BSDF, VXPG };

struct Settings
{
    bool enabled = false;
    bool useGuiding = true;
    bool freezeUpdates = false;
    bool pgUseCache = false;
    bool visibilityEnabled = true;
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

/** Owns VXPG data independently of legacy PG and SHaRC. No CPU tree publication. */
class Manager
{
public:
    explicit Manager(Falcor::ref<Falcor::Device> device) : mpDevice(device) {}
    static void validate(const Settings& settings);
    void configure(const Settings& settings, Falcor::uint2 frameDim, uint32_t sharedStride, uint32_t sharedBounces);
    void invalidate();
    void invalidateDistribution(const std::string& reason = "View-dependent proposal needs rebuilding");
    void cameraChanged();
    void invalidateLighting();
    void resetLightingHistory();
    std::array<uint32_t, 8> readHistoryCounters() const;
    std::array<uint32_t, 8> readQueryCounters() const;
    std::array<uint32_t, 16> readTreeCounters() const;
    std::array<uint32_t, 16> readGridCounters() const;
    void setScene(const Falcor::ref<Falcor::Scene>& scene);
    void buildGeometry(Falcor::RenderContext* context);
    // Prepare/clear observation buffers before sparse SHaRC/VXPG training.
    void prepareLighting(Falcor::RenderContext* context);
    bool canInjectShared() const { return mLightingPrepared; }
    uint32_t getLightingFrameIndex() const { return mLightingFrameIndex; }
    uint64_t getDiscoveryRecordCount() const;
    std::array<uint32_t,32> readSharedObservationCounts() const;
    void barrierInjection(Falcor::RenderContext* context) const;
    void updateLighting(Falcor::RenderContext* context, uint32_t seed, uint32_t sampleOffset, bool useNRD);
    // Must be called even when guiding/model updates are disabled or frozen.
    void beginFrame() { mLightingPrepared = false; }
    void bind(const Falcor::ShaderVar& root, uint32_t frameIndex, bool active) const;
    std::array<uint32_t, 32> readCounters() const;
    std::array<uint32_t, 128> readLodCounts(uint32_t geometryCount, uint32_t activeCount) const;
    void appendObservationStatistics(Falcor::Properties& props, uint32_t geometryCount, uint32_t activeCount) const;
    std::array<uint32_t, 8> readClusterCounters() const;
    // Explicit, gated readback for same-model structural diagnostics/replay.
    // Never called from the render loop or ordinary statistics collection.
    Falcor::Properties readTreeSnapshot(const Settings& requested) const;
    void invalidateDiagnosticSnapshot() { mModelDiagnosticsAvailable = false; }
    bool hasModelDiagnostics() const { return mSettings.detailedDiagnostics && mModelDiagnosticsAvailable; }
    uint32_t getModelDiagnosticsFrameIndex() const { return mModelDiagnosticsFrameIndex; }
    void renderDebug(Falcor::RenderContext* context, const Falcor::ref<Falcor::Texture>& output);
    uint32_t getGeneration() const { return mGeneration; }
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
    bool isReady() const { return mReady; }

private:
    void advanceGeneration(uint32_t& generation);
    uint64_t estimateModelBytes() const;
    uint64_t primaryDiscoveryCount() const;
    uint64_t discoveryRequestCount() const { return primaryDiscoveryCount() + getDiscoveryRecordCount(); }
    void resetClusterPasses();
    void releaseModelResources();
    void updateVisibility(Falcor::RenderContext* context);
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
    uint64_t mScreenAllocationBytes = 0;
    bool mLightingPrepared = false;
    bool mResetHistory = true;
    bool mReady = false;
    bool mGeometryValid = false;
    bool mDistributionValid = false;
    bool mModelDiagnosticsAvailable = false;
    uint32_t mModelDiagnosticsFrameIndex = 0;
    Falcor::ref<Falcor::Scene> mpScene;
    Falcor::ref<Falcor::Buffer> mpBoundMin, mpBoundMax, mpState, mpInverse;
    Falcor::ref<Falcor::Buffer> mpHash, mpCellKeys;
    Falcor::ref<Falcor::Buffer> mpWorkArgs, mpWorkDispatch;
    Falcor::ref<Falcor::ComputePass> mpGeometryWork, mpActiveWork, mpForestWork;
    Falcor::ref<Falcor::ComputePass> mpDebug;
    Falcor::ref<Falcor::ComputePass> mpClearFrame, mpPrimary, mpGlobalLeaves, mpGlobalLevel, mpPublish;
    Falcor::ref<Falcor::ComputePass> mpClearDiagnostics;
    Falcor::ref<Falcor::SampleGenerator> mpSampleGenerator;
    Falcor::ref<Falcor::Buffer> mpFlux, mpCount, mpCompactIndices, mpMass, mpGlobalTree, mpRepresentativePosition, mpRepresentativeNormal;
    Falcor::ref<Falcor::Buffer> mpHistory, mpHistoryStats, mpHistoryPrevious, mpNormalPrevious;
    Falcor::ref<Falcor::Buffer> mpQueryStats;
    Falcor::float3 mPreviousLodCamera = Falcor::float3(0.f);
    Falcor::ref<Falcor::Buffer> mpCellMass, mpTreeState, mpDirtyLeaves, mpDirtyNodes, mpLocalArgs, mpLocalDispatch;
    Falcor::ref<Falcor::ComputePass> mpBeginLocal, mpResolveLocal, mpSelectLocal, mpCompactLocal, mpLocalWork, mpLocalLeaves, mpLocalLevel;
    Falcor::ref<Falcor::Buffer> mpGridState, mpCellLifetime, mpFreeCells, mpRetiredCells, mpDiscovery, mpPendingHash, mpPendingSlots;
    Falcor::ref<Falcor::ComputePass> mpGridClear, mpGridBegin, mpGridEvict, mpGridDiscover, mpGridInsert, mpGridReplay, mpGridRetire;
    Falcor::ref<Falcor::Texture> mpPrimaryPosition, mpPrimaryNormal, mpPrimaryHit;
    Falcor::ref<Falcor::Buffer> mpRowPosition, mpRowNormal, mpVisibility, mpSeeds, mpCluster, mpClusterInfo;
    Falcor::ref<Falcor::Buffer> mpForest, mpCompactToLeaf, mpSuperpixelPosition, mpSuperpixelNormal, mpTopTree, mpClusterState, mpClusterArgs;
    Falcor::ref<Falcor::Texture> mpFuzzyIds, mpFuzzyWeights;
    Falcor::ref<Falcor::Buffer> mpSortA, mpSortB, mpHistogram, mpBinOffsets;
    Falcor::ref<Falcor::Buffer> mpSuperpixelCount, mpSuperpixelRange, mpSuperpixelBlocks, mpSuperpixelPoints;
    Falcor::ref<Falcor::ComputePass> mpPrepareClusters, mpRows, mpRowVisibility, mpSeedsPass, mpAssignClusters;
    Falcor::ref<Falcor::ComputePass> mpCenters, mpAssociate, mpTopLeaves, mpTopParents, mpDistributionDebug;
    Falcor::ref<Falcor::ComputePass> mpSuperpixelPrefix, mpSuperpixelBlockPrefix, mpSuperpixelRanges, mpSuperpixelScatter;
    Falcor::ref<Falcor::ComputePass> mpEncode, mpHistogramPass, mpPrefixPass, mpScatter, mpAllocateForest, mpInitializeForest;
    Falcor::ref<Falcor::ComputePass> mpForestLeaves, mpForestLevel, mpPublishClusters;
    uint32_t mAllocatedSuperpixelSize = 0;
    uint32_t mLeafCapacity = 0;
    uint32_t mAllocatedCapacity = 0;
    uint32_t mLightingFrameIndex = 0;
    Falcor::uint2 mAllocatedFrameDim = Falcor::uint2(0);
    Falcor::float3 mGridMin = Falcor::float3(0.f);
    float mCellSize = 1.f;
    std::string mFallbackReason = "Voxel proposal has not been built";
};
}
