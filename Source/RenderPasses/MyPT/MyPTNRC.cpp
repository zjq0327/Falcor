#include "MyPT.h"
#include "Core/Platform/OS.h"
#include "Core/Program/ProgramManager.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "Rendering/Lights/EmissivePowerSampler.h"

namespace
{
const char kNrcShader[] = "RenderPasses/MyPT/NRC/NrcPathTrace.rt.slang";
const char kNrcResolve[] = "RenderPasses/MyPT/NRC/NrcResolve.cs.slang";

void addNrcIncludePath(ProgramDesc& desc)
{
#if FALCOR_HAS_NRC
    auto directory = getRuntimeDirectory() / "shaders/RenderPasses/MyPT/NRC/SDK";
    if (!std::filesystem::is_regular_file(directory / "Nrc.hlsli")) directory = FALCOR_NRC_SDK_INCLUDE_DIR;
    desc.addCompilerArguments({"-I", directory.string()});
#endif
}
}

void MyPT::resetNRC()
{
    mNRC = {};
    mNrcResetRequested = true;
}

void MyPT::resetNrcCache()
{
    mNrcResetRequested = true;
    mNRC.failed = false;
    mOptionsChanged = true;
    mFrameCount = 0;
}

void MyPT::onHotReload(HotReloadFlags reloaded)
{
    if (!is_set(reloaded, HotReloadFlags::Program)) return;
    mpDevice->getRenderContext()->submit(true);
    resetNRC();
    resetGRIS();
    mTracer.pVars = nullptr;
    mFrameCount = 0;
    mOptionsChanged = true;
}

void MyPT::reloadShaders()
{
    // Script diagnostic uses the same program reload API as F5. F5 additionally
    // notifies every pass of the active graph; this method notifies this MyPT.
    mpDevice->getRenderContext()->submit(true);
    mpDevice->getProgramManager()->reloadAllPrograms(true);
    onHotReload(HotReloadFlags::Program);
}

Properties MyPT::getNRCStats() const
{
    Properties stats;
    const auto* sdk = mNRC.integration.get();
    stats["compiled"] = NrcIntegration::isCompiled();
    stats["available"] = sdk && sdk->isInitialized() && !mNRC.failed;
    stats["status"] = mNRC.status;
    stats["cacheGeneration"] = mNrcCacheGeneration;
    stats["frameIndex"] = mNRC.frameIndex;
    stats["trainingEnabled"] = mMode == Mode::NRC && mNrcUseCache && mMaxBounces > 0 && mNrcTrainCache;
    stats["trainingSource"] = "QueryOnly";
    stats["queryTrainingBufferBytes"] = (mNRC.queryTrainingPaths ? uint64_t(mNRC.queryTrainingPaths->getSize()) : 0ull) +
        (mNRC.queryTrainingVertices ? uint64_t(mNRC.queryTrainingVertices->getSize()) : 0ull);
    stats["publicBufferBytes"] = sdk ? sdk->getPublicBufferBytes() : uint64_t(0);
    stats["explicitTextureBytes"] = mNRC.explicitColor ? uint64_t(mNRC.dimensions.x) * mNRC.dimensions.y * 16 : uint64_t(0);
    const auto dimensions = sdk ? sdk->getTrainingDimensions() : uint2(0);
    stats["trainingWidth"] = dimensions.x;
    stats["trainingHeight"] = dimensions.y;
    stats["sdkFramesCompleted"] = sdk ? sdk->getFramesCompleted() : uint64_t(0);
    return stats;
}

