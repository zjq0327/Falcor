#include "RTPTLightCatalog.h"
#include "Core/API/Device.h"
#include "Scene/Lights/LightCollection.h"
#include "Scene/Scene.h"
#include <algorithm>
#include <exception>
#include <limits>
#include <unordered_set>
#include <utility>

using namespace Falcor;

namespace
{
constexpr uint32_t kEmissive = 1u;
constexpr uint32_t kPoint = 2u;
constexpr uint32_t kInvalidRank = std::numeric_limits<uint32_t>::max();
constexpr uint64_t kMaxSdkLightIndex = 0x7fffffffu;

struct LightInfo
{
    uint32_t kind = 0u;
    uint32_t sourceIndex = 0u;
    uint32_t stable0 = 0u;
    uint32_t stable1 = 0u;
    uint32_t generation = 0u;
    float sourcePMF = 0.f;
    uint32_t stableId = 0u;
    uint32_t pad = 0u;
};
static_assert(sizeof(LightInfo) == RTPTLightCatalog::kLightStride);
}

uint64_t RTPTLightCatalog::Snapshot::getBytes() const
{
    return (lights ? lights->getSize() : 0u) + (uncoveredAnalyticIndices ? uncoveredAnalyticIndices->getSize() : 0u);
}

bool RTPTLightCatalog::prepare(Scene& scene, Device& device, uint64_t budgetBytes)
{
    std::vector<uint64_t> signature;
    Snapshot next;
    next.generation = mSnapshot.generation;

    try
    {
        const auto& renderSettings = scene.getRenderSettings();
        const auto collection = renderSettings.useEmissiveLights ? scene.getLightCollection(device.getRenderContext()) : nullptr;
        // Zero-flux triangles still have proposal support because a texture can contain bright texels.
        next.emissiveCount = collection ? collection->getTotalLightCount() : 0u;
        const auto& activeLights = scene.getActiveAnalyticLights();
        // Keep previous active lights alive through identity assignment so delete+new cannot inherit a reused address.
        std::unordered_set<const Light*> activeLightPointers;
        activeLightPointers.reserve(activeLights.size());
        for (const auto& light : activeLights) activeLightPointers.insert(light.get());
        for (auto identity = mAnalyticIdentities.begin(); identity != mAnalyticIdentities.end();)
        {
            if (activeLightPointers.find(identity->first) == activeLightPointers.end())
                identity = mAnalyticIdentities.erase(identity);
            else ++identity;
        }

        std::vector<uint32_t> pointIndices, pointIdentities, uncoveredIndices;
        signature = {uint64_t(next.emissiveCount), uint64_t(renderSettings.useAnalyticLights),
            collection ? uint64_t(collection->getMeshLights().size()) : 0u,
            renderSettings.useAnalyticLights ? uint64_t(activeLights.size()) : 0u};
        if (collection)
            for (const auto& mesh : collection->getMeshLights())
            {
                signature.push_back((uint64_t(mesh.instanceID) << 32) | mesh.triangleOffset);
                signature.push_back((uint64_t(mesh.materialID) << 32) | mesh.triangleCount);
            }
        if (renderSettings.useAnalyticLights)
            for (uint32_t index = 0u; index < activeLights.size(); ++index)
            {
                const auto& light = activeLights[index];
                auto identity = mAnalyticIdentities.find(light.get());
                if (identity == mAnalyticIdentities.end())
                {
                    FALCOR_CHECK(mNextAnalyticIdentity != 0u, "ReSTIR DI light identity range exhausted.");
                    identity = mAnalyticIdentities.emplace(light.get(), mNextAnalyticIdentity++).first;
                }
                signature.push_back((uint64_t(identity->second) << 32) | uint32_t(light->getType()));
                if (light->getType() == LightType::Point)
                {
                    pointIndices.push_back(index);
                    pointIdentities.push_back(identity->second);
                }
                else uncoveredIndices.push_back(index);
            }
        mAnalyticIdentityOwners.assign(activeLights.begin(), activeLights.end());

        next.pointCount = uint32_t(pointIndices.size());
        next.uncoveredAnalyticCount = uint32_t(uncoveredIndices.size());
        next.coverageMask = (next.emissiveCount ? kEmissive : 0u) | (next.pointCount ? kPoint : 0u);
        const uint64_t lightCount = uint64_t(next.emissiveCount) + next.pointCount;
        next.lightCount = lightCount <= kMaxSdkLightIndex ? uint32_t(lightCount) : 0u;

        const bool sameLayout = signature == mSignature;
        if (sameLayout && !mFailure.empty()) return false;

        FALCOR_CHECK(lightCount <= kMaxSdkLightIndex, "ReSTIR DI catalogue exceeds the SDK light-index range.");
        FALCOR_CHECK(lightCount <= (1u << 24), "ReSTIR DI uniform proposal exceeds its 24-bit random-number support.");
        const uint32_t lightCapacity = std::max(1u, next.lightCount);
        const uint32_t uncoveredCapacity = std::max(1u, next.uncoveredAnalyticCount);
        const uint64_t bytes = uint64_t(lightCapacity) * sizeof(LightInfo) + uint64_t(uncoveredCapacity) * sizeof(uint32_t);
        FALCOR_CHECK(bytes <= budgetBytes, "RTPT light catalogue needs {} bytes, exceeding its {} MiB budget.", bytes, budgetBytes >> 20);
        if (sameLayout && mSnapshot.lights) return true;

        if (++next.generation == 0u) ++next.generation;
        std::vector<LightInfo> lights(lightCapacity);
        const float sourcePMF = lightCount > 0u ? 1.f / float(lightCount) : 0.f;
        if (collection)
            for (const auto& mesh : collection->getMeshLights())
                for (uint32_t primitive = 0u; primitive < mesh.triangleCount; ++primitive)
                {
                    const uint32_t index = mesh.triangleOffset + primitive;
                    FALCOR_CHECK(index < next.emissiveCount, "Invalid emissive catalogue layout.");
                    lights[index] = {kEmissive, index, mesh.instanceID, primitive, next.generation, sourcePMF, 0u, 0u};
                }
        for (uint32_t rank = 0u; rank < next.pointCount; ++rank)
            lights[next.emissiveCount + rank] = {
                kPoint, pointIndices[rank], pointIdentities[rank], 0u, next.generation, sourcePMF, 0u, 0u
            };

        // Keep world-space cell identities stable when the current catalogue ranks change.
        for (uint32_t rank = 0u; rank < next.lightCount; ++rank)
        {
            auto& light = lights[rank];
            const auto key = std::make_tuple(light.kind, light.stable0, light.stable1);
            auto stable = mStableIds.find(key);
            if (stable == mStableIds.end())
            {
                FALCOR_CHECK(mNextStableId != kInvalidRank, "ReGIR stable light identity range exhausted.");
                stable = mStableIds.emplace(key, mNextStableId++).first;
            }
            light.stableId = stable->second;
        }
        next.idToRank.assign(mNextStableId, kInvalidRank);
        for (uint32_t rank = 0u; rank < next.lightCount; ++rank)
            next.idToRank[lights[rank].stableId] = rank;

        next.lights = device.createStructuredBuffer(
            sizeof(LightInfo), lightCapacity, ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, lights.data(), false
        );
        if (uncoveredIndices.empty()) uncoveredIndices.push_back(0u);
        next.uncoveredAnalyticIndices = device.createStructuredBuffer(
            sizeof(uint32_t), uncoveredCapacity, ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, uncoveredIndices.data(), false
        );

        mSnapshot = std::move(next);
        mSignature = std::move(signature);
        mFailure.clear();
        return true;
    }
    catch (const std::exception& error)
    {
        // A budget rejection can leave the matching snapshot available for a retry.
        // A changed topology must never expose the old or partially uploaded buffers.
        if (signature != mSignature || !mSnapshot.lights)
        {
            next.generation = mSnapshot.generation;
            next.lights = next.uncoveredAnalyticIndices = nullptr;
            next.idToRank.clear();
            mSnapshot = std::move(next);
            mSignature = std::move(signature);
        }
        mFailure = error.what();
        return false;
    }
}

void RTPTLightCatalog::release()
{
    const uint32_t generation = mSnapshot.generation;
    mSnapshot = {};
    mSnapshot.generation = generation;
    mSignature.clear();
    mFailure.clear();
}

void RTPTLightCatalog::reset()
{
    release();
    mAnalyticIdentities.clear();
    mAnalyticIdentityOwners.clear();
    mNextAnalyticIdentity = 1u;
    mStableIds.clear();
    mNextStableId = 0u;
}
