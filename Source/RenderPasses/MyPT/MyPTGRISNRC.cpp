#include "MyPT.h"
#include "RenderGraph/RenderPassStandardFlags.h"

void MyPT::prepareNrcTrainingResources(const RenderData& data)
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
    const auto dim = mNRC.integration->getTrainingDimensions();
    const uint64_t count = uint64_t(dim.x) * dim.y;
    FALCOR_CHECK(count * mNrcQueryTrainingMaxVertices <= UINT32_MAX, "NRC query training allocation overflow");
    auto var = mNRC.buildQueryTraining->getRootVar();
    if (!mNRC.queryTrainingPaths || mNRC.queryTrainingPaths->getElementCount() != count)
        mNRC.queryTrainingPaths = mpDevice->createStructuredBuffer(var["gQueryTrainingPaths"], uint32_t(count));
    if (!mNRC.queryTrainingVertices || mNRC.queryTrainingVertices->getElementCount() != count * mNrcQueryTrainingMaxVertices)
        mNRC.queryTrainingVertices = mpDevice->createStructuredBuffer(var["gQueryTrainingVertices"], uint32_t(count * mNrcQueryTrainingMaxVertices));
}

void MyPT::bindNrcTraining(const ShaderVar& var, uint2 dimensions, uint32_t frame, uint32_t candidates, uint32_t seed)
{
    if (auto cb = var.findMember("QueryTrainingCB"); cb.isValid())
    {
        cb["gRecordFrameDim"] = dimensions;
        cb["gRecordTrainingDim"] = mNRC.integration->getTrainingDimensions();
        cb["gRecordFrameIndex"] = frame;
        cb["gRecordMaxVertices"] = mNrcQueryTrainingMaxVertices;
        cb["gRecordCandidateCount"] = candidates;
        cb["gRecordSeed"] = seed;
    }
    if (auto field = var.findMember("gQueryTrainingPaths"); field.isValid()) field = mNRC.queryTrainingPaths;
    if (auto field = var.findMember("gQueryTrainingVertices"); field.isValid()) field = mNRC.queryTrainingVertices;
}

bool MyPT::prepareGRISNRC(RenderContext* context, const RenderData& data)
{
    if (mMode != Mode::ReSTIR || !nrcUseCache() || mMaxBounces == 0 || mGIRISCandidateCount == 0)
    {
        if (mMode == Mode::ReSTIR) mNRC.status = "GRIS NRC bypassed; ordinary GRIS";
        return false;
    }
    FALCOR_CHECK(mShiftStrategy == ShiftStrategy::Reconnection, "ReSTIR with NRC enabled supports Reconnection only");
    if (mNRC.failed && !mNrcResetRequested) return false;
    try
    {
        FALCOR_CHECK(NrcIntegration::isCompiled(), "{}", NrcIntegration::getBuildStatus());
        // F5 also reloads programs owned by inactive graphs, without notifying
        // those passes. Never retain buffers/vars reflected from the old layout.
        auto stale = [](const ref<ComputePass>& pass)
        {
            return pass && pass->getVars() && pass->getVars()->getReflection() != pass->getProgram()->getReflector();
        };
        if (stale(mNRC.prepareQueryTraining) || stale(mNRC.buildQueryTraining) ||
            stale(mGRIS.tracePaths) || stale(mGRIS.finalizeNrc))
        {
            resetNRC();
            resetGRIS();
        }
        if (mNrcResetRequested && mNRC.integration) resetNRC();
        if (!mNRC.integration) mNRC.integration = std::make_unique<NrcIntegration>(mpDevice);
        auto& sdk = *mNRC.integration;
        FALCOR_CHECK(sdk.initialize(), "{}", sdk.getError());
        const auto bounds = mpScene->getSceneBounds();
        if (!mNRC.boundsValid || any(bounds.minPoint < mNRC.sceneBoundsMin) || any(bounds.maxPoint > mNRC.sceneBoundsMax))
        {
            const float3 padding = max((bounds.maxPoint - bounds.minPoint) * 0.1f, float3(mNrcFeatureSize));
            mNRC.sceneBoundsMin = bounds.minPoint - padding;
            mNRC.sceneBoundsMax = bounds.maxPoint + padding;
            mNRC.boundsValid = true;
        }
        NrcIntegration::Configuration config;
        config.frameDimensions = data.getDefaultTextureDims();
        config.sceneBoundsMin = mNRC.sceneBoundsMin;
        config.sceneBoundsMax = mNRC.sceneBoundsMax;
        config.smallestResolvableFeatureSize = mNrcFeatureSize;
        config.samplesPerPixel = mGIRISCandidateCount;
        config.maxPathVertices = mNrcQueryTrainingMaxVertices;
        config.trainingIterations = mNrcTrainingIterations;
        config.requestReset = mNrcResetRequested;
        const auto oldFrames = sdk.getFramesCompleted();
        FALCOR_CHECK(sdk.configure(context, config), "{}", sdk.getError());
        if (mNrcResetRequested || (oldFrames > 0 && sdk.getFramesCompleted() == 0))
        {
            ++mNrcCacheGeneration;
            mNRC.frameIndex = 0;
            mGRIS.historyValid = false;
            auto& dict = data.getDictionary();
            dict[kRenderPassRefreshFlags] = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None) |
                RenderPassRefreshFlags::RenderOptionsChanged;
        }
        mNrcResetRequested = false;
        mNRC.dimensions = config.frameDimensions;
        mNRC.failed = false;
        mNrcPendingSceneUpdates = Scene::UpdateFlags::None;
        // Allocate even while frozen so record toggles don't recompile GRIS/history.
        prepareNrcTrainingResources(data);
        mNRC.status = mNrcTrainCache ? "GRIS NRC active; QueryOnly training" : "GRIS NRC active; training paused";
        return true;
    }
    catch (const std::exception& e)
    {
        mNRC.status = std::string("GRIS NRC unavailable; ordinary GRIS fallback: ") + e.what();
        logWarning("{}", mNRC.status);
        mNRC.failed = true;
        mNrcResetRequested = false;
        if (mNRC.integration) mNRC.integration->shutdown();
        mGRIS.historyValid = false;
        return false;
    }
}
