#pragma once

#include "Core/API/Buffer.h"
#include "Scene/Lights/Light.h"
#include <cstdint>
#include <map>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>

namespace Falcor
{
class Device;
class Scene;
}

class RTPTLightCatalog
{
public:
    static constexpr uint32_t kLightStride = 32u;

    struct Snapshot
    {
        Falcor::ref<Falcor::Buffer> lights;
        Falcor::ref<Falcor::Buffer> uncoveredAnalyticIndices;
        // Per stable ID: birth epoch, last physical change, alive, light kind.
        // This is separate from ReGIR's culling/proxy descriptors.
        Falcor::ref<Falcor::Buffer> lightHistoryMetadata;
        std::vector<uint32_t> idToRank;
        uint32_t generation = 1u;
        uint32_t lightCount = 0u;
        uint32_t emissiveCount = 0u;
        uint32_t pointCount = 0u;
        uint32_t uncoveredAnalyticCount = 0u;
        uint32_t coverageMask = 0u;

        uint64_t getBytes() const;
    };

    const Snapshot& getSnapshot() const { return mSnapshot; }
    const std::string& getFailure() const { return mFailure; }
    uint32_t getStableIdCount() const { return mNextStableId; }
    uint32_t getLightHistoryEpoch() const { return mLightHistoryEpoch; }
    uint64_t getLightHistoryGeneration() const { return mLightHistoryGeneration; }
    bool hasLightHistoryMetadata() const { return bool(mSnapshot.lightHistoryMetadata); }
    const std::vector<Falcor::uint4>& getLightHistoryMetadata() const { return mLightHistoryMetadata; }
    const std::vector<uint32_t>& getLightHistoryChangedIds() const { return mLightHistoryChangedIds; }
    bool prepare(Falcor::Scene& scene, Falcor::Device& device, uint64_t budgetBytes, bool trackLightHistory = false);
    void release();
    void reset();
    void retry() { mFailure.clear(); }

private:
    void updateLightHistory(Falcor::Scene& scene, Falcor::Device& device, uint64_t budgetBytes);
    Snapshot mSnapshot;
    std::vector<uint64_t> mSignature;
    std::string mFailure;
    std::unordered_map<const Falcor::Light*, uint32_t> mAnalyticIdentities;
    std::vector<Falcor::ref<Falcor::Light>> mAnalyticIdentityOwners;
    uint32_t mNextAnalyticIdentity = 1u;
    std::map<std::tuple<uint32_t, uint32_t, uint32_t>, uint32_t> mStableIds;
    uint32_t mNextStableId = 0u;
    std::vector<Falcor::uint4> mLightHistoryMetadata;
    std::unordered_map<uint32_t, Falcor::LightData> mPointHistoryData;
    std::vector<uint64_t> mLightHistoryEmissiveSignature;
    std::vector<uint32_t> mLightHistoryChangedIds;
    uint32_t mLightHistoryEpoch = 1u;
    uint32_t mLightHistoryCapacity = 0u;
    uint64_t mLightHistoryGeneration = 1u;
    bool mLightHistoryInitialized = false;
    bool mLightHistoryUploadDirty = false;
};
