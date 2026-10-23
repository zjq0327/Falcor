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
        pass.def_property_readonly("pgStats", [](const RTPT& self) { return self.getPGStatistics().toPython(); });
        pass.def("resetPG", &RTPT::resetPG);
        pass.def_property_readonly("vxpgStats", [](const RTPT& self) { return self.getVXPGStatistics().toPython(); });
        pass.def("resetVXPG", &RTPT::resetVXPG);
    });
}

RTPT::RTPT(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    mpPG = std::make_unique<RTPTPG::Manager>(mpDevice);
    mpVXPG = std::make_unique<RTPTVXPG::Manager>(mpDevice);
    setProperties(props);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
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
    bool enablePG = mEnablePG;
    auto pg = mPGSettings;
    auto vxpg = mVXPGSettings;
    auto guidingMode = mGuidingMode;
    bool enableVXPG = mEnableVXPG;
    uint32_t pgUpdateStride = mPGUpdateStride, pgUpdateBounces = mPGUpdateBounces;
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
        else if (key == "enablePG") enablePG = value;
        else if (key == "enableVXPG") enableVXPG = value;
        else if (key == "guidingMode")
        {
            const std::string mode = value;
            FALCOR_CHECK(mode == "BSDF" || mode == "PG" || mode == "VXPG", "Invalid RTPT guiding mode '{}'.", mode);
            guidingMode = mode == "BSDF" ? RTPTVXPG::GuidingMode::BSDF : mode == "PG" ? RTPTVXPG::GuidingMode::PG : RTPTVXPG::GuidingMode::VXPG;
        }
        else if (key == "vxpgEstimator")
        {
            const std::string mode = value;
            // Accept old ShortBranch graphs, but never silently substitute for B.
            FALCOR_CHECK(mode == "ShortBranch", "VXPG supports only ShortBranch; estimator '{}' is no longer supported.", mode);
        }
        else if (key == "vxpgEnabled") vxpg.enabled = value;
        else if (key == "vxpgUseGuiding") vxpg.useGuiding = value;
        else if (key == "vxpgFreezeUpdates") vxpg.freezeUpdates = value;
        else if (key == "vxpgPGUseCache") vxpg.pgUseCache = value;
        else if (key == "vxpgVisibilityEnabled") vxpg.visibilityEnabled = value;
        else if (key == "vxpgDebugEnabled") vxpg.debugEnabled = value;
        else if (key == "vxpgDetailedDiagnostics") vxpg.detailedDiagnostics = value;
        else if (key == "vxpgSharedInjectionEnabled") vxpg.sharedInjectionEnabled = value;
        else if (key == "vxpgDebugMode") vxpg.debugMode = value;
        else if (key == "vxpgGuideFraction")
            logWarning("RTPT: vxpgGuideFraction is obsolete and ignored; VXPG uses ShortBranch only.");
        else if (key == "vxpgGridResolution") vxpg.gridResolution = value;
        else if (key == "vxpgMaxVoxels") vxpg.maxVoxels = value;
        else if (key == "vxpgClusterCount") vxpg.clusterCount = value;
        else if (key == "vxpgSuperpixelSize") vxpg.superpixelSize = value;
        else if (key == "vxpgBudgetMB") vxpg.budgetMiB = value;
        else if (key == "pgEnabled") pg.enabled = value;
        else if (key == "pgUseGuiding") pg.useGuiding = value;
        else if (key == "pgFreeze") pg.trainingEnabled = !bool(value);
        else if (key == "pgDetailedDiagnostics") pg.detailedDiagnostics = value;
        else if (key == "pgGuideFraction") pg.guideFraction = value;
        else if (key == "pgTreeBudgetMB") pg.treeBudgetMiB = value;
        else if (key == "pgRecordBudgetMB") pg.recordBudgetMiB = value;
        else if (key == "pgCoarseLevels") pg.coarseLevels = value;
        else if (key == "pgPublishInterval") pg.pollFrames = value;
        else if (key == "pgMaxRegions") pg.maxRegions = value;
        else if (key == "pgMaxNodesPerRegion") pg.maxNodesPerRegion = value;
        else if (key == "pgMaxDirectionalDepth") pg.maxDirectionalDepth = value;
        else if (key == "pgDirectionalThreshold") pg.directionalThreshold = value;
        else if (key == "pgUpdateStride") pgUpdateStride = value;
        else if (key == "pgUpdateBounces") pgUpdateBounces = value;
        else FALCOR_THROW("Unknown RTPT property '{}'.", key);
    }
    FALCOR_CHECK(samplesPerPixel >= 1 && samplesPerPixel <= 1024, "RTPT samplesPerPixel must be in [1, 1024].");
    FALCOR_CHECK(maxBounces >= 1 && maxBounces <= 64, "RTPT maxBounces must be in [1, 64].");
    FALCOR_CHECK(rrStartBounce >= 1 && rrStartBounce <= 64, "RTPT rrStartBounce must be in [1, 64].");
    FALCOR_CHECK(!enableNRD || (samplesPerPixel == 1 && !accumulate),
        "RTPT NRD mode requires samplesPerPixel=1 and accumulate=false; NRD manages temporal history.");
    FALCOR_CHECK(!enableSHARC || !accumulate,
        "RTPT SHaRC mode requires accumulate=false; its world-space cache changes between frames.");
    FALCOR_CHECK(!enablePG || !accumulate, "RTPT PG requires accumulate=false; use the independent FrameAccumulation pass.");
    FALCOR_CHECK(!enableVXPG || !accumulate, "RTPT VXPG requires accumulate=false; use the independent FrameAccumulation pass.");
    RTPTVXPG::Manager::validate(vxpg);
    FALCOR_CHECK(pgUpdateStride >= 1 && pgUpdateStride <= 64 && pgUpdateBounces >= 1 && pgUpdateBounces <= 32,
        "PG update stride must be in [1,64] and bounces in [1,32].");
    FALCOR_CHECK(pg.treeBudgetMiB >= 16 && pg.treeBudgetMiB <= 1024 && pg.recordBudgetMiB >= 1 && pg.recordBudgetMiB <= 2048,
        "PG model budget must be in [16,1024] MiB and record budget in [1,2048] MiB.");
    FALCOR_CHECK(pg.coarseLevels <= 8 && pg.pollFrames >= 1 && pg.pollFrames <= 1024 && pg.maxRegions >= 1 && pg.maxRegions <= 65536,
        "Invalid PG coarse level, publish interval or region limit.");
    FALCOR_CHECK(pg.maxNodesPerRegion >= 1 && pg.maxNodesPerRegion <= 1024 &&
        pg.maxDirectionalDepth >= 1 && pg.maxDirectionalDepth <= 16 &&
        std::isfinite(pg.directionalThreshold) && pg.directionalThreshold > 0.f && pg.directionalThreshold <= 1.f,
        "Invalid PG directional tree limits.");
    FALCOR_CHECK(std::isfinite(pg.guideFraction) && pg.guideFraction >= 0.f && pg.guideFraction < 1.f,
        "PG guide fraction must be in [0,1), preserving BSDF support.");
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
    if (enableSHARC || enablePG || enableVXPG)
        FALCOR_CHECK(mpDevice->getType() == Device::Type::D3D12 && mpDevice->isShaderModelSupported(ShaderModel::SM6_6),
            "RTPT SHaRC currently requires D3D12 and Shader Model 6.6 for native 16-bit types and 64-bit buffer atomics.");
    const bool newPairedSharc = enableSHARC && enableVXPG && guidingMode == RTPTVXPG::GuidingMode::VXPG &&
        vxpg.enabled;
    const bool pairedChanged = newPairedSharc != usesPairedSharc();
    const bool modeChanged = enableNRD != mEnableNRD || enableSHARC != mEnableSHARC || enablePG != mEnablePG || enableVXPG != mEnableVXPG ||
        guidingMode != mGuidingMode || pairedChanged;
    const bool vxpgStructureChanged = enableVXPG != mEnableVXPG || vxpg.gridResolution != mVXPGSettings.gridResolution ||
        vxpg.maxVoxels != mVXPGSettings.maxVoxels || vxpg.clusterCount != mVXPGSettings.clusterCount ||
        vxpg.superpixelSize != mVXPGSettings.superpixelSize || vxpg.budgetMiB != mVXPGSettings.budgetMiB;
    const bool vxpgTrainingChanged = vxpg.sharedInjectionEnabled != mVXPGSettings.sharedInjectionEnabled ||
        (vxpg.sharedInjectionEnabled && (sharcUpdateStride != mSHARCUpdateStride || sharcUpdateBounces != mSHARCUpdateBounces));
    if (vxpgTrainingChanged)
    {
        mpVXPG->invalidateDistribution("Training source changed; rebuild the VXPG proposal");
        mpSparseUpdate = nullptr;
    }
    const bool vxpgSignalChanged = vxpgTrainingChanged || vxpgStructureChanged || guidingMode != mGuidingMode || vxpg.enabled != mVXPGSettings.enabled ||
        vxpg.useGuiding != mVXPGSettings.useGuiding ||
        vxpg.pgUseCache != mVXPGSettings.pgUseCache || vxpg.visibilityEnabled != mVXPGSettings.visibilityEnabled;
    if (vxpg.detailedDiagnostics != mVXPGSettings.detailedDiagnostics)
    {
        // Instrumentation does not change the transport signal or model. Do
        // not request a render-graph recompile or reset any temporal history.
        if (mpComputePass)
            mpComputePass->addDefine("RTPT_VXPG_DETAILED_DIAGNOSTICS", vxpg.detailedDiagnostics ? "1" : "0", true);
        if (mpSparseUpdate)
            mpSparseUpdate->addDefine("RTPT_VXPG_DETAILED_DIAGNOSTICS", vxpg.detailedDiagnostics ? "1" : "0", true);
        mVXPGDiagnosticFrameAvailable = false;
        mpVXPG->invalidateDiagnosticSnapshot();
        mVXPGDiagnosticText.clear();
    }
    if (vxpgStructureChanged) mpVXPG->invalidate();
    const bool pgStructureChanged = enablePG != mEnablePG || pg.coarseLevels != mPGSettings.coarseLevels ||
        pg.treeBudgetMiB != mPGSettings.treeBudgetMiB || pg.maxRegions != mPGSettings.maxRegions ||
        pg.maxNodesPerRegion != mPGSettings.maxNodesPerRegion || pgUpdateBounces != mPGUpdateBounces || sharcSceneScale != mSHARCSceneScale;
    const bool pgDepthChanged = pg.maxDirectionalDepth != mPGSettings.maxDirectionalDepth;
    const bool pgRecordsChanged = pg.recordBudgetMiB != mPGSettings.recordBudgetMiB || pgUpdateStride != mPGUpdateStride;
    const bool pgSignalChanged = pgStructureChanged || pg.enabled != mPGSettings.enabled || pg.useGuiding != mPGSettings.useGuiding ||
        pg.guideFraction != mPGSettings.guideFraction;
    const bool sharcStructureChanged = enableSHARC != mEnableSHARC || sharcEntries != mSHARCEntries ||
        sharcSceneScale != mSHARCSceneScale || sharcUpdateBounces != mSHARCUpdateBounces;
    const bool sharcSignalChanged = sharcStructureChanged || sharcUseCache != mSHARCUseCache ||
        sharcUpdateStride != mSHARCUpdateStride || sharcMinBounce != mSHARCMinBounce || sharcMinRoughness != mSHARCMinRoughness ||
        sharcAccumulationFrames != mSHARCAccumulationFrames || sharcStaleFrames != mSHARCStaleFrames;
    mOptionsChanged |= samplesPerPixel != mSamplesPerPixel || maxBounces != mMaxBounces || rrStartBounce != mRRStartBounce ||
        seed != mSeed || useNEE != mUseNEE || useRussianRoulette != mUseRussianRoulette || accumulate != mAccumulate ||
        maxAccumulationFrames != mMaxAccumulationFrames || sharcEnabled != mSHARCEnabled || modeChanged || sharcSignalChanged || pgSignalChanged || vxpgSignalChanged;
    mResetPG |= pgStructureChanged || pgDepthChanged || seed != mSeed || useNEE != mUseNEE || useRussianRoulette != mUseRussianRoulette;
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
    mEnablePG = enablePG;
    mPGSettings = pg;
    mEnableVXPG = enableVXPG;
    mVXPGSettings = vxpg;
    mGuidingMode = guidingMode;
    mPGUpdateStride = pgUpdateStride;
    mPGUpdateBounces = pgUpdateBounces;
    if (pgStructureChanged || pgDepthChanged)
    {
        // Drop parameter-block references before rebuilding bounded PG pools.
        mpComputePass = mpSparseUpdate = mpPGPrepare = mpPGTrain = nullptr;
    }
    else if (pgRecordsChanged) mpSparseUpdate = mpPGPrepare = mpPGTrain = nullptr;
    if (modeChanged)
    {
        mpComputePass = nullptr;
        mpSparseUpdate = mpPGPrepare = mpPGTrain = nullptr;
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
    props["enablePG"] = mEnablePG;
    props["enableVXPG"] = mEnableVXPG;
    props["guidingMode"] = mGuidingMode == RTPTVXPG::GuidingMode::BSDF ? "BSDF" : mGuidingMode == RTPTVXPG::GuidingMode::PG ? "PG" : "VXPG";
    props["vxpgEnabled"] = mVXPGSettings.enabled;
    props["vxpgUseGuiding"] = mVXPGSettings.useGuiding;
    props["vxpgFreezeUpdates"] = mVXPGSettings.freezeUpdates;
    props["vxpgPGUseCache"] = mVXPGSettings.pgUseCache;
    props["vxpgVisibilityEnabled"] = mVXPGSettings.visibilityEnabled;
    props["vxpgDebugEnabled"] = mVXPGSettings.debugEnabled;
    props["vxpgDetailedDiagnostics"] = mVXPGSettings.detailedDiagnostics;
    props["vxpgSharedInjectionEnabled"] = mVXPGSettings.sharedInjectionEnabled;
    props["vxpgDebugMode"] = mVXPGSettings.debugMode;
    props["vxpgGridResolution"] = mVXPGSettings.gridResolution;
    props["vxpgMaxVoxels"] = mVXPGSettings.maxVoxels;
    props["vxpgClusterCount"] = mVXPGSettings.clusterCount;
    props["vxpgSuperpixelSize"] = mVXPGSettings.superpixelSize;
    props["vxpgBudgetMB"] = mVXPGSettings.budgetMiB;
    props["pgEnabled"] = mPGSettings.enabled;
    props["pgUseGuiding"] = mPGSettings.useGuiding;
    props["pgFreeze"] = !mPGSettings.trainingEnabled;
    props["pgDetailedDiagnostics"] = mPGSettings.detailedDiagnostics;
    props["pgGuideFraction"] = mPGSettings.guideFraction;
    props["pgTreeBudgetMB"] = mPGSettings.treeBudgetMiB;
    props["pgRecordBudgetMB"] = mPGSettings.recordBudgetMiB;
    props["pgCoarseLevels"] = mPGSettings.coarseLevels;
    props["pgPublishInterval"] = mPGSettings.pollFrames;
    props["pgMaxRegions"] = mPGSettings.maxRegions;
    props["pgMaxNodesPerRegion"] = mPGSettings.maxNodesPerRegion;
    props["pgMaxDirectionalDepth"] = mPGSettings.maxDirectionalDepth;
    props["pgDirectionalThreshold"] = mPGSettings.directionalThreshold;
    props["pgUpdateStride"] = mPGUpdateStride;
    props["pgUpdateBounces"] = mPGUpdateBounces;
    return props;
}

