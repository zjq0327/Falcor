#include "RTPTPG.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <unordered_set>

namespace RTPTPG
{
namespace
{
constexpr uint64_t kMiB = 1024ull * 1024ull;
// Dedicated upload/readback buffers avoid Falcor's growing transient heaps.
// Reserve their sizes plus room for resource allocation alignment in the cap.
constexpr uint64_t kTransferReserve = 8ull * kMiB;
constexpr uint64_t kRecordAlignmentReserve = 128ull * 1024ull;
constexpr size_t kReadbackStageBytes = 2u * 1024u * 1024u;
constexpr size_t kUploadStageBytes = 4u * 1024u * 1024u;
constexpr uint32_t kReady = 1u;
constexpr uint32_t kObservedZero = 2u;

uint32_t nextPowerOfTwo(uint32_t x)
{
    uint32_t result = 1;
    while (result < x) result <<= 1;
    return result;
}

uint32_t popcount4(uint32_t x)
{
    x &= 15u;
    return (x & 1u) + ((x >> 1) & 1u) + ((x >> 2) & 1u) + ((x >> 3) & 1u);
}

double elapsedMs(std::chrono::steady_clock::time_point start)
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

struct PublicationWallTimer
{
    Statistics& statistics;
    std::chrono::steady_clock::time_point start;

