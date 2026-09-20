#include "MyPT.h"
#include "PG/SDTree.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include <chrono>
#include <cmath>
#include <limits>

namespace
{
constexpr uint32_t kHeaderStride = 32;
constexpr uint32_t kVertexStride = 80;
constexpr uint32_t kDiagnosticCount = 16;
constexpr uint64_t kMiB = 1024ull * 1024ull;
uint64_t bufferBytes(const ref<Buffer>& buffer) { return buffer ? buffer->getSize() : 0; }

// Different entry points dead-strip different parts of the common binding contract.
template<typename T> void setPG(const ShaderVar& root, const char* name, const T& value)
{
    auto var = root.findMember(name);
    if (var.isValid()) var = value;
}

void checkPGLayout(const ShaderVar& root)
{
    const std::pair<const char*, size_t> layouts[] = {
        {"gPGPathHeaders", kHeaderStride}, {"gPGVertexRecords", kVertexStride},
        {"gPGReadSpatial", sizeof(PG::SpatialNode)}, {"gPGBuildSpatial", sizeof(PG::SpatialNode)},
        {"gPGReadDirectional", sizeof(PG::DirectionalNode)}, {"gPGBuildDirectional", sizeof(PG::DirectionalNode)}
    };
    for (const auto& [name, stride] : layouts)
    {
        const auto v = root.findMember(name);
        if (!v.isValid()) continue;
        const auto type = v.getType()->asResourceType();
        FALCOR_CHECK(type && type->getSize() == stride, "PG CPU/shader layout mismatch for {} (expected {} bytes)", name, stride);
    }
}
}

void MyPT::resetPG()
{
    mPG = {};
    mPGResetRequested = true;
}

void MyPT::resetPGCache()
{
    mPGResetRequested = true;
    mOptionsChanged = true;
    mFrameCount = 0;
}

void MyPT::renderPGUI(Gui::Widgets& widget)
{
    widget.text(mPG.status);
    mOptionsChanged |= widget.checkbox("Use path guiding", mPGUseGuiding);
    widget.checkbox("Train SD-tree", mPGTrain);
    mOptionsChanged |= widget.var("Guiding fraction", mPGGuideFraction, 0.f, 0.95f);
    widget.var("Training iterations", mPGTrainingIterations, 1u, 24u);
    bool reset = widget.var("Tree budget (MiB)", mPGTreeBudgetMB, 1u, 4096u);
    widget.var("Record budget (MiB)", mPGRecordBudgetMB, 1u, 4096u);
    widget.tooltip("Only selected existing paths are recorded. No additional training rays. Records are bounded by this budget.");
    if (widget.button("Reset PG")) resetPGCache();
    if (reset) resetPGCache();
    widget.text("Epoch " + std::to_string(mPG.epochsCompleted) + ", spp " + std::to_string(mPG.epochSpp) +
        "/" + std::to_string(mPG.epochTargetSpp) + ", generation " + std::to_string(mPGGeneration));
    if (mPG.tree)
    {
        const auto& s = mPG.tree->statistics();
        widget.text("Spatial leaves " + std::to_string(s.spatialLeaves) + ", directional nodes " + std::to_string(s.directionalNodes));
        widget.text("Published training vertices " + std::to_string(mPG.trainedVertices) +
            ", invalid " + std::to_string(mPG.invalidSamples) + ", overflow " + std::to_string(mPG.overflowPaths));
    }
}