Properties RTPT::getPGStatistics() const
{
    Properties props;
    const auto& s = mpPG->getStatistics();
    props["enabled"] = mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG && mPGSettings.enabled;
    props["trainingEnabled"] = mPGSettings.trainingEnabled;
    props["detailedDiagnostics"] = mPGSettings.detailedDiagnostics;
    props["regions"] = s.regions;
    props["readyRegions"] = s.readyRegions;
    props["observedZeroRegions"] = s.observedZeroRegions;
    props["readNodes"] = s.readNodes;
    props["buildNodes"] = s.buildNodes;
    props["nodeCapacity"] = s.nodeCapacity;
    props["trainingFrames"] = s.trainingFrames;
    props["publications"] = s.publications;
    props["modelBytes"] = s.modelBytes;
    props["modelReservedBytes"] = s.modelReservedBytes;
    props["recordBytes"] = s.recordBytes;
    props["recordReservedBytes"] = s.recordReservedBytes;
    props["lastPublishMs"] = s.lastPublishMs;
    props["publishCalls"] = s.publishCalls;
    props["totalPublishMs"] = s.totalPublishMs;
    props["maxPublishMs"] = s.maxPublishMs;
    props["lastDrainMs"] = s.lastDrainMs;
    props["totalDrainMs"] = s.totalDrainMs;
    props["lastReadbackMs"] = s.lastReadbackMs;
    props["totalReadbackMs"] = s.totalReadbackMs;
    props["lastCpuRebuildMs"] = s.lastCpuRebuildMs;
    props["totalCpuRebuildMs"] = s.totalCpuRebuildMs;
    props["lastUploadMs"] = s.lastUploadMs;
    props["totalUploadMs"] = s.totalUploadMs;
    props["lastReadbackBytes"] = s.lastReadbackBytes;
    props["totalReadbackBytes"] = s.totalReadbackBytes;
    props["lastUploadBytes"] = s.lastUploadBytes;
    props["totalUploadBytes"] = s.totalUploadBytes;
    props["lastDrainWaits"] = s.lastDrainWaits;
    props["totalDrainWaits"] = s.totalDrainWaits;
    props["lastReadbackWaits"] = s.lastReadbackWaits;
    props["totalReadbackWaits"] = s.totalReadbackWaits;
    props["lastUploadWaits"] = s.lastUploadWaits;
    props["totalUploadWaits"] = s.totalUploadWaits;
    props["lastZeroFastPathRegions"] = s.lastZeroFastPathRegions;
    props["totalZeroFastPathRegions"] = s.totalZeroFastPathRegions;
    props["requestOverflow"] = s.requestOverflow;
    props["invalidSamples"] = s.invalidSamples;
    props["recordOverflow"] = s.recordOverflow;
    props["accumulationOverflow"] = s.accumulationOverflow;
    props["admissionRejected"] = s.admissionRejected;
    props["actualStride"] = mpPG->getRecordStride();
    props["pathCapacity"] = mpPG->getPathCapacity();
    props["generation"] = mpPG->getGeneration();
    props["sharedTraining"] = mSharedTrainingThisFrame;
    for (uint32_t i = 0; i < s.diagnostics.size(); ++i)
        props["diagnostic" + std::to_string(i)] = s.diagnostics[i];
    return props;
}

