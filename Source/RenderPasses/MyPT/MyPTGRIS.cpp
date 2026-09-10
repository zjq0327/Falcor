#include "MyPT.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "RenderGraph/RenderPassStandardFlags.h"

void MyPT::resetGRIS()
{
    mGRIS = {};
}

void MyPT::executeGRIS(RenderContext* context, const RenderData& data)
{
    FALCOR_CHECK(!mpScene->hasProceduralGeometry(), "GRIS currently supports triangle geometry only.");
    const uint2 dimensions = data.getDefaultTextureDims();
    if (dimensions.x == 0 || dimensions.y == 0) { mGRIS.historyValid = false; return; }
    const bool useSpatial = mSpatialReuse && mSpatialNeighborCount > 0 && mSpatialReuseRounds > 0;
    const auto& camera = mpScene->getCamera();
    const bool useTemporal = mTemporalReuse && mMaxHistoryLength > 0 && camera->getApertureRadius() == 0.f;
    const bool useHybrid = mShiftStrategy == ShiftStrategy::Hybrid;
    if (auto texture = data.getTexture("spatialDebug")) context->clearTexture(texture.get(), float4(0.f));
    if (auto texture = data.getTexture("temporalDebug")) context->clearTexture(texture.get(), float4(0.f));
    if (auto texture = data.getTexture("shiftDebug")) context->clearTexture(texture.get(), float4(0.f));

    // The suffix is only reusable while geometry, materials and lighting are unchanged.
    // CameraPropertiesChanged also includes per-frame jitter, so inspect its finer flags.
    const auto updates = mpScene->getUpdates() | mPendingSceneUpdates;
    mPendingSceneUpdates = IScene::UpdateFlags::None;
    const auto cameraOnly = IScene::UpdateFlags::CameraMoved | IScene::UpdateFlags::CameraPropertiesChanged |
        IScene::UpdateFlags::SceneGraphChanged;
    const auto benignCameraChanges = Camera::Changes::Movement | Camera::Changes::Jitter | Camera::Changes::History;
    const auto refresh = data.getDictionary().getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    if (!useTemporal || (updates & ~cameraOnly) != IScene::UpdateFlags::None ||
        (camera->getChanges() & ~benignCameraChanges) != Camera::Changes::None ||
        refresh != RenderPassRefreshFlags::None ||
        (mGRIS.historyValid && camera->getData().prevViewProjMatNoJitter != mGRIS.previousViewProj))
        mGRIS.historyValid = false;

    // Sampler specialization can change with scene lighting, independently of UI options.
    if (mpScene->useEmissiveLights())
    {
        if (!mpEmissiveSampler)
            mpEmissiveSampler = std::make_unique<EmissivePowerSampler>(context, mpScene->getILightCollection(context));
        mpEmissiveSampler->update(context, mpScene->getILightCollection(context));
    }
    if (mpScene->useEnvLight() && (!mGRIS.envSampler || mGRIS.envSampler->getEnvMap() != mpScene->getEnvMap()))
        mGRIS.envSampler = std::make_unique<EnvMapSampler>(mpDevice, mpScene->getEnvMap());

    DefineList defines = mpScene->getSceneDefines();
    defines.add("SAMPLE_GENERATOR_TYPE", std::to_string(SAMPLE_GENERATOR_TINY_UNIFORM));
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add("GRIS_USE_NEE", "1");
    defines.add("GRIS_USE_MIS", mUseMIS ? "1" : "0");
    defines.add("GRIS_SHIFT_STRATEGY", std::to_string(uint32_t(mShiftStrategy)));
    defines.add("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    defines.add("GRIS_HAS_VIEW", data.getTexture("viewW") ? "1" : "0");
    defines.add("GRIS_HAS_REFERENCE", data.getTexture("ptReference") ? "1" : "0");
    defines.add("GRIS_HAS_F", data.getTexture("reservoirF") ? "1" : "0");
    defines.add("GRIS_HAS_DEBUG", data.getTexture("reservoirDebug") ? "1" : "0");
    defines.add("GRIS_HAS_INITIAL", data.getTexture("initialColor") ? "1" : "0");
    defines.add("GRIS_HAS_SPATIAL_DEBUG", data.getTexture("spatialDebug") ? "1" : "0");
    defines.add("GRIS_HAS_TEMPORAL_DEBUG", data.getTexture("temporalDebug") ? "1" : "0");
    defines.add("GRIS_HAS_TEMPORAL_COLOR", data.getTexture("temporalColor") ? "1" : "0");
    defines.add("GRIS_HAS_MOTION", data.getTexture("mvec") ? "1" : "0");
    defines.add("GRIS_HAS_SHIFT_DEBUG", data.getTexture("shiftDebug") ? "1" : "0");
    defines.add("GRIS_HAS_PATH_DEBUG", data.getTexture("pathDebug") ? "1" : "0");
    if (mpEmissiveSampler) defines.add(mpEmissiveSampler->getDefines());

    if (!mGRIS.generatePaths || defines != mGRIS.defines)
    {
        ProgramDesc base;
        // Replay evaluates the same transport in separately compiled passes.
        // Preserve floating-point operation ordering across their call contexts.
        base.setCompilerFlags(SlangCompilerFlags::FloatingPointModePrecise);
        mpScene->getShaderModules(base.shaderModules);
        TypeConformanceList conformances;
        mpScene->getTypeConformances(conformances);
        base.addTypeConformances(conformances);
        auto create = [&](const char* filename)
        {
            auto desc = base;
            desc.addShaderLibrary(std::string("RenderPasses/MyPT/GRIS/") + filename).csEntry("main");
            return ComputePass::create(mpDevice, desc, defines);
        };
        mGRIS.generatePaths = create("GeneratePaths.cs.slang");
        mGRIS.tracePaths = create("TracePaths.cs.slang");
        mGRIS.temporalPathRetrace = create("TemporalPathRetrace.cs.slang");
        mGRIS.spatialPathRetrace = create("SpatialPathRetrace.cs.slang");
        mGRIS.validateShift = create("ValidateShift.cs.slang");
        mGRIS.temporalReuse = create("TemporalReuse.cs.slang");
        mGRIS.spatialReuse = create("SpatialReuse.cs.slang");
        mGRIS.resolve = create("Resolve.cs.slang");
        mGRIS.defines = defines;
        mGRIS.primary = nullptr; // Reflection may have changed (PackedHitInfo is scene-dependent).
        mGRIS.frameIndex = 0;
        mGRIS.historyValid = false;
    }
    if (!mGRIS.primary || any(mGRIS.dimensions != dimensions))
    {
        const uint64_t count = uint64_t(dimensions.x) * dimensions.y;
        FALCOR_CHECK(count <= UINT32_MAX, "GRIS buffer element count overflow.");
        auto var = mGRIS.generatePaths->getRootVar();
        // Reflect the actual shader resources; no duplicated C++ layout/stride constants.
        mGRIS.primary = mpDevice->createStructuredBuffer(var["gPrimary"], uint32_t(count));
        mGRIS.fresh = mpDevice->createStructuredBuffer(var["gFresh"], uint32_t(count));
        mGRIS.reference = mpDevice->createStructuredBuffer(var["gReference"], uint32_t(count));
        mGRIS.temporal = nullptr;
        mGRIS.historyPrimary = nullptr;
        mGRIS.historyReservoir = nullptr;
        mGRIS.hybridPairs = nullptr;
        mGRIS.historyValid = false;
        for (auto& buffer : mGRIS.spatial) buffer = nullptr;
        mGRIS.dimensions = dimensions;
        mGRIS.frameIndex = 0;
    }
    if (useTemporal && !mGRIS.historyReservoir)
    {
        auto var = mGRIS.generatePaths->getRootVar();
        const uint32_t count = dimensions.x * dimensions.y;
        mGRIS.historyPrimary = mpDevice->createStructuredBuffer(var["gPrimary"], count);
        mGRIS.historyReservoir = mpDevice->createStructuredBuffer(var["gFresh"], count);
        mGRIS.temporal = mpDevice->createStructuredBuffer(var["gFresh"], count);
        mGRIS.historyValid = false;
    }
    if (useHybrid && (useTemporal || useSpatial))
    {
        const uint64_t count = uint64_t(dimensions.x) * dimensions.y * std::max(1u, mSpatialNeighborCount);
        FALCOR_CHECK(count <= UINT32_MAX, "GRIS hybrid pair buffer element count overflow.");
        if (!mGRIS.hybridPairs || mGRIS.hybridPairs->getElementCount() != uint32_t(count))
        {
            // Pair layouts are scene-dependent too. Reflect the retrace output rather
            // than duplicating HybridPair's shader layout on the host.
            const auto& pass = useSpatial ? mGRIS.spatialPathRetrace : mGRIS.temporalPathRetrace;
            mGRIS.hybridPairs = mpDevice->createStructuredBuffer(pass->getRootVar()["gHybridPairs"], uint32_t(count));
        }
    }
    auto bind = [&](const ref<ComputePass>& pass)
    {
        auto var = pass->getRootVar();
        var["CB"]["gDimensions"] = dimensions;
        var["CB"]["gFrameIndex"] = mGRIS.frameIndex;
        var["CB"]["gSeed"] = mSeed;
        var["CB"]["gCandidateCount"] = std::max(1u, mGIRISCandidateCount);
        // Preserve zero-candidate DI-only and maxBounces=0 direct-only behavior.
        var["CB"]["gMaxSurfaceBounces"] = mGIRISCandidateCount == 0 ? 1u : mMaxBounces + 1u;
        var["CB"]["gRRProbability"] = mRRProbability;
        var["CB"]["gSpatialNeighborCount"] = mSpatialNeighborCount;
        var["CB"]["gSpatialRadius"] = mSpatialRadius;
        var["CB"]["gSpatialDepthThreshold"] = mSpatialDepthThreshold;
        var["CB"]["gSpatialNormalThreshold"] = mSpatialNormalThreshold;
        var["CB"]["gSpatialNeighborOffset"] = mSpatialNeighborOffset;
        var["CB"]["gHistoryValid"] = uint32_t(mGRIS.historyValid);
        var["CB"]["gTemporalReprojection"] = uint32_t(mTemporalReprojection);
        var["CB"]["gMaxHistoryLength"] = mMaxHistoryLength;
        var["CB"]["gTemporalDepthThreshold"] = mTemporalDepthThreshold;
        var["CB"]["gTemporalNormalThreshold"] = mTemporalNormalThreshold;
        var["CB"]["gPreviousViewProj"] = mGRIS.previousViewProj;
        var["CB"]["gPreviousCameraPosition"] = mGRIS.previousCameraPosition;
        var["CB"]["gRoughnessThreshold"] = mSpecularRoughnessThreshold;
        var["CB"]["gNearFieldDistance"] = mNearFieldDistance;
        var["gPrimary"] = mGRIS.primary;
        var["gFresh"] = mGRIS.fresh;
        var["gReference"] = mGRIS.reference;
    };
    auto bindTransport = [&](const ref<ComputePass>& pass)
    {
        auto var = pass->getRootVar();
        mpScene->bindShaderDataForRaytracing(context, var["gScene"]);
        if (mpScene->useEnvLight()) mGRIS.envSampler->bindShaderData(var["gEnvSampler"]);
        if (mpEmissiveSampler) mpEmissiveSampler->bindShaderData(var["gMyPTEmissiveSampler"]);
    };
    auto bindHistory = [&](const ref<ComputePass>& pass)
    {
        auto var = pass->getRootVar();
        var["gHistoryPrimary"] = mGRIS.historyPrimary;
        var["gHistoryReservoir"] = mGRIS.historyReservoir;
        if (auto texture = data.getTexture("mvec")) var["gMotionVector"] = texture;
    };
    auto bindReuseDiagnostics = [&](const ref<ComputePass>& pass)
    {
        auto var = pass->getRootVar();
        if (useHybrid) var["gHybridPairs"] = mGRIS.hybridPairs;
        if (auto texture = data.getTexture("shiftDebug")) var["gShiftDebug"] = texture;
    };
    {
        FALCOR_PROFILE(context, "GRIS.GeneratePaths");
        bind(mGRIS.generatePaths);
        auto var = mGRIS.generatePaths->getRootVar();
        mpScene->bindShaderDataForRaytracing(context, var["gScene"]);
        var["gVBuffer"] = data.getTexture("vbuffer");
        if (data.getTexture("viewW")) var["gViewW"] = data.getTexture("viewW");
        mGRIS.generatePaths->execute(context, uint3(dimensions, 1));
    }
    {
        FALCOR_PROFILE(context, "GRIS.TracePaths");
        bind(mGRIS.tracePaths);
        auto var = mGRIS.tracePaths->getRootVar();
        bindTransport(mGRIS.tracePaths);
        if (auto texture = data.getTexture("pathDebug")) var["gPathDebug"] = texture;
        mGRIS.tracePaths->execute(context, uint3(dimensions, 1));
    }
    if (auto texture = data.getTexture("shiftDebug"))
    {
        FALCOR_PROFILE(context, "GRIS.ValidateShift");
        bind(mGRIS.validateShift);
        bindTransport(mGRIS.validateShift);
        mGRIS.validateShift->getRootVar()["gShiftDebug"] = texture;
        mGRIS.validateShift->execute(context, uint3(dimensions, 1));
    }
    ref<Buffer> current = mGRIS.fresh;
    if (useTemporal)
    {
        if (useHybrid)
        {
            FALCOR_PROFILE(context, "GRIS.TemporalPathRetrace");
            bind(mGRIS.temporalPathRetrace);
            bindHistory(mGRIS.temporalPathRetrace);
            bindTransport(mGRIS.temporalPathRetrace);
            bindReuseDiagnostics(mGRIS.temporalPathRetrace);
            mGRIS.temporalPathRetrace->execute(context, uint3(dimensions, 1));
        }
        FALCOR_PROFILE(context, "GRIS.TemporalReuse");
        bind(mGRIS.temporalReuse);
        bindHistory(mGRIS.temporalReuse);
        bindTransport(mGRIS.temporalReuse);
        bindReuseDiagnostics(mGRIS.temporalReuse);
        auto var = mGRIS.temporalReuse->getRootVar();
        var["gTemporalOutput"] = mGRIS.temporal;
        if (auto texture = data.getTexture("temporalDebug")) var["gTemporalDebug"] = texture;
        mGRIS.temporalReuse->execute(context, uint3(dimensions, 1));
        current = mGRIS.temporal;
    }
    const ref<Buffer> temporal = current;
    if (useSpatial)
    {
        for (uint round = 0; round < mSpatialReuseRounds; ++round)
        {
            if (useHybrid)
            {
                FALCOR_PROFILE(context, "GRIS.SpatialPathRetrace");
                bind(mGRIS.spatialPathRetrace);
                bindTransport(mGRIS.spatialPathRetrace);
                bindReuseDiagnostics(mGRIS.spatialPathRetrace);
                auto var = mGRIS.spatialPathRetrace->getRootVar();
                var["CB"]["gSpatialRound"] = round;
                var["gSpatialInput"] = current;
                mGRIS.spatialPathRetrace->execute(context, uint3(dimensions, 1));
            }
            FALCOR_PROFILE(context, "GRIS.SpatialReuse");
            auto& output = mGRIS.spatial[round & 1u];
            if (!output)
                output = mpDevice->createStructuredBuffer(mGRIS.generatePaths->getRootVar()["gFresh"], dimensions.x * dimensions.y);
            bind(mGRIS.spatialReuse);
            bindTransport(mGRIS.spatialReuse);
            bindReuseDiagnostics(mGRIS.spatialReuse);
            auto var = mGRIS.spatialReuse->getRootVar();
            var["CB"]["gSpatialRound"] = round;
            var["gSpatialInput"] = current;
            var["gSpatialOutput"] = output;
            if (auto texture = data.getTexture("spatialDebug")) var["gSpatialDebug"] = texture;
            mGRIS.spatialReuse->execute(context, uint3(dimensions, 1));
            current = output;
        }
    }
    {
        FALCOR_PROFILE(context, "GRIS.Resolve");
        bind(mGRIS.resolve);
        auto var = mGRIS.resolve->getRootVar();
        var["gCurrent"] = current;
        if (data.getTexture("temporalColor")) var["gTemporal"] = temporal;
        var["gColor"] = data.getTexture("color");
        if (auto texture = data.getTexture("ptReference")) var["gPTReference"] = texture;
        if (auto texture = data.getTexture("reservoirF")) var["gReservoirF"] = texture;
        if (auto texture = data.getTexture("reservoirDebug")) var["gReservoirDebug"] = texture;
        if (auto texture = data.getTexture("initialColor")) var["gInitialColor"] = texture;
        if (auto texture = data.getTexture("temporalColor")) var["gTemporalColor"] = texture;
        mGRIS.resolve->execute(context, uint3(dimensions, 1));
    }
    if (useTemporal)
    {
        // Reference endFrame preserves the FINAL spatial reservoir, together with the
        // actual primary directions. All history readers have finished before these copies.
        FALCOR_PROFILE(context, "GRIS.StoreHistory");
        context->copyResource(mGRIS.historyReservoir.get(), current.get());
        context->copyResource(mGRIS.historyPrimary.get(), mGRIS.primary.get());
        mGRIS.previousViewProj = camera->getViewProjMatrixNoJitter();
        mGRIS.previousCameraPosition = camera->getPosition();
        mGRIS.historyValid = true;
    }
    ++mGRIS.frameIndex;
}