void MyPT::executeNRC(RenderContext* context, const RenderData& data)
{
    const auto output = data.getTexture("color");
    const uint2 dimensions = data.getDefaultTextureDims();
    if (dimensions.x == 0 || dimensions.y == 0) return;
    auto refreshAccumulation = [&]()
    {
        auto& dict = data.getDictionary();
        const auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[kRenderPassRefreshFlags] = flags | RenderPassRefreshFlags::RenderOptionsChanged;
    };
    if (mNRC.failed && !mNrcResetRequested)
    {
        context->clearTexture(output.get(), float4(0.f));
        return;
    }
    try
    {
        FALCOR_CHECK(NrcIntegration::isCompiled(), "{}", NrcIntegration::getBuildStatus());
        FALCOR_CHECK(!mpScene->hasProceduralGeometry(), "NRC currently supports the MyPT triangle geometry path only");
        FALCOR_CHECK(!is_set(mNrcPendingSceneUpdates, Scene::UpdateFlags::GeometryChanged) &&
            !is_set(mNrcPendingSceneUpdates, Scene::UpdateFlags::RecompileNeeded),
            "NRC scene geometry or shader representation changed; reload the scene");
        // F5 resets all programs but only notifies the active graph. Detect an
        // old layout when a previously inactive NRC graph resumes rendering.
        auto stale = [](const NrcTracer& tracer)
        {
            return tracer.vars && tracer.program && tracer.vars->getReflection() != tracer.program->getReflector();
        };
        const bool staleResolve = mNRC.resolve &&
            mNRC.resolve->getVars()->getReflection() != mNRC.resolve->getProgram()->getReflector();
        auto staleCompute = [](const ref<ComputePass>& pass)
        {
            return pass && pass->getVars() && pass->getVars()->getReflection() != pass->getProgram()->getReflector();
        };
        if (stale(mNRC.query) || staleResolve ||
            staleCompute(mNRC.prepareQueryTraining) || staleCompute(mNRC.buildQueryTraining)) resetNRC();
        // Explicit reset creates a new SDK context to ensure a fresh network,
        // independent of the SDK's buffer-reconfiguration policy.
        if (mNrcResetRequested && mNRC.integration && mNRC.integration->isInitialized()) resetNRC();
        if (!mNRC.integration) mNRC.integration = std::make_unique<NrcIntegration>(mpDevice);
        auto& sdk = *mNRC.integration;
        FALCOR_CHECK(sdk.initialize(), "{}", sdk.getError());
        auto checkpoint = [&](const char* stage) { sdk.diagnosticCheckpoint(context, stage); };

        const bool resized = any(mNRC.dimensions != dimensions);
        const auto bounds = mpScene->getSceneBounds();
        // Preserve the encoding during ordinary animation. Reconfigure only if
        // geometry leaves the padded domain or the user explicitly resets it.
        if (!mNRC.boundsValid || mNrcResetRequested || any(bounds.minPoint < mNRC.sceneBoundsMin) ||
            any(bounds.maxPoint > mNRC.sceneBoundsMax))
        {
            const float3 padding = max((bounds.maxPoint - bounds.minPoint) * 0.1f, float3(mNrcFeatureSize));
            mNRC.sceneBoundsMin = bounds.minPoint - padding;
            mNRC.sceneBoundsMax = bounds.maxPoint + padding;
            mNRC.boundsValid = true;
        }
        NrcIntegration::Configuration config;
        config.frameDimensions = dimensions;
        config.sceneBoundsMin = mNRC.sceneBoundsMin;
        config.sceneBoundsMax = mNRC.sceneBoundsMax;
        config.smallestResolvableFeatureSize = mNrcFeatureSize;
        const bool recordQueries = mNrcTrainCache;
        config.maxPathVertices = mNrcQueryTrainingMaxVertices;
        config.trainingIterations = mNrcTrainingIterations;
        config.requestReset = mNrcResetRequested;
        const auto oldCompleted = sdk.getFramesCompleted();
        FALCOR_CHECK(sdk.configure(context, config), "{}", sdk.getError());
        if (mNrcResetRequested || resized || (oldCompleted > 0 && sdk.getFramesCompleted() == 0))
        {
            ++mNrcCacheGeneration;
            mNRC.frameIndex = 0;
            mOptionsChanged = true;
        }
        // Keep real scene changes made while this graph was inactive. Camera
        // jitter/history are benign; compare the actual lens and unjittered view.
        const auto& camera = mpScene->getCamera();
        const auto viewProj = camera->getViewProjMatrixNoJitter();
        const float2 lens(camera->getApertureRadius(), camera->getFocalDistance());
        if ((mNrcPendingSceneUpdates & ~Scene::UpdateFlags::CameraPropertiesChanged) != Scene::UpdateFlags::None ||
            (mNRC.frameIndex > 0 && (viewProj != mNRC.accumulationViewProj || any(lens != mNRC.accumulationLens))))
            mOptionsChanged = true;
        mNrcResetRequested = false;
        mNRC.failed = false;
        mNrcPendingSceneUpdates = Scene::UpdateFlags::None;

        if (resized || !mNRC.explicitColor)
        {
            mNRC.explicitColor = mpDevice->createTexture2D(dimensions.x, dimensions.y, ResourceFormat::RGBA32Float,
                1, 1, nullptr, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
            mNRC.dimensions = dimensions;
        }
        if (mpScene->useEmissiveLights())
        {
            if (!mNRC.emissiveSampler)
                mNRC.emissiveSampler = std::make_unique<EmissivePowerSampler>(context, mpScene->getILightCollection(context));
            mNRC.emissiveSampler->update(context, mpScene->getILightCollection(context));
        }

        if (recordQueries)
        {
            DefineList defines;
            defines.add("MYPT_HAS_NRC_TRAINING_DEBUG", data.getTexture("nrcTrainingDebug") ? "1" : "0");
            defines.add("MYPT_HAS_NRC_QUERY_TRAINING_DEBUG", data.getTexture("nrcQueryTrainingDebug") ? "1" : "0");
            auto create = [&](ref<ComputePass>& pass, const char* filename)
            {
                if (!pass)
                {
                    ProgramDesc desc;
                    desc.addShaderLibrary(std::string("RenderPasses/MyPT/NRC/") + filename).csEntry("main");
                    addNrcIncludePath(desc);
                    pass = ComputePass::create(mpDevice, desc, defines);
                }
                else if (pass->getProgram()->addDefines(defines)) pass->setVars(nullptr);
            };
            create(mNRC.prepareQueryTraining, "NrcPrepareQueryTraining.cs.slang");
            create(mNRC.buildQueryTraining, "NrcBuildTrainingFromQuery.cs.slang");
            const auto trainingDim = sdk.getTrainingDimensions();
            const uint64_t count = uint64_t(trainingDim.x) * trainingDim.y;
            FALCOR_CHECK(count * mNrcQueryTrainingMaxVertices <= UINT32_MAX, "NRC query training allocation overflow");
            auto var = mNRC.buildQueryTraining->getRootVar();
            if (!mNRC.queryTrainingPaths || mNRC.queryTrainingPaths->getElementCount() != count)
                mNRC.queryTrainingPaths = mpDevice->createStructuredBuffer(var["gQueryTrainingPaths"], uint32_t(count));
            if (!mNRC.queryTrainingVertices || mNRC.queryTrainingVertices->getElementCount() != count * mNrcQueryTrainingMaxVertices)
                mNRC.queryTrainingVertices = mpDevice->createStructuredBuffer(var["gQueryTrainingVertices"], uint32_t(count * mNrcQueryTrainingMaxVertices));
        }
        auto bindRecords = [&](const ShaderVar& var)
        {
            auto cb = var["QueryTrainingCB"];
            cb["gRecordFrameDim"] = dimensions;
            cb["gRecordTrainingDim"] = sdk.getTrainingDimensions();
            cb["gRecordFrameIndex"] = mFrameCount;
            cb["gRecordMaxVertices"] = mNrcQueryTrainingMaxVertices;
            if (auto field = var.findMember("gQueryTrainingPaths"); field.isValid()) field = mNRC.queryTrainingPaths;
            if (auto field = var.findMember("gQueryTrainingVertices"); field.isValid()) field = mNRC.queryTrainingVertices;
        };
        auto prepareQuery = [&]()
        {
            auto& tracer = mNRC.query;
            DefineList defines = mpScene->getSceneDefines();
            defines.add(mpSampleGenerator->getDefines());
            if (mNRC.emissiveSampler) defines.add(mNRC.emissiveSampler->getDefines());
            defines.add("NRC_QUERY", "1");
            defines.add("MYPT_NRC_QUERY_RECORDS", recordQueries ? "1" : "0");
            defines.add("MAX_BOUNCES", std::to_string(mMaxBounces));
            defines.add("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
            defines.add("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
            defines.add("USE_MIS", "1");
            defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
            defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
            defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
            defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
            defines.add("MYPT_HAS_RAY_STATS2", "0");
            defines.add("MYPT_HAS_NRC_QUERY_DEBUG", data.getTexture("nrcQueryDebug") ? "1" : "0");
            defines.add("is_valid_gVBuffer", "1");
            defines.add("is_valid_gViewW", data.getTexture("viewW") ? "1" : "0");
            defines.add("is_valid_gMotionVector", "0");
            defines.add("is_valid_gOutputColor", "1");
            if (mReferenceLambertian) defines.add("DiffuseBrdf", "0");
            if (!tracer.program || tracer.defines != defines)
            {
                ProgramDesc desc;
                desc.addShaderModules(mpScene->getShaderModules());
                desc.addShaderLibrary(recordQueries ?
                    "RenderPasses/MyPT/NRC/NrcQueryWithTrainingRecords.rt.slang" : kNrcShader);
                addNrcIncludePath(desc);
                desc.setMaxPayloadSize(recordQueries ? 384 : 256);
                desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
                desc.setMaxTraceRecursionDepth(2);
                auto raygen = desc.addRayGen("rayGen");
                auto scatterMiss = desc.addMiss("scatterMiss");
                auto shadowMiss = desc.addMiss("shadowMiss");
                auto table = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
                table->setRayGen(raygen);
                table->setMiss(0, scatterMiss);
                table->setMiss(1, shadowMiss);
                if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
                {
                    auto scatterHit = desc.addHitGroup("scatterTriangleMeshClosestHit", "scatterTriangleMeshAnyHit");
                    auto shadowHit = desc.addHitGroup("", "shadowTriangleMeshAnyHit");
                    table->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), scatterHit);
                    table->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), shadowHit);
                }
                tracer.vars = nullptr;
                tracer.program = Program::create(mpDevice, desc, defines);
                tracer.program->setTypeConformances(mpScene->getTypeConformances());
                tracer.bindingTable = table;
                tracer.vars = RtProgramVars::create(mpDevice, tracer.program, table);
                tracer.defines = defines;
            }
            auto var = tracer.vars->getRootVar();
            mpSampleGenerator->bindShaderData(var);
            if (mNRC.emissiveSampler) mNRC.emissiveSampler->bindShaderData(var["gMyPTEmissiveSampler"]);
            sdk.bindShaderData(var);
            if (recordQueries) bindRecords(var);
            auto cb = var["CB"];
            cb["gFrameCount"] = mFrameCount;
            cb["gSeed"] = mSeed;
            const auto& dict = data.getDictionary();
            cb["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
            cb["gRRProbability"] = mRRProbability;
            auto nrcCB = var["NrcRuntimeCB"];
            nrcCB["gNrcFrameDim"] = dimensions;
            nrcCB["gNrcUseCache"] = 1u;
            var["gVBuffer"] = data.getTexture("vbuffer");
            if (data.getTexture("viewW")) var["gViewW"] = data.getTexture("viewW");
            if (var.findMember("gOutputColor").isValid()) var["gOutputColor"] = mNRC.explicitColor;
            if (var.findMember("gNrcQueryDebug").isValid()) var["gNrcQueryDebug"] = data.getTexture("nrcQueryDebug");
        };

        NrcIntegration::FrameSettings frame;
        frame.trainTheCache = mNrcTrainCache;
        frame.trainingIterations = mNrcTrainingIterations;
        frame.terminationThreshold = mNrcTerminationThreshold;
        FALCOR_CHECK(sdk.beginFrame(context, frame), "{}", sdk.getError());
        checkpoint("BeginFrame");
        if (recordQueries)
        {
            FALCOR_PROFILE(context, "NRC.PrepareQueryTraining");
            bindRecords(mNRC.prepareQueryTraining->getRootVar());
            mNRC.prepareQueryTraining->execute(context, uint3(sdk.getTrainingDimensions(), 1));
            context->uavBarrier(mNRC.queryTrainingPaths.get());
        }
        checkpoint("PrepareQueryTraining");
        {
            FALCOR_PROFILE(context, "NRC.QueryPT");
            prepareQuery();
            sdk.prepareForPathTracing(context);
            mpScene->raytrace(context, mNRC.query.program.get(), mNRC.query.vars, uint3(dimensions, 1));
        }
        checkpoint("QueryPT");
        if (recordQueries)
        {
            FALCOR_PROFILE(context, "NRC.BuildTrainingFromQuery");
            context->uavBarrier(mNRC.queryTrainingPaths.get());
            context->uavBarrier(mNRC.queryTrainingVertices.get());
            auto var = mNRC.buildQueryTraining->getRootVar();
            bindRecords(var);
            sdk.prepareForPathTracing(context);
            sdk.bindShaderData(var);
            if (auto texture = data.getTexture("nrcTrainingDebug")) var["gNrcTrainingDebug"] = texture;
            if (auto texture = data.getTexture("nrcQueryTrainingDebug")) var["gNrcQueryTrainingDebug"] = texture;
            mNRC.buildQueryTraining->execute(context, uint3(sdk.getTrainingDimensions(), 1));
        }
        checkpoint("BuildTrainingFromQuery");
        if (auto explicitOutput = data.getTexture("nrcExplicit"))
            context->copyResource(explicitOutput.get(), mNRC.explicitColor.get());
        {
            FALCOR_PROFILE(context, "NRC.QueryAndTrain");
            FALCOR_CHECK(sdk.queryAndTrain(context), "{}", sdk.getError());
        }
        checkpoint("QueryAndTrain");
        {
            FALCOR_PROFILE(context, "NRC.Resolve");
            DefineList defines;
            defines.add("MYPT_HAS_NRC_CACHED", data.getTexture("nrcCached") ? "1" : "0");
            if (!mNRC.resolve)
            {
                ProgramDesc desc;
                desc.addShaderLibrary(kNrcResolve).csEntry("main");
                addNrcIncludePath(desc);
                mNRC.resolve = ComputePass::create(mpDevice, desc, defines);
            }
            else if (mNRC.resolve->getProgram()->addDefines(defines)) mNRC.resolve->setVars(nullptr);
            auto var = mNRC.resolve->getRootVar();
            sdk.bindResolveData(var);
            var["gNrcExplicit"] = mNRC.explicitColor;
            var["gOutputColor"] = output;
            if (auto cached = data.getTexture("nrcCached")) var["gNrcCached"] = cached;
            mNRC.resolve->execute(context, uint3(dimensions, 1));
        }
        checkpoint("Resolve");
        if (auto reference = data.getTexture("nrcSdkReference"))
        {
            // Optional validation of the custom resolve against the SDK, using
            // the very same queries and network output (no extra training).
            context->copyResource(reference.get(), mNRC.explicitColor.get());
            FALCOR_CHECK(sdk.resolve(context, reference), "{}", sdk.getError());
        }
        {
            FALCOR_PROFILE(context, "NRC.Submit");
            FALCOR_CHECK(sdk.endFrame(context), "{}", sdk.getError());
        }
        ++mNRC.frameIndex;
        mNRC.accumulationViewProj = viewProj;
        mNRC.accumulationLens = lens;
        ++mFrameCount;
        mNRC.status = mNrcTrainCache ? "NRC active; online training" : "NRC active; training paused";
        // AccumulatePass controls frame averaging, including online training.
        // Only configuration, scene, or cache lifecycle changes clear history.
        if (mOptionsChanged)
        {
            refreshAccumulation();
            mOptionsChanged = false;
        }
    }
    catch (const std::exception& error)
    {
        // Do not blend the first failed/black frame with previous valid output.
        refreshAccumulation();
        mNRC.failed = true;
        mNrcResetRequested = false;
        const std::string detail = error.what();
        mNRC.status = "NRC unavailable: " + detail.substr(0, detail.find('\n'));
        logError("NRC unavailable: {}", detail);
        context->clearTexture(output.get(), float4(0.f));
        if (mNRC.integration) mNRC.integration->shutdown();
    }
}