Properties RTPT::getVXPGStatistics() const
{
    Properties props;
    props["selected"] = mGuidingMode == RTPTVXPG::GuidingMode::VXPG;
    props["enabled"] = mEnableVXPG && mVXPGSettings.enabled;
    props["ready"] = mpVXPG->isReady();
    props["generation"] = mpVXPG->getGeneration();
    props["estimatedBytes"] = mpVXPG->getEstimatedBytes();
    props["allocatedPayloadBytes"] = mpVXPG->getPayloadBytes();
    props["fallbackReason"] = mpVXPG->getFallbackReason();
    const bool selectedEnabled = mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG && mVXPGSettings.enabled;
    const auto counters = selectedEnabled && mpVXPG->isReady() ? mpVXPG->readCounters() : std::array<uint32_t,32>{};
    props["ready"] = mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG && mVXPGSettings.enabled && mVXPGSettings.useGuiding &&
        mpVXPG->isReady() && counters[5] == mpVXPG->getGeneration();
    if (mpVXPG->isReady() && counters[5] == 0) props["fallbackReason"] = "No valid voxel distribution; using BSDF";
    if (counters[1] != 0) props["fallbackReason"] = (counters[1]&2u) != 0 ?
        "Non-finite triangle geometry; using BSDF" : "Geometry job capacity exceeded; reduce grid resolution";
    else if (counters[4] != 0) props["fallbackReason"] = "Active voxel capacity exceeded; increase capacity or reduce grid resolution";
    else if (counters[11] != 0) props["fallbackReason"] = "Invalid/non-finite proposal data; using BSDF";
    props["pairedCacheBytes"] = usesPairedSharc() ? uint64_t(mSHARCEntries) * 120ull : 0ull;
    props["sharcFrameIndex"] = mSHARCFrameIndex;
    props["geometryJobs"] = counters[0];
    props["geometryOverflow"] = counters[1];
    props["occupiedCells"] = counters[2];
    props["activeVoxels"] = counters[3];
    props["distributionOverflow"] = counters[4];
    props["gpuReady"] = counters[5];
    props["invalidSamples"] = counters[11];
    props["gatheredShadingPoints"] = counters[26];
    props["sharedInjectionEnabled"] = mVXPGSettings.sharedInjectionEnabled;
    props["sharedInjectionActive"] = mVXPGSharedTrainingThisFrame;
    props["sharedWithSHARC"] = mVXPGSharedWithSHARCThisFrame;
    props["sharedInjectionStride"] = mSHARCUpdateStride;
    const bool diagnosticsAvailable = selectedEnabled && mVXPGSettings.detailedDiagnostics && mVXPGDiagnosticFrameAvailable &&
        mVXPGDiagnosticFrameGeneration == mpVXPG->getGeneration();
    const bool modelDiagnosticsAvailable = diagnosticsAvailable && mpVXPG->hasModelDiagnostics();
    props["detailedDiagnostics"] = mVXPGSettings.detailedDiagnostics;
    props["diagnosticsAvailable"] = diagnosticsAvailable;
    props["diagnosticsStatus"] = !mVXPGSettings.detailedDiagnostics ? "disabled" : diagnosticsAvailable ? "current_frame" : "unavailable";
    props["modelDiagnosticsAvailable"] = modelDiagnosticsAvailable;
    props["modelDiagnosticsStatus"] = !mVXPGSettings.detailedDiagnostics ? "disabled" :
        modelDiagnosticsAvailable ? "current_update" : "unavailable";
    // Missing activity fields mean unavailable, not zero rays/cache hits.
    // Structural and error fields above remain readable in every mode.
    if (diagnosticsAvailable)
    {
        props["diagnosticsFrameCount"] = 1u;
        props["diagnosticsFrameSampleOffset"] = mVXPGDiagnosticFrameSampleOffset;
        props["diagnosticsFrameSamplesPerPixel"] = mVXPGDiagnosticFrameSamplesPerPixel;
        props["diagnosticsGeneration"] = mVXPGDiagnosticFrameGeneration;
        props["guideAttempts"] = counters[6];
        props["guideAccepted"] = counters[7];
        props["guideRejected"] = counters[8];
        props["pgCacheHits"] = counters[10];
        props["hypotheticalPGCacheChecks"] = counters[13];
        props["primaryGuideAttempts"] = counters[14];
        props["secondGuideAttempts"] = counters[15];
        props["actualGuideRays"] = counters[19];
        props["brdfRays"] = counters[20];
        props["primaryRays"] = counters[21];
        props["sharedInjectionPaths"] = counters[28];
        props["pgShadowRays"] = counters[22];
        props["mainShadowRays"] = counters[23];
        props["brdfCacheHits"] = counters[24];
    }
    if (modelDiagnosticsAvailable)
    {
        props["modelDiagnosticsGeneration"] = mpVXPG->getGeneration();
        props["modelDiagnosticsFrameIndex"] = mpVXPG->getModelDiagnosticsFrameIndex();
        props["modelDiagnosticsFrameCount"] = 1u;
        props["injectedObservations"] = counters[12];
        props["injectionShadowRays"] = counters[16];
        props["injectionPrimaryRays"] = counters[17];
        props["injectionSecondaryRays"] = counters[18];
        props["positiveThroughputPairs"] = counters[25];
    }
    const auto cluster = selectedEnabled && mpVXPG->isReady() ? mpVXPG->readClusterCounters() : std::array<uint32_t,8>{};
    props["validSuperpixels"] = cluster[0];
    props["nonemptyClusters"] = cluster[1];
    if (modelDiagnosticsAvailable)
    {
        props["visibilityRays"] = mVXPGSettings.visibilityEnabled ? cluster[2] : 0u;
        props["visiblePairs"] = mVXPGSettings.visibilityEnabled ? cluster[3] : 0u;
    }
    props["forestNodes"] = cluster[4];
    props["topRows"] = cluster[5];
    props["clusterReady"] = mVXPGSettings.visibilityEnabled && cluster[6] == mpVXPG->getGeneration();
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
    mpSparseUpdate = mpPGPrepare = mpPGTrain = nullptr;
    mpEnvMapSampler = nullptr;
    mLightingMask = ~0u;
    mpCameraPattern = nullptr;
    mpJitterCamera = nullptr;
    mResetSHARCCache = true;
    mResetPG = true;
    mpVXPG->invalidate();
    reset();
    if (mpScene)
    {
        validateScene();
        if (mpScene->getCamera()->getApertureRadius() > 0.f)
            logWarning("RTPT uses a pinhole camera; aperture is ignored.");
    }
}

