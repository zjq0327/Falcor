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
    bool prepare(Falcor::Scene& scene, Falcor::Device& device, uint64_t budgetBytes);
    void release();
    void reset();
    void retry() { mFailure.clear(); }

private:
    Snapshot mSnapshot;
    std::vector<uint64_t> mSignature;
    std::string mFailure;
    std::unordered_map<const Falcor::Light*, uint32_t> mAnalyticIdentities;
    std::vector<Falcor::ref<Falcor::Light>> mAnalyticIdentityOwners;
    uint32_t mNextAnalyticIdentity = 1u;
    std::map<std::tuple<uint32_t, uint32_t, uint32_t>, uint32_t> mStableIds;
    uint32_t mNextStableId = 0u;
};
