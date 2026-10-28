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

uint64_t Manager::getDiscoveryRecordCount() const
{
    const uint32_t stride = mSharedTrainingStride;
    return uint64_t((mFrameDim.x + stride - 1) / stride) * ((mFrameDim.y + stride - 1) / stride) * mSharedTrainingBounces;
}

uint64_t Manager::primaryDiscoveryCount() const
{
    const uint32_t stride = mSettings.discoveryStride;
    return uint64_t((mFrameDim.x + stride - 1) / stride) * ((mFrameDim.y + stride - 1) / stride);
}

uint2 Manager::superpixelDimensions() const
{
    return (mFrameDim + mSettings.superpixelSize - 1u) / mSettings.superpixelSize;
}

Manager::ResourceDimensions Manager::getResourceDimensions() const
{
    ResourceDimensions dimensions = {};
    dimensions.cells = cellCapacity();
    dimensions.hashSlots = getHashCapacity();
    dimensions.activeVoxels = mSettings.maxVoxels;
    dimensions.leafCapacity = 1;
    while (dimensions.leafCapacity < dimensions.activeVoxels)
        dimensions.leafCapacity *= 2;
    dimensions.forestNodes = 4 * dimensions.activeVoxels + 64;
    dimensions.dirtyNodes = 2 * dimensions.leafCapacity + dimensions.forestNodes;
    dimensions.frameDim = mFrameDim;
    dimensions.superpixelDim = superpixelDimensions();
    dimensions.pixels = uint64_t(mFrameDim.x) * mFrameDim.y;
    dimensions.superpixelRows = uint64_t(dimensions.superpixelDim.x) * dimensions.superpixelDim.y;
    dimensions.discoveryRecords = getDiscoveryRecordCount();
    dimensions.pendingSlots = std::min<uint64_t>(discoveryRequestCount(), dimensions.hashSlots);
    return dimensions;
}

uint64_t Manager::estimateModelBytes() const
{
    const auto dimensions = getResourceDimensions();
    const uint64_t cells = dimensions.cells;
    // Preserve the conservative estimate, including driver padding and safety margin.
    const uint64_t gridExtra = cells * 44ull + uint64_t(dimensions.hashSlots) * 8ull + dimensions.discoveryRecords * 48ull +
                               dimensions.pendingSlots * 4ull + 64ull;
    const uint64_t localExtra = cells * 4ull + uint64_t(dimensions.activeVoxels) * 36ull + 344ull;
    const uint64_t historySnapshots = cells * 32ull;
    return historySnapshots + gridExtra + localExtra + cells * 96ull + 16ull + uint64_t(dimensions.activeVoxels) * 216ull +
           dimensions.superpixelRows * 304ull + mView.allocationBytes + dimensions.pixels * 4ull + (2ull << 20);
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

void Manager::ViewResources::release()
{
    // This is a cached driver estimate, not a GPU allocation. configure() still
    // compares against the old frame size before updating the requested layout.
    const uint64_t screenAllocationBytes = allocationBytes;
    *this = {};
    allocationBytes = screenAllocationBytes;
}

void Manager::releaseModelResources()
{
    // invalidate(Resources) owns validity/history; each group releases all of
    // its buffers, textures, passes and allocated-layout metadata together.
    mGrid.release();
    mLighting.release();
    mProposal.release();
    mView.release();
}

void Manager::resetTrainingPasses()
{
    mLighting.pClearFrame = mView.pPrimary = mProposal.pGlobalLeaves = mProposal.pGlobalLevel = mProposal.pPublish = nullptr;
}

void Manager::resetScenePasses()
{
    mView.pDebug = nullptr;
    resetTrainingPasses();
    resetClusterPasses();
}

void Manager::bindTraining(const ShaderVar& root, bool writeObservations) const
{
    bindParameters(root, mLightingFrameIndex, writeObservations);
    bindResources(root);
}

void Manager::bindRendering(const ShaderVar& root, uint32_t sampleOffset, bool useSubmittedModel) const
{
    // Keep the existing GPU field/layout: rendering supplies the sample offset,
    // while training/build kernels supply the lighting frame index.
    bindParameters(root, sampleOffset, useSubmittedModel);
    bindResources(root);
}

void Manager::bindParameters(const ShaderVar& root, uint32_t frameIndex, bool active) const
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
        parameters["superpixelDim"] = superpixelDimensions();
    }
}

namespace
{
struct ResourceBinder
{
    const ShaderVar& root;

