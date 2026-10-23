#include "RTPTVXPG.h"
#include "Core/API/GFXAPI.h"
#include <cmath>
#include "Utils/Timing/Profiler.h"

using namespace Falcor;
namespace RTPTVXPG
{
void Manager::validate(const Settings& s)
{
    FALCOR_CHECK(s.gridResolution >= 16 && s.gridResolution <= 128 && (s.gridResolution & (s.gridResolution - 1)) == 0,
        "VXPG grid resolution must be a power of two in [16,128].");
    FALCOR_CHECK(s.maxVoxels >= 256 && s.maxVoxels <= 262144, "VXPG active voxel capacity must be in [256,262144].");
    FALCOR_CHECK(s.clusterCount >= 1 && s.clusterCount <= 32, "VXPG cluster count must be in [1,32].");
    FALCOR_CHECK(s.superpixelSize >= 8 && s.superpixelSize <= 64, "VXPG superpixel size must be in [8,64].");
    FALCOR_CHECK(s.budgetMiB >= 32 && s.budgetMiB <= 2048, "VXPG resource budget must be in [32,2048] MiB.");
    FALCOR_CHECK(s.debugMode <= 3, "VXPG debug mode must be in [0,3].");
}

void Manager::configure(const Settings& settings, uint2 frameDim)
{
    validate(settings);
    if (settings.sharedInjectionEnabled != mSettings.sharedInjectionEnabled)
    {
        invalidateDistribution("Training source changed; rebuild the VXPG proposal");
        if (mpInject) mpInject->addDefine("RTPT_VXPG_SHARED_INJECTION", settings.sharedInjectionEnabled ? "1" : "0", true);
    }
    if (settings.detailedDiagnostics != mSettings.detailedDiagnostics)
    {
        // Change only instrumentation variants; published data and histories
        // remain usable, including a frozen proposal and its debug view.
        const char* enabled = settings.detailedDiagnostics ? "1" : "0";
        for (const auto& pass : {mpInject, mpRowVisibility, mpTopLeaves})
            if (pass) pass->addDefine("RTPT_VXPG_DETAILED_DIAGNOSTICS", enabled, true);
        invalidateDiagnosticSnapshot();
    }
    const bool structural = settings.gridResolution != mSettings.gridResolution || settings.maxVoxels != mSettings.maxVoxels ||
        settings.clusterCount != mSettings.clusterCount || settings.superpixelSize != mSettings.superpixelSize ||
        any(frameDim != mFrameDim);
    if (structural) invalidate();
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
    mEstimatedBytes = estimateModelBytes();
    if (mEstimatedBytes > uint64_t(settings.budgetMiB) * 1024ull * 1024ull)
    {
        releaseModelResources();
        mFallbackReason = "Resource estimate exceeds VXPG budget";
    }
}

uint64_t Manager::estimateModelBytes() const
{
    const uint64_t cells = uint64_t(mSettings.gridResolution) * mSettings.gridResolution * mSettings.gridResolution;
    const uint64_t superpixels = uint64_t((mFrameDim.x + mSettings.superpixelSize - 1) / mSettings.superpixelSize) *
        ((mFrameDim.y + mSettings.superpixelSize - 1) / mSettings.superpixelSize);
    // 216 B/capacity covers next-power-of-two trees even for non-power capacities.
    return cells * 80ull + uint64_t(mSettings.maxVoxels) * 216ull + superpixels * 304ull +
        mScreenAllocationBytes + uint64_t(mFrameDim.x) * mFrameDim.y * 4ull +
        uint64_t(mJobCapacity) * sizeof(uint2) + uint64_t(mTriangleCount) * 24ull + (2ull << 20);
}

void Manager::invalidateDistribution(const std::string& reason)
{
    beginFrame();
    invalidateDiagnosticSnapshot();
    ++mGeneration;
    mReady = mDistributionValid = false;
    mFallbackReason = reason;
}

void Manager::invalidateLighting()
{
    invalidateDistribution("Lighting configuration needs rebuilding");
    mpInject = nullptr;
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
    mpClearGeometry=mpMakeJobs=mpFinalizeJobs=mpVoxelize=mpDebug=nullptr;
    mpClearFrame=mpInject=mpCompact=mpGlobalLeaves=mpGlobalLevel=mpPublish=mpClearDiagnostics=nullptr;
    resetClusterPasses();
    mpBoundMin=mpBoundMax=mpState=mpInverse=mpJobs=mpDispatchArgs=nullptr;
    mpTriangles=mpTriangleRanges=nullptr;
    mpFlux=mpCount=mpCompactIndices=mpMass=mpGlobalTree=mpRepresentativePosition=mpRepresentativeNormal=nullptr;
    mpRowPosition=mpRowNormal=mpVisibility=mpSeeds=mpCluster=mpClusterInfo=nullptr;
    mpForest=mpCompactToLeaf=mpSuperpixelPosition=mpSuperpixelNormal=mpTopTree=mpClusterState=mpClusterArgs=nullptr;
    mpSortA=mpSortB=mpHistogram=mpBinOffsets=nullptr;
    mpPrimaryPosition=mpPrimaryNormal=mpPrimaryHit=mpFuzzyIds=mpFuzzyWeights=nullptr;
    mpSuperpixelCount=mpSuperpixelRange=mpSuperpixelBlocks=mpSuperpixelPoints=nullptr;
    mAllocatedResolution=mAllocatedCapacity=mAllocatedSuperpixelSize=mLeafCapacity=0;
    mAllocatedFrameDim=uint2(0);
}

void Manager::invalidate()
{
    beginFrame();
    invalidateDiagnosticSnapshot();
    ++mGeneration;
    mReady = false;
    mGeometryValid = false;
    mDistributionValid = false;
    mLightingFrameIndex = 0;
    mpTriangles = mpTriangleRanges = nullptr;
    mTriangleCount = 0;
    mFallbackReason = "Voxel proposal has not been built";
}

void Manager::setScene(const ref<Scene>& scene)
{
    mpScene = scene;
    mpClearGeometry = mpMakeJobs = mpFinalizeJobs = mpVoxelize = mpDebug = nullptr;
    mpClearFrame = mpInject = mpCompact = mpGlobalLeaves = mpGlobalLevel = mpPublish = nullptr;
    resetClusterPasses();
    mpTriangles = mpTriangleRanges = nullptr;
    mTriangleCount = 0;
    invalidate();
}

void Manager::bind(const ShaderVar& root, uint32_t frameIndex, bool active) const
{
    auto parameters = root.findMember("gVXPGParams");
    if (parameters.isValid())
    {
        parameters["frameDim"] = mFrameDim;
        parameters["resolution"] = mSettings.gridResolution;
        parameters["cellCount"] = mSettings.gridResolution * mSettings.gridResolution * mSettings.gridResolution;
        parameters["gridMin"] = mGridMin;
        parameters["cellSize"] = mCellSize;
        parameters["activeCapacity"] = mSettings.maxVoxels;
        parameters["triangleCount"] = mTriangleCount;
        parameters["jobCapacity"] = mJobCapacity;
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
    buffer("gVXPGInverse", mpInverse);
    buffer("gVXPGTriangles", mpTriangles);
    buffer("gVXPGTriangleRanges", mpTriangleRanges);
    buffer("gVXPGJobs", mpJobs);
    buffer("gVXPGDispatchArgs", mpDispatchArgs);
    buffer("gVXPGFlux", mpFlux);
    buffer("gVXPGCount", mpCount);
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
    for (const auto& buffer : {mpBoundMin,mpBoundMax,mpState,mpInverse,mpTriangles,mpTriangleRanges,mpJobs,mpDispatchArgs,
        mpFlux,mpCount,mpCompactIndices,mpMass,mpGlobalTree,mpRepresentativePosition,mpRepresentativeNormal,
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

void Manager::buildGeometry(RenderContext* context, const ref<Texture>& debugOutput)
{
    if (!mpScene || !mSettings.enabled) return;
    if (mEstimatedBytes > uint64_t(mSettings.budgetMiB)*1024ull*1024ull)
    {
        mFallbackReason="Resource estimate exceeds VXPG budget";
        return;
    }
    const auto* animation = mpScene->getAnimationController();
    if (animation && (animation->hasSkinnedMeshes() || animation->hasAnimatedMeshCaches()))
    {
        mGeometryValid = mReady = false;
        mFallbackReason = "Skinned/vertex-cache geometry is not validated for VXPG; using BSDF";
        return;
    }
    const uint32_t cells = mSettings.gridResolution * mSettings.gridResolution * mSettings.gridResolution;
    if (!mpTriangles)
    {
        uint64_t references=0;
        for (uint32_t i = 0; i < mpScene->getGeometryInstanceCount(); ++i)
        {
            const auto& instance = mpScene->getGeometryInstance(i);
            if (instance.getType() != GeometryType::TriangleMesh) continue;
            const auto& mesh = mpScene->getMesh(MeshID(instance.geometryID));
            references+=mesh.getTriangleCount();
        }
        if (references > (1ull<<26))
        {
            mFallbackReason="Triangle reference limit exceeded; using BSDF";
            return;
        }
        mTriangleCount = uint32_t(references);
        if (mTriangleCount==0)
        {
            mFallbackReason = "Scene contains no triangle geometry";
            return;
        }
    }
    const uint64_t planned = estimateModelBytes();
    mEstimatedBytes = planned;
    if (planned > uint64_t(mSettings.budgetMiB) * 1024ull * 1024ull)
    {
        releaseModelResources();
        mFallbackReason = "Resource estimate exceeds VXPG budget";
        mGeometryValid = mReady = false;
        return;
    }
    if (!mpTriangles)
    {
        std::vector<uint2> triangles;
        triangles.reserve(mTriangleCount);
        for (uint32_t i=0;i<mpScene->getGeometryInstanceCount();++i)
        {
            const auto& instance=mpScene->getGeometryInstance(i);
            if (instance.getType()!=GeometryType::TriangleMesh) continue;
            const auto& mesh=mpScene->getMesh(MeshID(instance.geometryID));
            for(uint32_t t=0;t<mesh.getTriangleCount();++t) triangles.emplace_back(i,t);
        }
        mpTriangles=mpDevice->createStructuredBuffer(sizeof(uint2),mTriangleCount,ResourceBindFlags::ShaderResource,
            MemoryType::DeviceLocal,triangles.data());
        mpTriangleRanges=mpDevice->createStructuredBuffer(sizeof(uint4),mTriangleCount);
    }
    if (!mpBoundMin || mAllocatedResolution != mSettings.gridResolution)
    {
        // Drop parameter-block references before changing resource generations.
        mpClearGeometry = mpMakeJobs = mpFinalizeJobs = mpVoxelize = mpDebug = nullptr;
        mpClearFrame = mpInject = mpCompact = mpGlobalLeaves = mpGlobalLevel = mpPublish = nullptr;
        resetClusterPasses();
        mpForest = nullptr;
        mpFlux = mpCount = mpCompactIndices = mpMass = mpGlobalTree = mpRepresentativePosition = mpRepresentativeNormal = nullptr;
        mpBoundMin = mpDevice->createStructuredBuffer(sizeof(uint4), cells);
        mpBoundMax = mpDevice->createStructuredBuffer(sizeof(uint4), cells);
        mpInverse = mpDevice->createStructuredBuffer(sizeof(uint32_t), cells);
        const std::array<uint32_t, 32> zero = {};
        mpState = mpDevice->createStructuredBuffer(sizeof(uint32_t), 32,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, zero.data());
        mpJobs = mpDevice->createStructuredBuffer(sizeof(uint2), mJobCapacity);
        mpDispatchArgs = mpDevice->createStructuredBuffer(sizeof(uint32_t), 3,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::IndirectArg);
        mAllocatedResolution = mSettings.gridResolution;
        mGeometryValid = false;
    }
    if (!mGeometryValid && mSettings.freezeUpdates)
    {
        mFallbackReason = "Frozen proposal is invalid; unfreeze to rebuild";
        return;
    }
    auto makePass = [&](const char* entry)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary("RenderPasses/RTPT/RTPTVXPGGeometry.cs.slang").csEntry(entry);
        desc.addTypeConformances(mpScene->getTypeConformances());
        desc.setShaderModel(ShaderModel::SM6_6);
        return ComputePass::create(mpDevice, desc, mpScene->getSceneDefines(), true);
    };
    auto execute = [&](const ref<ComputePass>& pass, uint3 size)
    {
        auto root = pass->getRootVar();
        auto scene = root.findMember("gScene");
        if (scene.isValid()) mpScene->bindShaderDataForRaytracing(context, scene);
        bind(root, 0, true);
        pass->execute(context, size);
    };
    if (!mGeometryValid)
    {
        FALCOR_PROFILE(context, "VXPGGeometry");
        const auto& bounds = mpScene->getSceneBounds();
        const float3 extent = bounds.extent();
        const float side = std::max(1.e-3f, std::max(extent.x, std::max(extent.y, extent.z))) * 1.0001f;
        mGridMin = bounds.center() - float3(0.5f * side);
        mCellSize = side / float(mSettings.gridResolution);
        if (!mpClearGeometry) mpClearGeometry = makePass("clearGeometry");
        if (!mpMakeJobs) mpMakeJobs = makePass("makeGeometryJobs");
        if (!mpFinalizeJobs) mpFinalizeJobs = makePass("finalizeGeometryJobs");
        if (!mpVoxelize) mpVoxelize = makePass("voxelizeGeometry");
        for (const auto& buffer : {mpState,mpBoundMin,mpBoundMax,mpJobs,mpTriangleRanges,mpDispatchArgs})
            context->uavBarrier(buffer.get());
        execute(mpClearGeometry, uint3(cells, 1, 1));
        context->uavBarrier(mpState.get());
        context->uavBarrier(mpBoundMin.get());
        context->uavBarrier(mpBoundMax.get());
        constexpr uint32_t triangleRow=65535u*64u;
        execute(mpMakeJobs, uint3(std::min(mTriangleCount,triangleRow),(mTriangleCount+triangleRow-1)/triangleRow,1));
        context->uavBarrier(mpState.get());
        context->uavBarrier(mpJobs.get());
        context->uavBarrier(mpTriangleRanges.get());
        execute(mpFinalizeJobs, uint3(1));
        context->uavBarrier(mpDispatchArgs.get());
        auto root = mpVoxelize->getRootVar();
        mpScene->bindShaderDataForRaytracing(context, root["gScene"]);
        bind(root, 0, true);
        mpVoxelize->executeIndirect(context, mpDispatchArgs.get());
        context->uavBarrier(mpBoundMin.get());
        context->uavBarrier(mpBoundMax.get());
        context->uavBarrier(mpState.get());
        mGeometryValid = true;
        mFallbackReason = "Voxel bounds built; lighting distribution not built";
    }
    if (mSettings.debugEnabled && debugOutput)
    {
        if (!mpDebug) mpDebug = makePass("debugGeometry");
        auto root = mpDebug->getRootVar();
        mpScene->bindShaderDataForRaytracing(context, root["gScene"]);
        bind(root, 0, true);
        root["gVXPGDebug"] = debugOutput;
        mpDebug->execute(context, uint3(mFrameDim, 1));
    }
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
            bind(mpClearDiagnostics->getRootVar(), mLightingFrameIndex, true);
            mpClearDiagnostics->execute(context, uint3(32,1,1));
            context->uavBarrier(mpState.get());
        }
        return;
    }
    const uint32_t cells = mSettings.gridResolution * mSettings.gridResolution * mSettings.gridResolution;
    if (!mpFlux || mAllocatedCapacity != mSettings.maxVoxels || any(mAllocatedFrameDim != mFrameDim))
    {
        mpClearFrame = mpInject = mpCompact = mpGlobalLeaves = mpGlobalLevel = mpPublish = nullptr;
        resetClusterPasses();
        mpForest = nullptr;
        mpFlux = mpDevice->createStructuredBuffer(sizeof(uint64_t), cells);
        mpCount = mpDevice->createStructuredBuffer(sizeof(uint32_t), cells);
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
        mpCompact = makePrepare("compact");
        mpGlobalLeaves = makePrepare("globalLeaves");
        mpGlobalLevel = makePrepare("globalLevel");
        mpPublish = makePrepare("publish");
    }
    if (!mpInject)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary("RenderPasses/RTPT/RTPTVXPGInject.cs.slang").csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());
        desc.setShaderModel(ShaderModel::SM6_6);
        DefineList defines = mpScene->getSceneDefines();
        defines.add(mpSampleGenerator->getDefines());
        defines.add("ENABLE_PG", "0");
        defines.add("ENABLE_NRD", "0");
        defines.add("RTPT_VXPG_DETAILED_DIAGNOSTICS", mSettings.detailedDiagnostics ? "1" : "0");
        defines.add("RTPT_VXPG_SHARED_INJECTION", mSettings.sharedInjectionEnabled ? "1" : "0");
        defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
        defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
        defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
        mpInject = ComputePass::create(mpDevice, desc, defines, true);
    }
    ++mGeneration;
    auto execute = [&](const ref<ComputePass>& pass, uint3 size)
    {
        bind(pass->getRootVar(), mLightingFrameIndex, true);
        pass->execute(context, size);
    };
    {
        FALCOR_PROFILE(context, "VXPGClear");
        context->uavBarrier(mpState.get());
        context->uavBarrier(mpGlobalTree.get());
        context->uavBarrier(mpMass.get());
        context->uavBarrier(mpCompactIndices.get());
        context->uavBarrier(mpInverse.get());
        context->uavBarrier(mpFlux.get());
        context->uavBarrier(mpCount.get());
        context->uavBarrier(mpBoundMax.get());
        execute(mpClearFrame, uint3(cells, 1, 1));
        context->uavBarrier(mpState.get());
        context->uavBarrier(mpFlux.get());
        context->uavBarrier(mpCount.get());
        context->uavBarrier(mpBoundMax.get());
        context->uavBarrier(mpInverse.get());
    }
    if (mSettings.sharedInjectionEnabled)
    {
        context->uavBarrier(mpRepresentativePosition.get());
        context->uavBarrier(mpRepresentativeNormal.get());
    }
    mLightingPrepared = true;
}

