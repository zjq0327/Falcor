#include "RTPT.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "Scene/Material/StandardMaterial.h"
#include "Utils/SampleGenerators/HaltonSamplePattern.h"
#include "Utils/Timing/Profiler.h"
#include <cmath>
#include <limits>

namespace
{
struct NRDOutput
{
    const char* name;
    const char* shaderName;
    ResourceFormat format;
};
const NRDOutput kNRDOutputs[] = {
    {"nrdDiffuseRadianceHitDist", "gNRDDiffuseRadianceHitDist", ResourceFormat::RGBA32Float},
    {"nrdSpecularRadianceHitDist", "gNRDSpecularRadianceHitDist", ResourceFormat::RGBA32Float},
    {"nrdEmission", "gNRDEmission", ResourceFormat::RGBA32Float},
    {"nrdDiffuseReflectance", "gNRDDiffuseReflectance", ResourceFormat::RGBA32Float},
    {"nrdSpecularReflectance", "gNRDSpecularReflectance", ResourceFormat::RGBA32Float},
    {"nrdResidualRadiance", "gNRDResidualRadiance", ResourceFormat::RGBA32Float},
    {"normWRoughnessMaterialID", "gNRDNormalRoughness", ResourceFormat::RGB10A2Unorm},
    {"viewZ", "gNRDViewZ", ResourceFormat::R32Float},
    {"mvecW", "gNRDMotionW", ResourceFormat::RGBA32Float},
};
const char* kSHARCOutputs[] = {"sharcDebug", "sharcCacheRadiance", "sharcStats"};
const Gui::DropdownList kSHARCDebugModes = {
    {0, "Voxel grid"}, {1, "Cached radiance"}, {2, "Sample count"}, {3, "Entry age"},
    {4, "Actual cache hits"}, {5, "Traced rays"}, {6, "Update coverage"}, {7, "Hash occupancy"},
};
const Gui::DropdownList kSHARCCapacities = {
    {1u << 16, "64K entries (2.5 MiB)"}, {1u << 18, "256K entries (10 MiB)"},
    {1u << 20, "1M entries (40 MiB)"}, {1u << 22, "4M entries (160 MiB)"},
};
}

extern "C" FALCOR_API_EXPORT void registerPlugin(PluginRegistry& registry)
{
    registry.registerClass<RenderPass, RTPT>();
    ScriptBindings::registerBinding([](pybind11::module& m)
    {
        pybind11::class_<RTPT, RenderPass, ref<RTPT>> pass(m, "RTPT");
        pass.def_property_readonly("vxpgStats", [](const RTPT& self) { return self.getVXPGStatistics().toPython(); });
        pass.def("vxpgTreeSnapshot", [](const RTPT& self) { return self.getVXPGTreeSnapshot().toPython(); });
        pass.def("resetVXPG", &RTPT::resetVXPG);
    });
}