void RTPT::prepareProgram(RenderContext* pRenderContext)
{
    const bool compilePG = mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG;
    const bool compileVXPG = mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG;
    const bool compileSharedVXPG = compileVXPG && mVXPGSettings.sharedInjectionEnabled;
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
        mpVXPG->invalidateLighting();
        mpComputePass = nullptr;
        mpSparseUpdate = nullptr;
        mResetSHARCCache = true;
        mResetPG = true;
        reset();
    }
    if (mpScene->useEnvLight())
    {
        if (!mpEnvMapSampler || mpEnvMapSampler->getEnvMap() != mpScene->getEnvMap())
            mpEnvMapSampler = std::make_unique<EnvMapSampler>(mpDevice, mpScene->getEnvMap());
    }
    else mpEnvMapSampler = nullptr;

    if (!mpComputePass || ((mEnableSHARC || compilePG || compileSharedVXPG) && !mpSparseUpdate) ||
        (compilePG && (!mpPGPrepare || !mpPGTrain)) || (mEnableSHARC && !mpSHARCResolve))
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
        defines.add("ENABLE_PG", compilePG ? "1" : "0");
        defines.add("ENABLE_VXPG", compileVXPG ? "1" : "0");
        defines.add("RTPT_VXPG_DETAILED_DIAGNOSTICS", mVXPGSettings.detailedDiagnostics ? "1" : "0");
        defines.add("RTPT_SHARC_PAIR", usesPairedSharc() ? "1" : "0");
        if (mEnableSHARC || mEnablePG || mEnableVXPG)
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
        if ((mEnableSHARC || compilePG || compileSharedVXPG) && !mpSparseUpdate)
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
            updateDefines.add("RTPT_VXPG_SHARED_INJECTION", compileSharedVXPG ? "1" : "0");
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
            updateDefines.add("ENABLE_PG", "0");
            updateDefines.add("RTPT_SHARC_SPLIT_RESOLVE", usesPairedSharc() ? "1" : "0");
            mpSHARCResolve = ComputePass::create(mpDevice, resolveDesc, updateDefines, true);
        }
        if (compilePG)
        {
            DefineList pgDefines;
            pgDefines.add("ENABLE_PG", "1");
            auto makePGPass = [&](const char* file)
            {
                ProgramDesc pgDesc;
                pgDesc.addShaderLibrary(file).csEntry("main");
                pgDesc.setShaderModel(ShaderModel::SM6_6);
                return ComputePass::create(mpDevice, pgDesc, pgDefines, true);
            };
            if (!mpPGPrepare) mpPGPrepare = makePGPass("RenderPasses/RTPT/RTPTPGPrepare.cs.slang");
            if (!mpPGTrain) mpPGTrain = makePGPass("RenderPasses/RTPT/RTPTPGTrain.cs.slang");
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
    bool sharc, bool pg, bool vxpg)
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
    if (mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG)
        mpPG->bind(var, mpScene->getCamera()->getPosition(), mSHARCSceneScale, frameIndex, pg);
    auto sparse = var["gSparseSettings"];
    sparse["frameDim"] = mFrameDim;
    sparse["updateStride"] = stride;
    sparse["frameIndex"] = frameIndex;
    sparse["updateBounces"] = bounces;
    sparse["writeSHARC"] = sharc ? 1u : 0u;
    sparse["recordPG"] = pg ? 1u : 0u;
    sparse["writeVXPG"] = vxpg ? 1u : 0u;
    if (mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG && mVXPGSettings.sharedInjectionEnabled)
        mpVXPG->bind(var, mpVXPG->getLightingFrameIndex(), vxpg);
    const uint2 updateDim = (mFrameDim + stride - 1u) / stride;
    mpSparseUpdate->execute(pRenderContext, uint3(updateDim, 1));
    if (vxpg) mpVXPG->barrierInjection(pRenderContext);
    if (mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG) mpPG->barrierTraining(pRenderContext);
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

