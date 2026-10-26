#include "RTPTVXPG.h"
#include "Core/API/GFXAPI.h"
#include <cmath>
#include "Utils/Timing/Profiler.h"

using namespace Falcor;
namespace RTPTVXPG
{
void Manager::validate(const Settings& s)
{
    FALCOR_CHECK(s.discoveryStride>=1 && s.discoveryStride<=32 && s.spatialStaleFrames>=1 && s.spatialStaleFrames<=16384,"Invalid incremental grid stride or lifetime.");
    FALCOR_CHECK(s.treeRefreshFrames >= 1 && s.treeRefreshFrames <= 1024, "VXPG tree refresh interval must be in [1,1024].");
    FALCOR_CHECK(s.historyFrames >= 1 && s.historyFrames <= 1024 && s.historyStaleFrames >= 1 && s.historyStaleFrames <= 4096,
        "VXPG history frames must be in [1,1024] and lifetime in [1,4096].");
    FALCOR_CHECK(std::isfinite(s.lodSceneScale) && s.lodSceneScale > 0.f, "Invalid VXPG LOD scale.");
    FALCOR_CHECK(s.lodHashCapacity >= 256 && s.lodHashCapacity <= (1u << 22) && (s.lodHashCapacity & (s.lodHashCapacity - 1)) == 0, "Invalid VXPG hash capacity.");
    FALCOR_CHECK(s.lodGeometryCapacity >= 256 && s.lodGeometryCapacity <= (1u << 21) && s.lodGeometryCapacity <= s.lodHashCapacity, "Invalid VXPG geometry capacity.");
    FALCOR_CHECK(s.lodBudgetMiB >= 32 && s.lodBudgetMiB <= 2048, "Invalid VXPG budget.");
    FALCOR_CHECK(s.maxVoxels >= 256 && s.maxVoxels <= 262144, "VXPG active voxel capacity must be in [256,262144].");
    FALCOR_CHECK(s.clusterCount >= 1 && s.clusterCount <= 32, "VXPG cluster count must be in [1,32].");
    FALCOR_CHECK(s.superpixelSize >= 8 && s.superpixelSize <= 64, "VXPG superpixel size must be in [8,64].");
    FALCOR_CHECK(s.debugMode <= 4, "VXPG debug mode must be in [0,4].");
}

void Manager::configure(const Settings& settings, uint2 frameDim, uint32_t sharedStride, uint32_t sharedBounces)
{
    validate(settings);
    FALCOR_CHECK(sharedStride>=1 && sharedStride<=32 && sharedBounces>=1 && sharedBounces<=32,"Invalid shared training layout.");
    if(settings.spatialStaleFrames!=mSettings.spatialStaleFrames)invalidateDistribution("Spatial lifetime changed");
    if (settings.historyFrames != mSettings.historyFrames ||
        settings.historyStaleFrames != mSettings.historyStaleFrames || settings.enabled != mSettings.enabled ||
        sharedStride!=mSharedTrainingStride || sharedBounces!=mSharedTrainingBounces)
        resetLightingHistory();
    if (settings.treeRefreshFrames != mSettings.treeRefreshFrames)
        invalidateDistribution("Topology refresh interval changed");
    const bool layoutChanged = settings.discoveryStride != mSettings.discoveryStride ||
        settings.lodSceneScale != mSettings.lodSceneScale || settings.lodHashCapacity != mSettings.lodHashCapacity ||
        settings.lodGeometryCapacity != mSettings.lodGeometryCapacity || settings.lodBudgetMiB != mSettings.lodBudgetMiB;
    if (layoutChanged) { releaseModelResources(); invalidate(); }
    if (settings.detailedDiagnostics != mSettings.detailedDiagnostics)
    {
        // Change only instrumentation variants; published data and histories
        // remain usable, including a frozen proposal and its debug view.
        const char* enabled = settings.detailedDiagnostics ? "1" : "0";
        for (const auto& pass : {mpPrimary, mpRowVisibility, mpTopLeaves})
            if (pass) pass->addDefine("RTPT_VXPG_DETAILED_DIAGNOSTICS", enabled, true);
        invalidateDiagnosticSnapshot();
    }
    const bool structural = settings.maxVoxels != mSettings.maxVoxels ||
        settings.clusterCount != mSettings.clusterCount || settings.superpixelSize != mSettings.superpixelSize ||
        any(frameDim != mFrameDim);
    if (structural)
    {
        releaseModelResources();
        invalidate();
    }
    else if (settings.visibilityEnabled != mSettings.visibilityEnabled) invalidateDistribution();
    if (any(frameDim != mFrameDim) || mScreenAllocationBytes == 0)
    {
        // Query the same driver allocation descriptions as Texture uses, before
        // allocating. Pixel payload misses odd-size padding; arbitrary tile
        // rounding can instead reject a valid 1080p model under its budget.
        auto textureBytes = [&](gfx::Format format)
        {
            if (!frameDim.x || !frameDim.y) return uint64_t(0);
            gfx::ITextureResource::Desc desc = {};
            desc.type = gfx::IResource::Type::Texture2D;
            desc.size = {int(frameDim.x), int(frameDim.y), 1};
            desc.arraySize = desc.numMipLevels = desc.sampleDesc.numSamples = 1;
            desc.format = format;
            desc.memoryType = gfx::MemoryType::DeviceLocal;
            desc.defaultState = gfx::ResourceState::General;
            desc.allowedStates = gfx::ResourceStateSet(gfx::ResourceState::General);
            for (auto state : {gfx::ResourceState::ShaderResource, gfx::ResourceState::UnorderedAccess,
                gfx::ResourceState::CopySource, gfx::ResourceState::CopyDestination}) desc.allowedStates.add(state);
            size_t bytes = 0, alignment = 0;
            FALCOR_GFX_CALL(mpDevice->getGfxDevice()->getTextureAllocationInfo(desc, &bytes, &alignment));
            return uint64_t(bytes);
        };
        mScreenAllocationBytes = 3 * textureBytes(gfx::Format::R32G32B32A32_FLOAT) +
            2 * textureBytes(gfx::Format::R32G32B32A32_UINT);
    }
    mSettings = settings;
    mFrameDim = frameDim;
    mSharedTrainingStride = sharedStride;
    mSharedTrainingBounces = sharedBounces;
    mEstimatedBytes = estimateModelBytes();
    if (mEstimatedBytes > uint64_t(getBudgetMiB()) * 1024ull * 1024ull)
    {
        releaseModelResources();
        mFallbackReason = "Resource estimate exceeds VXPG budget";
    }
}

uint64_t Manager::primaryDiscoveryCount() const
{
    const uint32_t stride=mSettings.discoveryStride;
    return uint64_t((mFrameDim.x+stride-1)/stride)*((mFrameDim.y+stride-1)/stride);
}

uint64_t Manager::getDiscoveryRecordCount() const
{
    const uint32_t stride=mSharedTrainingStride;
    return uint64_t((mFrameDim.x+stride-1)/stride)*((mFrameDim.y+stride-1)/stride)*mSharedTrainingBounces;
}

std::array<uint32_t,32> Manager::readSharedObservationCounts() const
{
    std::array<uint32_t,32> counts={};
    if(!mpDiscovery || !hasModelDiagnostics())return counts;
    // Explicit statistics readback only; never part of frame scheduling.
    const uint32_t depth=mSharedTrainingBounces;
    std::vector<float4> records(size_t(getDiscoveryRecordCount())*3);
    mpDiscovery->getBlob(records.data(),0,records.size()*sizeof(float4));
    for(size_t i=0;i<records.size()/3;++i)if(records[i*3].w!=0.f)++counts[i%depth];
    return counts;
}

uint64_t Manager::estimateModelBytes() const
{
    const uint64_t cells = cellCapacity();
    const uint64_t superpixels = uint64_t((mFrameDim.x + mSettings.superpixelSize - 1) / mSettings.superpixelSize) *
        ((mFrameDim.y + mSettings.superpixelSize - 1) / mSettings.superpixelSize);
    // Conservative capacities for the persistent grid, local trees and screen data.
    const uint64_t pendingCount=std::min<uint64_t>(discoveryRequestCount(),getHashCapacity());
    const uint64_t gridExtra = cells * 44ull + uint64_t(getHashCapacity()) * 8ull +
        getDiscoveryRecordCount()*48ull + pendingCount*4ull + 64ull;
    const uint64_t localExtra = cells * 4ull + uint64_t(mSettings.maxVoxels) * 36ull + 344ull;
    const uint64_t historySnapshots = cells * 32ull;
    return historySnapshots + gridExtra + localExtra + cells * 96ull + 16ull +
        uint64_t(mSettings.maxVoxels) * 216ull + superpixels * 304ull + mScreenAllocationBytes +
        uint64_t(mFrameDim.x) * mFrameDim.y * 4ull + (2ull << 20);
}

void Manager::advanceGeneration(uint32_t& generation)
{
    if(generation==std::numeric_limits<uint32_t>::max())
    {
        // No queued consumer may retain the identity when it is reused.
        mpDevice->wait();
        generation=1;
    }
    else ++generation;
}

void Manager::invalidateDistribution(const std::string& reason)
{
    beginFrame();
    invalidateDiagnosticSnapshot();
    advanceGeneration(mGeneration);
    mReady = mDistributionValid = false;
    mFallbackReason = reason;
}

void Manager::cameraChanged()
{
    // Screen points and top weights refresh before publication. Frozen data
    // cannot refresh those view-dependent inputs and must fall back instead.
    if (mSettings.freezeUpdates) invalidateDistribution();
}

void Manager::invalidateLighting()
{
    resetLightingHistory();
    invalidateDistribution("Lighting configuration needs rebuilding");
    mpPrimary = nullptr;
}

void Manager::resetLightingHistory()
{
    mResetHistory = true;
    invalidateDistribution("Lighting history needs rebuilding");
}

std::array<uint32_t, 8> Manager::readHistoryCounters() const
{
    std::array<uint32_t, 8> result = {};
    if (mpHistoryStats && !mResetHistory) mpHistoryStats->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t,8> Manager::readQueryCounters() const
{
    std::array<uint32_t,8> result={};
    if(mSettings.detailedDiagnostics && mpQueryStats)mpQueryStats->getBlob(result.data(),0,sizeof(result));
    return result;
}

std::array<uint32_t,16> Manager::readGridCounters() const
{
    std::array<uint32_t,16> result={};
    if(mpGridState)mpGridState->getBlob(result.data(),0,sizeof(result));
    return result;
}

std::array<uint32_t, 16> Manager::readTreeCounters() const
{
    std::array<uint32_t, 16> result = {};
    if (mpTreeState && mDistributionValid) mpTreeState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

void Manager::resetClusterPasses()
{
    mpPrepareClusters = mpRows = mpRowVisibility = mpSeedsPass = mpAssignClusters = nullptr;
    mpCenters = mpAssociate = mpTopLeaves = mpTopParents = mpDistributionDebug = nullptr;
    mpSuperpixelPrefix=mpSuperpixelBlockPrefix=mpSuperpixelRanges=mpSuperpixelScatter=nullptr;
    mpEncode = mpHistogramPass = mpPrefixPass = mpScatter = mpAllocateForest = mpInitializeForest = nullptr;
    mpForestLeaves = mpForestLevel = mpPublishClusters = nullptr;
}

void Manager::releaseModelResources()
{
    beginFrame();
    invalidateDiagnosticSnapshot();
    mReady=mGeometryValid=mDistributionValid=false;
    mpDebug = nullptr;
    mpClearFrame=mpPrimary=mpGlobalLeaves=mpGlobalLevel=mpPublish=mpClearDiagnostics=nullptr;
    resetClusterPasses();
    mpBoundMin = mpBoundMax = mpState = mpInverse = nullptr;
    mpHash = mpCellKeys = mpWorkArgs = mpWorkDispatch = nullptr;
    mpHistoryPrevious=mpNormalPrevious=nullptr;
    mpGeometryWork=mpActiveWork=mpForestWork=nullptr;
    mpFlux=mpCount=mpCompactIndices=mpMass=mpGlobalTree=mpRepresentativePosition=mpRepresentativeNormal=nullptr;
    mpHistory = mpHistoryStats = mpQueryStats = nullptr;
    mpCellMass = mpTreeState = mpDirtyLeaves = mpDirtyNodes = mpLocalArgs = mpLocalDispatch = nullptr;
    mpGridState=mpCellLifetime=mpFreeCells=mpRetiredCells=mpDiscovery=mpPendingHash=mpPendingSlots=nullptr;
    mpGridClear=mpGridBegin=mpGridEvict=mpGridDiscover=mpGridInsert=mpGridReplay=mpGridRetire=nullptr;
    mpBeginLocal = mpResolveLocal = mpSelectLocal = mpCompactLocal = mpLocalWork = mpLocalLeaves = mpLocalLevel = nullptr;
    mResetHistory = true;
    mpRowPosition=mpRowNormal=mpVisibility=mpSeeds=mpCluster=mpClusterInfo=nullptr;
    mpForest=mpCompactToLeaf=mpSuperpixelPosition=mpSuperpixelNormal=mpTopTree=mpClusterState=mpClusterArgs=nullptr;
    mpSortA=mpSortB=mpHistogram=mpBinOffsets=nullptr;
    mpPrimaryPosition=mpPrimaryNormal=mpPrimaryHit=mpFuzzyIds=mpFuzzyWeights=nullptr;
    mpSuperpixelCount=mpSuperpixelRange=mpSuperpixelBlocks=mpSuperpixelPoints=nullptr;
    mAllocatedCapacity = mAllocatedSuperpixelSize = mLeafCapacity = 0;
    mAllocatedFrameDim=uint2(0);
}

void Manager::invalidate()
{
    mResetHistory = true;
    beginFrame();
    invalidateDiagnosticSnapshot();
    advanceGeneration(mGeneration);
    mReady = false;
    mGeometryValid = false;
    mDistributionValid = false;
    mLightingFrameIndex = 0;
    mFallbackReason = "Voxel proposal has not been built";
}

void Manager::setScene(const ref<Scene>& scene)
{
    mpScene = scene;
    mpDebug = nullptr;
    mpClearFrame = mpPrimary = mpGlobalLeaves = mpGlobalLevel = mpPublish = nullptr;
    resetClusterPasses();
    invalidate();
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
        parameters["globalLeafCapacity"] = mLeafCapacity;
        parameters["discoveryStride"]=mSettings.discoveryStride;
        parameters["spatialStaleFrames"]=mSettings.spatialStaleFrames;
        parameters["discoveryRecordCount"]=uint32_t(getDiscoveryRecordCount());
        parameters["sharedInjectionStride"]=mSharedTrainingStride;
        parameters["sharedInjectionBounces"]=mSharedTrainingBounces;
        parameters["activeCapacity"] = mSettings.maxVoxels;
        parameters["frameIndex"] = frameIndex;
        parameters["generation"] = mGeneration;
        parameters["enabled"] = active && mSettings.enabled ? 1u : 0u;
        parameters["useGuiding"] = mSettings.useGuiding ? 1u : 0u;
        parameters["pgUseCache"] = mSettings.pgUseCache ? 1u : 0u;
        parameters["visibilityEnabled"] = mSettings.visibilityEnabled ? 1u : 0u;
        parameters["debugEnabled"] = mSettings.debugEnabled ? 1u : 0u;
        parameters["debugMode"] = mSettings.debugMode;
        parameters["superpixelSize"] = mSettings.superpixelSize;
        parameters["clusterCount"] = mSettings.clusterCount;
        parameters["superpixelDim"] = (mFrameDim + mSettings.superpixelSize - 1u) / mSettings.superpixelSize;
    }
    auto buffer = [&](const char* name, const ref<Buffer>& value)
    {
        auto member = root.findMember(name);
        if (member.isValid()) member = value;
    };
    buffer("gVXPGBoundMin", mpBoundMin);
    buffer("gVXPGBoundMax", mpBoundMax);
    buffer("gVXPGState", mpState);
    buffer("gVXPGQueryStats",mpQueryStats);
    buffer("gVXPGInverse", mpInverse);
    buffer("gVXPGWorkArgs",mpWorkArgs);
    buffer("gVXPGHashSlots",mpHash);
    buffer("gVXPGCellKeys",mpCellKeys);
    buffer("gVXPGFlux", mpFlux);
    buffer("gVXPGCount", mpCount);
    buffer("gVXPGHistoryPrevious",mpHistoryPrevious);buffer("gVXPGNormalPrevious",mpNormalPrevious);

    buffer("gVXPGHistory", mpHistory);
    buffer("gVXPGHistoryStats", mpHistoryStats);
    buffer("gVXPGCellMass", mpCellMass);
    buffer("gVXPGTreeState", mpTreeState);
    buffer("gVXPGDirtyLeaves", mpDirtyLeaves);
    buffer("gVXPGDirtyNodes", mpDirtyNodes);
    buffer("gVXPGLocalArgs", mpLocalArgs);
    buffer("gVXPGGridState",mpGridState);buffer("gVXPGCellLifetime",mpCellLifetime);
    buffer("gVXPGFreeCells",mpFreeCells);buffer("gVXPGRetiredCells",mpRetiredCells);
    buffer("gVXPGDiscovery",mpDiscovery);buffer("gVXPGPendingHash",mpPendingHash);buffer("gVXPGPendingSlots",mpPendingSlots);

    buffer("gVXPGCompact", mpCompactIndices);
    buffer("gVXPGMass", mpMass);
    buffer("gVXPGGlobalTree", mpGlobalTree);
    buffer("gVXPGRepresentativePosition", mpRepresentativePosition);
    buffer("gVXPGRepresentativeNormal", mpRepresentativeNormal);
    buffer("gVXPGRowPosition", mpRowPosition);
    buffer("gVXPGRowNormal", mpRowNormal);
    buffer("gVXPGVisibility", mpVisibility);
    buffer("gVXPGSeeds", mpSeeds);
    buffer("gVXPGCluster", mpCluster);
    buffer("gVXPGClusterInfo", mpClusterInfo);

    buffer("gVXPGForest", mpForest);
    buffer("gVXPGCompactToLeaf", mpCompactToLeaf);
    buffer("gVXPGSuperpixelPosition", mpSuperpixelPosition);
    buffer("gVXPGSuperpixelNormal", mpSuperpixelNormal);
    buffer("gVXPGTopTree", mpTopTree);
    buffer("gVXPGClusterState", mpClusterState);
    buffer("gVXPGClusterArgs", mpClusterArgs);
    buffer("gVXPGSuperpixelCount",mpSuperpixelCount);
    buffer("gVXPGSuperpixelRange",mpSuperpixelRange);
    buffer("gVXPGSuperpixelBlocks",mpSuperpixelBlocks);
    buffer("gVXPGSuperpixelPoints",mpSuperpixelPoints);
    auto ids = root.findMember("gVXPGFuzzyIds");
    if (ids.isValid()) ids = mpFuzzyIds;
    auto weights = root.findMember("gVXPGFuzzyWeights");
    if (weights.isValid()) weights = mpFuzzyWeights;
    auto position = root.findMember("gVXPGPrimaryPosition");
    if (position.isValid()) position = mpPrimaryPosition;
    auto normal = root.findMember("gVXPGPrimaryNormal");
    if (normal.isValid()) normal = mpPrimaryNormal;
    auto hit=root.findMember("gVXPGPrimaryHit");
    if(hit.isValid())hit=mpPrimaryHit;
}

std::array<uint32_t, 8> Manager::readClusterCounters() const
{
    std::array<uint32_t, 8> result = {};
    if (mpClusterState) mpClusterState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

uint64_t Manager::getPayloadBytes() const
{
    uint64_t bytes=0;
    for (const auto& buffer : {mpWorkArgs,mpWorkDispatch,mpHash,mpCellKeys,mpBoundMin,mpBoundMax,mpState,mpInverse,
        mpGridState,mpCellLifetime,mpFreeCells,mpRetiredCells,mpDiscovery,mpPendingHash,mpPendingSlots,mpFlux,mpCount,mpHistory,mpHistoryStats,mpQueryStats,mpHistoryPrevious,mpNormalPrevious,mpCellMass,mpTreeState,mpDirtyLeaves,mpDirtyNodes,mpLocalArgs,mpLocalDispatch,mpCompactIndices,mpMass,mpGlobalTree,mpRepresentativePosition,mpRepresentativeNormal,
        mpRowPosition,mpRowNormal,mpVisibility,mpSeeds,mpCluster,mpClusterInfo,mpForest,mpCompactToLeaf,
        mpSuperpixelPosition,mpSuperpixelNormal,mpTopTree,mpClusterState,mpClusterArgs,mpSortA,mpSortB,mpHistogram,mpBinOffsets,
        mpSuperpixelCount,mpSuperpixelRange,mpSuperpixelBlocks,mpSuperpixelPoints})
        if (buffer) bytes+=buffer->getSize();
    for (const auto& texture : {mpPrimaryPosition,mpPrimaryNormal,mpPrimaryHit,mpFuzzyIds,mpFuzzyWeights})
        if (texture) bytes+=texture->getTextureSizeInBytes();
    return bytes;
}

std::array<uint32_t, 32> Manager::readCounters() const
{
    std::array<uint32_t, 32> result = {};
    if (mpState) mpState->getBlob(result.data(), 0, sizeof(result));
    return result;
}

std::array<uint32_t,128> Manager::readLodCounts(uint32_t geometryCount,uint32_t activeCount) const
{
    std::array<uint32_t,128> counts={};
    if(!mpCellKeys || !mpCompactIndices)return counts;
    geometryCount=std::min(geometryCount,cellCapacity());activeCount=std::min(activeCount,mSettings.maxVoxels);
    std::vector<int4> keys(geometryCount);std::vector<uint32_t> active(activeCount);
    std::vector<uint4> bounds;
    if(geometryCount)mpCellKeys->getBlob(keys.data(),0,keys.size()*sizeof(int4));
    if(geometryCount)
    {bounds.resize(geometryCount);mpBoundMin->getBlob(bounds.data(),0,bounds.size()*sizeof(uint4));}
    if(activeCount)mpCompactIndices->getBlob(active.data(),0,active.size()*sizeof(uint32_t));
    for(size_t i=0;i<keys.size();++i)
        if((bounds.empty() || bounds[i].w!=0) && keys[i].w>0 && keys[i].w<64)++counts[keys[i].w];
    for(auto cell:active)if(cell<keys.size() && keys[cell].w>0 && keys[cell].w<64)++counts[64+keys[cell].w];
    return counts;
}

void Manager::appendObservationStatistics(Properties& props,uint32_t geometryCount,uint32_t activeCount) const
{
    if(!hasModelDiagnostics() || !mpCount || !mpCompactIndices || !mpMass)return;
    const uint32_t cells = std::min(geometryCount, cellCapacity());
    activeCount=std::min(activeCount,mSettings.maxVoxels);
    if(!cells || !activeCount)return;
    // Explicit statistics read only; never invoked by normal render dispatch.
    std::vector<uint32_t> observations(cells),active(activeCount);
    std::vector<float> mass(activeCount);
    mpCount->getBlob(observations.data(),0,observations.size()*sizeof(uint32_t));
    mpCompactIndices->getBlob(active.data(),0,active.size()*sizeof(uint32_t));
    mpMass->getBlob(mass.data(),0,mass.size()*sizeof(float));
    std::vector<int4> keys;
    {keys.resize(cells);mpCellKeys->getBlob(keys.data(),0,keys.size()*sizeof(int4));}
    for(uint32_t level=0;level<64u;++level)
    {
        std::vector<uint32_t> counts;uint64_t total=0;uint32_t single=0,low=0;
        double totalMass=0.,lowMass=0.;
        for(uint32_t i=0;i<activeCount;++i)
        {
            const uint32_t cell=active[i];if(cell>=cells || (level!=0 && keys[cell].w!=int(level)))continue;
            const uint32_t n=observations[cell];counts.push_back(n);total+=n;
            single+=n==1;low+=n<=4;totalMass+=mass[i];if(n<=4)lowMass+=mass[i];
        }
        if(counts.empty())continue;
        std::sort(counts.begin(),counts.end());
        const std::string prefix=level==0?"observation":"lod"+std::to_string(level)+"Observation";
        props[prefix+"Count"]=total;
        props[prefix+"PerActive"]=double(total)/counts.size();
        props[prefix+"P10"]=counts[(counts.size()-1)/10];
        props[prefix+"Median"]=.5*(double(counts[(counts.size()-1)/2])+counts[counts.size()/2]);
        props[prefix+"SingleFraction"]=double(single)/counts.size();
        props[prefix+"LowCountFraction"]=double(low)/counts.size();
        props[prefix+"LowCountMassFraction"]=totalMass>0.?lowMass/totalMass:0.;
    }
}

void Manager::buildIncrementalGeometry(RenderContext* context)
{
    const float3 camera=mpScene->getCamera()->getPosition();
    if(any(camera!=mLodCamera))cameraChanged();
    if(mSettings.freezeUpdates)return;
    mLodCamera=camera;
    mEstimatedBytes=estimateModelBytes();
    if(mEstimatedBytes>uint64_t(getBudgetMiB())*1024ull*1024ull)
    {mGeometryValid=mReady=false;mFallbackReason="Incremental grid exceeds VXPG budget";return;}
    const auto* animation=mpScene->getAnimationController();
    if(animation && (animation->hasSkinnedMeshes() || animation->hasAnimatedMeshCaches()))
    {mGeometryValid=mReady=false;mFallbackReason="Skinned/vertex-cache geometry is not validated for VXPG";return;}
    if(mGeometryValid)return;
    FALCOR_PROFILE(context,"VXPGIncrementalGridReset");
    const uint32_t cells=cellCapacity();
    if(!mpBoundMin)
    {
        mpBoundMin=mpDevice->createStructuredBuffer(16,cells);mpBoundMax=mpDevice->createStructuredBuffer(16,cells);
        mpInverse=mpDevice->createStructuredBuffer(4,cells);mpCellKeys=mpDevice->createStructuredBuffer(16,cells);
        mpHash=mpDevice->createStructuredBuffer(4,getHashCapacity());mpState=mpDevice->createStructuredBuffer(4,32);
        mpWorkArgs=mpDevice->createStructuredBuffer(4,256);
        mpWorkDispatch=mpDevice->createStructuredBuffer(4,256,ResourceBindFlags::ShaderResource|ResourceBindFlags::UnorderedAccess|ResourceBindFlags::IndirectArg);
        mpGridState=mpDevice->createStructuredBuffer(4,16);mpCellLifetime=mpDevice->createStructuredBuffer(16,cells);
        mpFreeCells=mpDevice->createStructuredBuffer(4,cells);mpRetiredCells=mpDevice->createStructuredBuffer(4,cells);
        mpPendingHash=mpDevice->createStructuredBuffer(4,getHashCapacity());
        auto make=[&](const char* entry)
        {
            ProgramDesc desc;desc.addShaderLibrary("RenderPasses/RTPT/RTPTVXPGIncremental.cs.slang").csEntry(entry);desc.setShaderModel(ShaderModel::SM6_6);
            return ComputePass::create(mpDevice,desc,{},true);
        };
        mpGridClear=make("clearGrid");mpGridBegin=make("beginGrid");mpGridEvict=make("evictGrid");
        mpGridDiscover=make("discover");mpGridInsert=make("insertGrid");mpGridReplay=make("replay");mpGridRetire=make("retire");
    }
    mGridMin = float3(-1.e-4f);
    mCellSize = 2.f / mSettings.lodSceneScale;
    mLodLevels = 63u;
    for(const auto& b:{mpHash,mpState,mpBoundMin,mpBoundMax,mpInverse,mpCellKeys,mpCellLifetime,mpGridState})if(b)context->uavBarrier(b.get());
    bind(mpGridClear->getRootVar(),mLightingFrameIndex,true);
    mpGridClear->execute(context,uint3(std::max(cells,getHashCapacity()),1,1));
    for(const auto& b:{mpHash,mpState,mpBoundMin,mpBoundMax,mpInverse,mpCellKeys,mpCellLifetime,mpGridState})if(b)context->uavBarrier(b.get());
    mResetHistory=true;mDistributionValid=false;mGeometryValid=true;mReady=false;
    advanceGeneration(mGeometryGeneration);++mGeometryRebuilds;
}

void Manager::prepareIncrementalGrid(RenderContext* context)
{
    FALCOR_PROFILE(context,"VXPGIncrementalMaintenance");
    // Resize only observation scratch when training depth/stride changes. Keep
    // the persistent spatial map, including while its proposal is frozen.
    const uint32_t records=uint32_t(getDiscoveryRecordCount());
    const uint32_t pending=uint32_t(std::min<uint64_t>(discoveryRequestCount(),getHashCapacity()));
    if(!mpDiscovery || mpDiscovery->getElementCount()!=records)mpDiscovery=mpDevice->createStructuredBuffer(48,records);
    if(!mpPendingSlots || mpPendingSlots->getElementCount()!=pending)mpPendingSlots=mpDevice->createStructuredBuffer(4,pending);
    for(const auto& b:{mpPendingHash,mpDiscovery,mpGridState,mpCellLifetime,mpRetiredCells,mpHash,mpBoundMin})if(b)context->uavBarrier(b.get());
    bind(mpGridBegin->getRootVar(),mLightingFrameIndex,true);
    mpGridBegin->execute(context,uint3(std::max(records,getHashCapacity()),1,1));
    context->uavBarrier(mpGridState.get());context->uavBarrier(mpPendingHash.get());context->uavBarrier(mpDiscovery.get());
    bind(mpGridEvict->getRootVar(),mLightingFrameIndex,true);
    mpGridEvict->execute(context,uint3(cellCapacity(),1,1));
    for(const auto& b:{mpHash,mpBoundMin,mpGridState,mpRetiredCells,mpHistory})if(b)context->uavBarrier(b.get());
}

void Manager::finishIncrementalGrid(RenderContext* context)
{
    FALCOR_PROFILE(context,"VXPGIncrementalInsert");
    const uint32_t requests=uint32_t(discoveryRequestCount());
    auto barriers=[&]()
    {
        for(const auto& b:{mpHash,mpCellKeys,mpState,mpBoundMin,mpBoundMax,mpInverse,mpGridState,mpCellLifetime,
            mpFreeCells,mpPendingHash,mpPendingSlots,mpDiscovery,mpCount,mpFlux,mpHistory,mpRepresentativePosition,mpRepresentativeNormal})
            if(b)context->uavBarrier(b.get());
    };
    auto run=[&](const ref<ComputePass>& pass,uint32_t count)
    {bind(pass->getRootVar(),mLightingFrameIndex,true);pass->execute(context,uint3(count,1,1));barriers();};
    barriers();run(mpGridDiscover,requests);
    run(mpGridInsert,uint32_t(std::min<uint64_t>(requests,getHashCapacity())));
    run(mpGridReplay,uint32_t(getDiscoveryRecordCount()));
    bind(mpGeometryWork->getRootVar(),mLightingFrameIndex,true);
    mpGeometryWork->execute(context,uint3(1));context->uavBarrier(mpWorkArgs.get());
    context->copyResource(mpWorkDispatch.get(),mpWorkArgs.get());
}

void Manager::buildGeometry(RenderContext* context)
{
    if (!mpScene || !mSettings.enabled) return;
    buildIncrementalGeometry(context);
}

void Manager::prepareLighting(RenderContext* context)
{
    beginFrame();
    // Construction observations describe one actual update, never a frozen
    // frame or an old update from before diagnostics were enabled.
    invalidateDiagnosticSnapshot();
    if (!mGeometryValid || !mSettings.enabled) return;
    if (mSettings.freezeUpdates)
    {
        if (!mDistributionValid) mFallbackReason = "Frozen proposal is invalid; unfreeze to rebuild";
        else
        {
            if (!mpClearDiagnostics)
            {
                ProgramDesc desc;
                desc.addShaderLibrary("RenderPasses/RTPT/RTPTVXPGPrepare.cs.slang").csEntry("clearDiagnostics");
                desc.setShaderModel(ShaderModel::SM6_6);
                mpClearDiagnostics = ComputePass::create(mpDevice, desc, {}, true);
            }
            context->uavBarrier(mpState.get());
            context->uavBarrier(mpQueryStats.get());
            bind(mpClearDiagnostics->getRootVar(), mLightingFrameIndex, true);
            mpClearDiagnostics->execute(context, uint3(32,1,1));
            context->uavBarrier(mpQueryStats.get());
            context->uavBarrier(mpState.get());
        }
        return;
    }
    const uint32_t cells = cellCapacity();
    if (!mpFlux || mAllocatedCapacity != mSettings.maxVoxels || any(mAllocatedFrameDim != mFrameDim))
    {
        mpClearFrame = mpPrimary = mpGlobalLeaves = mpGlobalLevel = mpPublish = nullptr;
        resetClusterPasses();
        mpForest = nullptr;
        mpFlux = mpDevice->createStructuredBuffer(sizeof(uint64_t), cells);
        mpCount = mpDevice->createStructuredBuffer(sizeof(uint32_t), cells);
        mpCellMass = mpTreeState = mpDirtyLeaves = mpDirtyNodes = mpLocalArgs = mpLocalDispatch = nullptr;
        mDistributionValid = false;
        mpQueryStats=mpDevice->createStructuredBuffer(4,8);
        mpHistoryStats = mpDevice->createStructuredBuffer(4, 8);
        context->clearUAV(mpHistoryStats->getUAV().get(),uint4(0));
        mpHistory = nullptr;
        mResetHistory = true;
        mpRepresentativePosition = mpDevice->createStructuredBuffer(sizeof(float4), cells);
        mpRepresentativeNormal = mpDevice->createStructuredBuffer(sizeof(float4), cells);
        mpCompactIndices = mpDevice->createStructuredBuffer(sizeof(uint32_t), mSettings.maxVoxels);
        mpMass = mpDevice->createStructuredBuffer(sizeof(float), mSettings.maxVoxels);
        mLeafCapacity = 1;
        while (mLeafCapacity < mSettings.maxVoxels) mLeafCapacity *= 2;
        mpGlobalTree = mpDevice->createStructuredBuffer(sizeof(float), 2 * mLeafCapacity);
        mpPrimaryPosition = mpDevice->createTexture2D(mFrameDim.x, mFrameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpPrimaryNormal = mpDevice->createTexture2D(mFrameDim.x, mFrameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpPrimaryHit = mpDevice->createTexture2D(mFrameDim.x,mFrameDim.y,ResourceFormat::RGBA32Uint,1,1,nullptr,
            ResourceBindFlags::ShaderResource|ResourceBindFlags::UnorderedAccess);
        mAllocatedFrameDim = mFrameDim;
        mAllocatedCapacity = mSettings.maxVoxels;
    }
    if (!mpSampleGenerator) mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    if (!mpHistory)
    {
        mpHistory = mpDevice->createStructuredBuffer(16, cells);
        mResetHistory = true;
    }
    // A grid reset may already have reduced the occupied span to zero. Clear the
    // complete history allocation before taking the previous-frame snapshot so
    // newly reused cell IDs cannot inherit a different cell's stale history.
    if (mpHistory && mResetHistory)
        context->clearUAV(mpHistory->getUAV().get(), uint4(0));
    if(!mpHistoryPrevious)
    {
        mpHistoryPrevious=mpDevice->createStructuredBuffer(16,cells);
        mpNormalPrevious=mpDevice->createStructuredBuffer(16,cells);
    }
    if (!mpTreeState)
    {
        const uint32_t zero[16] = {};
        mpTreeState = mpDevice->createStructuredBuffer(4, 16, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            MemoryType::DeviceLocal, zero);
        mpCellMass = mpDevice->createStructuredBuffer(4, cells);
        mpDirtyLeaves = mpDevice->createStructuredBuffer(4, mSettings.maxVoxels);
        mpDirtyNodes = mpDevice->createStructuredBuffer(4, 2*mLeafCapacity + 4*mSettings.maxVoxels + 64);
        context->clearUAV(mpDirtyNodes->getUAV().get(), uint4(0));
        mpLocalArgs = mpDevice->createStructuredBuffer(4, 3);
        mpLocalDispatch = mpDevice->createStructuredBuffer(4, 3,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg);
        mDistributionValid = false;
    }
    if (!mpClearFrame)
    {
        auto makePrepare = [&](const char* entry)
        {
            ProgramDesc desc;
            desc.addShaderLibrary("RenderPasses/RTPT/RTPTVXPGPrepare.cs.slang").csEntry(entry);
            desc.setShaderModel(ShaderModel::SM6_6);
            return ComputePass::create(mpDevice, desc, {}, true);
        };
        mpClearFrame = makePrepare("clearFrame");
        mpGlobalLeaves = makePrepare("globalLeaves");
        mpGlobalLevel = makePrepare("globalLevel");
        mpPublish = makePrepare("publish");
        auto makeLocal = [&](const char* entry)
        {
            ProgramDesc desc;
            desc.addShaderLibrary("RenderPasses/RTPT/RTPTVXPGLocal.cs.slang").csEntry(entry);
            desc.setShaderModel(ShaderModel::SM6_6);
            return ComputePass::create(mpDevice, desc, {}, true);
        };
        mpBeginLocal = makeLocal("beginLocal"); mpResolveLocal = makeLocal("resolveLocal");
        mpSelectLocal = makeLocal("selectLocal"); mpCompactLocal = makeLocal("compactLocal");
        mpLocalWork = makeLocal("localWork"); mpLocalLeaves = makeLocal("localLeaves"); mpLocalLevel = makeLocal("localLevel");
        {
            mpGeometryWork=makePrepare("geometryWork");
            mpActiveWork=makePrepare("activeWork");
            mpForestWork=makePrepare("forestWork");
        }
    }
    if (!mpPrimary)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary("RenderPasses/RTPT/RTPTVXPGPrimary.cs.slang").csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());
        desc.setShaderModel(ShaderModel::SM6_6);
        DefineList defines = mpScene->getSceneDefines();
        defines.add(mpSampleGenerator->getDefines());
        defines.add("RTPT_VXPG_DETAILED_DIAGNOSTICS", mSettings.detailedDiagnostics ? "1" : "0");
        mpPrimary = ComputePass::create(mpDevice, desc, defines, true);
    }
    advanceGeneration(mGeneration);
    auto execute = [&](const ref<ComputePass>& pass, uint3 size)
    {
        bind(pass->getRootVar(), mLightingFrameIndex, true);
        pass->execute(context, size);
    };
    {
        FALCOR_PROFILE(context, "VXPGClear");
        {
            if (mGeneration == 1) context->clearUAV(mpDirtyNodes->getUAV().get(), uint4(0));
            context->uavBarrier(mpTreeState.get());
            execute(mpBeginLocal, uint3(1));
            context->uavBarrier(mpTreeState.get());
        }
        context->uavBarrier(mpState.get());
        context->uavBarrier(mpGlobalTree.get());
        context->uavBarrier(mpMass.get());
        context->uavBarrier(mpCompactIndices.get());
        context->uavBarrier(mpInverse.get());
        context->uavBarrier(mpFlux.get());
        context->uavBarrier(mpCount.get());
        context->uavBarrier(mpBoundMax.get());
        context->uavBarrier(mpHistoryStats.get());
        context->uavBarrier(mpQueryStats.get());
        if (mpHistory) context->uavBarrier(mpHistory.get());
        {
            context->uavBarrier(mpWorkArgs.get());
            execute(mpGeometryWork,uint3(1));
            context->uavBarrier(mpWorkArgs.get());
            context->copyResource(mpWorkDispatch.get(),mpWorkArgs.get());
            bind(mpClearFrame->getRootVar(),mLightingFrameIndex,true);
            mpClearFrame->executeIndirect(context,mpWorkDispatch.get(),4*sizeof(uint32_t));
        }
        context->uavBarrier(mpQueryStats.get());
        context->uavBarrier(mpState.get());
        context->uavBarrier(mpFlux.get());
        context->uavBarrier(mpCount.get());
        context->uavBarrier(mpBoundMax.get());
        context->uavBarrier(mpInverse.get());
    }
    prepareIncrementalGrid(context);
    if(mpHistoryPrevious)
    {
        context->copyResource(mpHistoryPrevious.get(),mpHistory.get());
        context->copyResource(mpNormalPrevious.get(),mpRepresentativeNormal.get());
    }
    context->uavBarrier(mpRepresentativePosition.get());
    context->uavBarrier(mpRepresentativeNormal.get());
    if (mpHistory) context->uavBarrier(mpHistory.get());
    context->uavBarrier(mpHistoryStats.get());
    mResetHistory = false;
    mLightingPrepared = true;
}

void Manager::barrierInjection(RenderContext* context) const
{
    for (const auto& buffer : {mpFlux, mpCount, mpState, mpBoundMax, mpRepresentativePosition, mpRepresentativeNormal})
        if (buffer) context->uavBarrier(buffer.get());
}

void Manager::updateLighting(RenderContext* context, uint32_t seed, uint32_t sampleOffset, bool useNRD)
{
    if (!mLightingPrepared) return;
    mLightingPrepared = false;
    const uint32_t cells = cellCapacity();
    auto execute = [&](const ref<ComputePass>& pass, uint3 size)
    {
        bind(pass->getRootVar(), mLightingFrameIndex, true);
        pass->execute(context, size);
    };
    {
        FALCOR_PROFILE(context, "VXPGPrimary");
        context->uavBarrier(mpPrimaryPosition.get());
        context->uavBarrier(mpPrimaryNormal.get());
        context->uavBarrier(mpPrimaryHit.get());
        context->uavBarrier(mpRepresentativePosition.get());
        context->uavBarrier(mpRepresentativeNormal.get());
        auto root = mpPrimary->getRootVar();
        bind(root, mLightingFrameIndex, true);
        mpScene->bindShaderDataForRaytracing(context, root["gScene"]);
        mpSampleGenerator->bindShaderData(root);
        root["gParams"]["seed"] = seed;
        root["gParams"]["sampleOffset"] = sampleOffset;
        root["gParams"]["useNRD"] = useNRD ? 1u : 0u;
        mpPrimary->execute(context, uint3(mFrameDim, 1));
        context->uavBarrier(mpFlux.get());
        context->uavBarrier(mpCount.get());
        context->uavBarrier(mpState.get());
        context->uavBarrier(mpBoundMax.get());
        context->uavBarrier(mpRepresentativePosition.get());
        context->uavBarrier(mpRepresentativeNormal.get());
        context->uavBarrier(mpPrimaryPosition.get());
        context->uavBarrier(mpPrimaryNormal.get());
        context->uavBarrier(mpPrimaryHit.get());
    }
    finishIncrementalGrid(context);
    {
        FALCOR_PROFILE(context, "VXPGCompactAndTree");
        auto geometryPass = [&](const ref<ComputePass>& pass)
        {
            { bind(pass->getRootVar(), mLightingFrameIndex, true); pass->executeIndirect(context, mpWorkDispatch.get(), 4*sizeof(uint32_t)); }
        };
        {
            context->uavBarrier(mpCellMass.get());
            context->uavBarrier(mpDirtyLeaves.get());
            geometryPass(mpResolveLocal);
            context->uavBarrier(mpCellMass.get()); context->uavBarrier(mpTreeState.get()); context->uavBarrier(mpState.get());
            execute(mpSelectLocal, uint3(1));
            context->uavBarrier(mpTreeState.get()); context->uavBarrier(mpState.get());
            geometryPass(mpCompactLocal);
            context->uavBarrier(mpDirtyLeaves.get()); context->uavBarrier(mpTreeState.get());
        }
        context->uavBarrier(mpMass.get());
        context->uavBarrier(mpCompactIndices.get());
        context->uavBarrier(mpInverse.get());
        context->uavBarrier(mpState.get());
        if (mpHistory) context->uavBarrier(mpHistory.get());
        context->uavBarrier(mpHistoryStats.get());
        context->uavBarrier(mpQueryStats.get());
        {
            context->uavBarrier(mpWorkArgs.get());
            execute(mpActiveWork,uint3(1));
            context->uavBarrier(mpWorkArgs.get());
            context->copyResource(mpWorkDispatch.get(),mpWorkArgs.get());
        }
        mpGlobalLeaves->getRootVar()["VXPGTreeLevel"]["leafCapacity"] = mLeafCapacity;
        {
            bind(mpGlobalLeaves->getRootVar(),mLightingFrameIndex,true);
            mpGlobalLeaves->executeIndirect(context,mpWorkDispatch.get(),12*sizeof(uint32_t));
        }
        context->uavBarrier(mpGlobalTree.get());
        for (uint32_t offset = mLeafCapacity / 2, level=1; offset > 0; offset /= 2,++level)
        {
            auto root = mpGlobalLevel->getRootVar();
            root["VXPGTreeLevel"]["nodeOffset"] = level;
            root["VXPGTreeLevel"]["nodeCount"] = offset;
            {
                bind(root,mLightingFrameIndex,true);
                mpGlobalLevel->executeIndirect(context,mpWorkDispatch.get(),(32+(level-1)*3)*sizeof(uint32_t));
            }
            context->uavBarrier(mpGlobalTree.get());
        }
    }
    {
        FALCOR_PROFILE(context, "VXPGLocalTreeUpdate");
        context->uavBarrier(mpLocalArgs.get());
        execute(mpLocalWork, uint3(1));
        context->uavBarrier(mpLocalArgs.get());
        context->copyResource(mpLocalDispatch.get(), mpLocalArgs.get());
        auto localDispatch = [&](const ref<ComputePass>& pass)
        {
            bind(pass->getRootVar(), mLightingFrameIndex, true);
            pass->executeIndirect(context, mpLocalDispatch.get());
            context->uavBarrier(mpGlobalTree.get());
            if (mpForest) context->uavBarrier(mpForest.get());
            context->uavBarrier(mpDirtyNodes.get());
            context->uavBarrier(mpTreeState.get());
        };
        if (mpForest) context->uavBarrier(mpForest.get());
        localDispatch(mpLocalLeaves);
        for (uint32_t level = 1; (mLeafCapacity >> level) > 0; ++level)
        {
            mpLocalLevel->getRootVar()["VXPGLocalLevel"]["localTreeLevel"] = level;
            localDispatch(mpLocalLevel);
        }
    }
    if (mSettings.visibilityEnabled) updateVisibility(context);
    {
        context->uavBarrier(mpState.get());
        execute(mpPublish, uint3(1));
        context->uavBarrier(mpState.get());
        if (mpTreeState) context->uavBarrier(mpTreeState.get());
    }
    {
        bind(mpGridRetire->getRootVar(),mLightingFrameIndex,true);
        mpGridRetire->execute(context,uint3(cellCapacity(),1,1));
        context->uavBarrier(mpFreeCells.get());context->uavBarrier(mpGridState.get());context->uavBarrier(mpInverse.get());
    }
    mDistributionValid = true;
    mReady = true;
    mFallbackReason.clear();
    mModelDiagnosticsAvailable = mSettings.detailedDiagnostics;
    mModelDiagnosticsFrameIndex = mLightingFrameIndex;
    mPreviousLodCamera=mLodCamera;
    ++mLightingFrameIndex;
}

void Manager::updateVisibility(RenderContext* context)
{
    const uint32_t rows = ((mFrameDim.x + mSettings.superpixelSize - 1) / mSettings.superpixelSize) *
        ((mFrameDim.y + mSettings.superpixelSize - 1) / mSettings.superpixelSize);
    if (mSettings.visibilityEnabled && (!mpForest || mAllocatedSuperpixelSize != mSettings.superpixelSize))
    {
        resetClusterPasses();
        mpRowPosition = mpDevice->createStructuredBuffer(sizeof(float4), 128);
        mpRowNormal = mpDevice->createStructuredBuffer(sizeof(float4), 128);
        mpVisibility = mpDevice->createStructuredBuffer(sizeof(uint4), mSettings.maxVoxels);
        mpSeeds = mpDevice->createStructuredBuffer(32, 32);
        mpCluster = mpDevice->createStructuredBuffer(4, mSettings.maxVoxels);
        mpClusterInfo = mpDevice->createStructuredBuffer(sizeof(uint4), 32);
        mpForest = mpDevice->createStructuredBuffer(32, 4 * mSettings.maxVoxels + 64);
        mpCompactToLeaf = mpDevice->createStructuredBuffer(4, mSettings.maxVoxels);
        mpSuperpixelPosition = mpDevice->createStructuredBuffer(sizeof(float4), rows);
        mpSuperpixelNormal = mpDevice->createStructuredBuffer(sizeof(float4), rows);
        mpTopTree = mpDevice->createStructuredBuffer(sizeof(float), rows * 64);
        mpSuperpixelCount=mpDevice->createStructuredBuffer(4,rows);
        mpSuperpixelRange=mpDevice->createStructuredBuffer(8,rows);
        mpSuperpixelBlocks=mpDevice->createStructuredBuffer(4,(rows+255)/256);
        mpSuperpixelPoints=mpDevice->createStructuredBuffer(4,mFrameDim.x*mFrameDim.y);
        const std::array<uint32_t, 8> zero = {};
        mpClusterState = mpDevice->createStructuredBuffer(4, 8,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, zero.data());
        mpClusterArgs = mpDevice->createStructuredBuffer(4, 3,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg);
        mpSortA = mpDevice->createStructuredBuffer(sizeof(uint2), mLeafCapacity);
        mpSortB = mpDevice->createStructuredBuffer(sizeof(uint2), mLeafCapacity);
        mpHistogram = mpDevice->createStructuredBuffer(4, mLeafCapacity);
        mpBinOffsets = mpDevice->createStructuredBuffer(4, 256);
        mpFuzzyIds = mpDevice->createTexture2D(mFrameDim.x, mFrameDim.y, ResourceFormat::RGBA32Uint, 1, 1, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mpFuzzyWeights = mpDevice->createTexture2D(mFrameDim.x, mFrameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
        mAllocatedSuperpixelSize = mSettings.superpixelSize;
    }
    auto makePass = [&](const char* library, const char* entry, bool scene)
    {
        ProgramDesc desc;
        if (scene) desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(library).csEntry(entry);
        if (scene) desc.addTypeConformances(mpScene->getTypeConformances());
        desc.setShaderModel(ShaderModel::SM6_6);
        DefineList defines=scene?mpScene->getSceneDefines():DefineList();
        if(scene)defines.add(mpSampleGenerator->getDefines());
        defines.add("RTPT_VXPG_DETAILED_DIAGNOSTICS", mSettings.detailedDiagnostics ? "1" : "0");
        return ComputePass::create(mpDevice,desc,defines,true);
    };
    if (!mpPrepareClusters)
    {
        const char* visibility = "RenderPasses/RTPT/RTPTVXPGVisibility.cs.slang";
        const char* tree = "RenderPasses/RTPT/RTPTVXPGTree.cs.slang";
        mpPrepareClusters = makePass(visibility, "prepareClusterArgs", true);
        mpRows = makePass(visibility, "representativeRows", true);
        mpRowVisibility = makePass(visibility, "rowVisibility", true);
        mpSeedsPass = makePass(visibility, "seedClusters", true);
        mpAssignClusters = makePass(visibility, "assignClusters", true);
        mpCenters = makePass(visibility, "superpixelCenters", true);
        mpAssociate = makePass(visibility, "associateSuperpixels", true);
        mpSuperpixelPrefix=makePass(visibility,"prefixSuperpixels",true);
        mpSuperpixelBlockPrefix=makePass(visibility,"prefixSuperpixelBlocks",true);
        mpSuperpixelRanges=makePass(visibility,"finalizeSuperpixelRanges",true);
        mpSuperpixelScatter=makePass(visibility,"scatterSuperpixelPoints",true);
        mpTopLeaves = makePass(visibility, "topLevelLeaves", true);
        mpTopParents = makePass(visibility, "topLevelParents", true);
        mpDistributionDebug = makePass(visibility, "debugDistribution", true);
        mpEncode = makePass(tree, "encodeVoxels", false);
        mpHistogramPass = makePass(tree, "radixHistogram", false);
        mpPrefixPass = makePass(tree, "radixPrefix", false);
        mpScatter = makePass(tree, "radixScatter", false);
        mpAllocateForest = makePass(tree, "allocateForest", false);
        mpInitializeForest = makePass(tree, "initializeForest", false);
        mpForestLeaves = makePass(tree, "forestLeaves", false);
        mpForestLevel = makePass(tree, "forestLevel", false);
        mpPublishClusters = makePass(tree, "publishClusters", false);
    }
    auto rootFor = [&](const ref<ComputePass>& pass)
    {
        auto root = pass->getRootVar();
        bind(root, mLightingFrameIndex, true);
        auto scene = root.findMember("gScene");
        if (scene.isValid()) mpScene->bindShaderDataForRaytracing(context, scene);
        return root;
    };
    auto execute = [&](const ref<ComputePass>& pass, uint3 threads)
    {
        rootFor(pass);
        pass->execute(context, threads);
    };
    {
        FALCOR_PROFILE(context, "VXPGVisibilityClusters");
        for (const auto& buffer : {mpClusterInfo, mpClusterState, mpRowPosition, mpRowNormal, mpVisibility, mpSeeds, mpCluster})
            context->uavBarrier(buffer.get());
        execute(mpPrepareClusters, uint3(64, 1, 1));
        context->uavBarrier(mpClusterArgs.get());
        context->uavBarrier(mpClusterState.get());
        context->uavBarrier(mpClusterInfo.get());
        execute(mpRows, uint3(128, 1, 1));
        context->uavBarrier(mpRowPosition.get());
        context->uavBarrier(mpRowNormal.get());
        rootFor(mpRowVisibility);
        mpRowVisibility->executeIndirect(context, mpClusterArgs.get());
        context->uavBarrier(mpVisibility.get());
        context->uavBarrier(mpClusterState.get());
        execute(mpSeedsPass, uint3(256, 1, 1));
        context->uavBarrier(mpSeeds.get());
        {rootFor(mpAssignClusters);mpAssignClusters->executeIndirect(context,mpWorkDispatch.get(),8*sizeof(uint32_t));}
        context->uavBarrier(mpCluster.get());
        context->uavBarrier(mpClusterInfo.get());
    }
    ref<Buffer> sorted = mpSortA, scratch = mpSortB;
    {
        FALCOR_PROFILE(context, "VXPGMortonSort");
        context->uavBarrier(mpSortA.get());
        context->uavBarrier(mpSortB.get());
        auto constants = [&](const ShaderVar& root, uint32_t shift)
        {
            auto cb = root["VXPGClusterBuild"];
            cb["sortCapacity"] = mLeafCapacity;
            cb["sortGroups"] = (mLeafCapacity + 255) / 256;
            cb["sortShift"] = shift;
        };
        auto root = rootFor(mpEncode);
        constants(root, 0);
        root["gVXPGSortOutput"] = sorted;
        mpEncode->executeIndirect(context,mpWorkDispatch.get(),16*sizeof(uint32_t));
        context->uavBarrier(sorted.get());
        for (uint32_t shift = 0; shift < 32; shift += 8)
        {
            root = rootFor(mpHistogramPass);
            constants(root, shift);
            root["gVXPGSortInput"] = sorted;
            root["gVXPGHistogram"] = mpHistogram;
            mpHistogramPass->executeIndirect(context,mpWorkDispatch.get(),16*sizeof(uint32_t));
            context->uavBarrier(mpHistogram.get());
            root = rootFor(mpPrefixPass);
            constants(root, shift);
            root["gVXPGHistogram"] = mpHistogram;
            root["gVXPGBinOffsets"] = mpBinOffsets;
            mpPrefixPass->execute(context, uint3(256, 1, 1));
            context->uavBarrier(mpHistogram.get());
            context->uavBarrier(mpBinOffsets.get());
            root = rootFor(mpScatter);
            constants(root, shift);
            root["gVXPGSortInput"] = sorted;
            root["gVXPGSortOutput"] = scratch;
            root["gVXPGHistogram"] = mpHistogram;
            root["gVXPGBinOffsets"] = mpBinOffsets;
            mpScatter->executeIndirect(context,mpWorkDispatch.get(),16*sizeof(uint32_t));
            context->uavBarrier(scratch.get());
            context->uavBarrier(sorted.get());
            context->uavBarrier(mpHistogram.get());
            context->uavBarrier(mpBinOffsets.get());
            std::swap(sorted, scratch);
        }
    }
    {
        FALCOR_PROFILE(context, "VXPGClusterForest");
        context->uavBarrier(mpForest.get());
        execute(mpAllocateForest, uint3(1));
        context->uavBarrier(mpClusterInfo.get());
        context->uavBarrier(mpClusterState.get());
        {
            context->uavBarrier(mpWorkArgs.get());
            execute(mpForestWork,uint3(1));
            context->uavBarrier(mpWorkArgs.get());
            context->copyResource(mpWorkDispatch.get(),mpWorkArgs.get());
            rootFor(mpInitializeForest);
            mpInitializeForest->executeIndirect(context,mpWorkDispatch.get(),20*sizeof(uint32_t));
        }
        context->uavBarrier(mpForest.get());
        auto root = rootFor(mpForestLeaves);
        context->uavBarrier(mpCompactToLeaf.get());
        root["gVXPGSortInput"] = sorted;
        mpForestLeaves->executeIndirect(context,mpWorkDispatch.get(),8*sizeof(uint32_t));
        context->uavBarrier(mpForest.get());
        context->uavBarrier(mpCompactToLeaf.get());
        for (uint32_t level = 1; (mLeafCapacity >> level) > 0; ++level)
        {
            root = rootFor(mpForestLevel);
            root["VXPGClusterBuild"]["treeLevel"] = level;
            mpForestLevel->executeIndirect(context,mpWorkDispatch.get(),(96+(level-1)*3)*sizeof(uint32_t));
            context->uavBarrier(mpForest.get());
        }
        execute(mpPublishClusters, uint3(1));
        // Publication converts the remaining AABB roots to query geometry.
        context->uavBarrier(mpForest.get());
        context->uavBarrier(mpClusterState.get());
        context->uavBarrier(mpState.get());
    }
    {
        FALCOR_PROFILE(context, "VXPGSuperpixelTopTree");
        context->uavBarrier(mpSuperpixelPosition.get());
        context->uavBarrier(mpSuperpixelNormal.get());
        context->uavBarrier(mpSuperpixelCount.get());
        execute(mpCenters, uint3(rows, 1, 1));
        context->uavBarrier(mpSuperpixelPosition.get());
        context->uavBarrier(mpSuperpixelNormal.get());
        context->uavBarrier(mpSuperpixelCount.get());
        context->uavBarrier(mpFuzzyIds.get());
        context->uavBarrier(mpFuzzyWeights.get());
        execute(mpAssociate, uint3(mFrameDim, 1));
        context->uavBarrier(mpFuzzyIds.get());
        context->uavBarrier(mpFuzzyWeights.get());
        context->uavBarrier(mpSuperpixelCount.get());
        context->uavBarrier(mpSuperpixelRange.get());
        context->uavBarrier(mpSuperpixelBlocks.get());
        execute(mpSuperpixelPrefix,uint3(rows,1,1));
        context->uavBarrier(mpSuperpixelRange.get());
        context->uavBarrier(mpSuperpixelBlocks.get());
        context->uavBarrier(mpSuperpixelCount.get());
        execute(mpSuperpixelBlockPrefix,uint3(1));
        context->uavBarrier(mpSuperpixelBlocks.get());
        execute(mpSuperpixelRanges,uint3(rows,1,1));
        context->uavBarrier(mpSuperpixelRange.get());
        context->uavBarrier(mpSuperpixelPoints.get());
        execute(mpSuperpixelScatter,uint3(mFrameDim,1));
        context->uavBarrier(mpSuperpixelPoints.get());
        context->uavBarrier(mpSuperpixelCount.get());
        context->uavBarrier(mpTopTree.get());
        const uint32_t pairs=rows*32;
        execute(mpTopLeaves, uint3(std::min(1024u,pairs)*32,(pairs+1023)/1024,1));
        context->uavBarrier(mpTopTree.get());
        execute(mpTopParents, uint3(rows, 1, 1));
        context->uavBarrier(mpTopTree.get());
        context->uavBarrier(mpClusterState.get());
    }
}

void Manager::renderDebug(RenderContext* context, const ref<Texture>& output)
{
    if(mSettings.debugEnabled && mGeometryValid && output &&
        (mSettings.debugMode==0 || mSettings.debugMode==4 || !mSettings.visibilityEnabled))
    {
        if(!mpDebug)
        {
            ProgramDesc desc;desc.addShaderModules(mpScene->getShaderModules());
            desc.addShaderLibrary("RenderPasses/RTPT/RTPTVXPGDebug.cs.slang").csEntry("debugGeometry");
            desc.addTypeConformances(mpScene->getTypeConformances());desc.setShaderModel(ShaderModel::SM6_6);
            mpDebug = ComputePass::create(mpDevice, desc, mpScene->getSceneDefines(), true);
        }
        auto root=mpDebug->getRootVar();bind(root,mLightingFrameIndex,true);
        mpScene->bindShaderDataForRaytracing(context,root["gScene"]);root["gVXPGDebug"]=output;
        mpDebug->execute(context,uint3(mFrameDim,1));return;
    }
    if (!mSettings.debugEnabled || mSettings.debugMode == 0 || mSettings.debugMode == 4 || !mSettings.visibilityEnabled || !mDistributionValid || !mpDistributionDebug) return;
    auto root = mpDistributionDebug->getRootVar();
    bind(root, mLightingFrameIndex, true);
    root["gVXPGDebug"] = output;
    mpDistributionDebug->execute(context, uint3(mFrameDim, 1));
}
}