RTPT::RTPT(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    mpVXPG = std::make_unique<RTPTVXPG::Manager>(mpDevice);
    setProperties(props);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

RTPTVXPG::RuntimeContext RTPT::getVXPGContext() const
{
    RTPTVXPG::RuntimeContext runtime;
    runtime.enabled = mEnableVXPG;
    runtime.guidingMode = mGuidingMode;
    runtime.sharcQueries = mEnableSHARC && mSHARCEnabled && mSHARCUseCache;
    runtime.sharedTraining = mVXPGSharedTrainingThisFrame;
    runtime.sharedWithSHARC = mVXPGSharedWithSHARCThisFrame;
    runtime.trainingStride = mSHARCUpdateStride;
    runtime.trainingBounces = mSHARCUpdateBounces;
    runtime.pairedCacheBytes = usesPairedSharc() ? uint64_t(mSHARCEntries) * 120ull : 0ull;
    runtime.sharcFrameIndex = mSHARCFrameIndex;
    runtime.diagnosticFrameAvailable = mVXPGDiagnosticFrameAvailable;
    runtime.diagnosticSampleOffset = mVXPGDiagnosticFrameSampleOffset;
    runtime.diagnosticSamplesPerPixel = mVXPGDiagnosticFrameSamplesPerPixel;
    runtime.diagnosticGeneration = mVXPGDiagnosticFrameGeneration;
    return runtime;
}

Properties RTPT::getVXPGStatistics() const
{
    return mpVXPG->getStatistics(mVXPGSettings, getVXPGContext());
}

Properties RTPT::getVXPGTreeSnapshot() const
{
    return mpVXPG->getTreeSnapshot(mVXPGSettings, getVXPGContext());
}

void RTPT::setProperties(const Properties& props)
{
    uint32_t samplesPerPixel = mSamplesPerPixel, maxBounces = mMaxBounces, rrStartBounce = mRRStartBounce, seed = mSeed;
    uint32_t maxAccumulationFrames = mMaxAccumulationFrames;
    bool useNEE = mUseNEE, useRussianRoulette = mUseRussianRoulette, accumulate = mAccumulate;
    bool enableNRD = mEnableNRD;
    bool enableSHARC = mEnableSHARC, sharcUseCache = mSHARCUseCache, sharcFreeze = mSHARCFreeze;
    bool sharcEnabled = mSHARCEnabled;
    uint32_t sharcEntries = mSHARCEntries, sharcUpdateStride = mSHARCUpdateStride, sharcUpdateBounces = mSHARCUpdateBounces;
    uint32_t sharcMinBounce = mSHARCMinBounce, sharcAccumulationFrames = mSHARCAccumulationFrames;
    uint32_t sharcStaleFrames = mSHARCStaleFrames, sharcDebugMode = mSHARCDebugMode;
    float sharcSceneScale = mSHARCSceneScale, sharcMinRoughness = mSHARCMinRoughness;
    auto vxpg = mVXPGSettings;
    auto guidingMode = mGuidingMode;
    bool enableVXPG = mEnableVXPG;
    for (const auto& [key, value] : props)
    {
        if (key == "samplesPerPixel") samplesPerPixel = value;
        else if (key == "maxBounces") maxBounces = value;
        else if (key == "rrStartBounce") rrStartBounce = value;
        else if (key == "seed") seed = value;
        else if (key == "useNEE") useNEE = value;
        else if (key == "useRussianRoulette") useRussianRoulette = value;
        else if (key == "accumulate") accumulate = value;
        else if (key == "maxAccumulationFrames") maxAccumulationFrames = value;
        else if (key == "enableNRD") enableNRD = value;
        else if (key == "enableSHARC") enableSHARC = value;
        else if (key == "sharcEnabled") sharcEnabled = value;
        else if (key == "sharcUseCache") sharcUseCache = value;
        else if (key == "sharcFreeze") sharcFreeze = value;
        else if (key == "sharcEntries") sharcEntries = value;
        else if (key == "sharcUpdateStride") sharcUpdateStride = value;
        else if (key == "sharcUpdateBounces") sharcUpdateBounces = value;
        else if (key == "sharcMinBounce") sharcMinBounce = value;
        else if (key == "sharcAccumulationFrames") sharcAccumulationFrames = value;
        else if (key == "sharcStaleFrames") sharcStaleFrames = value;
        else if (key == "sharcDebugMode") sharcDebugMode = value;
        else if (key == "sharcSceneScale") sharcSceneScale = value;
        else if (key == "sharcMinRoughness") sharcMinRoughness = value;
        else if (key == "enableVXPG") enableVXPG = value;
        else if (key == "guidingMode")
        {
            const std::string mode = value;
            FALCOR_CHECK(mode == "BSDF" || mode == "VXPG", "Invalid RTPT guiding mode '{}'.", mode);
            guidingMode = mode == "BSDF" ? RTPTVXPG::GuidingMode::BSDF : RTPTVXPG::GuidingMode::VXPG;
        }
        else if (!RTPTVXPG::parseSetting(key, value, vxpg))
            FALCOR_THROW("Unknown RTPT property '{}'.", key);
    }
    FALCOR_CHECK(samplesPerPixel >= 1 && samplesPerPixel <= 1024, "RTPT samplesPerPixel must be in [1, 1024].");
    FALCOR_CHECK(maxBounces >= 1 && maxBounces <= 64, "RTPT maxBounces must be in [1, 64].");
    FALCOR_CHECK(rrStartBounce >= 1 && rrStartBounce <= 64, "RTPT rrStartBounce must be in [1, 64].");
    FALCOR_CHECK(!enableNRD || (samplesPerPixel == 1 && !accumulate),
        "RTPT NRD mode requires samplesPerPixel=1 and accumulate=false; NRD manages temporal history.");
    FALCOR_CHECK(!enableSHARC || !accumulate,
        "RTPT SHaRC mode requires accumulate=false; its world-space cache changes between frames.");
    FALCOR_CHECK(!enableVXPG || !accumulate, "RTPT VXPG requires accumulate=false; use the independent FrameAccumulation pass.");
    RTPTVXPG::Manager::validate(vxpg);
    FALCOR_CHECK(sharcEntries >= (1u << 16) && sharcEntries <= (1u << 22) && (sharcEntries & (sharcEntries - 1)) == 0,
        "SHaRC entries must be a power of two in [65536, 4194304].");
    FALCOR_CHECK(sharcUpdateStride >= 1 && sharcUpdateStride <= 32 && sharcUpdateBounces >= 1 && sharcUpdateBounces <= 32,
        "SHaRC update stride and bounces must be in [1, 32].");
    FALCOR_CHECK(sharcMinBounce >= 1 && sharcMinBounce <= 64 && sharcDebugMode <= 7,
        "SHaRC minimum query bounce must be in [1, 64] and debug mode in [0, 7].");
    FALCOR_CHECK(sharcAccumulationFrames >= 1 && sharcAccumulationFrames <= 1024 && sharcStaleFrames >= 8 && sharcStaleFrames <= 1024,
        "SHaRC accumulation frames must be in [1, 1024] and stale frames in [8, 1024].");
    FALCOR_CHECK(std::isfinite(sharcSceneScale) && sharcSceneScale > 0.f && std::isfinite(sharcMinRoughness) &&
        sharcMinRoughness >= 0.f && sharcMinRoughness <= 1.f, "Invalid SHaRC scene scale or minimum roughness.");
    if (enableSHARC || enableVXPG)
        FALCOR_CHECK(mpDevice->getType() == Device::Type::D3D12 && mpDevice->isShaderModelSupported(ShaderModel::SM6_6),
            "RTPT SHaRC currently requires D3D12 and Shader Model 6.6 for native 16-bit types and 64-bit buffer atomics.");
    const bool newPairedSharc = enableSHARC && enableVXPG && guidingMode == RTPTVXPG::GuidingMode::VXPG &&
        vxpg.enabled;
    const bool pairedChanged = newPairedSharc != usesPairedSharc();
    const bool modeChanged = enableNRD != mEnableNRD || enableSHARC != mEnableSHARC || enableVXPG != mEnableVXPG ||
        guidingMode != mGuidingMode || pairedChanged;
    const auto vxpgChanges = RTPTVXPG::compareSettings(mVXPGSettings, vxpg);
    const bool vxpgStructureChanged = vxpgChanges.resources() || enableVXPG != mEnableVXPG;
    const bool vxpgTrainingChanged = useNEE != mUseNEE || seed != mSeed ||
        sharcUpdateStride != mSHARCUpdateStride || sharcUpdateBounces != mSHARCUpdateBounces ||
        (enableSHARC && sharcEnabled && !sharcFreeze) != (mEnableSHARC && mSHARCEnabled && !mSHARCFreeze);
    // Invalidate immediately for callers observing properties before the next
    // frame. configure() later applies resource changes without retiring again.
    if (vxpgStructureChanged)
        mpVXPG->invalidate(RTPTVXPG::Invalidation::Grid);
    else if (vxpgTrainingChanged)
        mpVXPG->invalidate(RTPTVXPG::Invalidation::LightingHistory);
    if (vxpgTrainingChanged) mpSparseUpdate = nullptr;
    const bool vxpgSignalChanged = vxpgTrainingChanged || vxpgStructureChanged || guidingMode != mGuidingMode || vxpgChanges.signal;
    if (vxpgChanges.diagnostics)
    {
        // Instrumentation does not change the transport signal or model. Do
        // not request a render-graph recompile or reset any temporal history.
        if (mpComputePass)
            mpComputePass->addDefine("RTPT_VXPG_DETAILED_DIAGNOSTICS", vxpg.detailedDiagnostics ? "1" : "0", true);
        if (mpSparseUpdate)
            mpSparseUpdate->addDefine("RTPT_VXPG_DETAILED_DIAGNOSTICS", vxpg.detailedDiagnostics ? "1" : "0", true);
        mVXPGDiagnosticFrameAvailable = false;
        mpVXPG->invalidateDiagnosticSnapshot();
        mVXPGUI.statisticsText.clear();
    }
    const bool sharcStructureChanged = enableSHARC != mEnableSHARC || sharcEntries != mSHARCEntries ||
        sharcSceneScale != mSHARCSceneScale || sharcUpdateBounces != mSHARCUpdateBounces;
    const bool sharcSignalChanged = sharcStructureChanged || sharcUseCache != mSHARCUseCache ||
        sharcUpdateStride != mSHARCUpdateStride || sharcMinBounce != mSHARCMinBounce || sharcMinRoughness != mSHARCMinRoughness ||
        sharcAccumulationFrames != mSHARCAccumulationFrames || sharcStaleFrames != mSHARCStaleFrames;
    mOptionsChanged |= samplesPerPixel != mSamplesPerPixel || maxBounces != mMaxBounces || rrStartBounce != mRRStartBounce ||
        seed != mSeed || useNEE != mUseNEE || useRussianRoulette != mUseRussianRoulette || accumulate != mAccumulate ||
        maxAccumulationFrames != mMaxAccumulationFrames || sharcEnabled != mSHARCEnabled || modeChanged || sharcSignalChanged || vxpgSignalChanged;
    mResetSHARCCache |= sharcStructureChanged || seed != mSeed || useNEE != mUseNEE || useRussianRoulette != mUseRussianRoulette;
    mResetSHARCCache |= pairedChanged;
    if (sharcEntries != mSHARCEntries)
    {
        mpSHARCHashEntries = mpSHARCAccumulation = mpSHARCResolved = nullptr;
        mpSHARCHashSnapshot = mpSHARCResolvedNext = nullptr;
        mpSHARCLocalAccumulation = mpSHARCLocalResolved = mpSHARCLocalNext = nullptr;
        mpSHARCSuffixAccumulation = mpSHARCSuffixResolved = mpSHARCSuffixNext = nullptr;
    }
    if (modeChanged || sharcUpdateBounces != mSHARCUpdateBounces)
    {
        mpSHARCResolve = nullptr;
        mpSparseUpdate = nullptr;
    }
    mSamplesPerPixel = samplesPerPixel;
    mMaxBounces = maxBounces;
    mRRStartBounce = rrStartBounce;
    mSeed = seed;
    mUseNEE = useNEE;
    mUseRussianRoulette = useRussianRoulette;
    mAccumulate = accumulate;
    mMaxAccumulationFrames = maxAccumulationFrames;
    mEnableNRD = enableNRD;
    mEnableSHARC = enableSHARC;
    mSHARCEnabled = sharcEnabled;
    mSHARCUseCache = sharcUseCache;
    mSHARCFreeze = sharcFreeze;
    mSHARCEntries = sharcEntries;
    mSHARCUpdateStride = sharcUpdateStride;
    mSHARCUpdateBounces = sharcUpdateBounces;
    mSHARCMinBounce = sharcMinBounce;
    mSHARCAccumulationFrames = sharcAccumulationFrames;
    mSHARCStaleFrames = sharcStaleFrames;
    mSHARCDebugMode = sharcDebugMode;
    mSHARCSceneScale = sharcSceneScale;
    mSHARCMinRoughness = sharcMinRoughness;
    mEnableVXPG = enableVXPG;
    mVXPGSettings = vxpg;
    mGuidingMode = guidingMode;
    if (modeChanged)
    {
        mpComputePass = nullptr;
        mpSparseUpdate = nullptr;
        mpCameraPattern = nullptr;
        mpJitterCamera = nullptr;
        requestRecompile();
    }
}

Properties RTPT::getProperties() const
{
    Properties props;
    props["samplesPerPixel"] = mSamplesPerPixel;
    props["maxBounces"] = mMaxBounces;
    props["rrStartBounce"] = mRRStartBounce;
    props["seed"] = mSeed;
    props["useNEE"] = mUseNEE;
    props["useRussianRoulette"] = mUseRussianRoulette;
    props["accumulate"] = mAccumulate;
    props["maxAccumulationFrames"] = mMaxAccumulationFrames;
    props["enableNRD"] = mEnableNRD;
    props["enableSHARC"] = mEnableSHARC;
    props["sharcEnabled"] = mSHARCEnabled;
    props["sharcUseCache"] = mSHARCUseCache;
    props["sharcFreeze"] = mSHARCFreeze;
    props["sharcEntries"] = mSHARCEntries;
    props["sharcUpdateStride"] = mSHARCUpdateStride;
    props["sharcUpdateBounces"] = mSHARCUpdateBounces;
    props["sharcMinBounce"] = mSHARCMinBounce;
    props["sharcAccumulationFrames"] = mSHARCAccumulationFrames;
    props["sharcStaleFrames"] = mSHARCStaleFrames;
    props["sharcDebugMode"] = mSHARCDebugMode;
    props["sharcSceneScale"] = mSHARCSceneScale;
    props["sharcMinRoughness"] = mSHARCMinRoughness;
    props["enableVXPG"] = mEnableVXPG;
    props["guidingMode"] = mGuidingMode == RTPTVXPG::GuidingMode::BSDF ? "BSDF" : "VXPG";
    RTPTVXPG::writeSettings(props, mVXPGSettings);
    return props;
}

RenderPassReflection RTPT::reflect(const CompileData& compileData)
{
    RenderPassReflection reflection;
    reflection.addOutput("color", "Linear HDR radiance, optionally progressively accumulated")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    reflection.addOutput("noisyColor", "Linear HDR radiance from the most recently traced frame")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    if (mEnableNRD)
    {
        for (const auto& output : kNRDOutputs)
            reflection.addOutput(output.name, "Current-frame NRD signal or primary-hit guide")
                .format(output.format)
                .bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    }
    if (mEnableSHARC)
        for (const auto* output : kSHARCOutputs)
            reflection.addOutput(output, "SHaRC visualization or current-frame cache diagnostics")
                .format(ResourceFormat::RGBA32Float)
                .bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    if (mEnableVXPG)
        reflection.addOutput("vxpgDebug", "VXPG voxel/proposal diagnostics, independent of NRD")
            .format(ResourceFormat::RGBA32Float)
            .bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    return reflection;
}

void RTPT::reset()
{
    mVXPGDiagnosticFrameAvailable = false;
    mSampleOffset = 0;
    mAccumulatedSamples = 0;
    mAccumulatedFrames = 0;
    mResetNRDHistory = true;
}

void RTPT::validateScene() const
{
    FALCOR_CHECK(mpScene->getGridVolumes().empty(), "RTPT currently supports surface transport only, without volumes.");
    for (uint32_t i = 0; i < mpScene->getGeometryCount(); ++i)
        FALCOR_CHECK(mpScene->getGeometryType(GlobalGeometryID(i)) == Scene::GeometryType::TriangleMesh,
            "RTPT currently supports triangle meshes only.");

    const auto& materials = mpScene->getMaterialSystem();
    for (uint32_t i = 0; i < materials.getMaterialCount(); ++i)
    {
        const auto& material = materials.getMaterial(MaterialID(i));
        const auto* standard = dynamic_cast<const StandardMaterial*>(material.get());
        FALCOR_CHECK(standard && standard->getSpecularTransmission() == 0.f && standard->getDiffuseTransmission() == 0.f,
            "RTPT currently supports opaque/alpha-tested StandardMaterial surfaces with reflection only (material '{}').",
            material->getName());
    }
}

void RTPT::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;
    mpVXPG->setScene(pScene);
    mpComputePass = nullptr;
    mpSHARCResolve = nullptr;
    mpSparseUpdate = nullptr;
    mpEnvMapSampler = nullptr;
    mLightingMask = ~0u;
    mpCameraPattern = nullptr;
    mpJitterCamera = nullptr;
    mResetSHARCCache = true;
    reset();
    if (mpScene)
    {
        validateScene();
        if (mpScene->getCamera()->getApertureRadius() > 0.f)
            logWarning("RTPT uses a pinhole camera; aperture is ignored.");
    }
}