    ~PublicationWallTimer()
    {
        // Scope exit includes local scratch destruction. Everything outside
        // the transfer phases is CPU
        // planning, flattening, allocation and cleanup, with no GPU waits.
        auto& s = statistics;
        s.lastPublishMs = elapsedMs(start);
        s.lastCpuRebuildMs = std::max(0., s.lastPublishMs - s.lastDrainMs - s.lastReadbackMs - s.lastUploadMs);
        s.totalPublishMs += s.lastPublishMs;
        s.maxPublishMs = std::max(s.maxPublishMs, s.lastPublishMs);
        s.totalDrainMs += s.lastDrainMs;
        s.totalReadbackMs += s.lastReadbackMs;
        s.totalCpuRebuildMs += s.lastCpuRebuildMs;
        s.totalUploadMs += s.lastUploadMs;
        s.totalReadbackBytes += s.lastReadbackBytes;
        s.totalUploadBytes += s.lastUploadBytes;
        s.totalDrainWaits += s.lastDrainWaits;
        s.totalReadbackWaits += s.lastReadbackWaits;
        s.totalUploadWaits += s.lastUploadWaits;
        s.totalZeroFastPathRegions += s.lastZeroFastPathRegions;
    }
};

template<typename T>
void setIfPresent(const ShaderVar& var, const char* name, const T& value)
{
    auto member = var.findMember(name);
    if (member.isValid()) member = value;
}
}

Manager::Manager(ref<Device> pDevice) : mpDevice(std::move(pDevice))
{
    static_assert(sizeof(Node) == 20);
    static_assert(sizeof(NodeStats) == 48);
    static_assert(sizeof(MapEntry) == 16);
    static_assert(sizeof(RegionDesc) == 32);
}

bool Manager::prepare(RenderContext* pContext, const Settings& settings, uint2 frameDim, uint32_t updateBounces, uint32_t preferredStride)
{
    FALCOR_CHECK(settings.treeBudgetMiB >= 16 && settings.treeBudgetMiB <= 1024, "PG tree budget must be 16..1024 MiB.");
    FALCOR_CHECK(settings.recordBudgetMiB >= 1 && settings.recordBudgetMiB <= 4096, "PG record budget must be 1..4096 MiB.");
    FALCOR_CHECK(settings.guideFraction >= 0.f && settings.guideFraction < 1.f, "PG guide fraction must be in [0,1).");
    FALCOR_CHECK(std::isfinite(settings.weightScale) && settings.weightScale > 0.f, "PG weight scale must be positive and finite.");
    FALCOR_CHECK(settings.maxRegions >= 1 && settings.maxRegions <= 65536, "PG maxRegions must be 1..65536.");
    FALCOR_CHECK(updateBounces <= 64, "PG record depth exceeds the supported 64-bounce bound.");
    const bool structural = !mpReadMap || settings.treeBudgetMiB != mSettings.treeBudgetMiB ||
        settings.maxRegions != mSettings.maxRegions || settings.coarseLevels != mSettings.coarseLevels ||
        settings.weightScale != mSettings.weightScale;
    mSettings = settings;
    if (structural) allocateModel(pContext);

    const uint32_t verticesPerPath = updateBounces + 2;
    const uint64_t bytesPerPath = 32ull + 80ull * verticesPerPath;
    const uint64_t recordBudget = uint64_t(settings.recordBudgetMiB) * kMiB;
    const uint64_t maxPaths = std::max<uint64_t>(1, (recordBudget - kRecordAlignmentReserve) / bytesPerPath);
    uint32_t stride = std::max(1u, preferredStride);
    auto capacityAt = [&](uint32_t s)
    {
        return uint64_t((frameDim.x + s - 1) / s) * ((frameDim.y + s - 1) / s);
    };
    if (capacityAt(stride) > maxPaths)
        stride = std::max(stride, uint32_t(std::ceil(std::sqrt(double(frameDim.x) * frameDim.y / double(maxPaths)))));
    while (capacityAt(stride) > maxPaths) ++stride;
    const uint32_t capacity = uint32_t(std::max<uint64_t>(1, capacityAt(stride)));
    if (!mpPathHeaders || capacity != mPathCapacity || verticesPerPath != mVerticesPerPath)
    {
        pContext->submit(true);
        mpPathHeaders = mpVertices = nullptr;
        mpDevice->wait();
        mpPathHeaders = mpDevice->createStructuredBuffer(32u, capacity);
        mpVertices = mpDevice->createStructuredBuffer(80u, capacity * verticesPerPath);
        mpPathHeaders->setName("RTPT PG complete path headers");
        mpVertices->setName("RTPT PG complete path vertices");
    }
    mFrameDim = frameDim;
    mVerticesPerPath = verticesPerPath;
    mPathCapacity = capacity;
    mRecordStride = stride;
    mStatistics.recordBytes = uint64_t(capacity) * bytesPerPath;
    mStatistics.recordReservedBytes = mStatistics.recordBytes + kRecordAlignmentReserve;
    FALCOR_CHECK(mStatistics.recordReservedBytes <= recordBudget, "PG record allocation exceeds its budget.");
    return structural;
}

void Manager::allocateModel(RenderContext* pContext)
{
    pContext->submit(true);
    mpReadMap = mpReadRegions = mpReadNodes = nullptr;
    mpBuildMap = mpBuildRegions = mpBuildNodes = mpBuildStats = nullptr;
    mpRequests = mpDiagnostics = mpTrainingDiagnostics = nullptr;
    mpUploadStage = mpReadbackStage = nullptr;
    mpDevice->wait();
    mRegionCapacity = mSettings.maxRegions;
    mMapCapacity = nextPowerOfTwo(std::max(16u, mRegionCapacity * 4u));
    mRequestCapacity = mMapCapacity;
    const uint64_t auxiliary = uint64_t(mMapCapacity) * sizeof(MapEntry) * 2 +
        uint64_t(mRegionCapacity) * sizeof(RegionDesc) * 2 + uint64_t(mRequestCapacity) * 16 + 32 * sizeof(uint32_t);
    const uint64_t budget = uint64_t(mSettings.treeBudgetMiB) * kMiB;
    FALCOR_CHECK(auxiliary + kTransferReserve + uint64_t(mRegionCapacity) * 88 < budget,
        "PG tree budget cannot contain the requested region table and one node per region.");
    mNodeCapacity = uint32_t((budget - auxiliary - kTransferReserve) / 88);
    mNodeCapacity = std::min(mNodeCapacity, mRegionCapacity);
    mpReadMap = mpDevice->createStructuredBuffer(16u, mMapCapacity);
    mpBuildMap = mpDevice->createStructuredBuffer(16u, mMapCapacity);
    mpReadRegions = mpDevice->createStructuredBuffer(32u, mRegionCapacity);
    mpBuildRegions = mpDevice->createStructuredBuffer(32u, mRegionCapacity);
    mpReadNodes = mpDevice->createStructuredBuffer(20u, mNodeCapacity);
    mpBuildNodes = mpDevice->createStructuredBuffer(20u, mNodeCapacity);
    mpBuildStats = mpDevice->createStructuredBuffer(48u, mNodeCapacity);
    // Shader sees uint64 elements, with two elements per logical request slot.
    mpRequests = mpDevice->createStructuredBuffer(8u, mRequestCapacity * 2u);
    mpDiagnostics = mpDevice->createStructuredBuffer(4u, 16u);
    // Queue-local counters avoid concurrent writes to one resource by rendering and PGTrain.
    mpTrainingDiagnostics = mpDevice->createStructuredBuffer(4u, 16u);
    mpUploadStage = mpDevice->createBuffer(kUploadStageBytes, ResourceBindFlags::None, MemoryType::Upload);
    mpReadbackStage = mpDevice->createBuffer(kReadbackStageBytes, ResourceBindFlags::None, MemoryType::ReadBack);
    mStatistics.modelBytes = auxiliary + uint64_t(mNodeCapacity) * 88 + kUploadStageBytes + kReadbackStageBytes;
    mStatistics.modelReservedBytes = auxiliary + uint64_t(mNodeCapacity) * 88 + kTransferReserve;
    mStatistics.nodeCapacity = mNodeCapacity;
    mStatistics.regionCapacity = mRegionCapacity;
    reset(pContext);
}

void Manager::reset(RenderContext* pContext)
{
    pContext->submit(true);
    ++mSceneGeneration;
    if (!mSceneGeneration) ++mSceneGeneration;
    mRecordGeneration = 1;
    mFramesSincePoll = 0;
    mRegions.clear();
    mKnownKeys.clear();
    mKnownKeys.reserve(mRegionCapacity);
    mReadMapCPU.assign(mMapCapacity, {});
    mBuildMapCPU.assign(mMapCapacity, {});
    mRequestsCPU.resize(mRequestCapacity);
    mReadMapDirty = mBuildMapDirty = false;
    mBuildLayoutDirty = true;
    const auto bytes = mStatistics.modelBytes;
    const auto reserved = mStatistics.modelReservedBytes;
    const auto records = mStatistics.recordBytes;
    const auto recordReserved = mStatistics.recordReservedBytes;
    mStatistics = {};
    mTrainingDiagnosticsCPU.fill(0u);
    mStatistics.modelBytes = bytes;
    mStatistics.modelReservedBytes = reserved;
    mStatistics.recordBytes = records;
    mStatistics.recordReservedBytes = recordReserved;
    mStatistics.nodeCapacity = mNodeCapacity;
    mStatistics.regionCapacity = mRegionCapacity;
    for (auto& buffer : {mpReadMap, mpReadRegions, mpReadNodes, mpBuildMap, mpBuildRegions, mpBuildNodes,
                         mpBuildStats, mpRequests, mpDiagnostics, mpTrainingDiagnostics, mpPathHeaders})
        if (buffer)
        {
            pContext->clearUAV(buffer->getUAV().get(), uint4(0));
            pContext->uavBarrier(buffer.get());
        }
}

void Manager::beginFrame(RenderContext* pContext)
{
    (void)pContext; // RTPTPGPrepare clears headers before this frame's sparse trace.
    ++mRecordGeneration;
    if (!mRecordGeneration) ++mRecordGeneration;
}

void Manager::barrierTraining(RenderContext* pContext, bool separateDiagnostics) const
{
    // Falcor's uavBarrier() requires a concrete resource; nullptr is not a
    // global UAV barrier and dereferences a null pointer in this framework.
    const auto& diagnostics = separateDiagnostics ? mpTrainingDiagnostics : mpDiagnostics;
    for (auto& buffer : {mpPathHeaders, mpVertices, mpBuildStats, mpRequests, diagnostics})
        if (buffer) pContext->uavBarrier(buffer.get());
}

void Manager::bind(const ShaderVar& rootVar, float3 cameraPosition, float sceneScale, uint32_t frameIndex, bool trainingActive,
    bool separateDiagnostics, bool readOnlyResources) const
{
    setIfPresent(rootVar, "gPGReadMap", mpReadMap);
    setIfPresent(rootVar, "gPGReadRegions", mpReadRegions);
    setIfPresent(rootVar, "gPGReadNodes", mpReadNodes);
    if (!readOnlyResources)
    {
        setIfPresent(rootVar, "gPGBuildMap", mpBuildMap);
        setIfPresent(rootVar, "gPGBuildRegions", mpBuildRegions);
        setIfPresent(rootVar, "gPGBuildNodes", mpBuildNodes);
        setIfPresent(rootVar, "gPGBuildStats", mpBuildStats);
        setIfPresent(rootVar, "gPGRequests", mpRequests);
        setIfPresent(rootVar, "gPGPathHeaders", mpPathHeaders);
        setIfPresent(rootVar, "gPGVertices", mpVertices);
    }
    setIfPresent(rootVar, "gPGDiagnostics", separateDiagnostics ? mpTrainingDiagnostics : mpDiagnostics);
    auto var = rootVar.findMember("gPGSettings");
    if (!var.isValid()) return;
    setIfPresent(var, "frameDim", mFrameDim);
    setIfPresent(var, "recordStride", mRecordStride);
    setIfPresent(var, "frameIndex", frameIndex);
    setIfPresent(var, "pathCapacity", mPathCapacity);
    setIfPresent(var, "verticesPerPath", mVerticesPerPath);
    setIfPresent(var, "sceneGeneration", mSceneGeneration);
    setIfPresent(var, "recordGeneration", mRecordGeneration);
    setIfPresent(var, "readMapCapacity", mMapCapacity);
    setIfPresent(var, "buildMapCapacity", mMapCapacity);
    setIfPresent(var, "requestCapacity", mRequestCapacity);
    setIfPresent(var, "coarseLevels", mSettings.coarseLevels);
    setIfPresent(var, "enabled", mSettings.enabled && mSettings.useGuiding ? 1u : 0u);
    setIfPresent(var, "trainingEnabled", mSettings.enabled && mSettings.trainingEnabled && trainingActive ? 1u : 0u);
    setIfPresent(var, "detailedDiagnostics", mSettings.detailedDiagnostics ? 1u : 0u);
    setIfPresent(var, "guideFraction", mSettings.guideFraction);
    setIfPresent(var, "weightScale", mSettings.weightScale);
    setIfPresent(var, "cameraPosition", cameraPosition);
    setIfPresent(var, "sceneScale", sceneScale);
    setIfPresent(var, "readRegionCount", uint32_t(mRegions.size()));
    setIfPresent(var, "buildRegionCount", uint32_t(mRegions.size()));
    setIfPresent(var, "readNodeCount", mStatistics.readNodes);
    setIfPresent(var, "buildNodeCount", mStatistics.buildNodes);
}

Manager::NativeTrainingData Manager::getNativeTrainingData(
    float3 cameraPosition, float sceneScale, uint32_t frameIndex, bool trainingActive) const
{
    NativeTrainingData data;
    data.buffers = {mpBuildMap, mpBuildRegions, mpBuildNodes, mpBuildStats,
        mpRequests, mpTrainingDiagnostics, mpPathHeaders, mpVertices};
    auto& words = data.constants;
    static_assert(sizeof(words) == 112);
    words[0] = mFrameDim.x;
    words[1] = mFrameDim.y;
    words[2] = mRecordStride;
    words[3] = frameIndex;
    words[4] = mPathCapacity;
    words[5] = mVerticesPerPath;
    words[6] = mSceneGeneration;
    words[7] = mRecordGeneration;
    words[8] = mMapCapacity;
    words[9] = mMapCapacity;
    words[10] = mRequestCapacity;
    words[11] = mSettings.coarseLevels;
    words[12] = mSettings.enabled && mSettings.useGuiding ? 1u : 0u;
    words[13] = mSettings.enabled && mSettings.trainingEnabled && trainingActive ? 1u : 0u;
    const auto setFloat = [&](size_t index, float value) { std::memcpy(&words[index], &value, sizeof(value)); };
    setFloat(14, mSettings.guideFraction);
    setFloat(15, mSettings.weightScale);
    setFloat(16, cameraPosition.x);
    setFloat(17, cameraPosition.y);
    setFloat(18, cameraPosition.z);
    setFloat(19, sceneScale);
    words[20] = uint32_t(mRegions.size());
    words[21] = uint32_t(mRegions.size());
    words[22] = mStatistics.readNodes;
    words[23] = mStatistics.buildNodes;
    words[24] = mSettings.detailedDiagnostics ? 1u : 0u;
    return data;
}

void Manager::prepareNativeTraining(RenderContext* pContext) const
{
    // Run transitions on the default direct queue before signaling input readiness.
    // The native compute list then only accesses resources in these established states.
    for (auto& buffer : {mpBuildMap, mpBuildRegions, mpBuildNodes})
        pContext->resourceBarrier(buffer.get(), Resource::State::NonPixelShader);
    for (auto& buffer : {mpBuildStats, mpRequests, mpTrainingDiagnostics, mpPathHeaders, mpVertices})
    {
        pContext->resourceBarrier(buffer.get(), Resource::State::UnorderedAccess);
        pContext->uavBarrier(buffer.get());
    }
}

uint32_t Manager::hashKey(uint64_t key)
{
    auto jenkins = [](uint32_t a)
    {
        a = (a + 0x7ed55d16u) + (a << 12);
        a = (a ^ 0xc761c23cu) ^ (a >> 19);
        a = (a + 0x165667b1u) + (a << 5);
        a = (a + 0xd3a2646cu) ^ (a << 9);
        a = (a + 0xfd7046c5u) + (a << 3);
        return (a ^ 0xb55a4f09u) ^ (a >> 16);
    };
    return jenkins(uint32_t(key)) ^ jenkins(uint32_t(key >> 32));
}

uint32_t Manager::childIndex(const Node& node, uint32_t quadrant)
{
    return (node.topology >> 4) + popcount4(node.topology & ((1u << quadrant) - 1u));
}

float Manager::asFloat(uint32_t bits)
{
    float value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

void Manager::readBatch(RenderContext* pContext, std::initializer_list<ReadTransfer> transfers)
{
    size_t stageOffset = 0;
    mReadbackPieces.clear();
    mReadbackPieces.reserve(transfers.size());
    auto flush = [&]()
    {
        if (!stageOffset) return;
        pContext->submit(true);
        ++mStatistics.lastReadbackWaits;
        const auto data = static_cast<const uint8_t*>(mpReadbackStage->map());
        for (const auto& piece : mReadbackPieces)
            std::memcpy(piece.destination, data + piece.stageOffset, piece.bytes);
        mpReadbackStage->unmap();
        mReadbackPieces.clear();
        stageOffset = 0;
    };
    for (const auto& transfer : transfers)
    {
        auto destination = static_cast<uint8_t*>(transfer.destination);
        mStatistics.lastReadbackBytes += transfer.bytes;
        for (size_t offset = 0; offset < transfer.bytes;)
        {
            const size_t count = std::min(kReadbackStageBytes - stageOffset, transfer.bytes - offset);
            pContext->copyBufferRegion(mpReadbackStage.get(), stageOffset, transfer.buffer.get(), offset, count);
            mReadbackPieces.push_back({destination + offset, stageOffset, count});
            stageOffset += count;
            offset += count;
            if (stageOffset == kReadbackStageBytes) flush();
        }
    }
    flush();
}

void Manager::uploadBatch(RenderContext* pContext, std::initializer_list<UploadTransfer> transfers)
{
    size_t stageOffset = 0;
    auto flush = [&]()
    {
        if (!stageOffset) return;
        pContext->submit(true);
        ++mStatistics.lastUploadWaits;
        stageOffset = 0;
    };
    for (const auto& transfer : transfers)
    {
        auto source = static_cast<const uint8_t*>(transfer.source);
        mStatistics.lastUploadBytes += transfer.bytes;
        for (size_t offset = 0; offset < transfer.bytes;)
        {
            const size_t count = std::min(kUploadStageBytes - stageOffset, transfer.bytes - offset);
            mpUploadStage->setBlob(source + offset, stageOffset, count);
            pContext->copyBufferRegion(transfer.buffer.get(), offset, mpUploadStage.get(), stageOffset, count);
            stageOffset += count;
            offset += count;
            // Wait before reusing any staging bytes. A buffer or an individual
            // node can span batches without changing its byte representation.
            if (stageOffset == kUploadStageBytes) flush();
        }
    }
    flush();
}

std::vector<Manager::Node> Manager::makeInitialTree() const
{
    std::vector<Node> nodes(1);
    nodes[0].topology = 1u << 4;
    return nodes;
}

void Manager::uploadModel(RenderContext* pContext)
{
    auto& readRegions = mReadRegionsCPU;
    auto& buildRegions = mBuildRegionsCPU;
    auto& readNodes = mReadNodesCPU;
    auto& buildNodes = mBuildNodesCPU;
    auto& statistics = mUploadStatsCPU;
    readRegions.clear();
    readNodes.clear();
    // Build contains only topology and zero masses. Retain its packed layout
    // until admission or reset changes it.
    if (mBuildLayoutDirty)
    {
        buildRegions.clear();
        buildNodes.clear();
    }
    statistics.clear();
    // New regions arrive gradually. Reserving the exact count every publication
    // repeatedly reallocates these arrays; their maximum size is already bounded.
    readRegions.reserve(mRegionCapacity);
    buildRegions.reserve(mRegionCapacity);
    auto insert = [&](std::vector<MapEntry>& map, const Region& region, uint32_t id)
    {
        uint32_t slot = hashKey(region.key) % mMapCapacity;
        while (map[slot].keyLo || map[slot].keyHi) slot = (slot + 1u) % mMapCapacity;
        map[slot] = {uint32_t(region.key), uint32_t(region.key >> 32), id, region.generation};
    };
    auto append = [](std::vector<Node>& dst, const std::vector<Node>& source)
    {
        const uint32_t offset = uint32_t(dst.size());
        dst.insert(dst.end(), source.begin(), source.end());
        for (size_t i = offset; i < dst.size(); ++i)
        {
            auto& node = dst[i];
            if (node.topology & 15u) node.topology = (((node.topology >> 4) + offset) << 4) | (node.topology & 15u);
        }
        return offset;
    };
    mStatistics.readyRegions = mStatistics.observedZeroRegions = 0;
    for (uint32_t id = 0; id < mRegions.size(); ++id)
    {
        auto& region = mRegions[id];
        const auto readRoot = append(readNodes, region.read);
        readRegions.push_back({uint32_t(region.key), uint32_t(region.key >> 32), readRoot, uint32_t(region.read.size()),
            region.generation, region.flags, region.observationCount, 0.f});
        if (mBuildLayoutDirty)
        {
            const auto buildRoot = append(buildNodes, region.build);
            buildRegions.push_back({uint32_t(region.key), uint32_t(region.key >> 32), buildRoot, uint32_t(region.build.size()),
                region.generation, 0u, 0u, 0.f});
        }
        statistics.insert(statistics.end(), region.statistics.begin(), region.statistics.end());
        if (!region.read.empty() && !region.readMapped)
        {
            region.readMapped = true;
            mReadMapDirty = true;
        }
        if (!region.buildMapped)
        {
            insert(mBuildMapCPU, region, id);
            region.buildMapped = true;
            mBuildMapDirty = true;
        }
        if (region.flags & kReady) ++mStatistics.readyRegions;
        if (region.flags & kObservedZero) ++mStatistics.observedZeroRegions;
    }
    if (mReadMapDirty)
    {
        // Preserve the original canonical region-ID insertion order when cold
        // older regions publish after newer ones. Stable key sets skip both
        // this work and the GPU map upload.
        std::fill(mReadMapCPU.begin(), mReadMapCPU.end(), MapEntry{});
        for (uint32_t id = 0; id < mRegions.size(); ++id)
            if (!mRegions[id].read.empty()) insert(mReadMapCPU, mRegions[id], id);
    }
    FALCOR_CHECK(readNodes.size() <= mNodeCapacity && buildNodes.size() <= mNodeCapacity, "PG node pool exceeded its fixed capacity.");
    const auto uploadStart = std::chrono::steady_clock::now();
    uploadBatch(pContext, {
        {mpReadMap, mReadMapCPU.data(), mReadMapDirty ? mReadMapCPU.size() * sizeof(MapEntry) : 0},
        {mpBuildMap, mBuildMapCPU.data(), mBuildMapDirty ? mBuildMapCPU.size() * sizeof(MapEntry) : 0},
        {mpReadRegions, readRegions.data(), readRegions.size() * sizeof(RegionDesc)},
        {mpBuildRegions, buildRegions.data(), mBuildLayoutDirty ? buildRegions.size() * sizeof(RegionDesc) : 0},
        {mpReadNodes, readNodes.data(), readNodes.size() * sizeof(Node)},
        {mpBuildNodes, buildNodes.data(), mBuildLayoutDirty ? buildNodes.size() * sizeof(Node) : 0},
        {mpBuildStats, statistics.data(), statistics.size() * sizeof(NodeStats)},
    });
    mReadMapDirty = mBuildMapDirty = false;
    mBuildLayoutDirty = false;
    mStatistics.regions = uint32_t(mRegions.size());
    mStatistics.readNodes = uint32_t(readNodes.size());
    mStatistics.buildNodes = uint32_t(buildNodes.size());
    for (auto& buffer : {mpReadMap, mpBuildMap, mpReadRegions, mpBuildRegions, mpReadNodes, mpBuildNodes, mpBuildStats})
        pContext->uavBarrier(buffer.get());
    mStatistics.lastUploadMs = elapsedMs(uploadStart);
}

bool Manager::finishTrainingFrame(RenderContext* pContext)
{
    ++mStatistics.trainingFrames;
    if (++mFramesSincePoll < std::max(1u, mSettings.pollFrames)) return false;
    mFramesSincePoll = 0;
    return publish(pContext);
}

bool Manager::publish(RenderContext* pContext)
{
    const auto start = std::chrono::steady_clock::now();
    ++mStatistics.publishCalls;
    mStatistics.lastDrainMs = mStatistics.lastReadbackMs = mStatistics.lastCpuRebuildMs = mStatistics.lastUploadMs = 0.;
    mStatistics.lastReadbackBytes = mStatistics.lastUploadBytes = 0;
    mStatistics.lastDrainWaits = mStatistics.lastReadbackWaits = mStatistics.lastUploadWaits = 0;
    mStatistics.lastZeroFastPathRegions = 0;
    PublicationWallTimer publicationTimer{mStatistics, start};
    const auto readbackStart = std::chrono::steady_clock::now();
    auto& statistics = mReadbackStatsCPU;
    auto& requests = mRequestsCPU;
    statistics.resize(mStatistics.buildNodes);
    requests.resize(mRequestCapacity);
    // The first readback fence also waits for earlier rendering/training. A
    // separate drain adds a queue round trip without changing visibility.
    readBatch(pContext, {
        {mpBuildStats, statistics.data(), statistics.size() * sizeof(NodeStats)},
        {mpRequests, requests.data(), requests.size() * sizeof(MapEntry)},
        {mpDiagnostics, mStatistics.diagnostics.data(), sizeof(mStatistics.diagnostics)},
        {mpTrainingDiagnostics, mTrainingDiagnosticsCPU.data(), sizeof(mTrainingDiagnosticsCPU)},
    });
    // The caller joins the training queue before publication. Both buffers are cumulative;
    // reread each source before adding so mode changes preserve the original counter semantics.
    for (size_t i = 0; i < mStatistics.diagnostics.size(); ++i)
        mStatistics.diagnostics[i] += mTrainingDiagnosticsCPU[i];
    mStatistics.lastReadbackMs = elapsedMs(readbackStart);
    const bool accumulationFailed = mStatistics.diagnostics[3] != mStatistics.accumulationOverflow;
    if (accumulationFailed) ++mStatistics.rejectedTrainingWindows;
    mStatistics.requestOverflow = mStatistics.diagnostics[0];
    mStatistics.recordOverflow = mStatistics.diagnostics[1];
    mStatistics.invalidSamples = mStatistics.diagnostics[2] + mStatistics.diagnostics[12] + mStatistics.rejectedTrainingWindows;
    mStatistics.accumulationOverflow = mStatistics.diagnostics[3];
    bool changed = false;
    size_t offset = 0;
    uint64_t plannedNodes = mStatistics.buildNodes;
    for (auto& region : mRegions)
    {
        // Inspect the readback in place. Consumed windows are cleared below, so
        // copying them into each region first only adds work immediately undone.
        const NodeStats* regionStats = statistics.data() + offset;
        offset += region.build.size();
        if (accumulationFailed)
        {
            // CAS additions of sum, squared sum and count are separate. Any
            // failed addition may leave a partially updated observation; no
            // region has an error mask in this first implementation.
            region.statistics.assign(region.build.size(), {});
            continue;
        }
        uint64_t observations = 0;
        bool valid = true;
        bool positiveMass = false;
        for (size_t i = 0; i < region.build.size(); ++i)
            for (uint32_t q = 0; q < 4; ++q)
                if (!(region.build[i].topology & (1u << q)))
                {
                    const double value = asFloat(regionStats[i].weightBits[q]);
                    const double squared = asFloat(regionStats[i].squareBits[q]);
                    valid &= std::isfinite(value) && value >= 0. && std::isfinite(squared) && squared >= 0.;
                    positiveMass |= value > 0.;
                    observations += regionStats[i].count[q];
                }
        if (!observations)
        {
            // Preserve all bytes, including nonleaf statistics, just as before.
            region.statistics.assign(regionStats, regionStats + region.build.size());
            continue;
        }
        if (!valid)
        {
            ++mStatistics.rejectedTrainingWindows;
            ++mStatistics.invalidSamples;
            region.statistics.assign(region.build.size(), {});
            continue;
        }
        if (!positiveMass)
        {
            // An observed zero distribution is a real publication, not a lack
            // of data. Copy this Build topology, including all existing children,
            // so a formerly nonzero Read cannot survive the zero window.
            region.read = region.build;
            for (auto& node : region.read) node.mass = {};
            region.flags = kObservedZero;
            region.observationCount = uint32_t(std::min<uint64_t>(observations, std::numeric_limits<uint32_t>::max()));
            // Fixed Build topology and its zero masses remain unchanged.
            region.statistics.assign(region.build.size(), {});
            ++mStatistics.lastZeroFastPathRegions;
            changed = true;
            continue;
        }
        auto& normalized = mNormalizedCPU;
        auto& mass = mMassCPU;
        normalized = region.build;
        mass.assign(normalized.size(), {});
        for (size_t i = 0; i < normalized.size(); ++i)
            for (uint32_t q = 0; q < 4; ++q)
                if (!(normalized[i].topology & (1u << q)))
                    mass[i][q] = asFloat(regionStats[i].weightBits[q]);
        for (size_t reverse = normalized.size(); reverse-- > 0;)
            for (uint32_t q = 0; q < 4; ++q)
                if (normalized[reverse].topology & (1u << q))
                {
                    const auto& child = mass[childIndex(normalized[reverse], q)];
                    mass[reverse][q] = child[0] + child[1] + child[2] + child[3];
                }
        const double total = mass[0][0] + mass[0][1] + mass[0][2] + mass[0][3];
        valid &= std::isfinite(total) && total >= 0.;
        if (!valid)
        {
            // A corrupt build window cannot be repaired by adding more values.
            // Keep Read and explicitly start a fresh window; expose the failure.
            ++mStatistics.rejectedTrainingWindows;
            ++mStatistics.invalidSamples;
            region.statistics.assign(region.build.size(), {});
            continue;
        }
        for (size_t i = 0; i < normalized.size(); ++i)
            for (uint32_t q = 0; q < 4; ++q)
                normalized[i].mass[q] = total > 0. ? float(mass[i][q] / total) : 0.f;
        region.read = normalized;
        region.flags = total > 0. ? kReady : kObservedZero;
        region.observationCount = uint32_t(std::min<uint64_t>(observations, std::numeric_limits<uint32_t>::max()));
        region.statistics.assign(region.build.size(), {});
        changed = true;
    }
    for (const auto& request : requests)
    {
        const uint64_t key = uint64_t(request.keyLo) | (uint64_t(request.keyHi) << 32);
        if (!key || mKnownKeys.find(key) != mKnownKeys.end()) continue;
        if (mRegions.size() >= mRegionCapacity)
        {
            ++mStatistics.admissionRejected;
            continue;
        }
        auto initial = makeInitialTree();
        if (plannedNodes + initial.size() > mNodeCapacity)
        {
            ++mStatistics.admissionRejected;
            continue;
        }
        Region region;
        region.key = key;
        region.generation = mSceneGeneration;
        region.build = std::move(initial);
        region.statistics.resize(region.build.size());
        plannedNodes += region.build.size();
        mRegions.push_back(std::move(region));
        mBuildLayoutDirty = true;
        mKnownKeys.insert(key);
    }
    uploadModel(pContext);
    const auto finalizeStart = std::chrono::steady_clock::now();
    pContext->clearUAV(mpRequests->getUAV().get(), uint4(0));
    pContext->uavBarrier(mpRequests.get());
    if (changed) ++mStatistics.publications;
    mStatistics.lastUploadMs += elapsedMs(finalizeStart);
    return changed;
}
}