    template<typename T>
    void operator()(const char* name, const ref<T>& resource) const
    {
        if (!name)
            return;
        auto member = root.findMember(name);
        if (member.isValid())
            member = resource;
    }
};

struct ResourcePayloadCounter
{
    uint64_t bytes = 0;

    void operator()(const char*, const ref<Buffer>& buffer)
    {
        if (buffer)
            bytes += buffer->getSize();
    }

    void operator()(const char*, const ref<Texture>& texture)
    {
        if (texture)
            bytes += texture->getTextureSizeInBytes();
    }
};
} // namespace

// Each group lists its owned buffers/textures once for binding and accounting.
// A null name includes an allocation in payload bytes without a common binding:
// indirect dispatch copies and stage-specific scratch retain their existing uses.
template<typename Visitor>
void Manager::GridResources::forEachResource(Visitor&& visit) const
{
    visit("gVXPGBoundMin", pBoundMin);
    visit("gVXPGBoundMax", pBoundMax);
    visit("gVXPGHashSlots", pHash);
    visit("gVXPGCellKeys", pCellKeys);
    visit("gVXPGGridState", pGridState);
    visit("gVXPGCellLifetime", pCellLifetime);
    visit("gVXPGFreeCells", pFreeCells);
    visit("gVXPGRetiredCells", pRetiredCells);
    visit("gVXPGDiscovery", pDiscovery);
    visit("gVXPGPendingHash", pPendingHash);
    visit("gVXPGPendingSlots", pPendingSlots);
}

void Manager::GridResources::bind(const ShaderVar& root) const
{
    forEachResource(ResourceBinder{root});
}

uint64_t Manager::GridResources::getPayloadBytes() const
{
    ResourcePayloadCounter counter;
    forEachResource(counter);
    return counter.bytes;
}

template<typename Visitor>
void Manager::LightingResources::forEachResource(Visitor&& visit) const
{
    visit("gVXPGFlux", pFlux);
    visit("gVXPGCount", pCount);
    visit("gVXPGRepresentativePosition", pRepresentativePosition);
    visit("gVXPGRepresentativeNormal", pRepresentativeNormal);
    visit("gVXPGHistory", pHistory);
    visit("gVXPGHistoryStats", pHistoryStats);
    visit("gVXPGHistoryPrevious", pHistoryPrevious);
    visit("gVXPGNormalPrevious", pNormalPrevious);
}

void Manager::LightingResources::bind(const ShaderVar& root) const
{
    forEachResource(ResourceBinder{root});
}

uint64_t Manager::LightingResources::getPayloadBytes() const
{
    ResourcePayloadCounter counter;
    forEachResource(counter);
    return counter.bytes;
}

template<typename Visitor>
void Manager::ProposalResources::forEachResource(Visitor&& visit) const
{
    visit("gVXPGState", pState);
    visit("gVXPGInverse", pInverse);
    visit("gVXPGWorkArgs", pWorkArgs);
    visit(nullptr, pWorkDispatch);
    visit("gVXPGCompact", pCompactIndices);
    visit("gVXPGMass", pMass);
    visit("gVXPGGlobalTree", pGlobalTree);
    visit("gVXPGQueryStats", pQueryStats);
    visit("gVXPGCellMass", pCellMass);
    visit("gVXPGTreeState", pTreeState);
    visit("gVXPGDirtyLeaves", pDirtyLeaves);
    visit("gVXPGDirtyNodes", pDirtyNodes);
    visit("gVXPGLocalArgs", pLocalArgs);
    visit(nullptr, pLocalDispatch);
    visit("gVXPGVisibility", pVisibility);
    visit("gVXPGSeeds", pSeeds);
    visit("gVXPGCluster", pCluster);
    visit("gVXPGClusterInfo", pClusterInfo);
    visit("gVXPGForest", pForest);
    visit("gVXPGCompactToLeaf", pCompactToLeaf);
    visit("gVXPGClusterState", pClusterState);
    visit("gVXPGClusterArgs", pClusterArgs);
    visit(nullptr, pSortA);
    visit(nullptr, pSortB);
    visit(nullptr, pHistogram);
    visit(nullptr, pBinOffsets);
}

void Manager::ProposalResources::bind(const ShaderVar& root) const
{
    forEachResource(ResourceBinder{root});
}

uint64_t Manager::ProposalResources::getPayloadBytes() const
{
    ResourcePayloadCounter counter;
    forEachResource(counter);
    return counter.bytes;
}