bool RTPT::updateSceneState()
{
    const auto updates = mpScene->getUpdates();
    const bool programsChanged = is_set(updates, IScene::UpdateFlags::RecompileNeeded) ||
        is_set(updates, IScene::UpdateFlags::GeometryChanged);
    if (programsChanged)
    {
        mpComputePass = nullptr;
        mpSparseUpdate = nullptr;
        mpVXPG->setScene(mpScene);
    }
    if (is_set(updates, IScene::UpdateFlags::GeometryChanged) || is_set(updates, IScene::UpdateFlags::MaterialsChanged))
        validateScene();
    if (is_set(updates, IScene::UpdateFlags::EnvMapChanged)) mpEnvMapSampler = nullptr;

    // Ignore jitter/history-only updates. Ordinary motion retains NRD history
    // and the world-space VXPG grid; final accumulation observes scene changes.
    const auto cameraChanges = is_set(updates, IScene::UpdateFlags::CameraPropertiesChanged)
        ? mpScene->getCamera()->getChanges() : Camera::Changes::None;
    const bool viewChanged = (cameraChanges & ~(Camera::Changes::Jitter | Camera::Changes::History)) != Camera::Changes::None;
    const bool cameraMoved = viewChanged ||
        (updates & (IScene::UpdateFlags::CameraSwitched | IScene::UpdateFlags::CameraMoved)) != IScene::UpdateFlags::None;
    const bool projectionChanged = is_set(cameraChanges, Camera::Changes::Frustum);
    const bool sceneChanged = viewChanged || (updates & ~IScene::UpdateFlags::CameraPropertiesChanged) != IScene::UpdateFlags::None;

    const auto discontinuities = IScene::UpdateFlags::CameraSwitched | IScene::UpdateFlags::GeometryChanged |
        IScene::UpdateFlags::MaterialsChanged | IScene::UpdateFlags::EmissiveMaterialsChanged |
        IScene::UpdateFlags::EnvMapChanged | IScene::UpdateFlags::EnvMapPropertiesChanged |
        IScene::UpdateFlags::LightIntensityChanged | IScene::UpdateFlags::LightPropertiesChanged |
        IScene::UpdateFlags::LightCountChanged | IScene::UpdateFlags::RenderSettingsChanged |
        IScene::UpdateFlags::RecompileNeeded;
    const bool nrdDiscontinuity = projectionChanged || (updates & discontinuities) != IScene::UpdateFlags::None;
    // Preserve the existing conservative rebuild policy for world changes.
    const auto worldInvalidations = discontinuities & ~IScene::UpdateFlags::CameraSwitched;
    const auto movingScene = IScene::UpdateFlags::GeometryMoved | IScene::UpdateFlags::MeshesChanged | IScene::UpdateFlags::LightsMoved;
    const bool worldChanged = (updates & (worldInvalidations | movingScene)) != IScene::UpdateFlags::None;
    if (worldChanged) mResetSHARCCache = true;
    // setScene() already invalidates the grid. World changes take precedence
    // over view-only changes; each scene update has one model invalidation.
    if (!programsChanged)
    {
        if (worldChanged) mpVXPG->invalidate(RTPTVXPG::Invalidation::Grid);
        // Scene notifications run before configure(); use the requested freeze
        // state so a same-frame camera change cannot retain a stale proposal.
        else if (cameraMoved || projectionChanged) mpVXPG->cameraChanged(projectionChanged, mVXPGSettings.freezeUpdates);
    }
    return mEnableNRD ? nrdDiscontinuity : sceneChanged;
}

