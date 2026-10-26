#include "RTPTVXPG.h"
#include "Core/API/GFXAPI.h"

using namespace Falcor;
namespace RTPTVXPG
{
ref<ComputePass> Manager::createPass(const char* library, const char* entry, PassScene scene, PassCounters counters) const
{
    ProgramDesc desc;
    DefineList defines;
    if (scene != PassScene::None)
    {
        desc.addShaderModules(mpScene->getShaderModules());
        defines = mpScene->getSceneDefines();
    }
    desc.addShaderLibrary(std::string("RenderPasses/RTPT/VXPG/") + library).csEntry(entry);
    if (scene != PassScene::None)
        desc.addTypeConformances(mpScene->getTypeConformances());
    desc.setShaderModel(ShaderModel::SM6_6);
    if (scene == PassScene::SceneAndSampler)
        defines.add(mpSampleGenerator->getDefines());
    if (counters == PassCounters::Configured)
        defines.add("RTPT_VXPG_DETAILED_DIAGNOSTICS", mSettings.detailedDiagnostics ? "1" : "0");
    return ComputePass::create(mpDevice, desc, defines, true);
}

uint64_t Manager::estimateModelBytes() const
{
    const uint64_t cells = cellCapacity();
    const uint64_t superpixels = uint64_t((mFrameDim.x + mSettings.superpixelSize - 1) / mSettings.superpixelSize) *
                                 ((mFrameDim.y + mSettings.superpixelSize - 1) / mSettings.superpixelSize);
    // Conservative capacities for the persistent grid, local trees and screen data.
    const uint64_t pendingCount = std::min<uint64_t>(discoveryRequestCount(), getHashCapacity());
    const uint64_t gridExtra =
        cells * 44ull + uint64_t(getHashCapacity()) * 8ull + getDiscoveryRecordCount() * 48ull + pendingCount * 4ull + 64ull;
    const uint64_t localExtra = cells * 4ull + uint64_t(mSettings.maxVoxels) * 36ull + 344ull;
    const uint64_t historySnapshots = cells * 32ull;
    return historySnapshots + gridExtra + localExtra + cells * 96ull + 16ull + uint64_t(mSettings.maxVoxels) * 216ull +
           superpixels * 304ull + mView.allocationBytes + uint64_t(mFrameDim.x) * mFrameDim.y * 4ull + (2ull << 20);
}

void Manager::resetClusterPasses()
{
    mProposal.pPrepareClusters = mProposal.pRows = mProposal.pRowVisibility = mProposal.pSeedsPass = mProposal.pAssignClusters = nullptr;
    mView.pCenters = mView.pAssociate = mView.pTopLeaves = mView.pTopParents = mView.pDistributionDebug = nullptr;
    mView.pSuperpixelPrefix = mView.pSuperpixelBlockPrefix = mView.pSuperpixelRanges = mView.pSuperpixelScatter = nullptr;
    mProposal.pEncode = mProposal.pHistogramPass = mProposal.pPrefixPass = mProposal.pScatter = mProposal.pAllocateForest =
        mProposal.pInitializeForest = nullptr;
    mProposal.pForestLeaves = mProposal.pForestLevel = mProposal.pPublishClusters = nullptr;
}

void Manager::releaseModelResources()
{
    // Model validity and history are handled by invalidate(Resources).
    mView.pDebug = nullptr;
    mLighting.pClearFrame = mView.pPrimary = mProposal.pGlobalLeaves = mProposal.pGlobalLevel = mProposal.pPublish =
        mProposal.pClearDiagnostics = nullptr;
    resetClusterPasses();
    mGrid.pBoundMin = mGrid.pBoundMax = mProposal.pState = mProposal.pInverse = nullptr;
    mGrid.pHash = mGrid.pCellKeys = mProposal.pWorkArgs = mProposal.pWorkDispatch = nullptr;
    mLighting.pHistoryPrevious = mLighting.pNormalPrevious = nullptr;
    mProposal.pGeometryWork = mProposal.pActiveWork = mProposal.pForestWork = nullptr;
    mLighting.pFlux = mLighting.pCount = mProposal.pCompactIndices = mProposal.pMass = mProposal.pGlobalTree =
        mLighting.pRepresentativePosition = mLighting.pRepresentativeNormal = nullptr;
    mLighting.pHistory = mLighting.pHistoryStats = mProposal.pQueryStats = nullptr;
    mProposal.pCellMass = mProposal.pTreeState = mProposal.pDirtyLeaves = mProposal.pDirtyNodes = mProposal.pLocalArgs =
        mProposal.pLocalDispatch = nullptr;
    mGrid.pGridState = mGrid.pCellLifetime = mGrid.pFreeCells = mGrid.pRetiredCells = mGrid.pDiscovery = mGrid.pPendingHash =
        mGrid.pPendingSlots = nullptr;
    mGrid.pGridClear = mGrid.pGridBegin = mGrid.pGridEvict = mGrid.pGridDiscover = mGrid.pGridInsert = mGrid.pGridReplay =
        mGrid.pGridRetire = nullptr;
    mProposal.pBeginLocal = mProposal.pResolveLocal = mProposal.pSelectLocal = mProposal.pCompactLocal = mProposal.pLocalWork =
        mProposal.pLocalLeaves = mProposal.pLocalLevel = nullptr;
    mView.pRowPosition = mView.pRowNormal = mProposal.pVisibility = mProposal.pSeeds = mProposal.pCluster = mProposal.pClusterInfo =
        nullptr;
    mProposal.pForest = mProposal.pCompactToLeaf = mView.pSuperpixelPosition = mView.pSuperpixelNormal = mView.pTopTree =
        mProposal.pClusterState = mProposal.pClusterArgs = nullptr;
    mProposal.pSortA = mProposal.pSortB = mProposal.pHistogram = mProposal.pBinOffsets = nullptr;
    mView.pPrimaryPosition = mView.pPrimaryNormal = mView.pPrimaryHit = mView.pFuzzyIds = mView.pFuzzyWeights = nullptr;
    mView.pSuperpixelCount = mView.pSuperpixelRange = mView.pSuperpixelBlocks = mView.pSuperpixelPoints = nullptr;
    mProposal.allocatedCapacity = mView.allocatedSuperpixelSize = mProposal.leafCapacity = 0;
    mView.allocatedFrameDim = uint2(0);
}

void Manager::bind(const ShaderVar& root, uint32_t frameIndex, bool active) const
{
    auto parameters = root.findMember("gVXPGParams");
    if (parameters.isValid())
    {
        parameters["frameDim"] = mFrameDim;
        parameters["cellCount"] = cellCapacity();
        parameters["hashCapacity"] = getHashCapacity();
        parameters["sortMin"] = mpScene ? mpScene->getSceneBounds().minPoint : float3(0.f);
        parameters["sortExtent"] = mpScene ? mpScene->getSceneBounds().extent() : float3(1.f);
        parameters["gridMin"] = mGridMin;
        parameters["cellSize"] = mCellSize;
        parameters["lodCamera"] = mLodCamera;
        parameters["lodSceneScale"] = mSettings.lodSceneScale;
        parameters["geometryGeneration"] = mGeometryGeneration;
        parameters["historyFrames"] = mSettings.historyFrames;
        parameters["historyStaleFrames"] = mSettings.historyStaleFrames;
        parameters["historyReset"] = mResetHistory ? 1u : 0u;
        parameters["lodPreviousCamera"] = mPreviousLodCamera;
        parameters["treeRefreshFrames"] = mSettings.treeRefreshFrames;
        parameters["treeReset"] = mDistributionValid ? 0u : 1u;
        parameters["globalLeafCapacity"] = mProposal.leafCapacity;
        parameters["discoveryStride"] = mSettings.discoveryStride;
        parameters["spatialStaleFrames"] = mSettings.spatialStaleFrames;
        parameters["discoveryRecordCount"] = uint32_t(getDiscoveryRecordCount());
        parameters["sharedInjectionStride"] = mSharedTrainingStride;
        parameters["sharedInjectionBounces"] = mSharedTrainingBounces;
        parameters["activeCapacity"] = mSettings.maxVoxels;
        parameters["frameIndex"] = frameIndex;
        parameters["generation"] = mGeneration;
        parameters["enabled"] = active && mSettings.enabled ? 1u : 0u;
        parameters["useGuiding"] = mSettings.useGuiding ? 1u : 0u;
        parameters["pgUseCache"] = mSettings.pgUseCache ? 1u : 0u;
        parameters["debugEnabled"] = mSettings.debugEnabled ? 1u : 0u;
        parameters["debugMode"] = mSettings.debugMode;
        parameters["superpixelSize"] = mSettings.superpixelSize;
        parameters["clusterCount"] = mSettings.clusterCount;
        parameters["superpixelDim"] = (mFrameDim + mSettings.superpixelSize - 1u) / mSettings.superpixelSize;
    }
    auto buffer = [&](const char* name, const ref<Buffer>& value)
    {
        auto member = root.findMember(name);
        if (member.isValid())
            member = value;
    };
    buffer("gVXPGBoundMin", mGrid.pBoundMin);
    buffer("gVXPGBoundMax", mGrid.pBoundMax);
    buffer("gVXPGState", mProposal.pState);
    buffer("gVXPGQueryStats", mProposal.pQueryStats);
    buffer("gVXPGInverse", mProposal.pInverse);
    buffer("gVXPGWorkArgs", mProposal.pWorkArgs);
    buffer("gVXPGHashSlots", mGrid.pHash);
    buffer("gVXPGCellKeys", mGrid.pCellKeys);
    buffer("gVXPGFlux", mLighting.pFlux);
    buffer("gVXPGCount", mLighting.pCount);
    buffer("gVXPGHistoryPrevious", mLighting.pHistoryPrevious);
    buffer("gVXPGNormalPrevious", mLighting.pNormalPrevious);

    buffer("gVXPGHistory", mLighting.pHistory);
    buffer("gVXPGHistoryStats", mLighting.pHistoryStats);
    buffer("gVXPGCellMass", mProposal.pCellMass);
    buffer("gVXPGTreeState", mProposal.pTreeState);
    buffer("gVXPGDirtyLeaves", mProposal.pDirtyLeaves);
    buffer("gVXPGDirtyNodes", mProposal.pDirtyNodes);
    buffer("gVXPGLocalArgs", mProposal.pLocalArgs);
    buffer("gVXPGGridState", mGrid.pGridState);
    buffer("gVXPGCellLifetime", mGrid.pCellLifetime);
    buffer("gVXPGFreeCells", mGrid.pFreeCells);
    buffer("gVXPGRetiredCells", mGrid.pRetiredCells);
    buffer("gVXPGDiscovery", mGrid.pDiscovery);
    buffer("gVXPGPendingHash", mGrid.pPendingHash);
    buffer("gVXPGPendingSlots", mGrid.pPendingSlots);

    buffer("gVXPGCompact", mProposal.pCompactIndices);
    buffer("gVXPGMass", mProposal.pMass);
    buffer("gVXPGGlobalTree", mProposal.pGlobalTree);
    buffer("gVXPGRepresentativePosition", mLighting.pRepresentativePosition);
    buffer("gVXPGRepresentativeNormal", mLighting.pRepresentativeNormal);
    buffer("gVXPGRowPosition", mView.pRowPosition);
    buffer("gVXPGRowNormal", mView.pRowNormal);
    buffer("gVXPGVisibility", mProposal.pVisibility);
    buffer("gVXPGSeeds", mProposal.pSeeds);
    buffer("gVXPGCluster", mProposal.pCluster);
    buffer("gVXPGClusterInfo", mProposal.pClusterInfo);

    buffer("gVXPGForest", mProposal.pForest);
    buffer("gVXPGCompactToLeaf", mProposal.pCompactToLeaf);
    buffer("gVXPGSuperpixelPosition", mView.pSuperpixelPosition);
    buffer("gVXPGSuperpixelNormal", mView.pSuperpixelNormal);
    buffer("gVXPGTopTree", mView.pTopTree);
    buffer("gVXPGClusterState", mProposal.pClusterState);
    buffer("gVXPGClusterArgs", mProposal.pClusterArgs);
    buffer("gVXPGSuperpixelCount", mView.pSuperpixelCount);
    buffer("gVXPGSuperpixelRange", mView.pSuperpixelRange);
    buffer("gVXPGSuperpixelBlocks", mView.pSuperpixelBlocks);
    buffer("gVXPGSuperpixelPoints", mView.pSuperpixelPoints);
    auto ids = root.findMember("gVXPGFuzzyIds");
    if (ids.isValid())
        ids = mView.pFuzzyIds;
    auto weights = root.findMember("gVXPGFuzzyWeights");
    if (weights.isValid())
        weights = mView.pFuzzyWeights;
    auto position = root.findMember("gVXPGPrimaryPosition");
    if (position.isValid())
        position = mView.pPrimaryPosition;
    auto normal = root.findMember("gVXPGPrimaryNormal");
    if (normal.isValid())
        normal = mView.pPrimaryNormal;
    auto hit = root.findMember("gVXPGPrimaryHit");
    if (hit.isValid())
        hit = mView.pPrimaryHit;
}

uint64_t Manager::getPayloadBytes() const
{
    uint64_t bytes = 0;
    for (const auto& buffer :
         {mProposal.pWorkArgs,
          mProposal.pWorkDispatch,
          mGrid.pHash,
          mGrid.pCellKeys,
          mGrid.pBoundMin,
          mGrid.pBoundMax,
          mProposal.pState,
          mProposal.pInverse,
          mGrid.pGridState,
          mGrid.pCellLifetime,
          mGrid.pFreeCells,
          mGrid.pRetiredCells,
          mGrid.pDiscovery,
          mGrid.pPendingHash,
          mGrid.pPendingSlots,
          mLighting.pFlux,
          mLighting.pCount,
          mLighting.pHistory,
          mLighting.pHistoryStats,
          mProposal.pQueryStats,
          mLighting.pHistoryPrevious,
          mLighting.pNormalPrevious,
          mProposal.pCellMass,
          mProposal.pTreeState,
          mProposal.pDirtyLeaves,
          mProposal.pDirtyNodes,
          mProposal.pLocalArgs,
          mProposal.pLocalDispatch,
          mProposal.pCompactIndices,
          mProposal.pMass,
          mProposal.pGlobalTree,
          mLighting.pRepresentativePosition,
          mLighting.pRepresentativeNormal,
          mView.pRowPosition,
          mView.pRowNormal,
          mProposal.pVisibility,
          mProposal.pSeeds,
          mProposal.pCluster,
          mProposal.pClusterInfo,
          mProposal.pForest,
          mProposal.pCompactToLeaf,
          mView.pSuperpixelPosition,
          mView.pSuperpixelNormal,
          mView.pTopTree,
          mProposal.pClusterState,
          mProposal.pClusterArgs,
          mProposal.pSortA,
          mProposal.pSortB,
          mProposal.pHistogram,
          mProposal.pBinOffsets,
          mView.pSuperpixelCount,
          mView.pSuperpixelRange,
          mView.pSuperpixelBlocks,
          mView.pSuperpixelPoints})
        if (buffer)
            bytes += buffer->getSize();
    for (const auto& texture : {mView.pPrimaryPosition, mView.pPrimaryNormal, mView.pPrimaryHit, mView.pFuzzyIds, mView.pFuzzyWeights})
        if (texture)
            bytes += texture->getTextureSizeInBytes();
    return bytes;
}

void Manager::updateScreenAllocation(uint2 frameDim)
{
    if (any(frameDim != mFrameDim) || mView.allocationBytes == 0)
    {
        // Query the same driver allocation descriptions as Texture uses, before
        // allocating. Pixel payload misses odd-size padding; arbitrary tile
        // rounding can instead reject a valid 1080p model under its budget.
        auto textureBytes = [&](gfx::Format format)
        {
            if (!frameDim.x || !frameDim.y)
                return uint64_t(0);
            gfx::ITextureResource::Desc desc = {};
            desc.type = gfx::IResource::Type::Texture2D;
            desc.size = {int(frameDim.x), int(frameDim.y), 1};
            desc.arraySize = desc.numMipLevels = desc.sampleDesc.numSamples = 1;
            desc.format = format;
            desc.memoryType = gfx::MemoryType::DeviceLocal;
            desc.defaultState = gfx::ResourceState::General;
            desc.allowedStates = gfx::ResourceStateSet(gfx::ResourceState::General);
            for (auto state :
                 {gfx::ResourceState::ShaderResource,
                  gfx::ResourceState::UnorderedAccess,
                  gfx::ResourceState::CopySource,
                  gfx::ResourceState::CopyDestination})
                desc.allowedStates.add(state);
            size_t bytes = 0, alignment = 0;
            FALCOR_GFX_CALL(mpDevice->getGfxDevice()->getTextureAllocationInfo(desc, &bytes, &alignment));
            return uint64_t(bytes);
        };
        mView.allocationBytes = 3 * textureBytes(gfx::Format::R32G32B32A32_FLOAT) + 2 * textureBytes(gfx::Format::R32G32B32A32_UINT);
    }
}

void Manager::ensureGridResources()
{
    const uint32_t cells = cellCapacity();
    if (!mGrid.pBoundMin)
    {
        mGrid.pBoundMin = mpDevice->createStructuredBuffer(16, cells);
        mGrid.pBoundMax = mpDevice->createStructuredBuffer(16, cells);
        mProposal.pInverse = mpDevice->createStructuredBuffer(4, cells);
        mGrid.pCellKeys = mpDevice->createStructuredBuffer(16, cells);
        mGrid.pHash = mpDevice->createStructuredBuffer(4, getHashCapacity());
        mProposal.pState = mpDevice->createStructuredBuffer(4, 32);
        mProposal.pWorkArgs = mpDevice->createStructuredBuffer(4, 256);
        mProposal.pWorkDispatch = mpDevice->createStructuredBuffer(
            4, 256, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg
        );
        mGrid.pGridState = mpDevice->createStructuredBuffer(4, 16);
        mGrid.pCellLifetime = mpDevice->createStructuredBuffer(16, cells);
        mGrid.pFreeCells = mpDevice->createStructuredBuffer(4, cells);
        mGrid.pRetiredCells = mpDevice->createStructuredBuffer(4, cells);
        mGrid.pPendingHash = mpDevice->createStructuredBuffer(4, getHashCapacity());
        mGrid.pGridClear = createPass("RTPTVXPGIncremental.cs.slang", "clearGrid");
        mGrid.pGridBegin = createPass("RTPTVXPGIncremental.cs.slang", "beginGrid");
        mGrid.pGridEvict = createPass("RTPTVXPGIncremental.cs.slang", "evictGrid");
        mGrid.pGridDiscover = createPass("RTPTVXPGIncremental.cs.slang", "discover");
        mGrid.pGridInsert = createPass("RTPTVXPGIncremental.cs.slang", "insertGrid");
        mGrid.pGridReplay = createPass("RTPTVXPGIncremental.cs.slang", "replay");
        mGrid.pGridRetire = createPass("RTPTVXPGIncremental.cs.slang", "retire");
    }
}

void Manager::ensureObservationResources()
{
    const uint32_t records = uint32_t(getDiscoveryRecordCount());
    const uint32_t pending = uint32_t(std::min<uint64_t>(discoveryRequestCount(), getHashCapacity()));
    if (!mGrid.pDiscovery || mGrid.pDiscovery->getElementCount() != records)
        mGrid.pDiscovery = mpDevice->createStructuredBuffer(48, records);
    if (!mGrid.pPendingSlots || mGrid.pPendingSlots->getElementCount() != pending)
        mGrid.pPendingSlots = mpDevice->createStructuredBuffer(4, pending);
}

void Manager::ensureLightingResources(RenderContext* context)
{
    const uint32_t cells = cellCapacity();
    if (!mLighting.pFlux || mProposal.allocatedCapacity != mSettings.maxVoxels || any(mView.allocatedFrameDim != mFrameDim))
    {
        mLighting.pClearFrame = mView.pPrimary = mProposal.pGlobalLeaves = mProposal.pGlobalLevel = mProposal.pPublish = nullptr;
        resetClusterPasses();
        mProposal.pForest = nullptr;
        mLighting.pFlux = mpDevice->createStructuredBuffer(sizeof(uint64_t), cells);
        mLighting.pCount = mpDevice->createStructuredBuffer(sizeof(uint32_t), cells);
        mProposal.pCellMass = mProposal.pTreeState = mProposal.pDirtyLeaves = mProposal.pDirtyNodes = mProposal.pLocalArgs =
            mProposal.pLocalDispatch = nullptr;
        mDistributionValid = false;
        mProposal.pQueryStats = mpDevice->createStructuredBuffer(4, 8);
        mLighting.pHistoryStats = mpDevice->createStructuredBuffer(4, 8);
        context->clearUAV(mLighting.pHistoryStats->getUAV().get(), uint4(0));
        mLighting.pHistory = nullptr;
        mResetHistory = true;
        mLighting.pRepresentativePosition = mpDevice->createStructuredBuffer(sizeof(float4), cells);
        mLighting.pRepresentativeNormal = mpDevice->createStructuredBuffer(sizeof(float4), cells);
        mProposal.pCompactIndices = mpDevice->createStructuredBuffer(sizeof(uint32_t), mSettings.maxVoxels);
        mProposal.pMass = mpDevice->createStructuredBuffer(sizeof(float), mSettings.maxVoxels);
        mProposal.leafCapacity = 1;
        while (mProposal.leafCapacity < mSettings.maxVoxels)
            mProposal.leafCapacity *= 2;
        mProposal.pGlobalTree = mpDevice->createStructuredBuffer(sizeof(float), 2 * mProposal.leafCapacity);
        mView.pPrimaryPosition = mpDevice->createTexture2D(
            mFrameDim.x,
            mFrameDim.y,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mView.pPrimaryNormal = mpDevice->createTexture2D(
            mFrameDim.x,
            mFrameDim.y,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mView.pPrimaryHit = mpDevice->createTexture2D(
            mFrameDim.x,
            mFrameDim.y,
            ResourceFormat::RGBA32Uint,
            1,
            1,
            nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mView.allocatedFrameDim = mFrameDim;
        mProposal.allocatedCapacity = mSettings.maxVoxels;
    }
    if (!mpSampleGenerator)
        mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    if (!mLighting.pHistory)
    {
        mLighting.pHistory = mpDevice->createStructuredBuffer(16, cells);
        mResetHistory = true;
    }
    // A grid reset may already have reduced the occupied span to zero. Clear the
    // complete history allocation before taking the previous-frame snapshot so
    // newly reused cell IDs cannot inherit a different cell's stale history.
    if (mLighting.pHistory && mResetHistory)
        context->clearUAV(mLighting.pHistory->getUAV().get(), uint4(0));
    if (!mLighting.pHistoryPrevious)
    {
        mLighting.pHistoryPrevious = mpDevice->createStructuredBuffer(16, cells);
        mLighting.pNormalPrevious = mpDevice->createStructuredBuffer(16, cells);
    }
    if (!mProposal.pTreeState)
    {
        const uint32_t zero[16] = {};
        mProposal.pTreeState = mpDevice->createStructuredBuffer(
            4, 16, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, zero
        );
        mProposal.pCellMass = mpDevice->createStructuredBuffer(4, cells);
        mProposal.pDirtyLeaves = mpDevice->createStructuredBuffer(4, mSettings.maxVoxels);
        mProposal.pDirtyNodes = mpDevice->createStructuredBuffer(4, 2 * mProposal.leafCapacity + 4 * mSettings.maxVoxels + 64);
        context->clearUAV(mProposal.pDirtyNodes->getUAV().get(), uint4(0));
        mProposal.pLocalArgs = mpDevice->createStructuredBuffer(4, 3);
        mProposal.pLocalDispatch = mpDevice->createStructuredBuffer(
            4, 3, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg
        );
        mDistributionValid = false;
    }
    if (!mLighting.pClearFrame)
    {
        mLighting.pClearFrame = createPass("RTPTVXPGPrepare.cs.slang", "clearFrame");
        mProposal.pGlobalLeaves = createPass("RTPTVXPGPrepare.cs.slang", "globalLeaves");
        mProposal.pGlobalLevel = createPass("RTPTVXPGPrepare.cs.slang", "globalLevel");
        mProposal.pPublish = createPass("RTPTVXPGPrepare.cs.slang", "publish");
        mProposal.pBeginLocal = createPass("RTPTVXPGLocal.cs.slang", "beginLocal");
        mProposal.pResolveLocal = createPass("RTPTVXPGLocal.cs.slang", "resolveLocal");
        mProposal.pSelectLocal = createPass("RTPTVXPGLocal.cs.slang", "selectLocal");
        mProposal.pCompactLocal = createPass("RTPTVXPGLocal.cs.slang", "compactLocal");
        mProposal.pLocalWork = createPass("RTPTVXPGLocal.cs.slang", "localWork");
        mProposal.pLocalLeaves = createPass("RTPTVXPGLocal.cs.slang", "localLeaves");
        mProposal.pLocalLevel = createPass("RTPTVXPGLocal.cs.slang", "localLevel");
        mProposal.pGeometryWork = createPass("RTPTVXPGPrepare.cs.slang", "geometryWork");
        mProposal.pActiveWork = createPass("RTPTVXPGPrepare.cs.slang", "activeWork");
        mProposal.pForestWork = createPass("RTPTVXPGPrepare.cs.slang", "forestWork");
    }
    if (!mView.pPrimary)
        mView.pPrimary = createPass("RTPTVXPGPrimary.cs.slang", "main", PassScene::SceneAndSampler, PassCounters::Configured);
}

void Manager::ensureVisibilityResources(uint32_t rows)
{
    if (!mProposal.pForest || mView.allocatedSuperpixelSize != mSettings.superpixelSize)
    {
        resetClusterPasses();
        mView.pRowPosition = mpDevice->createStructuredBuffer(sizeof(float4), 128);
        mView.pRowNormal = mpDevice->createStructuredBuffer(sizeof(float4), 128);
        mProposal.pVisibility = mpDevice->createStructuredBuffer(sizeof(uint4), mSettings.maxVoxels);
        mProposal.pSeeds = mpDevice->createStructuredBuffer(32, 32);
        mProposal.pCluster = mpDevice->createStructuredBuffer(4, mSettings.maxVoxels);
        mProposal.pClusterInfo = mpDevice->createStructuredBuffer(sizeof(uint4), 32);
        mProposal.pForest = mpDevice->createStructuredBuffer(32, 4 * mSettings.maxVoxels + 64);
        mProposal.pCompactToLeaf = mpDevice->createStructuredBuffer(4, mSettings.maxVoxels);
        mView.pSuperpixelPosition = mpDevice->createStructuredBuffer(sizeof(float4), rows);
        mView.pSuperpixelNormal = mpDevice->createStructuredBuffer(sizeof(float4), rows);
        mView.pTopTree = mpDevice->createStructuredBuffer(sizeof(float), rows * 64);
        mView.pSuperpixelCount = mpDevice->createStructuredBuffer(4, rows);
        mView.pSuperpixelRange = mpDevice->createStructuredBuffer(8, rows);
        mView.pSuperpixelBlocks = mpDevice->createStructuredBuffer(4, (rows + 255) / 256);
        mView.pSuperpixelPoints = mpDevice->createStructuredBuffer(4, mFrameDim.x * mFrameDim.y);
        const std::array<uint32_t, 8> zero = {};
        mProposal.pClusterState = mpDevice->createStructuredBuffer(
            4, 8, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, zero.data()
        );
        mProposal.pClusterArgs = mpDevice->createStructuredBuffer(
            4, 3, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg
        );
        mProposal.pSortA = mpDevice->createStructuredBuffer(sizeof(uint2), mProposal.leafCapacity);
        mProposal.pSortB = mpDevice->createStructuredBuffer(sizeof(uint2), mProposal.leafCapacity);
        mProposal.pHistogram = mpDevice->createStructuredBuffer(4, mProposal.leafCapacity);
        mProposal.pBinOffsets = mpDevice->createStructuredBuffer(4, 256);
        mView.pFuzzyIds = mpDevice->createTexture2D(
            mFrameDim.x,
            mFrameDim.y,
            ResourceFormat::RGBA32Uint,
            1,
            1,
            nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mView.pFuzzyWeights = mpDevice->createTexture2D(
            mFrameDim.x,
            mFrameDim.y,
            ResourceFormat::RGBA32Float,
            1,
            1,
            nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
        mView.allocatedSuperpixelSize = mSettings.superpixelSize;
    }
    if (!mProposal.pPrepareClusters)
    {
        const char* visibility = "RTPTVXPGVisibility.cs.slang";
        const char* tree = "RTPTVXPGTree.cs.slang";
        mProposal.pPrepareClusters = createPass(visibility, "prepareClusterArgs", PassScene::SceneAndSampler, PassCounters::Configured);
        mProposal.pRows = createPass(visibility, "representativeRows", PassScene::SceneAndSampler, PassCounters::Configured);
        mProposal.pRowVisibility = createPass(visibility, "rowVisibility", PassScene::SceneAndSampler, PassCounters::Configured);
        mProposal.pSeedsPass = createPass(visibility, "seedClusters", PassScene::SceneAndSampler, PassCounters::Configured);
        mProposal.pAssignClusters = createPass(visibility, "assignClusters", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pCenters = createPass(visibility, "superpixelCenters", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pAssociate = createPass(visibility, "associateSuperpixels", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pSuperpixelPrefix = createPass(visibility, "prefixSuperpixels", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pSuperpixelBlockPrefix =
            createPass(visibility, "prefixSuperpixelBlocks", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pSuperpixelRanges = createPass(visibility, "finalizeSuperpixelRanges", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pSuperpixelScatter = createPass(visibility, "scatterSuperpixelPoints", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pTopLeaves = createPass(visibility, "topLevelLeaves", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pTopParents = createPass(visibility, "topLevelParents", PassScene::SceneAndSampler, PassCounters::Configured);
        mView.pDistributionDebug =
            createPass("RTPTVXPGDebug.cs.slang", "debugDistribution", PassScene::SceneAndSampler, PassCounters::Configured);
        mProposal.pEncode = createPass(tree, "encodeVoxels", PassScene::None, PassCounters::Configured);
        mProposal.pHistogramPass = createPass(tree, "radixHistogram", PassScene::None, PassCounters::Configured);
        mProposal.pPrefixPass = createPass(tree, "radixPrefix", PassScene::None, PassCounters::Configured);
        mProposal.pScatter = createPass(tree, "radixScatter", PassScene::None, PassCounters::Configured);
        mProposal.pAllocateForest = createPass(tree, "allocateForest", PassScene::None, PassCounters::Configured);
        mProposal.pInitializeForest = createPass(tree, "initializeForest", PassScene::None, PassCounters::Configured);
        mProposal.pForestLeaves = createPass(tree, "forestLeaves", PassScene::None, PassCounters::Configured);
        mProposal.pForestLevel = createPass(tree, "forestLevel", PassScene::None, PassCounters::Configured);
        mProposal.pPublishClusters = createPass(tree, "publishClusters", PassScene::None, PassCounters::Configured);
    }
}
} // namespace RTPTVXPG