template<typename Visitor>
void Manager::ViewResources::forEachResource(Visitor&& visit) const
{
    visit("gVXPGPrimaryPosition", pPrimaryPosition);
    visit("gVXPGPrimaryNormal", pPrimaryNormal);
    visit("gVXPGPrimaryHit", pPrimaryHit);
    visit("gVXPGRowPosition", pRowPosition);
    visit("gVXPGRowNormal", pRowNormal);
    visit("gVXPGSuperpixelPosition", pSuperpixelPosition);
    visit("gVXPGSuperpixelNormal", pSuperpixelNormal);
    visit("gVXPGTopTree", pTopTree);
    visit("gVXPGFuzzyIds", pFuzzyIds);
    visit("gVXPGFuzzyWeights", pFuzzyWeights);
    visit("gVXPGSuperpixelCount", pSuperpixelCount);
    visit("gVXPGSuperpixelRange", pSuperpixelRange);
    visit("gVXPGSuperpixelBlocks", pSuperpixelBlocks);
    visit("gVXPGSuperpixelPoints", pSuperpixelPoints);
}

void Manager::ViewResources::bind(const ShaderVar& root) const
{
    forEachResource(ResourceBinder{root});
}

uint64_t Manager::ViewResources::getPayloadBytes() const
{
    ResourcePayloadCounter counter;
    forEachResource(counter);
    return counter.bytes;
}

void Manager::bindResources(const ShaderVar& root) const
{
    mGrid.bind(root);
    mLighting.bind(root);
    mProposal.bind(root);
    mView.bind(root);
}