void RTPT::prepareProgram(RenderContext* pRenderContext)
{
    const bool compileVXPG = mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG;
    // Request the mesh light collection before querying useEmissiveLights().
    if (mpScene->getRenderSettings().useEmissiveLights)
        mpScene->getILightCollection(pRenderContext);

    const uint32_t lightingMask = (mpScene->useEnvLight() ? 1u : 0u) |
        (mpScene->useEnvBackground() ? 2u : 0u) |
        (mpScene->useEmissiveLights() ? 4u : 0u) |
        (mpScene->useAnalyticLights() ? 8u : 0u);
    if (lightingMask != mLightingMask)
    {
        mLightingMask = lightingMask;
        mpVXPG->lightingChanged();
        mpComputePass = nullptr;
        mpSparseUpdate = nullptr;
        mResetSHARCCache = true;
        reset();
    }
    if (mpScene->useEnvLight())
    {
        if (!mpEnvMapSampler || mpEnvMapSampler->getEnvMap() != mpScene->getEnvMap())
            mpEnvMapSampler = std::make_unique<EnvMapSampler>(mpDevice, mpScene->getEnvMap());
    }
    else mpEnvMapSampler = nullptr;

    if (!mpComputePass || ((mEnableSHARC || compileVXPG) && !mpSparseUpdate) ||
        (mEnableSHARC && !mpSHARCResolve))
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary("RenderPasses/RTPT/RTPT.cs.slang").csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());
        DefineList defines = mpScene->getSceneDefines();
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
        defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
        defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
        defines.add("ENABLE_NRD", mEnableNRD ? "1" : "0");
        defines.add("ENABLE_SHARC", mEnableSHARC ? "1" : "0");
        defines.add("ENABLE_VXPG", compileVXPG ? "1" : "0");
        defines.add("RTPT_VXPG_DETAILED_DIAGNOSTICS", mVXPGSettings.detailedDiagnostics ? "1" : "0");
        defines.add("RTPT_SHARC_PAIR", usesPairedSharc() ? "1" : "0");
        if (mEnableSHARC || mEnableVXPG)
        {
            desc.setShaderModel(ShaderModel::SM6_6);
            desc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
        }
        if (mEnableSHARC)
        {
            defines.add("SHARC_MATERIAL_DEMODULATION", "1");
            defines.add("SHARC_SEPARATE_EMISSIVE", "1");
            defines.add("SHARC_ENABLE_CACHE_RESAMPLING", "0");
            defines.add("SHARC_PROPAGATION_DEPTH", std::to_string(mSHARCUpdateBounces + 1));
            defines.add("SHARC_SAMPLE_NUM_THRESHOLD", "4");
            defines.add("SHARC_ENABLE_SH_ENCODING", "0");
            defines.add("SHARC_ENABLE_RESPONSIVE_LIGHTING", "0");
            defines.add("SHARC_USE_FP16", "0");
            defines.add("HASH_GRID_ENABLE_64_BIT_ATOMICS", "1");
            defines.add("SHARC_UPDATE", "0");
            defines.add("SHARC_QUERY", "1");
        }
        if (!mpComputePass)
            mpComputePass = ComputePass::create(mpDevice, desc, defines, true);
        if ((mEnableSHARC || compileVXPG) && !mpSparseUpdate)
        {
            ProgramDesc updateDesc;
            updateDesc.addShaderModules(mpScene->getShaderModules());
            updateDesc.addShaderLibrary("RenderPasses/RTPT/RTPTSparseUpdate.cs.slang").csEntry("main");
            updateDesc.addTypeConformances(mpScene->getTypeConformances());
            updateDesc.setShaderModel(ShaderModel::SM6_6);
            updateDesc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
            auto updateDefines = defines;
            updateDefines.add("ENABLE_NRD", "0");
            updateDefines.add("SHARC_UPDATE", "1");
            updateDefines.add("SHARC_QUERY", "0");
            mpSparseUpdate = ComputePass::create(mpDevice, updateDesc, updateDefines, true);
        }
        if (mEnableSHARC && !mpSHARCResolve)
        {
            ProgramDesc resolveDesc;
            resolveDesc.addShaderLibrary("RenderPasses/RTPT/RTPTSharcResolve.cs.slang").csEntry("main");
            resolveDesc.setShaderModel(ShaderModel::SM6_6);
            resolveDesc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
            auto updateDefines = defines;
            updateDefines.add("SHARC_UPDATE", "0");
            updateDefines.add("SHARC_QUERY", "0");
            updateDefines.add("RTPT_SHARC_SPLIT_RESOLVE", usesPairedSharc() ? "1" : "0");
            mpSHARCResolve = ComputePass::create(mpDevice, resolveDesc, updateDefines, true);
        }
    }
}

