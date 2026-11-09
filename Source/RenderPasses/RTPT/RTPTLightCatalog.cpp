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

bool samePointLight(const LightData& a, const LightData& b)
{
    // Compare physical values, not struct padding or a max-channel proxy.
    return a.type == b.type && all(a.posW == b.posW) && all(a.dirW == b.dirW) &&
        all(a.intensity == b.intensity) && a.openingAngle == b.openingAngle &&
        a.cosOpeningAngle == b.cosOpeningAngle && a.penumbraAngle == b.penumbraAngle &&
        a.cosSubtendedAngle == b.cosSubtendedAngle && all(a.tangent == b.tangent) &&
        all(a.bitangent == b.bitangent) && a.surfaceArea == b.surfaceArea &&
        a.transMat == b.transMat && a.transMatIT == b.transMatIT;
}

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
    return (lights ? lights->getSize() : 0u) + (uncoveredAnalyticIndices ? uncoveredAnalyticIndices->getSize() : 0u) +
        (lightHistoryMetadata ? lightHistoryMetadata->getSize() : 0u);
}

bool RTPTLightCatalog::prepare(Scene& scene, Device& device, uint64_t budgetBytes, bool trackLightHistory)
{
    std::vector<uint64_t> signature;
    Snapshot next;
    next.generation = mSnapshot.generation;
    next.lightHistoryMetadata = mSnapshot.lightHistoryMetadata;

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
        if (sameLayout && mSnapshot.lights)
        {
            if (trackLightHistory) updateLightHistory(scene, device, budgetBytes);
            return true;
        }

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
        if (trackLightHistory) updateLightHistory(scene, device, budgetBytes);
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

void RTPTLightCatalog::updateLightHistory(Scene& scene, Device& device, uint64_t budgetBytes)
{
    std::unordered_map<uint32_t, LightData> points;
    // Match catalogue eligibility. Active scene objects are deliberately absent
    // from the catalogue when analytic lighting is disabled; their previous
    // stable IDs become tombstones via idToRank below.
    if (scene.getRenderSettings().useAnalyticLights)
    {
        for (const auto& light : scene.getActiveAnalyticLights())
        {
            if (light->getType() != LightType::Point) continue;
            const auto identity = mAnalyticIdentities.find(light.get());
            FALCOR_CHECK(identity != mAnalyticIdentities.end(), "Point-light history has no catalogue identity.");
            const auto stable = mStableIds.find(std::make_tuple(kPoint, identity->second, 0u));
            FALCOR_CHECK(stable != mStableIds.end(), "Point-light history has no stable ID.");
            points.emplace(stable->second, light->getData());
        }
    }

    std::vector<uint64_t> emissiveSignature;
    if (scene.getRenderSettings().useEmissiveLights)
    {
        const auto collection = scene.getLightCollection(device.getRenderContext());
        for (const auto& mesh : collection->getMeshLights())
        {
            emissiveSignature.push_back((uint64_t(mesh.instanceID) << 32) | mesh.triangleOffset);
            emissiveSignature.push_back((uint64_t(mesh.materialID) << 32) | mesh.triangleCount);
        }
    }
    const auto structuralUpdates = IScene::UpdateFlags::GeometryChanged | IScene::UpdateFlags::GeometryMoved |
        IScene::UpdateFlags::MeshesChanged | IScene::UpdateFlags::MaterialsChanged |
        IScene::UpdateFlags::EmissiveMaterialsChanged | IScene::UpdateFlags::LightCollectionChanged |
        IScene::UpdateFlags::EnvMapChanged | IScene::UpdateFlags::EnvMapPropertiesChanged |
        IScene::UpdateFlags::RenderSettingsChanged;
    if (mLightHistoryInitialized &&
        (emissiveSignature != mLightHistoryEmissiveSignature || (scene.getUpdates() & structuralUpdates) != IScene::UpdateFlags::None))
        ++mLightHistoryGeneration;
    mLightHistoryEmissiveSignature = std::move(emissiveSignature);

    const size_t oldSize = mLightHistoryMetadata.size();
    mLightHistoryMetadata.resize(mNextStableId, uint4(0u));
    mLightHistoryChangedIds.clear();
    for (const auto& [key, stableID] : mStableIds)
    {
        const uint32_t kind = std::get<0>(key);
        const bool alive = stableID < mSnapshot.idToRank.size() && mSnapshot.idToRank[stableID] != kInvalidRank;
        const auto& old = mLightHistoryMetadata[stableID];
        bool changed = stableID >= oldSize || old.z != uint32_t(alive) || old.w != kind;
        if (alive && kind == kPoint)
        {
            const auto current = points.find(stableID);
            const auto previous = mPointHistoryData.find(stableID);
            FALCOR_CHECK(current != points.end(), "Active point light is missing physical history data.");
            changed |= previous == mPointHistoryData.end() || !samePointLight(current->second, previous->second);
        }
        if (changed) mLightHistoryChangedIds.push_back(stableID);
    }
    const bool rebase = !mLightHistoryChangedIds.empty() && mLightHistoryEpoch == std::numeric_limits<uint32_t>::max();
    if (rebase)
    {
        // Never compare wrapped epochs against retained history.
        ++mLightHistoryGeneration;
        mLightHistoryEpoch = 1u;
        for (auto& meta : mLightHistoryMetadata) meta.x = meta.y = 1u;
    }
    else if (!mLightHistoryChangedIds.empty()) ++mLightHistoryEpoch;
    for (const auto& [key, stableID] : mStableIds)
    {
        auto& meta = mLightHistoryMetadata[stableID];
        if (meta.x == 0u) meta.x = mLightHistoryEpoch;
        meta.z = stableID < mSnapshot.idToRank.size() && mSnapshot.idToRank[stableID] != kInvalidRank ? 1u : 0u;
        meta.w = std::get<0>(key);
    }
    for (const uint32_t stableID : mLightHistoryChangedIds)
        mLightHistoryMetadata[stableID].y = mLightHistoryEpoch;
    mLightHistoryUploadDirty |= !mLightHistoryChangedIds.empty() || rebase;
    std::sort(mLightHistoryChangedIds.begin(), mLightHistoryChangedIds.end());
    mPointHistoryData = std::move(points);
    mLightHistoryInitialized = true;

    uint32_t capacity = 16u;
    while (capacity < mNextStableId)
    {
        FALCOR_CHECK(capacity <= std::numeric_limits<uint32_t>::max() / 2u, "Light-history metadata capacity exhausted.");
        capacity <<= 1u;
    }
    const bool allocate = !mSnapshot.lightHistoryMetadata || mLightHistoryCapacity < capacity;
    const uint64_t oldBytes = mSnapshot.lightHistoryMetadata ? mSnapshot.lightHistoryMetadata->getSize() : 0u;
    const uint64_t nextBytes = allocate ? uint64_t(capacity) * sizeof(uint4) : oldBytes;
    FALCOR_CHECK(mSnapshot.getBytes() - oldBytes + nextBytes <= budgetBytes,
        "Light-history metadata exceeds the light catalogue budget.");
    if (allocate)
    {
        std::vector<uint4> values(capacity, uint4(0u));
        std::copy(mLightHistoryMetadata.begin(), mLightHistoryMetadata.end(), values.begin());
        mSnapshot.lightHistoryMetadata = device.createStructuredBuffer(sizeof(uint4), capacity,
            ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, values.data(), false);
        mLightHistoryCapacity = capacity;
    }
    else if (mLightHistoryUploadDirty)
        device.getRenderContext()->updateBuffer(mSnapshot.lightHistoryMetadata.get(), mLightHistoryMetadata.data(), 0u,
            mLightHistoryMetadata.size() * sizeof(uint4));
    mLightHistoryUploadDirty = false;
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
    mLightHistoryMetadata.clear();
    mPointHistoryData.clear();
    mLightHistoryEmissiveSignature.clear();
    mLightHistoryChangedIds.clear();
    mLightHistoryEpoch = 1u;
    mLightHistoryCapacity = 0u;
    ++mLightHistoryGeneration;
    mLightHistoryInitialized = false;
    mLightHistoryUploadDirty = false;
}
