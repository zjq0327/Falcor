#pragma once
#include "Falcor.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Rendering/Lights/EnvMapSampler.h"
#include <array>

namespace RTPTVXPG
{
enum class GuidingMode : uint32_t { BSDF, PG, VXPG };
enum class Estimator : uint32_t { ShortBranch, MixturePath };

struct Settings
{
    bool enabled = false;
    bool useGuiding = true;
    bool freezeUpdates = false;
    bool pgUseCache = false;
    bool visibilityEnabled = true;
    bool debugEnabled = false;
    uint32_t debugMode = 0;
    Estimator estimator = Estimator::ShortBranch;
    float guideFraction = 0.5f;
    uint32_t gridResolution = 64;
    uint32_t maxVoxels = 65536;
    uint32_t clusterCount = 32;
    uint32_t superpixelSize = 32;
    uint32_t budgetMiB = 256;
};

/** Owns VXPG data independently of legacy PG and SHaRC. No CPU tree publication. */
class Manager
{
public:
    explicit Manager(Falcor::ref<Falcor::Device> device) : mpDevice(device) {}
    static void validate(const Settings& settings);
    void configure(const Settings& settings, Falcor::uint2 frameDim);
    void invalidate();
    void invalidateDistribution(const std::string& reason = "View-dependent proposal needs rebuilding");
    void invalidateLighting();
    void setScene(const Falcor::ref<Falcor::Scene>& scene);
    void buildGeometry(Falcor::RenderContext* context, const Falcor::ref<Falcor::Texture>& debugOutput);
    void updateLighting(Falcor::RenderContext* context, Falcor::EnvMapSampler* envSampler, uint32_t seed, bool useNEE,
        uint32_t sampleOffset, bool useNRD);
    void bind(const Falcor::ShaderVar& root, uint32_t frameIndex, bool active) const;
    std::array<uint32_t, 32> readCounters() const;
    std::array<uint32_t, 8> readClusterCounters() const;
    void renderDebug(Falcor::RenderContext* context, const Falcor::ref<Falcor::Texture>& output);
    uint32_t getGeneration() const { return mGeneration; }
    uint64_t getEstimatedBytes() const { return mEstimatedBytes; }
    uint64_t getPayloadBytes() const;
    const std::string& getFallbackReason() const { return mFallbackReason; }
    bool isReady() const { return mReady; }

private:
    uint64_t estimateModelBytes() const;
    void resetClusterPasses();
    void releaseModelResources();
    void updateVisibility(Falcor::RenderContext* context);
    Falcor::ref<Falcor::Device> mpDevice;
    Settings mSettings;
    Falcor::uint2 mFrameDim = Falcor::uint2(0);
    uint32_t mGeneration = 1;
    uint64_t mEstimatedBytes = 0;
    uint64_t mScreenAllocationBytes = 0;
    bool mReady = false;
    bool mGeometryValid = false;
    bool mDistributionValid = false;
    Falcor::ref<Falcor::Scene> mpScene;
    Falcor::ref<Falcor::Buffer> mpBoundMin, mpBoundMax, mpState, mpInverse;
    Falcor::ref<Falcor::Buffer> mpTriangles, mpTriangleRanges, mpJobs, mpDispatchArgs;
    Falcor::ref<Falcor::ComputePass> mpClearGeometry, mpMakeJobs, mpFinalizeJobs, mpVoxelize, mpDebug;
    Falcor::ref<Falcor::ComputePass> mpClearFrame, mpInject, mpCompact, mpGlobalLeaves, mpGlobalLevel, mpPublish;
    Falcor::ref<Falcor::ComputePass> mpClearDiagnostics;
    Falcor::ref<Falcor::SampleGenerator> mpSampleGenerator;
    Falcor::ref<Falcor::Buffer> mpFlux, mpCount, mpCompactIndices, mpMass, mpGlobalTree, mpRepresentativePosition, mpRepresentativeNormal;
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
    uint32_t mTriangleCount = 0;
    uint32_t mJobCapacity = 1u << 20;
    uint32_t mAllocatedResolution = 0;
    Falcor::float3 mGridMin = Falcor::float3(0.f);
    float mCellSize = 1.f;
    std::string mFallbackReason = "Voxel proposal has not been built";
};
}