bool RTPT::usesPairedSharc() const
{
    return mEnableSHARC && mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG &&
        mVXPGSettings.enabled;
}

void RTPT::bindSHARC(const ShaderVar& rootVar, bool resolve)
{
    auto bind = [&](const char* name, const ref<Buffer>& accumulation, const ref<Buffer>& source, const ref<Buffer>& destination)
    {
        auto sharc = rootVar.findMember(name);
        if (!sharc.isValid()) return;
        auto grid = sharc["hashGridParameters"];
        grid["cameraPosition"] = mpScene->getCamera()->getPosition();
        grid["logarithmBase"] = 2.f;
        grid["sceneScale"] = mSHARCSceneScale;
        grid["levelBias"] = 0.f;
        sharc["hashGridData"]["capacity"] = mSHARCEntries;
        sharc["hashGridData"]["hashEntriesBuffer"] = resolve && usesPairedSharc() ? mpSHARCHashSnapshot : mpSHARCHashEntries;
        sharc["accumulationBuffer"] = accumulation;
        sharc["resolvedBuffer"] = source;
        sharc["radianceScale"] = 1000.f;
        auto output = sharc.findMember("resolvedDestination");
        if (output.isValid()) output = destination;
        output = sharc.findMember("hashEntriesDestination");
        if (output.isValid()) output = mpSHARCHashEntries;
    };
    bind("gSharc", mpSHARCAccumulation, mpSHARCResolved, mpSHARCResolvedNext);
    bind("gSharcLocal", mpSHARCLocalAccumulation, mpSHARCLocalResolved, mpSHARCLocalNext);
    bind("gSharcSuffix", mpSHARCSuffixAccumulation, mpSHARCSuffixResolved, mpSHARCSuffixNext);
    auto settings = rootVar.findMember("gSharcSettings");
    if (!settings.isValid()) return;
    settings["frameDim"] = mFrameDim;
    settings["updateStride"] = mSHARCUpdateStride;
    settings["frameIndex"] = mSHARCFrameIndex;
    settings["updateBounces"] = mSHARCUpdateBounces;
    settings["minBounce"] = mSHARCMinBounce;
    settings["useCache"] = mSHARCEnabled && mSHARCUseCache ? 1u : 0u;
    settings["debugMode"] = mSHARCDebugMode;
    settings["minRoughness"] = mSHARCMinRoughness;
    settings["cameraPositionPrev"] = mSHARCCameraPositionPrev;
    settings["accumulationFrames"] = mSHARCAccumulationFrames;
    settings["staleFrames"] = mSHARCStaleFrames;
}

void RTPT::clearSHARC(RenderContext* pRenderContext)
{
    pRenderContext->clearUAV(mpSHARCHashEntries->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpSHARCAccumulation->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpSHARCResolved->getUAV().get(), uint4(0));
    for (const auto& buffer : {mpSHARCHashSnapshot, mpSHARCResolvedNext, mpSHARCLocalAccumulation, mpSHARCLocalResolved,
        mpSHARCLocalNext, mpSHARCSuffixAccumulation, mpSHARCSuffixResolved, mpSHARCSuffixNext})
    {
        if (!buffer) continue;
        pRenderContext->clearUAV(buffer->getUAV().get(), uint4(0));
        pRenderContext->uavBarrier(buffer.get());
    }
    pRenderContext->uavBarrier(mpSHARCHashEntries.get());
    pRenderContext->uavBarrier(mpSHARCAccumulation.get());
    pRenderContext->uavBarrier(mpSHARCResolved.get());
    mSHARCCameraPositionPrev = mpScene->getCamera()->getPosition();
    mSHARCFrameIndex = 0;
    mResetSHARCCache = false;
}

