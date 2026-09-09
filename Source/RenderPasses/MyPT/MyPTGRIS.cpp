#include "MyPT.h"
#include "Rendering/Lights/EmissivePowerSampler.h"

void MyPT::resetGRIS()
{
    mGRIS = {};
}

void MyPT::executeGRIS(RenderContext* context, const RenderData& data)
{
    FALCOR_CHECK(!mpScene->hasProceduralGeometry(), "GRIS currently supports triangle geometry only.");
    const uint2 dimensions = data.getDefaultTextureDims();
    if (dimensions.x == 0 || dimensions.y == 0) return;
    const bool useSpatial = mSpatialReuse && mSpatialNeighborCount > 0 && mSpatialReuseRounds > 0;
    if (auto texture = data.getTexture("spatialDebug")) context->clearTexture(texture.get(), float4(0.f));

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
    defines.add("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    defines.add("GRIS_HAS_VIEW", data.getTexture("viewW") ? "1" : "0");
    defines.add("GRIS_HAS_REFERENCE", data.getTexture("ptReference") ? "1" : "0");
    defines.add("GRIS_HAS_F", data.getTexture("reservoirF") ? "1" : "0");
    defines.add("GRIS_HAS_DEBUG", data.getTexture("reservoirDebug") ? "1" : "0");
    defines.add("GRIS_HAS_INITIAL", data.getTexture("initialColor") ? "1" : "0");
    defines.add("GRIS_HAS_SPATIAL_DEBUG", data.getTexture("spatialDebug") ? "1" : "0");
    if (mpEmissiveSampler) defines.add(mpEmissiveSampler->getDefines());

    if (!mGRIS.generatePaths || defines != mGRIS.defines)
    {
        ProgramDesc base;
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
        mGRIS.spatialReuse = create("SpatialReuse.cs.slang");
        mGRIS.resolve = create("Resolve.cs.slang");
        mGRIS.defines = defines;
        mGRIS.primary = nullptr; // Reflection may have changed (PackedHitInfo is scene-dependent).
        mGRIS.frameIndex = 0;
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
        for (auto& buffer : mGRIS.spatial) buffer = nullptr;
        mGRIS.dimensions = dimensions;
        mGRIS.frameIndex = 0;
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
        var["gPrimary"] = mGRIS.primary;
        var["gFresh"] = mGRIS.fresh;
        var["gReference"] = mGRIS.reference;
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
        mpScene->bindShaderDataForRaytracing(context, var["gScene"]);
        if (mpScene->useEnvLight()) mGRIS.envSampler->bindShaderData(var["gEnvSampler"]);
        if (mpEmissiveSampler) mpEmissiveSampler->bindShaderData(var["gMyPTEmissiveSampler"]);
        mGRIS.tracePaths->execute(context, uint3(dimensions, 1));
    }
    ref<Buffer> current = mGRIS.fresh;
    if (useSpatial)
    {
        for (uint round = 0; round < mSpatialReuseRounds; ++round)
        {
            FALCOR_PROFILE(context, "GRIS.SpatialReuse");
            auto& output = mGRIS.spatial[round & 1u];
            if (!output)
                output = mpDevice->createStructuredBuffer(mGRIS.generatePaths->getRootVar()["gFresh"], dimensions.x * dimensions.y);
            bind(mGRIS.spatialReuse);
            auto var = mGRIS.spatialReuse->getRootVar();
            var["CB"]["gSpatialRound"] = round;
            var["gSpatialInput"] = current;
            var["gSpatialOutput"] = output;
            mpScene->bindShaderDataForRaytracing(context, var["gScene"]);
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
        var["gColor"] = data.getTexture("color");
        if (auto texture = data.getTexture("ptReference")) var["gPTReference"] = texture;
        if (auto texture = data.getTexture("reservoirF")) var["gReservoirF"] = texture;
        if (auto texture = data.getTexture("reservoirDebug")) var["gReservoirDebug"] = texture;
        if (auto texture = data.getTexture("initialColor")) var["gInitialColor"] = texture;
        mGRIS.resolve->execute(context, uint3(dimensions, 1));
    }
    ++mGRIS.frameIndex;
}