uint64_t Manager::getPayloadBytes() const
{
    return mGrid.getPayloadBytes() + mLighting.getPayloadBytes() + mProposal.getPayloadBytes() + mView.getPayloadBytes();
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

void Manager::createGridBuffers(const ResourceDimensions& dimensions)
{
    mGrid.pBoundMin = mpDevice->createStructuredBuffer(16, dimensions.cells);
    mGrid.pBoundMax = mpDevice->createStructuredBuffer(16, dimensions.cells);
    mGrid.pCellKeys = mpDevice->createStructuredBuffer(16, dimensions.cells);
    mGrid.pHash = mpDevice->createStructuredBuffer(4, dimensions.hashSlots);
    mGrid.pGridState = mpDevice->createStructuredBuffer(RTPT_VXPG_WORD_BYTES, RTPT_VXPG_GRID_WORDS);
    mGrid.pCellLifetime = mpDevice->createStructuredBuffer(16, dimensions.cells);
    mGrid.pFreeCells = mpDevice->createStructuredBuffer(4, dimensions.cells);
    mGrid.pRetiredCells = mpDevice->createStructuredBuffer(4, dimensions.cells);
    mGrid.pPendingHash = mpDevice->createStructuredBuffer(4, dimensions.hashSlots);
}

void Manager::createProposalGridBuffers(const ResourceDimensions& dimensions)
{
    mProposal.pInverse = mpDevice->createStructuredBuffer(4, dimensions.cells);
    mProposal.pState = mpDevice->createStructuredBuffer(RTPT_VXPG_WORD_BYTES, RTPT_VXPG_STATE_WORDS);
    mProposal.pWorkArgs = mpDevice->createStructuredBuffer(RTPT_VXPG_WORD_BYTES, RTPT_VXPG_WORK_WORDS);
    mProposal.pWorkDispatch = mpDevice->createStructuredBuffer(
        RTPT_VXPG_WORD_BYTES,
        RTPT_VXPG_WORK_WORDS,
        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg
    );
}

void Manager::createGridPasses()
{
    mGrid.pGridClear = createPass("RTPTVXPGIncremental.cs.slang", "clearGrid");
    mGrid.pGridBegin = createPass("RTPTVXPGIncremental.cs.slang", "beginGrid");
    mGrid.pGridEvict = createPass("RTPTVXPGIncremental.cs.slang", "evictGrid");
    mGrid.pGridDiscover = createPass("RTPTVXPGIncremental.cs.slang", "discover");
    mGrid.pGridInsert = createPass("RTPTVXPGIncremental.cs.slang", "insertGrid");
    mGrid.pGridReplay = createPass("RTPTVXPGIncremental.cs.slang", "replay");
    mGrid.pGridRetire = createPass("RTPTVXPGIncremental.cs.slang", "retire");
}

void Manager::ensureGridResources()
{
    if (!mGrid.pBoundMin)
    {
        const auto dimensions = getResourceDimensions();
        createGridBuffers(dimensions);
        createProposalGridBuffers(dimensions);
        createGridPasses();
    }
}

void Manager::ensureObservationResources()
{
    const auto dimensions = getResourceDimensions();
    const uint32_t records = uint32_t(dimensions.discoveryRecords);
    const uint32_t pending = uint32_t(dimensions.pendingSlots);
    if (!mGrid.pDiscovery || mGrid.pDiscovery->getElementCount() != records)
        mGrid.pDiscovery = mpDevice->createStructuredBuffer(48, records);
    if (!mGrid.pPendingSlots || mGrid.pPendingSlots->getElementCount() != pending)
        mGrid.pPendingSlots = mpDevice->createStructuredBuffer(4, pending);
}

void Manager::createLightingBuffers(RenderContext* context, const ResourceDimensions& dimensions)
{
    mLighting.pFlux = mpDevice->createStructuredBuffer(sizeof(uint64_t), dimensions.cells);
    mLighting.pCount = mpDevice->createStructuredBuffer(sizeof(uint32_t), dimensions.cells);
    mLighting.pHistoryStats = mpDevice->createStructuredBuffer(RTPT_VXPG_WORD_BYTES, RTPT_VXPG_HISTORY_WORDS);
    context->clearUAV(mLighting.pHistoryStats->getUAV().get(), uint4(0));
    mLighting.pHistory = nullptr;
    mLighting.pRepresentativePosition = mpDevice->createStructuredBuffer(sizeof(float4), dimensions.cells);
    mLighting.pRepresentativeNormal = mpDevice->createStructuredBuffer(sizeof(float4), dimensions.cells);
}

void Manager::createProposalBuffers(const ResourceDimensions& dimensions)
{
    mProposal.pCellMass = mProposal.pTreeState = mProposal.pDirtyLeaves = mProposal.pDirtyNodes = mProposal.pLocalArgs =
        mProposal.pLocalDispatch = nullptr;
    mProposal.pQueryStats = mpDevice->createStructuredBuffer(RTPT_VXPG_WORD_BYTES, RTPT_VXPG_QUERY_WORDS);
    mProposal.pCompactIndices = mpDevice->createStructuredBuffer(sizeof(uint32_t), dimensions.activeVoxels);
    mProposal.pMass = mpDevice->createStructuredBuffer(sizeof(float), dimensions.activeVoxels);
    mProposal.leafCapacity = dimensions.leafCapacity;
    mProposal.pGlobalTree = mpDevice->createStructuredBuffer(sizeof(float), 2 * dimensions.leafCapacity);
}

void Manager::createPrimaryTextures(const ResourceDimensions& dimensions)
{
    mView.pPrimaryPosition = mpDevice->createTexture2D(
        dimensions.frameDim.x,
        dimensions.frameDim.y,
        ResourceFormat::RGBA32Float,
        1,
        1,
        nullptr,
        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
    );
    mView.pPrimaryNormal = mpDevice->createTexture2D(
        dimensions.frameDim.x,
        dimensions.frameDim.y,
        ResourceFormat::RGBA32Float,
        1,
        1,
        nullptr,
        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
    );
    mView.pPrimaryHit = mpDevice->createTexture2D(
        dimensions.frameDim.x,
        dimensions.frameDim.y,
        ResourceFormat::RGBA32Uint,
        1,
        1,
        nullptr,
        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
    );
}

void Manager::ensureLightingHistory(RenderContext* context, const ResourceDimensions& dimensions)
{
    if (!mLighting.pHistory)
    {
        mLighting.pHistory = mpDevice->createStructuredBuffer(16, dimensions.cells);
        mResetHistory = true;
    }
    // A grid reset may already have reduced the occupied span to zero. Clear the
    // complete history allocation before taking the previous-frame snapshot so
    // newly reused cell IDs cannot inherit a different cell's stale history.
    if (mLighting.pHistory && mResetHistory)
        context->clearUAV(mLighting.pHistory->getUAV().get(), uint4(0));
    if (!mLighting.pHistoryPrevious)
    {
        mLighting.pHistoryPrevious = mpDevice->createStructuredBuffer(16, dimensions.cells);
        mLighting.pNormalPrevious = mpDevice->createStructuredBuffer(16, dimensions.cells);
    }
}

void Manager::ensureLocalTreeResources(RenderContext* context, const ResourceDimensions& dimensions)
{
    if (!mProposal.pTreeState)
    {
        const uint32_t zero[RTPT_VXPG_TREE_WORDS] = {};
        mProposal.pTreeState = mpDevice->createStructuredBuffer(
            RTPT_VXPG_WORD_BYTES,
            RTPT_VXPG_TREE_WORDS,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            MemoryType::DeviceLocal,
            zero
        );
        mProposal.pCellMass = mpDevice->createStructuredBuffer(4, dimensions.cells);
        mProposal.pDirtyLeaves = mpDevice->createStructuredBuffer(4, dimensions.activeVoxels);
        mProposal.pDirtyNodes = mpDevice->createStructuredBuffer(4, dimensions.dirtyNodes);
        context->clearUAV(mProposal.pDirtyNodes->getUAV().get(), uint4(0));
        mProposal.pLocalArgs = mpDevice->createStructuredBuffer(RTPT_VXPG_WORD_BYTES, RTPT_VXPG_DISPATCH_WORDS);
        mProposal.pLocalDispatch = mpDevice->createStructuredBuffer(
            RTPT_VXPG_WORD_BYTES,
            RTPT_VXPG_DISPATCH_WORDS,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg
        );
        mDistributionValid = false;
    }
}

void Manager::ensureTrainingPasses()
{
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
        mView.pPrimary = createPass("RTPTVXPGPrimary.cs.slang", "main", PassScene::None, PassCounters::Configured);
}

void Manager::ensureTrainingResources(RenderContext* context)
{
    const auto dimensions = getResourceDimensions();
    // Retain the existing coupled rebuild: a frame-size/active-capacity change
    // replaces lighting, proposal and primary-view allocations together.
    if (!mLighting.pFlux || mProposal.allocatedCapacity != dimensions.activeVoxels || any(mView.allocatedFrameDim != dimensions.frameDim))
    {
        resetTrainingPasses();
        resetClusterPasses();
        mProposal.pForest = nullptr; // Rebuild the dependent cluster/screen allocations on demand.
        createLightingBuffers(context, dimensions);
        createProposalBuffers(dimensions);
        createPrimaryTextures(dimensions);
        mDistributionValid = false;
        mResetHistory = true;
        mView.allocatedFrameDim = dimensions.frameDim;
        mProposal.allocatedCapacity = dimensions.activeVoxels;
    }
    if (!mpSampleGenerator)
        mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    ensureLightingHistory(context, dimensions);
    ensureLocalTreeResources(context, dimensions);
    ensureTrainingPasses();
}

void Manager::createClusterBuffers(const ResourceDimensions& dimensions)
{
    const std::array<uint32_t, RTPT_VXPG_CLUSTER_WORDS> zero = {};
    mProposal.pVisibility = mpDevice->createStructuredBuffer(sizeof(uint4), dimensions.activeVoxels);
    mProposal.pSeeds = mpDevice->createStructuredBuffer(32, 32);
    mProposal.pCluster = mpDevice->createStructuredBuffer(4, dimensions.activeVoxels);
    mProposal.pClusterInfo = mpDevice->createStructuredBuffer(sizeof(uint4), 32);
    mProposal.pForest = mpDevice->createStructuredBuffer(32, dimensions.forestNodes);
    mProposal.pCompactToLeaf = mpDevice->createStructuredBuffer(4, dimensions.activeVoxels);
    mProposal.pClusterState = mpDevice->createStructuredBuffer(
        RTPT_VXPG_WORD_BYTES,
        RTPT_VXPG_CLUSTER_WORDS,
        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
        MemoryType::DeviceLocal,
        zero.data()
    );
    mProposal.pClusterArgs = mpDevice->createStructuredBuffer(
        RTPT_VXPG_WORD_BYTES,
        RTPT_VXPG_DISPATCH_WORDS,
        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg
    );
    mProposal.pSortA = mpDevice->createStructuredBuffer(sizeof(uint2), dimensions.leafCapacity);
    mProposal.pSortB = mpDevice->createStructuredBuffer(sizeof(uint2), dimensions.leafCapacity);
    mProposal.pHistogram = mpDevice->createStructuredBuffer(4, dimensions.leafCapacity);
    mProposal.pBinOffsets = mpDevice->createStructuredBuffer(4, 256);
}

void Manager::createScreenBuffers(const ResourceDimensions& dimensions)
{
    const uint32_t rows = uint32_t(dimensions.superpixelRows);
    mView.pRowPosition = mpDevice->createStructuredBuffer(sizeof(float4), 128);
    mView.pRowNormal = mpDevice->createStructuredBuffer(sizeof(float4), 128);
    mView.pSuperpixelPosition = mpDevice->createStructuredBuffer(sizeof(float4), rows);
    mView.pSuperpixelNormal = mpDevice->createStructuredBuffer(sizeof(float4), rows);
    mView.pTopTree = mpDevice->createStructuredBuffer(sizeof(float), rows * 64);
    mView.pSuperpixelCount = mpDevice->createStructuredBuffer(4, rows);
    mView.pSuperpixelRange = mpDevice->createStructuredBuffer(8, rows);
    mView.pSuperpixelBlocks = mpDevice->createStructuredBuffer(4, (rows + 255) / 256);
    mView.pSuperpixelPoints = mpDevice->createStructuredBuffer(4, dimensions.frameDim.x * dimensions.frameDim.y);
    mView.pFuzzyIds = mpDevice->createTexture2D(
        dimensions.frameDim.x,
        dimensions.frameDim.y,
        ResourceFormat::RGBA32Uint,
        1,
        1,
        nullptr,
        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
    );
    mView.pFuzzyWeights = mpDevice->createTexture2D(
        dimensions.frameDim.x,
        dimensions.frameDim.y,
        ResourceFormat::RGBA32Float,
        1,
        1,
        nullptr,
        ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
    );
}

void Manager::createClusterPasses()
{
    const char* visibility = "RTPTVXPGVisibility.cs.slang";
    const char* tree = "RTPTVXPGTree.cs.slang";
    mProposal.pPrepareClusters = createPass(visibility, "prepareClusterArgs", PassScene::SceneAndSampler, PassCounters::Configured);
    mProposal.pRows = createPass(visibility, "representativeRows", PassScene::SceneAndSampler, PassCounters::Configured);
    mProposal.pRowVisibility = createPass(visibility, "rowVisibility", PassScene::SceneAndSampler, PassCounters::Configured);
    mProposal.pSeedsPass = createPass(visibility, "seedClusters", PassScene::SceneAndSampler, PassCounters::Configured);
    mProposal.pAssignClusters = createPass(visibility, "assignClusters", PassScene::SceneAndSampler, PassCounters::Configured);
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

void Manager::createScreenPasses()
{
    const char* visibility = "RTPTVXPGVisibility.cs.slang";
    mView.pCenters = createPass(visibility, "superpixelCenters", PassScene::SceneAndSampler, PassCounters::Configured);
    mView.pAssociate = createPass(visibility, "associateSuperpixels", PassScene::SceneAndSampler, PassCounters::Configured);
    mView.pSuperpixelPrefix = createPass(visibility, "prefixSuperpixels", PassScene::SceneAndSampler, PassCounters::Configured);
    mView.pSuperpixelBlockPrefix = createPass(visibility, "prefixSuperpixelBlocks", PassScene::SceneAndSampler, PassCounters::Configured);
    mView.pSuperpixelRanges = createPass(visibility, "finalizeSuperpixelRanges", PassScene::SceneAndSampler, PassCounters::Configured);
    mView.pSuperpixelScatter = createPass(visibility, "scatterSuperpixelPoints", PassScene::SceneAndSampler, PassCounters::Configured);
    mView.pTopLeaves = createPass(visibility, "topLevelLeaves", PassScene::SceneAndSampler, PassCounters::Configured);
    mView.pTopParents = createPass(visibility, "topLevelParents", PassScene::SceneAndSampler, PassCounters::Configured);
    mView.pDistributionDebug =
        createPass("RTPTVXPGDebug.cs.slang", "debugDistribution", PassScene::SceneAndSampler, PassCounters::Configured);
}

void Manager::ensureVisibilityResources(const ResourceDimensions& dimensions)
{
    // Cluster and screen data keep their existing shared rebuild trigger.
    if (!mProposal.pForest || mView.allocatedSuperpixelSize != mSettings.superpixelSize)
    {
        resetClusterPasses();
        createClusterBuffers(dimensions);
        createScreenBuffers(dimensions);
        mView.allocatedSuperpixelSize = mSettings.superpixelSize;
    }
    if (!mProposal.pPrepareClusters)
    {
        createClusterPasses();
        createScreenPasses();
    }
}
} // namespace RTPTVXPG