void RTPT::dispatchSparse(RenderContext* pRenderContext, uint32_t stride, uint32_t bounces, uint32_t frameIndex,
    bool sharc, bool vxpg)
{
    FALCOR_PROFILE(pRenderContext, "SparseTrace");
    auto var = mpSparseUpdate->getRootVar();
    mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    mpSampleGenerator->bindShaderData(var);
    if (mpEnvMapSampler) mpEnvMapSampler->bindShaderData(var["gEnvMapSampler"]);
    auto params = var["gParams"];
    params["frameDim"] = mFrameDim;
    params["samplesPerPixel"] = 1u;
    params["maxBounces"] = bounces;
    params["rrStartBounce"] = mRRStartBounce;
    params["seed"] = mSeed;
    params["sampleOffset"] = mSampleOffset;
    params["accumulatedSamples"] = 0u;
    params["useNEE"] = mUseNEE ? 1u : 0u;
    params["useRussianRoulette"] = mUseRussianRoulette ? 1u : 0u;
    params["accumulate"] = 0u;
    if (mEnableSHARC) bindSHARC(var);
    auto sparse = var["gSparseSettings"];
    sparse["frameDim"] = mFrameDim;
    sparse["updateStride"] = stride;
    sparse["frameIndex"] = frameIndex;
    sparse["updateBounces"] = bounces;
    sparse["writeSHARC"] = sharc ? 1u : 0u;
    sparse["writeVXPG"] = vxpg ? 1u : 0u;
    if (mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG)
        mpVXPG->bindTraining(var, vxpg);
    const uint2 updateDim = (mFrameDim + stride - 1u) / stride;
    mpSparseUpdate->execute(pRenderContext, uint3(updateDim, 1));
    if (vxpg) mpVXPG->barrierInjection(pRenderContext);
    if (mEnableSHARC)
    {
        pRenderContext->uavBarrier(mpSHARCHashEntries.get());
        pRenderContext->uavBarrier(mpSHARCAccumulation.get());
        pRenderContext->uavBarrier(mpSHARCResolved.get());
        if (usesPairedSharc())
        {
            pRenderContext->uavBarrier(mpSHARCLocalAccumulation.get());
            pRenderContext->uavBarrier(mpSHARCSuffixAccumulation.get());
        }
    }
}

void RTPT::executeTraining(RenderContext* pRenderContext, const RTPTVXPG::TrainingInputs& vxpgTraining)
{
    // Query resources remain UAVs. Order the preceding frame's reads before
    // clearing, sparse writes or reusing a previous paired resolve destination.
    for (const auto& buffer : {mpSHARCHashEntries,mpSHARCAccumulation,mpSHARCResolved,mpSHARCHashSnapshot,mpSHARCResolvedNext,
        mpSHARCLocalAccumulation,mpSHARCLocalResolved,mpSHARCLocalNext,mpSHARCSuffixAccumulation,mpSHARCSuffixResolved,mpSHARCSuffixNext})
        if (buffer) pRenderContext->uavBarrier(buffer.get());
    if (mEnableSHARC)
    {
        if (!mpSHARCHashEntries)
        {
            mpSHARCHashEntries = mpDevice->createStructuredBuffer(8u, mSHARCEntries);
            mpSHARCAccumulation = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mpSHARCResolved = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mResetSHARCCache = true;
        }
        if (usesPairedSharc() && !mpSHARCHashSnapshot)
        {
            mpSHARCHashSnapshot = mpDevice->createStructuredBuffer(8u, mSHARCEntries);
            mpSHARCResolvedNext = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mpSHARCLocalAccumulation = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mpSHARCLocalResolved = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mpSHARCLocalNext = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mpSHARCSuffixAccumulation = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mpSHARCSuffixResolved = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mpSHARCSuffixNext = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mResetSHARCCache = true;
        }
        else if (!usesPairedSharc())
        {
            mpSHARCHashSnapshot = mpSHARCResolvedNext = nullptr;
            mpSHARCLocalAccumulation = mpSHARCLocalResolved = mpSHARCLocalNext = nullptr;
            mpSHARCSuffixAccumulation = mpSHARCSuffixResolved = mpSHARCSuffixNext = nullptr;
        }
        if (mResetSHARCCache) clearSHARC(pRenderContext);
    }
    const bool sharc = mEnableSHARC && mSHARCEnabled && !mSHARCFreeze;
    const bool vxpg = vxpgTraining.writeObservations;
    mVXPGSharedTrainingThisFrame = vxpg;
    mVXPGSharedWithSHARCThisFrame = vxpg && sharc;
    if (sharc)
        dispatchSparse(pRenderContext, mSHARCUpdateStride, mSHARCUpdateBounces, mSHARCFrameIndex, true, vxpg);
    else if (vxpg)
        dispatchSparse(pRenderContext, mSHARCUpdateStride, mSHARCUpdateBounces, vxpgTraining.frameIndex, false, true);
    if (sharc)
    {
        FALCOR_PROFILE(pRenderContext, "SHARCResolve");
        if (usesPairedSharc()) pRenderContext->copyResource(mpSHARCHashSnapshot.get(), mpSHARCHashEntries.get());
        bindSHARC(mpSHARCResolve->getRootVar(), true);
        mpSHARCResolve->execute(pRenderContext, uint3(mSHARCEntries, 1, 1));
        if (usesPairedSharc())
        {
            pRenderContext->uavBarrier(mpSHARCResolvedNext.get());
            pRenderContext->uavBarrier(mpSHARCLocalNext.get());
            pRenderContext->uavBarrier(mpSHARCSuffixNext.get());
            pRenderContext->uavBarrier(mpSHARCLocalAccumulation.get());
            pRenderContext->uavBarrier(mpSHARCSuffixAccumulation.get());
            std::swap(mpSHARCResolved, mpSHARCResolvedNext);
            std::swap(mpSHARCLocalResolved, mpSHARCLocalNext);
            std::swap(mpSHARCSuffixResolved, mpSHARCSuffixNext);
        }
        pRenderContext->uavBarrier(mpSHARCHashEntries.get());
        pRenderContext->uavBarrier(mpSHARCAccumulation.get());
        pRenderContext->uavBarrier(mpSHARCResolved.get());
    }
}