Properties MyPT::getPGStats() const
{
    Properties s;
    s["status"] = mPG.status;
    s["readGeneration"] = mPGGeneration;
    s["frameIndex"] = mPG.frameIndex;
    s["epochsCompleted"] = mPG.epochsCompleted;
    s["epochSpp"] = mPG.epochSpp;
    s["epochTargetSpp"] = mPG.epochTargetSpp;
    s["frozen"] = mPG.frozen;
    s["trainedPaths"] = mPG.trainedPaths;
    s["trainedVertices"] = mPG.trainedVertices;
    s["invalidSamples"] = mPG.invalidSamples;
    s["overflowPaths"] = mPG.overflowPaths;
    s["guidedSamples"] = mPG.guidedSamples;
    s["bsdfFallbackSamples"] = mPG.bsdfFallbackSamples;
    s["trainedSecondaryVertices"] = mPG.trainedSecondaryVertices;
    s["statisticsAtEpochBoundary"] = true;
    s["eventCountersAreSelectedPathsOnly"] = true;
    s["trainingPathCapacity"] = mPG.pathCapacity;
    s["recordsPerPath"] = mPG.verticesPerPath;
    s["ownerTileSize"] = mPG.tileSize;
    s["effectiveTrainingFraction"] = 1.f / (float(mPG.tileSize) * float(mPG.tileSize));
    s["recordBytes"] = bufferBytes(mPG.headers) + bufferBytes(mPG.vertices);
    s["treeBytes"] = bufferBytes(mPG.readSpatial) + bufferBytes(mPG.readDirectional) + bufferBytes(mPG.buildSpatial) +
        bufferBytes(mPG.buildDirectional) + bufferBytes(mPG.buildWeights) + bufferBytes(mPG.buildCounts);
    s["lastFinalizeCpuMs"] = mPG.lastFinalizeMs;
    s["readSpatialNodes"] = mPG.tree ? uint32_t(mPG.tree->readTree().spatial.size()) : 0u;
    s["readDirectionalNodes"] = mPG.tree ? uint32_t(mPG.tree->readTree().directional.size()) : 0u;
    s["buildSpatialNodes"] = mPG.tree ? uint32_t(mPG.tree->buildTree().spatial.size()) : 0u;
    s["buildDirectionalNodes"] = mPG.tree ? uint32_t(mPG.tree->buildTree().directional.size()) : 0u;
    s["treeBudgetBytes"] = uint64_t(mPGTreeBudgetMB) * kMiB;
    s["recordBudgetBytes"] = uint64_t(mPGRecordBudgetMB) * kMiB;
    s["hasDistribution"] = mPG.tree && mPG.tree->statistics().hasDistribution;
    s["budgetLimited"] = mPG.tree && mPG.tree->statistics().budgetLimited;
    s["treeReservedPeakBytes"] = mPG.tree ? mPG.tree->statistics().memoryBytes : uint64_t(0);
    return s;
}

void MyPT::uploadPGTrees(RenderContext* context, bool includeBuild)
{
    // First version synchronizes epoch publication explicitly. No old in-flight
    // buffer is overwritten; this wait is part of the measured total cost.
    context->submit(true);
    // Parameter blocks own strong resource references. Merely resetting the
    // member buffers would retain full records/builds inside frozen passes.
    auto unbind = [&](const ShaderVar& root)
    {
        for (const char* name : {"gPGReadSpatial", "gPGReadDirectional", "gPGBuildSpatial", "gPGBuildDirectional",
            "gPGBuildWeightBits", "gPGBuildSpatialCounts", "gPGPathHeaders", "gPGVertexRecords"})
            setPG(root, name, ref<Buffer>{});
    };
    if (mPG.vars) unbind(mPG.vars->getRootVar());
    for (const auto& pass : {mPG.prepareRecords, mPG.buildTraining, mPG.buildDistribution})
        if (pass) unbind(pass->getRootVar());
    const auto& read = mPG.tree->readTree();
    mPG.readSpatial = mpDevice->createStructuredBuffer(sizeof(PG::SpatialNode), uint32_t(read.spatial.size()),
        ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, read.spatial.data());
    mPG.readDirectional = mpDevice->createStructuredBuffer(sizeof(PG::DirectionalNode), uint32_t(read.directional.size()),
        ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, read.directional.data());
    if (includeBuild)
    {
        const auto& build = mPG.tree->buildTree();
        mPG.buildSpatial = mpDevice->createStructuredBuffer(sizeof(PG::SpatialNode), uint32_t(build.spatial.size()),
            ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, build.spatial.data());
        mPG.buildDirectional = mpDevice->createStructuredBuffer(sizeof(PG::DirectionalNode), uint32_t(build.directional.size()),
            ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, build.directional.data());
        mPG.buildWeights = mpDevice->createStructuredBuffer(4, uint32_t(build.directional.size() * 4));
        mPG.buildCounts = mpDevice->createStructuredBuffer(4, uint32_t(build.spatial.size()));
        context->clearUAV(mPG.buildWeights->getUAV().get(), uint4(0));
        context->clearUAV(mPG.buildCounts->getUAV().get(), uint4(0));
    }
    else
    {
        mPG.buildSpatial = nullptr;
        mPG.buildDirectional = nullptr;
        mPG.buildWeights = nullptr;
        mPG.buildCounts = nullptr;
    }
    if (!mPG.diagnostics) mPG.diagnostics = mpDevice->createStructuredBuffer(4, kDiagnosticCount);
    context->clearUAV(mPG.diagnostics->getUAV().get(), uint4(0));
}