void Manager::barrierInjection(RenderContext* context) const
{
    for (const auto& buffer : {mpFlux, mpCount, mpState, mpBoundMax, mpRepresentativePosition, mpRepresentativeNormal})
        if (buffer) context->uavBarrier(buffer.get());
}

void Manager::updateLighting(RenderContext* context, EnvMapSampler* envSampler, uint32_t seed, bool useNEE,
    uint32_t sampleOffset, bool useNRD)
{
    if (!mLightingPrepared) return;
    mLightingPrepared = false;
    const uint32_t cells = mSettings.gridResolution * mSettings.gridResolution * mSettings.gridResolution;
    auto execute = [&](const ref<ComputePass>& pass, uint3 size)
    {
        bind(pass->getRootVar(), mLightingFrameIndex, true);
        pass->execute(context, size);
    };
    {
        FALCOR_PROFILE(context, "VXPGInject");
        context->uavBarrier(mpPrimaryPosition.get());
        context->uavBarrier(mpPrimaryNormal.get());
        context->uavBarrier(mpPrimaryHit.get());
        context->uavBarrier(mpRepresentativePosition.get());
        context->uavBarrier(mpRepresentativeNormal.get());
        auto root = mpInject->getRootVar();
        bind(root, mLightingFrameIndex, true);
        mpScene->bindShaderDataForRaytracing(context, root["gScene"]);
        mpSampleGenerator->bindShaderData(root);
        if (envSampler && mpScene->useEnvLight()) envSampler->bindShaderData(root["gEnvMapSampler"]);
        root["gParams"]["seed"] = seed;
        root["gParams"]["useNEE"] = useNEE ? 1u : 0u;
        root["gParams"]["sampleOffset"] = sampleOffset;
        root["gParams"]["useNRD"] = useNRD ? 1u : 0u;
        mpInject->execute(context, uint3(mFrameDim, 1));
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
    {
        FALCOR_PROFILE(context, "VXPGCompactAndTree");
        execute(mpCompact, uint3(cells, 1, 1));
        context->uavBarrier(mpMass.get());
        context->uavBarrier(mpCompactIndices.get());
        context->uavBarrier(mpInverse.get());
        context->uavBarrier(mpState.get());
        mpGlobalLeaves->getRootVar()["VXPGTreeLevel"]["leafCapacity"] = mLeafCapacity;
        execute(mpGlobalLeaves, uint3(mLeafCapacity, 1, 1));
        context->uavBarrier(mpGlobalTree.get());
        for (uint32_t offset = mLeafCapacity / 2; offset > 0; offset /= 2)
        {
            auto root = mpGlobalLevel->getRootVar();
            root["VXPGTreeLevel"]["nodeOffset"] = offset;
            root["VXPGTreeLevel"]["nodeCount"] = offset;
            execute(mpGlobalLevel, uint3(offset, 1, 1));
            context->uavBarrier(mpGlobalTree.get());
        }
    }
    if (mSettings.visibilityEnabled) updateVisibility(context);
    {
        context->uavBarrier(mpState.get());
        execute(mpPublish, uint3(1));
        context->uavBarrier(mpState.get());
    }
    mDistributionValid = true;
    mReady = true;
    mFallbackReason.clear();
    mModelDiagnosticsAvailable = mSettings.detailedDiagnostics;
    mModelDiagnosticsFrameIndex = mLightingFrameIndex;
    ++mLightingFrameIndex;
}

void Manager::updateVisibility(RenderContext* context)
{
    const uint32_t rows = ((mFrameDim.x + mSettings.superpixelSize - 1) / mSettings.superpixelSize) *
        ((mFrameDim.y + mSettings.superpixelSize - 1) / mSettings.superpixelSize);
    if (!mpForest || mAllocatedSuperpixelSize != mSettings.superpixelSize)
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
        execute(mpAssignClusters, uint3(mSettings.maxVoxels, 1, 1));
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
        mpEncode->execute(context, uint3(mLeafCapacity, 1, 1));
        context->uavBarrier(sorted.get());
        for (uint32_t shift = 0; shift < 32; shift += 8)
        {
            root = rootFor(mpHistogramPass);
            constants(root, shift);
            root["gVXPGSortInput"] = sorted;
            root["gVXPGHistogram"] = mpHistogram;
            mpHistogramPass->execute(context, uint3(mLeafCapacity, 1, 1));
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
            mpScatter->execute(context, uint3(mLeafCapacity, 1, 1));
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
        execute(mpInitializeForest, uint3(4 * mSettings.maxVoxels + 64, 1, 1));
        context->uavBarrier(mpForest.get());
        auto root = rootFor(mpForestLeaves);
        context->uavBarrier(mpCompactToLeaf.get());
        root["gVXPGSortInput"] = sorted;
        mpForestLeaves->execute(context, uint3(mSettings.maxVoxels, 1, 1));
        context->uavBarrier(mpForest.get());
        context->uavBarrier(mpCompactToLeaf.get());
        for (uint32_t level = 1; (mLeafCapacity >> level) > 0; ++level)
        {
            root = rootFor(mpForestLevel);
            root["VXPGClusterBuild"]["treeLevel"] = level;
            mpForestLevel->execute(context, uint3(mLeafCapacity >> level, mSettings.clusterCount, 1));
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
    if (!mSettings.debugEnabled || mSettings.debugMode == 0 || !mSettings.visibilityEnabled || !mDistributionValid || !mpDistributionDebug) return;
    auto root = mpDistributionDebug->getRootVar();
    bind(root, mLightingFrameIndex, true);
    root["gVXPGDebug"] = output;
    mpDistributionDebug->execute(context, uint3(mFrameDim, 1));
}
}