void RTPT::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto vxpgUpdate = mpVXPG->beginUpdate();
    mVXPGSharedTrainingThisFrame = mVXPGSharedWithSHARCThisFrame = false;
    auto color = renderData.getTexture("color");
    auto noisyColor = renderData.getTexture("noisyColor");
    if (!mpScene)
    {
        pRenderContext->clearTexture(color.get());
        pRenderContext->clearTexture(noisyColor.get());
        if (mEnableNRD)
            for (const auto& output : kNRDOutputs)
                pRenderContext->clearTexture(renderData.getTexture(output.name).get());
        if (mEnableSHARC)
            for (const auto* output : kSHARCOutputs)
                pRenderContext->clearTexture(renderData.getTexture(output).get());
        if (mEnableVXPG) pRenderContext->clearTexture(renderData.getTexture("vxpgDebug").get());
        return;
    }

    const bool resetForScene = updateSceneState();
    auto& dict = renderData.getDictionary();
    const auto refreshFlags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    if (resetForScene || mOptionsChanged || refreshFlags != RenderPassRefreshFlags::None) reset();
    mOptionsChanged = false;

    // Primary producer and consumers must use the same absolute sample index.
    if (mSampleOffset > std::numeric_limits<uint32_t>::max() - mSamplesPerPixel ||
        mAccumulatedSamples > std::numeric_limits<uint32_t>::max() - mSamplesPerPixel)
        reset();

    const uint2 frameDim(color->getWidth(), color->getHeight());
    if (any(frameDim != mFrameDim) || !mpAccumulation)
    {
        mFrameDim = frameDim;
        mpAccumulation = mpDevice->createTexture2D(frameDim.x, frameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        reset();
    }
    if (mEnableNRD && (!mpCameraPattern || mpJitterCamera != mpScene->getCamera()))
    {
        mpCameraPattern = HaltonSamplePattern::create(32);
        mpJitterCamera = mpScene->getCamera();
        mpJitterCamera->setPatternGenerator(mpCameraPattern, 1.f / float2(frameDim));
        mResetNRDHistory = true;
    }
    else if (mEnableNRD)
        mpJitterCamera->setPatternGenerator(mpCameraPattern, 1.f / float2(frameDim));
    prepareProgram(pRenderContext);
    // Process scene, option, resolution and lighting changes before testing the
    // limit so a completed image starts accumulating again after invalidation.
    if (mAccumulate && mMaxAccumulationFrames != 0 && mAccumulatedFrames >= mMaxAccumulationFrames)
    {
        // Restore the persistent average even if the graph output was reused or
        // reallocated. noisyColor retains the last traced frame at the limit.
        pRenderContext->copyResource(color.get(), mpAccumulation.get());
        return;
    }
    RTPTVXPG::TrainingInputs vxpgTraining;
    if (mEnableVXPG)
        vxpgTraining = vxpgUpdate.prepare(pRenderContext, mVXPGSettings, mFrameDim, mSHARCUpdateStride, mSHARCUpdateBounces,
            mGuidingMode, renderData.getTexture("vxpgDebug"));
    if (mEnableSHARC || vxpgTraining.writeObservations)
    {
        if (mEnableSHARC && mResetSHARCCache) mResetNRDHistory = true;
        executeTraining(pRenderContext, vxpgTraining);
    }
    vxpgUpdate.finish(pRenderContext, mSeed, mSampleOffset, mEnableNRD);
    if ((mEnableNRD || mEnableSHARC || mEnableVXPG) && mResetNRDHistory)
        dict[kRenderPassRefreshFlags] = refreshFlags | RenderPassRefreshFlags::RenderOptionsChanged;
    mResetNRDHistory = false;

    auto var = mpComputePass->getRootVar();
    mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    mpSampleGenerator->bindShaderData(var);
    if (mpEnvMapSampler) mpEnvMapSampler->bindShaderData(var["gEnvMapSampler"]);
    auto params = var["gParams"];
    params["frameDim"] = frameDim;
    params["samplesPerPixel"] = mSamplesPerPixel;
    params["maxBounces"] = mMaxBounces;
    params["rrStartBounce"] = mRRStartBounce;
    params["seed"] = mSeed;
    params["sampleOffset"] = mSampleOffset;
    params["accumulatedSamples"] = mAccumulate ? mAccumulatedSamples : 0u;
    params["useNEE"] = mUseNEE ? 1u : 0u;
    params["useRussianRoulette"] = mUseRussianRoulette ? 1u : 0u;
    params["accumulate"] = mAccumulate ? 1u : 0u;
    var["gColor"] = color;
    var["gNoisyColor"] = noisyColor;
    var["gAccumulation"] = mpAccumulation;
    if (mEnableNRD)
        for (const auto& output : kNRDOutputs)
            var[output.shaderName] = renderData.getTexture(output.name);
    if (mEnableSHARC)
    {
        bindSHARC(var);
        var["gSharcDebug"] = renderData.getTexture("sharcDebug");
        var["gSharcCacheRadiance"] = renderData.getTexture("sharcCacheRadiance");
        var["gSharcStats"] = renderData.getTexture("sharcStats");
    }
    if (mEnableVXPG)
        mpVXPG->bindRendering(var, mSampleOffset, mGuidingMode == RTPTVXPG::GuidingMode::VXPG && mVXPGSettings.enabled && mpVXPG->hasSubmittedModel());
    pRenderContext->uavBarrier(mpAccumulation.get());
    {
        FALCOR_PROFILE(pRenderContext, "MainRender");
        mpComputePass->execute(pRenderContext, uint3(frameDim, 1));
    }
    mVXPGDiagnosticFrameAvailable = mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG &&
        mVXPGSettings.enabled && mVXPGSettings.detailedDiagnostics && mpVXPG->hasSubmittedModel();
    if (mVXPGDiagnosticFrameAvailable)
    {
        mVXPGDiagnosticFrameSampleOffset = mSampleOffset;
        mVXPGDiagnosticFrameSamplesPerPixel = mSamplesPerPixel;
        mVXPGDiagnosticFrameGeneration = mpVXPG->getGeneration();
    }
    mSampleOffset += mSamplesPerPixel;
    mAccumulatedSamples = mAccumulate ? mAccumulatedSamples + mSamplesPerPixel : 0u;
    mAccumulatedFrames = mAccumulate ? mAccumulatedFrames + 1u : 0u;
    if (mEnableSHARC && mSHARCEnabled && !mSHARCFreeze)
    {
        mSHARCCameraPositionPrev = mpScene->getCamera()->getPosition();
        ++mSHARCFrameIndex;
    }
}