void MyPT::bindPG(const ShaderVar& var, bool training)
{
    const auto& b = mPG.tree->bounds();
    auto tree = var.findMember("PGTreeCB");
    if (tree.isValid())
    {
        setPG(tree, "gPGSceneMin", float3(b.min[0], b.min[1], b.min[2]));
        setPG(tree, "gPGSceneMax", float3(b.max[0], b.max[1], b.max[2]));
        setPG(tree, "gPGReadSpatialCount", uint32_t(mPG.tree->readTree().spatial.size()));
        setPG(tree, "gPGReadDirectionalCount", uint32_t(mPG.tree->readTree().directional.size()));
        setPG(tree, "gPGBuildSpatialCount", uint32_t(mPG.tree->buildTree().spatial.size()));
        setPG(tree, "gPGBuildDirectionalCount", uint32_t(mPG.tree->buildTree().directional.size()));
        setPG(tree, "gPGTreeGeneration", mPGGeneration);
    }
    auto frame = var.findMember("PGFrameCB");
    if (frame.isValid())
    {
        setPG(frame, "gPGFrameDim", mPG.dimensions);
        setPG(frame, "gPGTrain", training ? 1u : 0u);
        setPG(frame, "gPGUseGuiding", mPGUseGuiding ? 1u : 0u);
        setPG(frame, "gPGGuideFraction", mPGGuideFraction);
        setPG(frame, "gPGOwnerTileSize", mPG.tileSize);
        setPG(frame, "gPGPathCapacity", mPG.pathCapacity);
        setPG(frame, "gPGRecordsPerPath", mPG.verticesPerPath);
        setPG(frame, "gPGOwnerSeed", mSeed ^ 0x51ed270bu);
        setPG(frame, "gPGFrameIndex", mFrameCount);
    }
    setPG(var, "gPGReadSpatial", mPG.readSpatial);
    setPG(var, "gPGReadDirectional", mPG.readDirectional);
    setPG(var, "gPGBuildSpatial", mPG.buildSpatial);
    setPG(var, "gPGBuildDirectional", mPG.buildDirectional);
    setPG(var, "gPGBuildWeightBits", mPG.buildWeights);
    setPG(var, "gPGBuildSpatialCounts", mPG.buildCounts);
    setPG(var, "gPGPathHeaders", mPG.headers);
    setPG(var, "gPGVertexRecords", mPG.vertices);
    setPG(var, "gPGDiagnostics", mPG.diagnostics);
}