void RTPT::executeTraining(RenderContext* pRenderContext)
{
    mPGTrainingThisFrame = mSharedTrainingThisFrame = false;
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
    bool pg = mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG && mPGSettings.enabled && mPGSettings.trainingEnabled;
    if (mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG)
    {
        auto effectivePG = mPGSettings;
        effectivePG.enabled &= mGuidingMode == RTPTVXPG::GuidingMode::PG;
        const bool rebuilt = mpPG->prepare(pRenderContext, effectivePG, mFrameDim, mPGUpdateBounces, mPGUpdateStride);
        if (mResetPG || rebuilt)
        {
            mpPG->reset(pRenderContext);
            mPGFrameIndex = 0;
            mPGCameraPosition = mpScene->getCamera()->getPosition();
            mResetPG = false;
            reset();
        }
        pg &= mpPG->getPathCapacity() > 0;
        if (pg)
        {
            FALCOR_PROFILE(pRenderContext, "PGPrepare");
            mpPG->beginFrame(pRenderContext);
            mpPG->bind(mpPGPrepare->getRootVar(), mpScene->getCamera()->getPosition(), mSHARCSceneScale, mPGFrameIndex, true);
            mpPGPrepare->execute(pRenderContext, uint3(mpPG->getPathCapacity(), 1, 1));
            mpPG->barrierTraining(pRenderContext);
        }
    }
    const bool shared = sharc && pg && mpPG->getRecordStride() == mSHARCUpdateStride && mPGUpdateBounces == mSHARCUpdateBounces;
    const bool vxpg = mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG && mpVXPG->canInjectShared();
    mVXPGSharedTrainingThisFrame = vxpg;
    mVXPGSharedWithSHARCThisFrame = vxpg && sharc;
    mSharedTrainingThisFrame = shared;
    if (shared) dispatchSparse(pRenderContext, mSHARCUpdateStride, mSHARCUpdateBounces, mSHARCFrameIndex, true, true, vxpg);
    else
    {
        if (sharc) dispatchSparse(pRenderContext, mSHARCUpdateStride, mSHARCUpdateBounces, mSHARCFrameIndex, true, false, vxpg);
        else if (vxpg)
            dispatchSparse(pRenderContext, mSHARCUpdateStride, 1u, mpVXPG->getLightingFrameIndex(), false, false, true);
        if (pg) dispatchSparse(pRenderContext, mpPG->getRecordStride(), mPGUpdateBounces, mPGFrameIndex, false, true);
    }
    if (pg)
    {
        FALCOR_PROFILE(pRenderContext, "PGTrain");
        mpPG->bind(mpPGTrain->getRootVar(), mpScene->getCamera()->getPosition(), mSHARCSceneScale, mPGFrameIndex, true);
        mpPGTrain->execute(pRenderContext, uint3(mpPG->getPathCapacity(), 1, 1));
        mpPG->barrierTraining(pRenderContext);
        mPGTrainingThisFrame = true;
    }
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
    mpVXPG->beginFrame();
    mVXPGSharedTrainingThisFrame = mVXPGSharedWithSHARCThisFrame = false;
    mPGTrainingThisFrame = mSharedTrainingThisFrame = false;
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

    const auto updates = mpScene->getUpdates();
    if (is_set(updates, IScene::UpdateFlags::RecompileNeeded) || is_set(updates, IScene::UpdateFlags::GeometryChanged))
    {
        mpComputePass = nullptr;
        mpSparseUpdate = nullptr;
        mpVXPG->setScene(mpScene);
    }
    if (is_set(updates, IScene::UpdateFlags::GeometryChanged) || is_set(updates, IScene::UpdateFlags::MaterialsChanged))
        validateScene();
    if (is_set(updates, IScene::UpdateFlags::EnvMapChanged)) mpEnvMapSampler = nullptr;

    // Ignore jitter/history-only camera updates: RTPT owns its pixel sampling.
    bool sceneChanged = (updates & ~IScene::UpdateFlags::CameraPropertiesChanged) != IScene::UpdateFlags::None;
    if (is_set(updates, IScene::UpdateFlags::CameraPropertiesChanged))
    {
        const bool viewChanged = (mpScene->getCamera()->getChanges() & ~(Camera::Changes::Jitter | Camera::Changes::History)) != Camera::Changes::None;
        sceneChanged |= viewChanged;
        if (viewChanged) mpVXPG->invalidateDistribution();
    }
    if ((updates & (IScene::UpdateFlags::CameraSwitched | IScene::UpdateFlags::CameraMoved)) != IScene::UpdateFlags::None)
        mpVXPG->invalidateDistribution();
    auto& dict = renderData.getDictionary();
    const auto refreshFlags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    // Motion is reprojected by NRD. Only discontinuities discard its history.
    const auto discontinuities = IScene::UpdateFlags::CameraSwitched | IScene::UpdateFlags::GeometryChanged |
        IScene::UpdateFlags::MaterialsChanged | IScene::UpdateFlags::EmissiveMaterialsChanged |
        IScene::UpdateFlags::EnvMapChanged | IScene::UpdateFlags::EnvMapPropertiesChanged |
        IScene::UpdateFlags::LightIntensityChanged | IScene::UpdateFlags::LightPropertiesChanged |
        IScene::UpdateFlags::LightCountChanged | IScene::UpdateFlags::RenderSettingsChanged |
        IScene::UpdateFlags::RecompileNeeded;
    bool nrdDiscontinuity = (updates & discontinuities) != IScene::UpdateFlags::None;
    if (is_set(updates, IScene::UpdateFlags::CameraPropertiesChanged))
        nrdDiscontinuity |= is_set(mpScene->getCamera()->getChanges(), Camera::Changes::Frustum);
    // World-space entries survive ordinary camera motion. The first version
    // conservatively discards them when lighting, materials or geometry change.
    const auto sharcInvalidations = discontinuities & ~IScene::UpdateFlags::CameraSwitched;
    const auto movingScene = IScene::UpdateFlags::GeometryMoved | IScene::UpdateFlags::MeshesChanged | IScene::UpdateFlags::LightsMoved;
    if ((updates & (sharcInvalidations | movingScene)) != IScene::UpdateFlags::None)
    {
        mResetSHARCCache = true;
        mResetPG = true;
        mpVXPG->invalidate();
    }
    // First PG version has no LOD hysteresis or cross-LOD model retention.
    // Actual camera translation restarts PG; projection jitter changes no position.
    if (mEnablePG && any(mpScene->getCamera()->getPosition() != mPGCameraPosition))
        mResetPG = true;
    if ((mEnableNRD ? nrdDiscontinuity : sceneChanged) || mOptionsChanged || refreshFlags != RenderPassRefreshFlags::None) reset();
    mOptionsChanged = false;

    // Primary producer and consumers must use the same absolute sample index.
    if (mSampleOffset > std::numeric_limits<uint32_t>::max() - mSamplesPerPixel ||
        mAccumulatedSamples > std::numeric_limits<uint32_t>::max() - mSamplesPerPixel)
        reset();

    const uint2 frameDim(color->getWidth(), color->getHeight());
    if (any(frameDim != mFrameDim) || !mpAccumulation)
    {
        if (mEnablePG) mpSparseUpdate = mpPGPrepare = mpPGTrain = nullptr;
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
    if (mEnableVXPG)
    {
        mpVXPG->configure(mVXPGSettings, mFrameDim);
        auto debug = renderData.getTexture("vxpgDebug");
        pRenderContext->clearTexture(debug.get());
        if (mGuidingMode == RTPTVXPG::GuidingMode::VXPG && mVXPGSettings.enabled)
        {
            mpVXPG->buildGeometry(pRenderContext, debug);
            mpVXPG->prepareLighting(pRenderContext);
        }
    }
    if (mEnableSHARC || (mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG) || mpVXPG->canInjectShared())
    {
        if ((mEnableSHARC && mResetSHARCCache) || (mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG && mResetPG)) mResetNRDHistory = true;
        executeTraining(pRenderContext);
    }
    if (mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG && mVXPGSettings.enabled)
    {
        mpVXPG->updateLighting(pRenderContext, mpEnvMapSampler.get(), mSeed, mUseNEE, mSampleOffset, mEnableNRD);
        mpVXPG->renderDebug(pRenderContext, renderData.getTexture("vxpgDebug"));
    }
    if ((mEnableNRD || mEnablePG || mEnableSHARC || mEnableVXPG) && mResetNRDHistory)
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
    if (mEnablePG && mGuidingMode == RTPTVXPG::GuidingMode::PG)
        mpPG->bind(var, mpScene->getCamera()->getPosition(), mSHARCSceneScale, mPGFrameIndex, false);
    if (mEnableVXPG)
        mpVXPG->bind(var, mSampleOffset, mGuidingMode == RTPTVXPG::GuidingMode::VXPG && mVXPGSettings.enabled && mpVXPG->isReady());
    pRenderContext->uavBarrier(mpAccumulation.get());
    {
        FALCOR_PROFILE(pRenderContext, "MainRender");
        mpComputePass->execute(pRenderContext, uint3(frameDim, 1));
    }
    mVXPGDiagnosticFrameAvailable = mEnableVXPG && mGuidingMode == RTPTVXPG::GuidingMode::VXPG &&
        mVXPGSettings.enabled && mVXPGSettings.detailedDiagnostics && mpVXPG->isReady();
    if (mVXPGDiagnosticFrameAvailable)
    {
        mVXPGDiagnosticFrameSampleOffset = mSampleOffset;
        mVXPGDiagnosticFrameSamplesPerPixel = mSamplesPerPixel;
        mVXPGDiagnosticFrameGeneration = mpVXPG->getGeneration();
    }
    if (mPGTrainingThisFrame)
    {
        FALCOR_PROFILE(pRenderContext, "PGPublishCPU");
        // A normal proposal publication never invalidates NRD or the final
        // 128-frame accumulation. Explicit controls/scene resets do above.
        mpPG->finishTrainingFrame(pRenderContext);
        ++mPGFrameIndex;
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
    if (!mEnableNRD && !mEnableSHARC && !mEnablePG && !mEnableVXPG)
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
    mResetPG |= previousNEE != mUseNEE || previousRR != mUseRussianRoulette || previousSeed != mSeed;
    if (mEnablePG || mEnableVXPG)
    {
        uint32_t mode = uint32_t(mGuidingMode);
        const Gui::DropdownList modes = {{0, "BSDF"}, {1, "PG"}, {2, "VXPG"}};
        if (widget.dropdown("Guiding mode", modes, mode))
        {
            Properties props;
            props["guidingMode"] = mode == 0 ? "BSDF" : mode == 1 ? "PG" : "VXPG";
            setProperties(props);
        }
    }
    if (mEnableVXPG)
    {
        auto vx = widget.group("VXPG");
        if (vx)
        {
            Properties props;
            bool flag = mVXPGSettings.enabled;
            if (vx.checkbox("Enabled", flag)) props["vxpgEnabled"] = flag;
            flag = mVXPGSettings.useGuiding;
            if (vx.checkbox("Use guiding", flag)) props["vxpgUseGuiding"] = flag;
            flag = mVXPGSettings.freezeUpdates;
            if (vx.checkbox("Freeze updates", flag)) props["vxpgFreezeUpdates"] = flag;
            vx.text("Estimator: ShortBranch (A)");
            vx.text("VXPG applies at physical bounce 0 and 1 only.");
            auto injection = vx.group("Shared injection");
            if (injection)
            {
                flag = mVXPGSettings.sharedInjectionEnabled;
                if (injection.checkbox("Enabled", flag)) props["vxpgSharedInjectionEnabled"] = flag;
                injection.text("Uses SHaRC Update stride (default 5x5), second surface only.");
                injection.text(mVXPGSharedWithSHARCThisFrame ? "Sharing the active SHaRC training paths." :
                    mVXPGSharedTrainingThisFrame ? "VXPG-only sparse paths; SHaRC updates are disabled/frozen." : "Shared injection inactive.");
                injection.tooltip("Keeps full-screen primary data. Shares raw direct-light observations before MIS, preserving SHaRC RNG and depth. Changes VXPG coverage; resets its proposal, NRD and final accumulation.", true);
            }
            auto cache = vx.group("PG SHaRC");
            if (cache)
            {
                flag = mVXPGSettings.pgUseCache;
                if (cache.checkbox("Enabled", flag)) props["vxpgPGUseCache"] = flag;
                if (!mEnableSHARC || !mSHARCEnabled || !mSHARCUseCache)
                    cache.text("Inactive: SHaRC cache queries are disabled.");
                cache.tooltip("Use full SHaRC on eligible PG hits; otherwise evaluate local lighting and end the branch. Resets NRD and final accumulation.", true);
            }
            uint32_t number = mVXPGSettings.gridResolution;
            const Gui::DropdownList grids = {{16, "16"}, {32, "32"}, {64, "64"}, {128, "128"}};
            if (vx.dropdown("Grid resolution", grids, number)) props["vxpgGridResolution"] = number;
            number = mVXPGSettings.maxVoxels;
            if (vx.var("Active voxel capacity", number, 256u, 262144u)) props["vxpgMaxVoxels"] = number;
            number = mVXPGSettings.clusterCount;
            if (vx.var("Clusters", number, 1u, 32u)) props["vxpgClusterCount"] = number;
            number = mVXPGSettings.superpixelSize;
            if (vx.var("Superpixel size", number, 8u, 64u)) props["vxpgSuperpixelSize"] = number;
            number = mVXPGSettings.budgetMiB;
            if (vx.var("Resource budget (MiB)", number, 32u, 2048u)) props["vxpgBudgetMB"] = number;
            flag = mVXPGSettings.visibilityEnabled;
            if (vx.checkbox("Visibility Enabled", flag)) props["vxpgVisibilityEnabled"] = flag;
            flag = mVXPGSettings.debugEnabled;
            if (vx.checkbox("Debug Enabled", flag)) props["vxpgDebugEnabled"] = flag;
            auto diagnostics = vx.group("Detailed diagnostics");
            if (diagnostics)
            {
                flag = mVXPGSettings.detailedDiagnostics;
                if (diagnostics.checkbox("Enabled", flag)) props["vxpgDetailedDiagnostics"] = flag;
                diagnostics.text("Activity counters cover one rendered frame; model counters require an update.");
                diagnostics.tooltip("Compile out activity atomics when disabled. Error and algorithm state remain enabled. Does not reset the model or image history.", true);
            }
            uint32_t debugMode = mVXPGSettings.debugMode;
            const Gui::DropdownList debugModes = {{0, "Voxel bounds"}, {1, "Superpixel ID"}, {2, "Voxel cluster ID"}, {3, "Visibility descriptor"}};
            if (vx.dropdown("Debug view", debugModes, debugMode)) props["vxpgDebugMode"] = debugMode;
            if (!props.empty()) setProperties(props);
            if (vx.button("Reset VXPG")) resetVXPG();
            if (mGuidingMode != RTPTVXPG::GuidingMode::VXPG) vx.text("Not selected; settings preserved.");
            else if (!mVXPGSettings.enabled) vx.text("Disabled; using BSDF.");
            else if (!mVXPGSettings.useGuiding) vx.text("Sampling disabled; using BSDF.");
            else if (!mpVXPG->isReady()) vx.text("Using BSDF: " + mpVXPG->getFallbackReason());
            else vx.text("VXPG selected; GPU-valid proposals are used, otherwise BSDF.");
            if (vx.button("Read GPU statistics"))
            {
                const auto s = mpVXPG->readCounters();
                const auto c = mpVXPG->readClusterCounters();
                mVXPGDiagnosticText = "Snapshot generation " + std::to_string(mpVXPG->getGeneration()) +
                    ": " + (s[5] == mpVXPG->getGeneration() ? "ready" : "BSDF fallback") +
                    ", voxels " + std::to_string(s[3]) + ", clusters " + std::to_string(c[1]) +
                    ", geometry overflow " + std::to_string(s[1]) + ", voxel overflow " + std::to_string(s[4]) +
                    ", invalid " + std::to_string(s[11]);
                const bool activityAvailable = mVXPGSettings.detailedDiagnostics && mVXPGDiagnosticFrameAvailable &&
                    mVXPGDiagnosticFrameGeneration == mpVXPG->getGeneration();
                if (activityAvailable)
                    mVXPGDiagnosticText += ", accepted " + std::to_string(s[7]) + "/" + std::to_string(s[6]) +
                        " (one frame, sample offset " + std::to_string(mVXPGDiagnosticFrameSampleOffset) +
                        ", spp " + std::to_string(mVXPGDiagnosticFrameSamplesPerPixel) + ")";
                else mVXPGDiagnosticText += ", activity unavailable";
                if (!mpVXPG->hasModelDiagnostics()) mVXPGDiagnosticText += ", model activity unavailable";
            }
            if (!mVXPGSettings.detailedDiagnostics) vx.text("Detailed activity unavailable (disabled); error counters remain enabled.");
            if (!mVXPGDiagnosticText.empty()) vx.text(mVXPGDiagnosticText);
            vx.text("Estimated resource MiB: " + std::to_string(double(mpVXPG->getEstimatedBytes()) / (1024. * 1024.)));
            if (usesPairedSharc()) vx.text("Paired SHaRC extra MiB: " + std::to_string(double(uint64_t(mSHARCEntries)*120ull)/(1024.*1024.)));
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
    if (mEnablePG)
    {
        auto pgWidget = widget.group("PG");
        if (pgWidget)
        {
            if (mGuidingMode != RTPTVXPG::GuidingMode::PG) pgWidget.text("Not selected; no guiding or training. Settings preserved.");
            Properties props;
            bool value = mPGSettings.enabled;
            if (pgWidget.checkbox("Enabled", value)) props["pgEnabled"] = value;
            pgWidget.tooltip("Enable guiding and training independently of SHaRC. Switching resets NRD and final accumulation.", true);
            value = mPGSettings.useGuiding;
            if (pgWidget.checkbox("Use guiding", value)) props["pgUseGuiding"] = value;
            value = !mPGSettings.trainingEnabled;
            if (pgWidget.checkbox("Freeze training", value)) props["pgFreeze"] = value;
            value = mPGSettings.detailedDiagnostics;
            if (pgWidget.checkbox("Detailed diagnostics enabled", value)) props["pgDetailedDiagnostics"] = value;
            pgWidget.tooltip("Count queries and training activity with GPU atomics. Error counters stay enabled. Toggling preserves the model and image history.", true);
            float fraction = mPGSettings.guideFraction;
            if (pgWidget.var("Guide fraction", fraction, 0.f, 0.95f)) props["pgGuideFraction"] = fraction;
            uint32_t number = mPGSettings.coarseLevels;
            if (pgWidget.var("Coarser grid levels", number, 0u, 8u)) props["pgCoarseLevels"] = number;
            number = mPGUpdateStride;
            if (pgWidget.var("Training tile size", number, 1u, 64u)) props["pgUpdateStride"] = number;
            number = mPGUpdateBounces;
            if (pgWidget.var("Training bounces", number, 1u, 32u)) props["pgUpdateBounces"] = number;
            number = mPGSettings.pollFrames;
            if (pgWidget.var("Publish interval", number, 1u, 1024u)) props["pgPublishInterval"] = number;
            number = mPGSettings.treeBudgetMiB;
            if (pgWidget.var("Model budget (MiB)", number, 16u, 1024u)) props["pgTreeBudgetMB"] = number;
            number = mPGSettings.recordBudgetMiB;
            if (pgWidget.var("Record budget (MiB)", number, 1u, 2048u)) props["pgRecordBudgetMB"] = number;
            number = mPGSettings.maxRegions;
            if (pgWidget.var("Max regions", number, 1u, 65536u)) props["pgMaxRegions"] = number;
            number = mPGSettings.maxNodesPerRegion;
            if (pgWidget.var("Max nodes per region", number, 1u, 1024u)) props["pgMaxNodesPerRegion"] = number;
            number = mPGSettings.maxDirectionalDepth;
            if (pgWidget.var("Max direction depth", number, 1u, 16u)) props["pgMaxDirectionalDepth"] = number;
            if (!props.empty()) setProperties(props);
            if (pgWidget.button("Reset PG")) resetPG();
            const auto& stats = mpPG->getStatistics();
            pgWidget.text("Ready regions: " + std::to_string(stats.readyRegions) + " / " + std::to_string(stats.regions));
            pgWidget.text("Direction nodes (read/build): " + std::to_string(stats.readNodes) + " / " + std::to_string(stats.buildNodes));
            pgWidget.text("Training frames / publications: " + std::to_string(stats.trainingFrames) + " / " + std::to_string(stats.publications));
            pgWidget.text("Actual tile size: " + std::to_string(mpPG->getRecordStride()));
            pgWidget.text("Model reserved MiB: " + std::to_string(double(stats.modelReservedBytes) / (1024. * 1024.)));
            pgWidget.text("Record MiB: " + std::to_string(double(stats.recordBytes) / (1024. * 1024.)));
            pgWidget.text("Last publish ms: " + std::to_string(stats.lastPublishMs));
            pgWidget.text("Publish mean / max ms: " + std::to_string(stats.publishCalls ? stats.totalPublishMs / stats.publishCalls : 0.) +
                " / " + std::to_string(stats.maxPublishMs));
            pgWidget.text("Last publish waits (drain/read/upload): " + std::to_string(stats.lastDrainWaits) + " / " +
                std::to_string(stats.lastReadbackWaits) + " / " + std::to_string(stats.lastUploadWaits));
            if (!mPGSettings.detailedDiagnostics) pgWidget.text("Detailed activity counters paused; error counters remain enabled.");
            pgWidget.text("Invalid / record overflow / accumulation overflow: " + std::to_string(stats.invalidSamples) + " / " +
                std::to_string(stats.recordOverflow) + " / " + std::to_string(stats.accumulationOverflow));
            pgWidget.text(mSharedTrainingThisFrame ? "Sparse training shared with SHaRC." : "Separate sparse update settings or inactive consumer.");
            pgWidget.text("PG-selected edges trace on; SHaRC termination remains on BSDF-selected edges.");
            pgWidget.text("Camera translation resets PG. LOD hysteresis, old LOD retention and maturity fallback are deferred.");
        }
    }
}