void RTPT::renderUI(Gui::Widgets& widget)
{
    bool changed = false;
    const bool previousNEE = mUseNEE;
    const bool previousRR = mUseRussianRoulette;
    const uint32_t previousSeed = mSeed;
    if (mEnableNRD)
        widget.text("NRD: 1 primary sample, one path per active diffuse/specular lobe.");
    else
        changed |= widget.var("Samples per pixel", mSamplesPerPixel, 1u, 1024u);
    changed |= widget.var("Max BSDF bounces", mMaxBounces, 1u, 64u);
    widget.tooltip("Number of BSDF scatter events. The final ray only collects emission or environment light.", true);
    changed |= widget.checkbox("Next-event estimation", mUseNEE);
    widget.tooltip("Sample analytic, mesh and environment lights. Analytic lights require NEE because rays cannot hit them.", true);
    changed |= widget.checkbox("Russian roulette", mUseRussianRoulette);
    changed |= widget.var("RR start bounce", mRRStartBounce, 1u, 64u);
    changed |= widget.var("Seed", mSeed);
    if (!mEnableNRD && !mEnableSHARC && !mEnableVXPG)
    {
        changed |= widget.checkbox("Progressive accumulation", mAccumulate);
        if (mAccumulate)
        {
            changed |= widget.var("Max frames", mMaxAccumulationFrames, 0u);
            widget.tooltip("Maximum frames to accumulate. 0 means unlimited. At the limit, tracing stops and both outputs are held. Changing this limit restarts accumulation.", true);
            const std::string target = mMaxAccumulationFrames != 0 ? " / " + std::to_string(mMaxAccumulationFrames) : " (unlimited)";
            widget.text("Accumulated frames: " + std::to_string(mAccumulatedFrames) + target);
            if (mMaxAccumulationFrames != 0 && mAccumulatedFrames >= mMaxAccumulationFrames && !changed && !mOptionsChanged)
                widget.text("Accumulation complete.");
        }
    }
    changed |= widget.button(mEnableNRD ? "Reset NRD history" : "Reset accumulation");
    if (!mEnableNRD)
        widget.text("Accumulated samples: " + std::to_string(mAccumulatedSamples));
    mOptionsChanged |= changed;
    mResetSHARCCache |= previousNEE != mUseNEE || previousRR != mUseRussianRoulette || previousSeed != mSeed;
    if (mEnableVXPG)
    {
        uint32_t mode = uint32_t(mGuidingMode);
        const Gui::DropdownList modes = {{0, "BSDF"}, {1, "VXPG"}};
        if (widget.dropdown("Guiding mode", modes, mode))
        {
            Properties props;
            props["guidingMode"] = mode == 0 ? "BSDF" : "VXPG";
            setProperties(props);
        }
    }
    if (mEnableVXPG)
    {
        auto vx = widget.group("VXPG");
        if (vx)
        {
            const auto props = mpVXPG->renderSettingsUI(vx, mVXPGSettings, getVXPGContext(), mVXPGUI);
            if (!props.empty()) setProperties(props);
            if (vx.button("Reset VXPG")) resetVXPG();
            mpVXPG->renderDiagnosticsUI(vx, mVXPGSettings, getVXPGContext(), mVXPGUI);
        }
    }
    if (mEnableSHARC)
    {
        auto sharcWidget = widget.group("SHaRC");
        if (sharcWidget)
        {
            // Apply algorithm controls through the same checked property path used
            // by scripts. Visualization and freezing do not reset temporal history.
            Properties props;
            bool value = mSHARCEnabled;
            if (sharcWidget.checkbox("Enabled", value)) props["sharcEnabled"] = value;
            sharcWidget.tooltip("Enable cache updates and path termination. Switching restarts NRD and final image accumulation.", true);
            value = mSHARCUseCache;
            if (sharcWidget.checkbox("Use cache for path termination", value)) props["sharcUseCache"] = value;
            value = mSHARCFreeze;
            if (sharcWidget.checkbox("Freeze cache", value)) props["sharcFreeze"] = value;
            uint32_t count = mSHARCEntries;
            if (sharcWidget.dropdown("Cache capacity", kSHARCCapacities, count)) props["sharcEntries"] = count;
            uint32_t stride = mSHARCUpdateStride;
            if (sharcWidget.var("Update tile size", stride, 1u, 32u)) props["sharcUpdateStride"] = stride;
            sharcWidget.text("Update budget: approximately " + std::to_string(100.f / float(stride * stride)) + "% of pixels");
            uint32_t bounces = mSHARCUpdateBounces;
            if (sharcWidget.var("Update path bounces", bounces, 1u, 32u)) props["sharcUpdateBounces"] = bounces;
            float scale = mSHARCSceneScale;
            if (sharcWidget.var("Grid scene scale", scale, 0.01f, 100000.f)) props["sharcSceneScale"] = scale;
            sharcWidget.tooltip("Larger values create smaller world-space voxels.", true);
            uint32_t minBounce = mSHARCMinBounce;
            if (sharcWidget.var("First query bounce", minBounce, 1u, 64u)) props["sharcMinBounce"] = minBounce;
            float roughness = mSHARCMinRoughness;
            if (sharcWidget.var("Minimum query roughness", roughness, 0.f, 1.f)) props["sharcMinRoughness"] = roughness;
            uint32_t frames = mSHARCAccumulationFrames;
            if (sharcWidget.var("Accumulation frames", frames, 1u, 1024u)) props["sharcAccumulationFrames"] = frames;
            frames = mSHARCStaleFrames;
            if (sharcWidget.var("Stale entry lifetime", frames, 8u, 1024u)) props["sharcStaleFrames"] = frames;
            sharcWidget.dropdown("Visualization", kSHARCDebugModes, mSHARCDebugMode);
            sharcWidget.text("Select RTPT.sharcDebug in the graph output menu to show this view.");
            if (!props.empty()) setProperties(props);
            if (sharcWidget.button("Clear radiance cache"))
            {
                mResetSHARCCache = true;
                mOptionsChanged = true;
            }
        }
    }

}