void MyPT::finalizePGEpoch(RenderContext* context, bool continueTraining)
{
    if (!mPG.tree || mPG.epochSpp == 0) return;
    const auto start = std::chrono::steady_clock::now();
    {
        FALCOR_PROFILE(context, "PG.BuildDistribution");
        context->uavBarrier(mPG.buildWeights.get());
        bindPG(mPG.buildDistribution->getRootVar(), true);
        mPG.buildDistribution->execute(context, uint3(uint32_t(mPG.tree->buildTree().spatial.size()), 1, 1));
        context->uavBarrier(mPG.buildWeights.get());
    }
    // getElements() uses Falcor's synchronized readBuffer path. No image/path
    // records are read back, only this epoch's compact tree statistics.
    std::vector<float> weights;
    std::vector<uint32_t> counts, diagnostics;
    {
        FALCOR_PROFILE(context, "PG.Readback");
        weights = mPG.buildWeights->getElements<float>();
        counts = mPG.buildCounts->getElements<uint32_t>();
        diagnostics = mPG.diagnostics->getElements<uint32_t>();
    }
    {
        FALCOR_PROFILE(context, "PG.Rebuild");
        if (mPG.tree->finalizeEpoch(weights, counts, mPG.epochsCompleted, continueTraining)) ++mPGGeneration;
        std::string error;
        FALCOR_CHECK(mPG.tree->validate(&error), "PG tree validation failed: {}", error);
    }
    // Counter indices are shared with PG/PathRecord.slang.
    mPG.trainedPaths += diagnostics[1];
    mPG.trainedVertices += diagnostics[3];
    mPG.invalidSamples += uint64_t(diagnostics[5]) + diagnostics[6] + diagnostics[12];
    mPG.overflowPaths += diagnostics[7];
    mPG.guidedSamples += diagnostics[9];
    mPG.bsdfFallbackSamples += diagnostics[10];
    mPG.trainedSecondaryVertices += diagnostics[11];
    ++mPG.epochsCompleted;
    mPG.epochSpp = 0;
    mPG.epochTargetSpp = uint32_t(std::min(uint64_t(mPG.epochTargetSpp) * 2, uint64_t(1) << 30));
    {
        FALCOR_PROFILE(context, "PG.Upload");
        uploadPGTrees(context, continueTraining);
    }
    mPG.lastFinalizeMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

void MyPT::executePG(RenderContext* context, const RenderData& data)
{
    FALCOR_CHECK(!mpScene->hasProceduralGeometry(), "PG currently supports the MyPT triangle geometry path only.");
    const uint2 dims = data.getDefaultTextureDims();
    if (dims.x == 0 || dims.y == 0) return;
    auto refresh = [&]()
    {
        auto& dict = data.getDictionary();
        dict[kRenderPassRefreshFlags] = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None) |
            RenderPassRefreshFlags::RenderOptionsChanged;
    };
    const auto benign = Scene::UpdateFlags::CameraMoved | Scene::UpdateFlags::CameraPropertiesChanged | Scene::UpdateFlags::CameraSwitched;
    const auto changes = mPGPendingSceneUpdates | mpScene->getUpdates();
    if ((changes & ~benign) != Scene::UpdateFlags::None) mPGResetRequested = true;
    mPGPendingSceneUpdates = Scene::UpdateFlags::None;
    auto staleCompute = [](const ref<ComputePass>& p)
    { return p && p->getVars() && p->getVars()->getReflection() != p->getProgram()->getReflector(); };
    if ((mPG.vars && mPG.vars->getReflection() != mPG.program->getReflector()) || staleCompute(mPG.prepareRecords) ||
        staleCompute(mPG.buildTraining) || staleCompute(mPG.buildDistribution)) mPGResetRequested = true;
    if (mPGResetRequested || !mPG.tree)
    {
        context->submit(true);
        mPG = {};
        mPG.tree = std::make_shared<PG::SDTree>();
        auto bounds = mpScene->getSceneBounds();
        float3 lo(-1.f), hi(1.f);
        if (std::isfinite(bounds.minPoint.x) && std::isfinite(bounds.minPoint.y) && std::isfinite(bounds.minPoint.z) &&
            std::isfinite(bounds.maxPoint.x) && std::isfinite(bounds.maxPoint.y) && std::isfinite(bounds.maxPoint.z) &&
            all(bounds.maxPoint >= bounds.minPoint))
        {
            const float3 padding = max((bounds.maxPoint - bounds.minPoint) * 0.001f, float3(1e-3f));
            lo = bounds.minPoint - padding;
            hi = bounds.maxPoint + padding;
        }
        PG::Config config;
        config.memoryBudgetBytes = uint64_t(mPGTreeBudgetMB) * kMiB;
        config.spatialThreshold = mPGSpatialThreshold;
        config.directionalThreshold = mPGDirectionalThreshold;
        config.maxSpatialDepth = mPGMaxSpatialDepth;
        config.maxDirectionalDepth = mPGMaxDirectionalDepth;
        mPG.tree->reset({{lo.x, lo.y, lo.z}, {hi.x, hi.y, hi.z}}, config);
        mPG.epochTargetSpp = mPGInitialEpochSpp;
        mPG.epochLimit = mPGTrainingIterations;
        mPG.configuredIterations = mPGTrainingIterations;
        mPG.previousTrainRequest = mPGTrain;
        ++mPGGeneration;
        uploadPGTrees(context, mPGTrain);
        mPGResetRequested = false;
        refresh();
    }
    if (mPG.configuredIterations != mPGTrainingIterations)
    {
        mPG.configuredIterations = mPGTrainingIterations;
        mPG.epochLimit = mPGTrainingIterations;
    }
    if (mPGTrain && !mPG.previousTrainRequest && mPG.epochsCompleted >= mPG.epochLimit)
        mPG.epochLimit = mPG.epochsCompleted + mPGTrainingIterations;
    mPG.previousTrainRequest = mPGTrain;
    bool training = mPGTrain && mPG.epochsCompleted < mPG.epochLimit;
    if (!training && mPG.wasTraining)
    {
        if (mPG.epochSpp > 0) finalizePGEpoch(context, false);
        else uploadPGTrees(context, false);
    }
    if (training && !mPG.buildWeights) uploadPGTrees(context, true);
    const auto camera = mpScene->getCamera();
    const auto view = camera->getViewProjMatrixNoJitter();
    const float2 lens(camera->getApertureRadius(), camera->getFocalDistance());
    const bool resized = any(mPG.dimensions != dims);
    if (resized || (mPG.frameIndex > 0 && (view != mPG.viewProj || any(lens != mPG.lens)))) refresh();
    mPG.viewProj = view;
    mPG.lens = lens;
    mPG.dimensions = dims;
    mPG.verticesPerPath = mMaxBounces + 2;
    if (training)
    {
        uint32_t tile = 1;
        while (1.0 / (double(tile) * double(tile)) > mPGTrainingFraction && tile < 32768) tile *= 2;
        const uint64_t pathBytes = kHeaderStride + uint64_t(kVertexStride) * mPG.verticesPerPath;
        auto slots = [&](uint32_t t) { return uint64_t((dims.x + t - 1) / t) * ((dims.y + t - 1) / t); };
        while (slots(tile) * pathBytes > uint64_t(mPGRecordBudgetMB) * kMiB && tile < 32768) tile *= 2;
        FALCOR_CHECK(slots(tile) * pathBytes <= uint64_t(mPGRecordBudgetMB) * kMiB,
            "PG record budget cannot hold one complete path. Increase pgRecordBudgetMB or reduce maxBounces.");
        const uint64_t paths = slots(tile), records = paths * mPG.verticesPerPath;
        FALCOR_CHECK(records <= std::numeric_limits<uint32_t>::max(), "PG vertex indexing exceeds 32 bits.");
        mPG.tileSize = tile;
        mPG.pathCapacity = uint32_t(paths);
        if (!mPG.headers || mPG.headers->getElementCount() != paths)
            mPG.headers = mpDevice->createStructuredBuffer(kHeaderStride, uint32_t(paths));
        if (!mPG.vertices || mPG.vertices->getElementCount() != records)
            mPG.vertices = mpDevice->createStructuredBuffer(kVertexStride, uint32_t(records));
    }
    else
    {
        mPG.pathCapacity = 0;
        mPG.headers = nullptr;
        mPG.vertices = nullptr;
    }
    if (training && !mPG.prepareRecords)
    {
        mPG.prepareRecords = ComputePass::create(mpDevice, "RenderPasses/MyPT/PG/PrepareRecords.cs.slang", "main");
        mPG.buildTraining = ComputePass::create(mpDevice, "RenderPasses/MyPT/PG/BuildTraining.cs.slang", "main");
        mPG.buildDistribution = ComputePass::create(mpDevice, "RenderPasses/MyPT/PG/BuildDistribution.cs.slang", "main");
        checkPGLayout(mPG.prepareRecords->getRootVar());
        checkPGLayout(mPG.buildTraining->getRootVar());
        checkPGLayout(mPG.buildDistribution->getRootVar());
    }
    if (mpScene->useEmissiveLights())
    {
        if (!mpEmissiveSampler) mpEmissiveSampler = std::make_unique<EmissivePowerSampler>(context, mpScene->getILightCollection(context));
        mpEmissiveSampler->update(context, mpScene->getILightCollection(context));
    }
    DefineList defines = mpScene->getSceneDefines();
    defines.add(mpSampleGenerator->getDefines());
    if (mpEmissiveSampler) defines.add(mpEmissiveSampler->getDefines());
    defines.add("MAX_BOUNCES", std::to_string(mMaxBounces));
    defines.add("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    defines.add("USE_MIS", "1");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add("MYPT_HAS_RAY_STATS2", data.getTexture("rayStats2") ? "1" : "0");
    defines.add("is_valid_gViewW", data.getTexture("viewW") ? "1" : "0");
    if (mReferenceLambertian) defines.add("DiffuseBrdf", "0");
    if (!mPG.program || mPG.defines != defines)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary("RenderPasses/MyPT/PG/PathTrace.rt.slang");
        desc.setMaxPayloadSize(160);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(2);
        auto raygen = desc.addRayGen("rayGen");
        auto miss = desc.addMiss("scatterMiss");
        auto shadowMiss = desc.addMiss("shadowMiss");
        mPG.bindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
        mPG.bindingTable->setRayGen(raygen);
        mPG.bindingTable->setMiss(0, miss);
        mPG.bindingTable->setMiss(1, shadowMiss);
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            auto hit = desc.addHitGroup("scatterTriangleMeshClosestHit", "scatterTriangleMeshAnyHit");
            auto shadowHit = desc.addHitGroup("", "shadowTriangleMeshAnyHit");
            auto ids = mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh);
            mPG.bindingTable->setHitGroup(0, ids, hit);
            mPG.bindingTable->setHitGroup(1, ids, shadowHit);
        }
        mPG.vars = nullptr;
        mPG.program = Program::create(mpDevice, desc, defines);
        mPG.program->setTypeConformances(mpScene->getTypeConformances());
        mPG.vars = RtProgramVars::create(mpDevice, mPG.program, mPG.bindingTable);
        checkPGLayout(mPG.vars->getRootVar());
        mPG.defines = defines;
    }
    if (training)
    {
        FALCOR_PROFILE(context, "PG.PrepareRecords");
        context->uavBarrier(mPG.headers.get());
        bindPG(mPG.prepareRecords->getRootVar(), true);
        mPG.prepareRecords->execute(context, uint3(std::max(mPG.pathCapacity, kDiagnosticCount), 1, 1));
        context->uavBarrier(mPG.headers.get());
    }
    {
        FALCOR_PROFILE(context, "PG.PathTrace");
        auto var = mPG.vars->getRootVar();
        bindPG(var, training);
        mpSampleGenerator->bindShaderData(var);
        if (mpEmissiveSampler) mpEmissiveSampler->bindShaderData(var["gMyPTEmissiveSampler"]);
        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gSeed"] = mSeed;
        const auto& dict = data.getDictionary();
        var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
        var["CB"]["gRRProbability"] = mRRProbability;
        var["gVBuffer"] = data.getTexture("vbuffer");
        setPG(var, "gViewW", data.getTexture("viewW"));
        var["gOutputColor"] = data.getTexture("color");
        if (auto output = data.getTexture("rayStats2")) var["gRayStats2"] = output;
        mpScene->raytrace(context, mPG.program.get(), mPG.vars, uint3(dims, 1));
    }
    if (training)
    {
        {
            FALCOR_PROFILE(context, "PG.BuildTraining");
            context->uavBarrier(mPG.headers.get());
            context->uavBarrier(mPG.vertices.get());
            context->uavBarrier(mPG.buildWeights.get());
            context->uavBarrier(mPG.buildCounts.get());
            context->uavBarrier(mPG.diagnostics.get());
            bindPG(mPG.buildTraining->getRootVar(), true);
            mPG.buildTraining->execute(context, uint3(mPG.pathCapacity, 1, 1));
        }
        ++mPG.epochSpp;
        if (mPG.epochSpp >= mPG.epochTargetSpp)
        {
            const bool more = mPG.epochsCompleted + 1 < mPG.epochLimit;
            finalizePGEpoch(context, more);
            if (!more) { training = false; mPG.headers = nullptr; mPG.vertices = nullptr; mPG.pathCapacity = 0; }
        }
    }
    mPG.wasTraining = training;
    mPG.frozen = !training;
    mPG.status = training ? "Training world-space SD-tree" : "Frozen SD-tree (rendering continues)";
    ++mPG.frameIndex;
    ++mFrameCount;
}
