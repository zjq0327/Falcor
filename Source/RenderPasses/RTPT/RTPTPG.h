#pragma once
#include "Falcor.h"
#include <array>
#include <initializer_list>
#include <unordered_set>
#include <vector>

namespace RTPTPG
{
using namespace Falcor;

struct Settings
{
    bool enabled = true;
    bool useGuiding = true;
    bool trainingEnabled = true;
    bool detailedDiagnostics = false;
    uint32_t treeBudgetMiB = 64;
    uint32_t recordBudgetMiB = 128;
    uint32_t coarseLevels = 2;
    uint32_t pollFrames = 16;
    uint32_t maxRegions = 16384;
    uint32_t initialNodes = 1;
    uint32_t maxNodesPerRegion = 85;
    uint32_t maxDirectionalDepth = 8;
    float guideFraction = 0.5f;
    float directionalThreshold = 0.01f;
    float weightScale = 1e-4f;
};

struct Statistics
{
    uint32_t regions = 0;
    uint32_t readyRegions = 0;
    uint32_t observedZeroRegions = 0;
    uint32_t readNodes = 0;
    uint32_t buildNodes = 0;
    uint32_t nodeCapacity = 0;
    uint32_t regionCapacity = 0;
    uint32_t trainingFrames = 0;
    uint32_t publications = 0;
    uint32_t requestOverflow = 0;
    uint32_t invalidSamples = 0;
    uint32_t recordOverflow = 0;
    uint32_t accumulationOverflow = 0;
    uint32_t rejectedTrainingWindows = 0;
    uint32_t admissionRejected = 0;
    uint64_t modelBytes = 0;
    uint64_t modelReservedBytes = 0;
    uint64_t recordBytes = 0;
    uint64_t recordReservedBytes = 0;
    // Wall-clock CPU phase timings. Drain/readback/upload include their existing
    // GPU waits; these counters never introduce additional synchronization.
    uint64_t publishCalls = 0;
    double lastPublishMs = 0.;
    double totalPublishMs = 0.;
    double maxPublishMs = 0.;
    double lastDrainMs = 0.;
    double totalDrainMs = 0.;
    double lastReadbackMs = 0.;
    double totalReadbackMs = 0.;
    double lastCpuRebuildMs = 0.;
    double totalCpuRebuildMs = 0.;
    double lastUploadMs = 0.;
    double totalUploadMs = 0.;
    uint64_t lastReadbackBytes = 0;
    uint64_t totalReadbackBytes = 0;
    uint64_t lastUploadBytes = 0;
    uint64_t totalUploadBytes = 0;
    uint64_t lastDrainWaits = 0;
    uint64_t totalDrainWaits = 0;
    uint64_t lastReadbackWaits = 0;
    uint64_t totalReadbackWaits = 0;
    uint64_t lastUploadWaits = 0;
    uint64_t totalUploadWaits = 0;
    uint64_t lastZeroFastPathRegions = 0;
    uint64_t totalZeroFastPathRegions = 0;
    std::array<uint32_t, 16> diagnostics = {};
};

/** CPU-owned topology and bounded GPU resources for the RayQuery PG implementation.
    Publishing is deliberately synchronous. It never changes render/NRD history.
*/
class Manager
{
public:
    explicit Manager(ref<Device> pDevice);
    bool prepare(RenderContext* pContext, const Settings& settings, uint2 frameDim, uint32_t updateBounces, uint32_t preferredStride);
    void reset(RenderContext* pContext);
    void beginFrame(RenderContext* pContext);
    void barrierTraining(RenderContext* pContext) const;
    void bind(const ShaderVar& rootVar, float3 cameraPosition, float sceneScale, uint32_t frameIndex, bool trainingActive) const;
    bool finishTrainingFrame(RenderContext* pContext);
    const Statistics& getStatistics() const { return mStatistics; }
    uint32_t getRecordStride() const { return mRecordStride; }
    uint32_t getPathCapacity() const { return mPathCapacity; }
    uint32_t getGeneration() const { return mSceneGeneration; }

private:
    struct Node
    {
        uint32_t topology = 0;
        std::array<float, 4> mass = {};
    };
    struct NodeStats
    {
        std::array<uint32_t, 4> weightBits = {};
        std::array<uint32_t, 4> squareBits = {};
        std::array<uint32_t, 4> count = {};
    };
    struct MapEntry
    {
        uint32_t keyLo = 0, keyHi = 0, regionId = 0, generation = 0;
    };
    struct RegionDesc
    {
        uint32_t keyLo = 0, keyHi = 0, root = 0, nodeCount = 0;
        uint32_t generation = 0, flags = 0, observationCount = 0;
        float reserved = 0.f;
    };
    struct Region
    {
        uint64_t key = 0;
        uint32_t generation = 1;
        uint32_t flags = 0;
        uint32_t observationCount = 0;
        bool readMapped = false;
        bool buildMapped = false;
        std::vector<Node> read;
        std::vector<Node> build;
        std::vector<NodeStats> statistics;
    };

    void allocateModel(RenderContext* pContext);
    void uploadModel(RenderContext* pContext);
    bool publish(RenderContext* pContext);
    std::vector<Node> makeInitialTree() const;
    std::vector<Node> refine(const std::vector<Node>& nodes, const std::vector<NodeStats>& statistics) const;
    static uint32_t hashKey(uint64_t key);
    static uint32_t childIndex(const Node& node, uint32_t quadrant);
    static float asFloat(uint32_t bits);
    struct ReadTransfer { ref<Buffer> buffer; void* destination; size_t bytes; };
    struct UploadTransfer { ref<Buffer> buffer; const void* source; size_t bytes; };
    struct ReadbackPiece { uint8_t* destination; size_t stageOffset; size_t bytes; };
    void readBatch(RenderContext* pContext, std::initializer_list<ReadTransfer> transfers);
    void uploadBatch(RenderContext* pContext, std::initializer_list<UploadTransfer> transfers);

    ref<Device> mpDevice;
    ref<Buffer> mpReadMap, mpReadRegions, mpReadNodes;
    ref<Buffer> mpBuildMap, mpBuildRegions, mpBuildNodes, mpBuildStats;
    ref<Buffer> mpRequests, mpDiagnostics, mpPathHeaders, mpVertices;
    ref<Buffer> mpUploadStage, mpReadbackStage;
    Settings mSettings;
    Statistics mStatistics;
    std::vector<Region> mRegions;
    std::unordered_set<uint64_t> mKnownKeys;
    std::vector<MapEntry> mReadMapCPU, mBuildMapCPU, mRequestsCPU;
    std::vector<RegionDesc> mReadRegionsCPU, mBuildRegionsCPU;
    std::vector<Node> mReadNodesCPU, mBuildNodesCPU, mNormalizedCPU;
    std::vector<NodeStats> mReadbackStatsCPU, mUploadStatsCPU;
    std::vector<std::array<double, 4>> mMassCPU;
    std::vector<ReadbackPiece> mReadbackPieces;
    bool mReadMapDirty = false;
    bool mBuildMapDirty = false;
    uint2 mFrameDim = uint2(0);
    uint32_t mNodeCapacity = 0;
    uint32_t mRegionCapacity = 0;
    uint32_t mMapCapacity = 0;
    uint32_t mRequestCapacity = 0;
    uint32_t mPathCapacity = 0;
    uint32_t mVerticesPerPath = 0;
    uint32_t mRecordStride = 1;
    uint32_t mSceneGeneration = 1;
    uint32_t mRecordGeneration = 1;
    uint32_t mFramesSincePoll = 0;
};
}
