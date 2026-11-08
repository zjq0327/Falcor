#include "RTPT.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "Scene/Material/StandardMaterial.h"
#include "Scene/Lights/Light.h"
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
    {4, "Cache terminations"}, {5, "Traced rays"}, {6, "Update coverage"}, {7, "Hash occupancy"},
};
const Gui::DropdownList kSHARCCapacities = {
    {1u << 16, "64K entries (2.5 MiB)"}, {1u << 18, "256K entries (10 MiB)"},
    {1u << 20, "1M entries (40 MiB)"}, {1u << 22, "4M entries (160 MiB)"},
};
const Gui::DropdownList kGRISPGPrefixDepths = {
    {0u, "Disabled"}, {1u, "D root: x0 to x1"},
};
}

extern "C" FALCOR_API_EXPORT void registerPlugin(PluginRegistry& registry)
{
    registry.registerClass<RenderPass, RTPT>();
    ScriptBindings::registerBinding([](pybind11::module& m)
    {
        pybind11::class_<RTPT, RenderPass, ref<RTPT>> pass(m, "RTPT");
        pass.def_property_readonly("pgStats", [](const RTPT& self) { return self.getPGStatistics().toPython(); });
        pass.def_property_readonly("pgAsyncStats", [](const RTPT& self) { return self.getPGAsyncStatistics().toPython(); });
        pass.def_property_readonly("sharcMotionStats", [](const RTPT& self) { return self.getSHARCMotionStatistics().toPython(); });
        pass.def_property_readonly("stageStats", [](const RTPT& self) { return self.getStageStatistics().toPython(); });
        pass.def("getGRISValidationBuffers", [](const RTPT& self)
        {
            const auto buffers = self.getGRISValidationBuffers();
            pybind11::dict result;
            result["fresh"] = buffers[0];
            result["winner"] = buffers[1];
            result["history"] = buffers[2];
            result["prefix"] = buffers[3];
            return result;
        });
        pass.def_property_readonly("diStats", [](const RTPT& self) { return self.getDIStatistics().toPython(); });
        pass.def_property_readonly("regirStats", [](const RTPT& self) { return self.getReGIRStatistics().toPython(); });
        pass.def("resetPG", &RTPT::resetPG);
    });
}

RTPT::RTPT(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    mpPG = std::make_unique<RTPTPG::Manager>(mpDevice);
    setProperties(props);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

void RTPT::setProperties(const Properties& props)
{
    const bool couldUseGRISTemporal = canUseGRISTemporal();
    drainPGAsync();
    uint32_t samplesPerPixel = mSamplesPerPixel, maxBounces = mMaxBounces, rrStartBounce = mRRStartBounce, seed = mSeed;
    uint32_t maxAccumulationFrames = mMaxAccumulationFrames;
    bool useNEE = mUseNEE, useRussianRoulette = mUseRussianRoulette, accumulate = mAccumulate;
    bool enableNRD = mEnableNRD;
    bool grisEnabled = mGRISEnabled;
    bool grisSpatialEnabled = mGRISSpatialEnabled;
    bool grisTemporalEnabled = mGRISTemporalEnabled;
    uint32_t grisPGPrefixDepth = mGRISPGPrefixDepth;
    float grisSharcX1Blend = mGRISSharcX1Blend;
    bool restirDIEnabled = mRestirDIEnabled;
    bool regirEnabled = mReGIREnabled, regirSecondaryEnabled = mReGIRSecondaryEnabled, regirTrainingEnabled = mReGIRTrainingEnabled;
    bool regirLightCullingEnabled = mReGIRCullingEnabled;
    uint32_t regirGridSize = mReGIRGridSize, regirLightsPerCell = mReGIRLightsPerCell;
    uint32_t regirBuildSamples = mReGIRBuildSamples, regirBudgetMB = mReGIRBudgetMB;
    float regirCellSize = mReGIRCellSize, regirSamplingJitter = mReGIRSamplingJitter;
    float regirCoarsenCellDistance = mReGIRCoarsenCellDistance, regirBrightnessThreshold = mReGIRBrightnessThreshold;
    uint32_t restirDICandidateCount = mRestirDICandidateCount, restirDIBudgetMB = mRestirDIBudgetMB;
    bool restirDITemporalEnabled = mRestirDITemporalEnabled, restirDISpatialEnabled = mRestirDISpatialEnabled;
    uint32_t restirDIHistoryLength = mRestirDIHistoryLength, restirDISpatialSamples = mRestirDISpatialSamples;
    float restirDISpatialRadius = mRestirDISpatialRadius;
    bool enableSHARC = mEnableSHARC, sharcUseCache = mSHARCUseCache, sharcFreeze = mSHARCFreeze;
    bool sharcEnabled = mSHARCEnabled;
    uint32_t sharcEntries = mSHARCEntries, sharcUpdateStride = mSHARCUpdateStride, sharcUpdateBounces = mSHARCUpdateBounces;
    uint32_t sharcMinBounce = mSHARCMinBounce, sharcAccumulationFrames = mSHARCAccumulationFrames;
    uint32_t sharcStaleFrames = mSHARCStaleFrames, sharcDebugMode = mSHARCDebugMode;
    float sharcSceneScale = mSHARCSceneScale, sharcMinRoughness = mSHARCMinRoughness;
    bool enablePG = mEnablePG;
    bool pgAsyncTraining = mPGAsyncTraining, pgAsyncMeasure = mPGAsyncMeasure;
    auto pg = mPGSettings;
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
        else if (key == "grisEnabled") grisEnabled = value;
        else if (key == "grisSpatialEnabled") grisSpatialEnabled = value;
        else if (key == "grisTemporalEnabled") grisTemporalEnabled = value;
        else if (key == "grisPGPrefixDepth") grisPGPrefixDepth = value;
        else if (key == "grisSharcX1Blend") grisSharcX1Blend = value;
        else if (key == "restirDIEnabled") restirDIEnabled = value;
        else if (key == "regirEnabled") regirEnabled = value;
        else if (key == "regirSecondaryEnabled") regirSecondaryEnabled = value;
        else if (key == "regirTrainingEnabled") regirTrainingEnabled = value;
        else if (key == "regirFreeze") logWarningOnce("RTPT ignores the retired regirFreeze property. ReGIR RIS reuse is automatic.");
        else if (key == "regirLightCullingEnabled") regirLightCullingEnabled = value;
        else if (key == "regirGridSize") regirGridSize = value;
        else if (key == "regirLightsPerCell") regirLightsPerCell = value;
        else if (key == "regirBuildSamples") regirBuildSamples = value;
        else if (key == "regirBudgetMB") regirBudgetMB = value;
        else if (key == "regirCellSize") regirCellSize = value;
        else if (key == "regirSamplingJitter") regirSamplingJitter = value;
        else if (key == "regirCoarsenCellDistance") regirCoarsenCellDistance = value;
        else if (key == "regirBrightnessThreshold") regirBrightnessThreshold = value;
        else if (key == "restirDICandidateCount") restirDICandidateCount = value;
        else if (key == "restirDIBudgetMB") restirDIBudgetMB = value;
        else if (key == "restirDITemporalEnabled") restirDITemporalEnabled = value;
        else if (key == "restirDISpatialEnabled") restirDISpatialEnabled = value;
        else if (key == "restirDIHistoryLength") restirDIHistoryLength = value;
        else if (key == "restirDISpatialSamples") restirDISpatialSamples = value;
        else if (key == "restirDISpatialRadius") restirDISpatialRadius = value;
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
        else if (key == "pgEnabled") pg.enabled = value;
        else if (key == "pgUseGuiding") pg.useGuiding = value;
        else if (key == "pgFreeze") pg.trainingEnabled = !bool(value);
        else if (key == "pgAsyncTraining") pgAsyncTraining = value;
        else if (key == "pgAsyncMeasure") pgAsyncMeasure = value;
        else if (key == "pgDetailedDiagnostics") pg.detailedDiagnostics = value;
        else if (key == "pgGuideFraction") pg.guideFraction = value;
        else if (key == "pgTreeBudgetMB") pg.treeBudgetMiB = value;
        else if (key == "pgRecordBudgetMB") pg.recordBudgetMiB = value;
        else if (key == "pgCoarseLevels") pg.coarseLevels = value;
        else if (key == "pgPublishInterval") pg.pollFrames = value;
        else if (key == "pgMaxRegions") pg.maxRegions = value;
        else if (key == "pgDirectionBins")
            FALCOR_CHECK(uint32_t(value) == RTPTPG::kDirectionBins, "PG uses four fixed hemisphere regions; directional resolution is no longer configurable.");
        else if (key == "pgMaxNodesPerRegion" || key == "pgMaxDirectionalDepth" || key == "pgDirectionalThreshold")
            logWarning("PG uses four fixed hemisphere regions; '{}' is ignored.", key);
        else if (key == "pgUpdateStride") pgUpdateStride = value;
        else if (key == "pgUpdateBounces") pgUpdateBounces = value;
        else FALCOR_THROW("Unknown RTPT property '{}'.", key);
    }
    FALCOR_CHECK(samplesPerPixel >= 1 && samplesPerPixel <= 1024, "RTPT samplesPerPixel must be in [1, 1024].");
    FALCOR_CHECK(maxBounces >= 1 && maxBounces <= 64, "RTPT maxBounces must be in [1, 64].");
    FALCOR_CHECK(grisPGPrefixDepth <= 1u, "RTPT grisPGPrefixDepth must be 0 or 1.");
    FALCOR_CHECK(std::isfinite(grisSharcX1Blend) && grisSharcX1Blend >= 0.f && grisSharcX1Blend < 1.f,
        "RTPT grisSharcX1Blend must be in [0, 1).");
    FALCOR_CHECK(restirDICandidateCount >= 1 && restirDICandidateCount <= 128,
        "ReSTIR DI Initial candidate count must be in [1, 128].");
    FALCOR_CHECK(restirDIBudgetMB >= 16 && restirDIBudgetMB <= 2048,
        "ReSTIR DI resource budget must be in [16, 2048] MiB.");
    FALCOR_CHECK(restirDIHistoryLength >= 1 && restirDIHistoryLength <= 32,
        "ReSTIR DI history length must be in [1, 32].");
    FALCOR_CHECK(restirDISpatialSamples >= 1 && restirDISpatialSamples <= 32,
        "ReSTIR DI spatial sample count must be in [1, 32].");
    FALCOR_CHECK(std::isfinite(restirDISpatialRadius) && restirDISpatialRadius >= 1.f && restirDISpatialRadius <= 64.f,
        "ReSTIR DI spatial radius must be in [1, 64] pixels.");
    FALCOR_CHECK(rrStartBounce >= 1 && rrStartBounce <= 64, "RTPT rrStartBounce must be in [1, 64].");
    FALCOR_CHECK(!enableNRD || (samplesPerPixel == 1 && !accumulate),
        "RTPT NRD mode requires samplesPerPixel=1 and accumulate=false; NRD manages temporal history.");
    FALCOR_CHECK(!enableSHARC || !accumulate,
        "RTPT SHaRC mode requires accumulate=false; its world-space cache changes between frames.");
    FALCOR_CHECK(!enablePG || !accumulate, "RTPT PG requires accumulate=false; use the independent FrameAccumulation pass.");
    FALCOR_CHECK(pgUpdateStride >= 1 && pgUpdateStride <= 64 && pgUpdateBounces >= 1 && pgUpdateBounces <= 32,
        "PG update stride must be in [1,64] and bounces in [1,32].");
    FALCOR_CHECK(pg.treeBudgetMiB >= 16 && pg.treeBudgetMiB <= 1024 && pg.recordBudgetMiB >= 1 && pg.recordBudgetMiB <= 2048,
        "PG model budget must be in [16,1024] MiB and record budget in [1,2048] MiB.");
    FALCOR_CHECK(pg.coarseLevels <= 8 && pg.pollFrames >= 1 && pg.pollFrames <= 1024 && pg.maxRegions >= 1 && pg.maxRegions <= 65536,
        "Invalid PG coarse level, publish interval or region limit.");
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
    if (enableSHARC || enablePG || regirEnabled)
        FALCOR_CHECK(mpDevice->getType() == Device::Type::D3D12 && mpDevice->isShaderModelSupported(ShaderModel::SM6_6),
            "RTPT SHaRC, PG and ReGIR require D3D12 and Shader Model 6.6 for native 16-bit types and 64-bit buffer atomics.");
    FALCOR_CHECK(regirGridSize >= 1u && regirGridSize <= 128u && regirLightsPerCell >= 1u && regirLightsPerCell <= 1024u,
        "ReGIR grid size must be in [1,128], slots per cell in [1,1024].");
    FALCOR_CHECK(regirBuildSamples >= 1u && regirBuildSamples <= 128u && regirBudgetMB >= 1u && regirBudgetMB <= 1024u,
        "ReGIR build samples must be in [1,128], budget in [1,1024] MiB.");
    FALCOR_CHECK(std::isfinite(regirCellSize) && regirCellSize >= 1e-6f && regirCellSize <= 1e6f && std::isfinite(regirSamplingJitter) &&
        regirSamplingJitter >= 0.f && regirSamplingJitter <= 4.f, "ReGIR cell size must be in [1e-6,1e6], jitter in [0,4].");
    FALCOR_CHECK(std::isfinite(regirCoarsenCellDistance) && regirCoarsenCellDistance >= 1.f && regirCoarsenCellDistance <= 1024.f &&
        std::isfinite(regirBrightnessThreshold) && regirBrightnessThreshold >= 0.f && regirBrightnessThreshold <= 1e12f,
        "ReGIR LOD distance must be in [1,1024] cells and brightness threshold in [0,1e12].");
    const bool regirChanged = regirEnabled != mReGIREnabled || regirSecondaryEnabled != mReGIRSecondaryEnabled ||
        regirTrainingEnabled != mReGIRTrainingEnabled || regirGridSize != mReGIRGridSize ||
        regirLightsPerCell != mReGIRLightsPerCell || regirBuildSamples != mReGIRBuildSamples ||
        regirBudgetMB != mReGIRBudgetMB || regirCellSize != mReGIRCellSize || regirSamplingJitter != mReGIRSamplingJitter ||
        regirLightCullingEnabled != mReGIRCullingEnabled || regirCoarsenCellDistance != mReGIRCoarsenCellDistance ||
        regirBrightnessThreshold != mReGIRBrightnessThreshold;
    const bool regirCompileChanged = regirEnabled != mReGIREnabled || (regirEnabled && restirDIEnabled != mRestirDIEnabled);
    const bool modeChanged = enableNRD != mEnableNRD || enableSHARC != mEnableSHARC || enablePG != mEnablePG || regirCompileChanged;
    const bool diChanged = restirDIEnabled != mRestirDIEnabled || restirDICandidateCount != mRestirDICandidateCount ||
        restirDIBudgetMB != mRestirDIBudgetMB || restirDITemporalEnabled != mRestirDITemporalEnabled ||
        restirDISpatialEnabled != mRestirDISpatialEnabled || restirDIHistoryLength != mRestirDIHistoryLength ||
        restirDISpatialSamples != mRestirDISpatialSamples || restirDISpatialRadius != mRestirDISpatialRadius;
    const bool neeChanged = useNEE != mUseNEE;
    const bool sampleCountChanged = samplesPerPixel != mSamplesPerPixel;
    const bool trainingSamplingChanged = neeChanged || seed != mSeed || useRussianRoulette != mUseRussianRoulette;
    const bool diEligibilityChanged = neeChanged || sampleCountChanged;
    const bool pgStructureChanged = enablePG != mEnablePG || pg.coarseLevels != mPGSettings.coarseLevels ||
        pg.treeBudgetMiB != mPGSettings.treeBudgetMiB || pg.maxRegions != mPGSettings.maxRegions ||
        pgUpdateBounces != mPGUpdateBounces || sharcSceneScale != mSHARCSceneScale;
    const bool pgRecordsChanged = pg.recordBudgetMiB != mPGSettings.recordBudgetMiB || pgUpdateStride != mPGUpdateStride;
    const bool pgSignalChanged = pgStructureChanged || pg.enabled != mPGSettings.enabled || pg.useGuiding != mPGSettings.useGuiding ||
        pg.guideFraction != mPGSettings.guideFraction;
    const bool sharcStructureChanged = enableSHARC != mEnableSHARC || sharcEntries != mSHARCEntries ||
        sharcSceneScale != mSHARCSceneScale || sharcUpdateBounces != mSHARCUpdateBounces;
    const bool sharcSignalChanged = sharcStructureChanged || sharcUseCache != mSHARCUseCache ||
        sharcUpdateStride != mSHARCUpdateStride || sharcMinBounce != mSHARCMinBounce || sharcMinRoughness != mSHARCMinRoughness ||
        sharcAccumulationFrames != mSHARCAccumulationFrames || sharcStaleFrames != mSHARCStaleFrames;
    const bool sharcQuery = enableSHARC && sharcEnabled && sharcUseCache;
    const bool grisSharcReuseChanged = sharcQuery != (mEnableSHARC && mSHARCEnabled && mSHARCUseCache);
    mOptionsChanged |= sampleCountChanged || maxBounces != mMaxBounces || rrStartBounce != mRRStartBounce ||
        trainingSamplingChanged || accumulate != mAccumulate || maxAccumulationFrames != mMaxAccumulationFrames ||
        sharcEnabled != mSHARCEnabled || modeChanged || sharcSignalChanged || pgSignalChanged || diChanged ||
        regirChanged || grisSharcX1Blend != mGRISSharcX1Blend;
    mResetPG |= pgStructureChanged || trainingSamplingChanged;
    mResetSHARCCache |= sharcStructureChanged || trainingSamplingChanged;
    if (sharcEntries != mSHARCEntries)
        mpSHARCHashEntries = mpSHARCAccumulation = mpSHARCResolved = nullptr;
    if (modeChanged || sharcUpdateBounces != mSHARCUpdateBounces)
    {
        mpSHARCResolve = nullptr;
        mpSHARCInvalidate = nullptr;
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
    if (grisEnabled != mGRISEnabled || grisSpatialEnabled != mGRISSpatialEnabled ||
        grisTemporalEnabled != mGRISTemporalEnabled || (grisEnabled && grisSharcReuseChanged))
    {
        mGRISEnabled = grisEnabled;
        mGRISSpatialEnabled = grisSpatialEnabled;
        mGRISTemporalEnabled = grisTemporalEnabled;
        mOptionsChanged = true;
        invalidateGRIS();
    }
    mGRISSharcX1Blend = grisSharcX1Blend;
    if (grisPGPrefixDepth != mGRISPGPrefixDepth)
    {
        mGRISPGPrefixDepth = grisPGPrefixDepth;
        // This changes only GRIS proposals. Preserve the guide model, sample
        // sequence and the independent SHaRC/NRD histories.
        invalidateGRIS();
    }
    mRestirDIEnabled = restirDIEnabled;
    mRestirDICandidateCount = restirDICandidateCount;
    mRestirDIBudgetMB = restirDIBudgetMB;
    mRestirDITemporalEnabled = restirDITemporalEnabled;
    mRestirDISpatialEnabled = restirDISpatialEnabled;
    mRestirDIHistoryLength = restirDIHistoryLength;
    mRestirDISpatialSamples = restirDISpatialSamples;
    mRestirDISpatialRadius = restirDISpatialRadius;
    mReGIREnabled = regirEnabled;
    mReGIRSecondaryEnabled = regirSecondaryEnabled;
    mReGIRTrainingEnabled = regirTrainingEnabled;
    mReGIRCullingEnabled = regirLightCullingEnabled;
    mReGIRGridSize = regirGridSize;
    mReGIRLightsPerCell = regirLightsPerCell;
    mReGIRBuildSamples = regirBuildSamples;
    mReGIRBudgetMB = regirBudgetMB;
    mReGIRCellSize = regirCellSize;
    mReGIRSamplingJitter = regirSamplingJitter;
    mReGIRCoarsenCellDistance = regirCoarsenCellDistance;
    mReGIRBrightnessThreshold = regirBrightnessThreshold;
    if (diChanged || diEligibilityChanged || regirChanged)
    {
        invalidateDirectLighting();
        mLightCatalog.retry();
    }
    if (regirChanged) invalidateReGIR();
    if (!mRestirDIEnabled && !mReGIREnabled && (diChanged || regirChanged)) mLightCatalog.release();
    mResetPG |= regirChanged || regirCompileChanged;
    mResetSHARCCache |= regirChanged || regirCompileChanged;
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
    mPGAsyncTraining = pgAsyncTraining;
    mPGAsyncMeasure = pgAsyncMeasure;
    mPGSettings = pg;
    mPGUpdateStride = pgUpdateStride;
    mPGUpdateBounces = pgUpdateBounces;
    if (mStagePreparationFailed && couldUseGRISTemporal != canUseGRISTemporal())
        invalidateStages();
    if (pgStructureChanged)
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
    props["grisEnabled"] = mGRISEnabled;
    props["grisSpatialEnabled"] = mGRISSpatialEnabled;
    props["grisTemporalEnabled"] = mGRISTemporalEnabled;
    props["grisPGPrefixDepth"] = mGRISPGPrefixDepth;
    props["grisSharcX1Blend"] = mGRISSharcX1Blend;
    props["restirDIEnabled"] = mRestirDIEnabled;
    props["regirEnabled"] = mReGIREnabled;
    props["regirSecondaryEnabled"] = mReGIRSecondaryEnabled;
    props["regirTrainingEnabled"] = mReGIRTrainingEnabled;
    props["regirLightCullingEnabled"] = mReGIRCullingEnabled;
    props["regirGridSize"] = mReGIRGridSize;
    props["regirLightsPerCell"] = mReGIRLightsPerCell;
    props["regirBuildSamples"] = mReGIRBuildSamples;
    props["regirBudgetMB"] = mReGIRBudgetMB;
    props["regirCellSize"] = mReGIRCellSize;
    props["regirSamplingJitter"] = mReGIRSamplingJitter;
    props["regirCoarsenCellDistance"] = mReGIRCoarsenCellDistance;
    props["regirBrightnessThreshold"] = mReGIRBrightnessThreshold;
    props["restirDICandidateCount"] = mRestirDICandidateCount;
    props["restirDIBudgetMB"] = mRestirDIBudgetMB;
    props["restirDITemporalEnabled"] = mRestirDITemporalEnabled;
    props["restirDISpatialEnabled"] = mRestirDISpatialEnabled;
    props["restirDIHistoryLength"] = mRestirDIHistoryLength;
    props["restirDISpatialSamples"] = mRestirDISpatialSamples;
    props["restirDISpatialRadius"] = mRestirDISpatialRadius;
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
    props["pgEnabled"] = mPGSettings.enabled;
    props["pgUseGuiding"] = mPGSettings.useGuiding;
    props["pgFreeze"] = !mPGSettings.trainingEnabled;
    props["pgAsyncTraining"] = mPGAsyncTraining;
    props["pgAsyncMeasure"] = mPGAsyncMeasure;
    props["pgDetailedDiagnostics"] = mPGSettings.detailedDiagnostics;
    props["pgGuideFraction"] = mPGSettings.guideFraction;
    props["pgTreeBudgetMB"] = mPGSettings.treeBudgetMiB;
    props["pgRecordBudgetMB"] = mPGSettings.recordBudgetMiB;
    props["pgCoarseLevels"] = mPGSettings.coarseLevels;
    props["pgPublishInterval"] = mPGSettings.pollFrames;
    props["pgMaxRegions"] = mPGSettings.maxRegions;
    props["pgDirectionBins"] = RTPTPG::kDirectionBins;
    props["pgUpdateStride"] = mPGUpdateStride;
    props["pgUpdateBounces"] = mPGUpdateBounces;
    return props;
}

Properties RTPT::getPGStatistics() const
{
    Properties props;
    const auto& s = mpPG->getStatistics();
    props["enabled"] = mEnablePG && mPGSettings.enabled;
    props["trainingEnabled"] = mPGSettings.trainingEnabled;
    props["directionBins"] = RTPTPG::kDirectionBins;
    props["hemisphereOnly"] = true;
    props["adaptiveRefinement"] = false;
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
    props["snapshotVersion"] = mpPG->getReadSnapshotVersion();
    props["sharedTraining"] = mSharedTrainingThisFrame;
    for (uint32_t i = 0; i < s.diagnostics.size(); ++i)
        props["diagnostic" + std::to_string(i)] = s.diagnostics[i];
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
    return reflection;
}

void RTPT::reset()
{
    mSampleOffset = 0;
    resetAccumulation();
    mResetNRDHistory = true;
    resetGRISHistory();
}

void RTPT::resetAccumulation()
{
    mAccumulatedSamples = 0;
    mAccumulatedFrames = 0;
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
        const bool grisDiffuse = mGRISEnabled && material->getType() == MaterialType::PBRTDiffuse;
        FALCOR_CHECK(grisDiffuse || (standard && standard->getSpecularTransmission() == 0.f && standard->getDiffuseTransmission() == 0.f),
            "RTPT supports reflection-only StandardMaterial surfaces and PBRTDiffuse surfaces in GRIS scenes (material '{}').",
            material->getName());
    }
}

void RTPT::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    drainPGAsync();
    invalidateStages();
    invalidateReGIR();
    mLightCatalog.reset();
    mpScene = pScene;
    mpComputePass = nullptr;
    mpSHARCResolve = nullptr;
    mpSHARCInvalidate = nullptr;
    mSHARCPreviousInstanceBounds.clear();
    mSHARCMotionBoundsCPU.clear();
    mSHARCMotionResponsiveFrames = 0;
    mpSparseUpdate = mpPGPrepare = mpPGTrain = nullptr;
    mpEnvMapSampler = nullptr;
    mLightingMask = ~0u;
    mpCameraPattern = nullptr;
    mpJitterCamera = nullptr;
    mResetSHARCCache = true;
    mSHARCFrameIndex = 0;
    mResetPG = true;
    reset();
    if (mpScene)
    {
        validateScene();
        if (mpScene->getCamera()->getApertureRadius() > 0.f)
            logWarning("RTPT uses a pinhole camera; aperture is ignored.");
    }
}

ProgramDesc RTPT::makeSceneProgramDesc(const char* path, const char* entry) const
{
    ProgramDesc desc;
    desc.addShaderModules(mpScene->getShaderModules());
    desc.addTypeConformances(mpScene->getTypeConformances());
    desc.addShaderLibrary(path).csEntry(entry);
    if (mEnableSHARC || mEnablePG || mReGIREnabled)
    {
        desc.setShaderModel(ShaderModel::SM6_6);
        desc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
    }
    return desc;
}

void RTPT::prepareProgram(RenderContext* pRenderContext)
{
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

    // A new scene/type/lighting specialization also invalidates the private
    // primary producer and its consumer. Ordinary camera motion does not.
    if (!mpComputePass)
    {
        invalidateStages();
        invalidateReGIRPrograms();
    }

    if (!mpComputePass || ((mEnableSHARC || mEnablePG) && !mpSparseUpdate) ||
        (mEnablePG && (!mpPGPrepare || !mpPGTrain)) || (mEnableSHARC && (!mpSHARCResolve || !mpSHARCInvalidate)))
    {
        const auto desc = makeSceneProgramDesc("RenderPasses/RTPT/RTPT.cs.slang");
        DefineList defines = mpScene->getSceneDefines();
        defines.add(mpSampleGenerator->getDefines());
        defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
        defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
        defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
        defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
        defines.add("ENABLE_NRD", mEnableNRD ? "1" : "0");
        defines.add("ENABLE_SHARC", mEnableSHARC ? "1" : "0");
        defines.add("ENABLE_PG", mEnablePG ? "1" : "0");
        if (mReGIREnabled)
        {
            defines.add("RTPT_REGIR_TRANSPORT", "1");
            if (!mRestirDIEnabled) defines.add("RTPT_REGIR_ONLY", "1");
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
        if ((mEnableSHARC || mEnablePG) && !mpSparseUpdate)
        {
            const auto updateDesc = makeSceneProgramDesc("RenderPasses/RTPT/RTPTSparseUpdate.cs.slang");
            auto updateDefines = defines;
            updateDefines.add("ENABLE_NRD", "0");
            updateDefines.add("SHARC_UPDATE", "1");
            updateDefines.add("SHARC_QUERY", "0");
            mpSparseUpdate = ComputePass::create(mpDevice, updateDesc, updateDefines, true);
        }
        if (mEnableSHARC && (!mpSHARCResolve || !mpSHARCInvalidate))
        {
            ProgramDesc resolveDesc;
            resolveDesc.addShaderLibrary("RenderPasses/RTPT/RTPTSharcResolve.cs.slang").csEntry("main");
            resolveDesc.setShaderModel(ShaderModel::SM6_6);
            resolveDesc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
            auto updateDefines = defines;
            updateDefines.add("SHARC_UPDATE", "0");
            updateDefines.add("SHARC_QUERY", "0");
            updateDefines.add("ENABLE_PG", "0");
            if (!mpSHARCResolve) mpSHARCResolve = ComputePass::create(mpDevice, resolveDesc, updateDefines, true);
            if (!mpSHARCInvalidate)
            {
                resolveDesc = ProgramDesc();
                resolveDesc.addShaderLibrary("RenderPasses/RTPT/RTPTSharcInvalidate.cs.slang").csEntry("main");
                resolveDesc.setShaderModel(ShaderModel::SM6_6);
                resolveDesc.setCompilerArguments({"-Xdxc", "-enable-16bit-types"});
                mpSHARCInvalidate = ComputePass::create(mpDevice, resolveDesc, updateDefines, true);
            }
        }
        if (mEnablePG)
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

void RTPT::bindNRDOutputs(const ShaderVar& rootVar, const RenderData& renderData) const
{
    for (const auto& output : kNRDOutputs)
        rootVar[output.shaderName] = renderData.getTexture(output.name);
}

void RTPT::bindSHARC(const ShaderVar& rootVar)
{
    auto sharc = rootVar["gSharc"];
    auto grid = sharc["hashGridParameters"];
    grid["cameraPosition"] = mpScene->getCamera()->getPosition();
    grid["logarithmBase"] = 2.f;
    grid["sceneScale"] = mSHARCSceneScale;
    grid["levelBias"] = 0.f;
    sharc["hashGridData"]["capacity"] = mSHARCEntries;
    sharc["hashGridData"]["hashEntriesBuffer"] = mpSHARCHashEntries;
    sharc["accumulationBuffer"] = mpSHARCAccumulation;
    sharc["resolvedBuffer"] = mpSHARCResolved;
    sharc["radianceScale"] = 1000.f;
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
    settings["motionResponsive"] = mSHARCMotionResponsiveFrames != 0u ? 1u : 0u;
}

void RTPT::updateSHARCMotionBounds()
{
    mSHARCMotionBoundsCPU.clear();
    if (!mEnableSHARC) return;
    const uint32_t count = mpScene->getGeometryInstanceCount();
    const bool previousValid = mSHARCPreviousInstanceBounds.size() == count;
    mSHARCPreviousInstanceBounds.resize(count);
    const auto* animation = mpScene->getAnimationController();
    const auto& matrices = animation->getGlobalMatrices();
    const bool deformed = is_set(mpScene->getUpdates(), IScene::UpdateFlags::MeshesChanged);
    for (uint32_t i = 0; i < count; ++i)
    {
        const auto& instance = mpScene->getGeometryInstance(i);
        if (instance.getType() != GeometryType::TriangleMesh) continue;
        const AABB current = mpScene->getMeshBounds(instance.geometryID).transform(matrices[instance.globalMatrixID]);
        const AABB previous = mSHARCPreviousInstanceBounds[i];
        if (previousValid && mSceneMotionThisFrame &&
            (animation->isMatrixChanged(NodeID{instance.globalMatrixID}) || (deformed && instance.isDynamic())))
        {
            AABB changed = current;
            if (previous.valid()) changed.include(previous);
            if (changed.valid())
            {
                mSHARCMotionBoundsCPU.emplace_back(changed.minPoint, 0.f);
                mSHARCMotionBoundsCPU.emplace_back(changed.maxPoint, 0.f);
            }
        }
        mSHARCPreviousInstanceBounds[i] = current;
    }
    // Bounds cover rigid geometry occupancy. Changes to remote illumination
    // are handled separately by observed per-entry radiance response.
    if (mSceneMotionThisFrame) mSHARCMotionResponsiveFrames = 8u;
}

Properties RTPT::getSHARCMotionStatistics() const
{
    Properties props;
    std::array<uint32_t, 4> counts = {};
    // Explicit diagnostic readback; ordinary rendering does not wait for it.
    if (mpSHARCMotionStats) mpSHARCMotionStats->getBlob(counts.data(), 0, sizeof(counts));
    props["occupiedEntries"] = counts[0];
    props["invalidatedEntries"] = counts[1];
    props["retainedEntries"] = counts[2];
    props["responsiveEntries"] = counts[3];
    props["boundsCount"] = uint32_t(mSHARCMotionBoundsCPU.size() / 2);
    return props;
}

void RTPT::clearSHARC(RenderContext* pRenderContext)
{
    if (mGRISHistoryFrame.historyValid && mGRISHistoryFrame.snapshot.sharcVersion != 0u) resetGRISHistory();
    pRenderContext->clearUAV(mpSHARCHashEntries->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpSHARCAccumulation->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpSHARCResolved->getUAV().get(), uint4(0));
    pRenderContext->uavBarrier(mpSHARCHashEntries.get());
    pRenderContext->uavBarrier(mpSHARCAccumulation.get());
    pRenderContext->uavBarrier(mpSHARCResolved.get());
    mSHARCCameraPositionPrev = mpScene->getCamera()->getPosition();
    // Cache lifetime is independent of the sparse sampling phase. In
    // particular, animated geometry must not restart the tile pixel cycle.
    mSHARCCacheResetThisFrame = true;
    ++mSHARCResolveVersion;
    mResetSHARCCache = false;
}

void RTPT::dispatchSparse(RenderContext* pRenderContext, uint32_t stride, uint32_t bounces, uint32_t frameIndex, bool sharc, bool pg)
{
    FALCOR_PROFILE(pRenderContext, "SparseTrace");
    auto var = mpSparseUpdate->getRootVar();
    mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    mpSampleGenerator->bindShaderData(var);
    if (mpEnvMapSampler && var.hasMember("gEnvMapSampler")) mpEnvMapSampler->bindShaderData(var["gEnvMapSampler"]);
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
    bindReGIRTransport(var);
    if (mEnablePG) mpPG->bind(var, mpScene->getCamera()->getPosition(), mSHARCSceneScale, frameIndex, pg);
    auto sparse = var["gSparseSettings"];
    sparse["frameDim"] = mFrameDim;
    sparse["updateStride"] = stride;
    sparse["frameIndex"] = frameIndex;
    sparse["updateBounces"] = bounces;
    sparse["writeSHARC"] = sharc ? 1u : 0u;
    sparse["recordPG"] = pg ? 1u : 0u;
    const uint2 updateDim = (mFrameDim + stride - 1u) / stride;
    mpSparseUpdate->execute(pRenderContext, uint3(updateDim, 1));
    if (mEnablePG) mpPG->barrierTraining(pRenderContext);
    if (mEnableSHARC)
    {
        pRenderContext->uavBarrier(mpSHARCHashEntries.get());
        pRenderContext->uavBarrier(mpSHARCAccumulation.get());
        pRenderContext->uavBarrier(mpSHARCResolved.get());
    }
}

void RTPT::executeTraining(RenderContext* pRenderContext)
{
    mPGTrainingThisFrame = mSharedTrainingThisFrame = false;
    if (mEnableSHARC)
    {
        if (!mpSHARCMotionStats) mpSHARCMotionStats = mpDevice->createStructuredBuffer(4u, 4u);
        pRenderContext->clearUAV(mpSHARCMotionStats->getUAV().get(), uint4(0));
        pRenderContext->uavBarrier(mpSHARCMotionStats.get());
        if (!mpSHARCHashEntries)
        {
            mpSHARCHashEntries = mpDevice->createStructuredBuffer(8u, mSHARCEntries);
            mpSHARCAccumulation = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mpSHARCResolved = mpDevice->createStructuredBuffer(16u, mSHARCEntries);
            mResetSHARCCache = true;
        }
        if (mResetSHARCCache) clearSHARC(pRenderContext);
        else if (!mSHARCMotionBoundsCPU.empty())
        {
            const size_t bytes = mSHARCMotionBoundsCPU.size() * sizeof(float4);
            if (!mpSHARCMotionBounds || mpSHARCMotionBounds->getSize() < bytes)
                mpSHARCMotionBounds = mpDevice->createStructuredBuffer(sizeof(float4), uint32_t(mSHARCMotionBoundsCPU.size()));
            mpSHARCMotionBounds->setBlob(mSHARCMotionBoundsCPU.data(), 0, bytes);
            auto var = mpSHARCInvalidate->getRootVar();
            bindSHARC(var);
            var["gSHARCMotionBounds"] = mpSHARCMotionBounds;
            var["gSHARCMotionStats"] = mpSHARCMotionStats;
            var["gSHARCMotionSettings"]["boundsCount"] = uint32_t(mSHARCMotionBoundsCPU.size() / 2);
            mpSHARCInvalidate->execute(pRenderContext, uint3(mSHARCEntries, 1, 1));
            pRenderContext->uavBarrier(mpSHARCHashEntries.get());
            pRenderContext->uavBarrier(mpSHARCAccumulation.get());
            pRenderContext->uavBarrier(mpSHARCResolved.get());
            pRenderContext->uavBarrier(mpSHARCMotionStats.get());
        }
    }
    const bool sharc = mEnableSHARC && mSHARCEnabled && !mSHARCFreeze;
    bool pg = mEnablePG && mPGSettings.enabled && mPGSettings.trainingEnabled;
    if (mEnablePG)
    {
        const bool rebuilt = mpPG->prepare(pRenderContext, mPGSettings, mFrameDim, mPGUpdateBounces, mPGUpdateStride);
        if (mResetPG || rebuilt)
        {
            mpPG->reset(pRenderContext);
            mPGFrameIndex = 0;
            mPGCameraPosition = mpScene->getCamera()->getPosition();
            mResetPG = false;
            mPGModelResetThisFrame = true;
            // Rebuilding a proposal does not reset the radiance estimate or
            // its sampling sequence. Scene/option resets are handled by execute().
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
    mSharedTrainingThisFrame = shared;
    if (shared) dispatchSparse(pRenderContext, mSHARCUpdateStride, mSHARCUpdateBounces, mSHARCFrameIndex, true, true);
    else
    {
        if (sharc) dispatchSparse(pRenderContext, mSHARCUpdateStride, mSHARCUpdateBounces, mSHARCFrameIndex, true, false);
        if (pg) dispatchSparse(pRenderContext, mpPG->getRecordStride(), mPGUpdateBounces, mPGFrameIndex, false, true);
    }
    if (pg)
    {
        const bool async = preparePGAsync();
        if (async)
        {
            recordPGAsyncTraining(pRenderContext);
        }
        else
        {
            beginPGAsyncTiming(pRenderContext, pRenderContext);
            writePGAsyncTimestamp(pRenderContext, 0);
            pRenderContext->getLowLevelData()->beginDebugEvent("PGTrainSerial");
            mpPG->bind(mpPGTrain->getRootVar(), mpScene->getCamera()->getPosition(), mSHARCSceneScale, mPGFrameIndex, true);
            mpPGTrain->execute(pRenderContext, uint3(mpPG->getPathCapacity(), 1, 1));
            mpPG->barrierTraining(pRenderContext);
            pRenderContext->getLowLevelData()->endDebugEvent();
            writePGAsyncTimestamp(pRenderContext, 1);
        }
        mPGTrainingThisFrame = true;
    }
    if (sharc)
    {
        FALCOR_PROFILE(pRenderContext, "SHARCResolve");
        bindSHARC(mpSHARCResolve->getRootVar());
        mpSHARCResolve->getRootVar()["gSHARCMotionStats"] = mpSHARCMotionStats;
        mpSHARCResolve->execute(pRenderContext, uint3(mSHARCEntries, 1, 1));
        ++mSHARCResolveVersion;
        pRenderContext->uavBarrier(mpSHARCHashEntries.get());
        pRenderContext->uavBarrier(mpSHARCAccumulation.get());
        pRenderContext->uavBarrier(mpSHARCResolved.get());
        pRenderContext->uavBarrier(mpSHARCMotionStats.get());
    }
}

void RTPT::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    collectPGAsyncTiming();
    mReGIRInitialActive = false;
    mNRDHistoryResetThisFrame = false;
    mPGTranslationPreservedNRDThisFrame = false;
    mPGModelResetThisFrame = false;
    mSHARCCacheResetThisFrame = false;
    mSceneMotionThisFrame = false;
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
        return;
    }

    const auto updates = mpScene->getUpdates();
    if (is_set(updates, IScene::UpdateFlags::RecompileNeeded) || is_set(updates, IScene::UpdateFlags::GeometryChanged))
    {
        mpComputePass = nullptr;
        mpSparseUpdate = nullptr;
    }
    if (is_set(updates, IScene::UpdateFlags::GeometryChanged) || is_set(updates, IScene::UpdateFlags::MaterialsChanged))
        validateScene();
    if (is_set(updates, IScene::UpdateFlags::EnvMapChanged)) mpEnvMapSampler = nullptr;

    // Ignore jitter/history-only camera updates: RTPT owns its pixel sampling.
    bool sceneChanged = (updates & ~IScene::UpdateFlags::CameraPropertiesChanged) != IScene::UpdateFlags::None;
    if (is_set(updates, IScene::UpdateFlags::CameraPropertiesChanged))
        sceneChanged |= (mpScene->getCamera()->getChanges() & ~(Camera::Changes::Jitter | Camera::Changes::History)) != Camera::Changes::None;
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
    mSceneMotionThisFrame = (updates & movingScene) != IScene::UpdateFlags::None;
    updateSHARCMotionBounds();
    if ((updates & (movingScene | IScene::UpdateFlags::LightCollectionChanged)) != IScene::UpdateFlags::None)
        resetGRISHistory();
    // Previous hit/material reconstruction and temporal visibility use the
    // current scene only while its physical state is unchanged. Camera motion
    // is handled by reprojection, independently of PG/NRD history resets.
    if ((updates & (discontinuities | movingScene)) != IScene::UpdateFlags::None)
        resetDIHistory("Scene geometry, materials or lighting changed");
    else if (is_set(mpScene->getCamera()->getChanges(), Camera::Changes::Frustum))
        resetDIHistory("Camera frustum changed");
    else if (mOptionsChanged)
        resetDIHistory("Render options or seed changed");
    if ((updates & sharcInvalidations) != IScene::UpdateFlags::None)
        mResetSHARCCache = true;
    // PG stores a proposal, not radiance. Keep its regions and progressively
    // train on the current scene during ordinary geometry/light motion.
    if ((updates & sharcInvalidations) != IScene::UpdateFlags::None)
        mResetPG = true;
    // First PG version has no LOD hysteresis or cross-LOD model retention.
    // Actual camera translation restarts PG; projection jitter changes no position.
    const bool pgCameraTranslated = mEnablePG && any(mpScene->getCamera()->getPosition() != mPGCameraPosition);
    if (pgCameraTranslated) mResetPG = true;
    if (nrdDiscontinuity || mOptionsChanged || refreshFlags != RenderPassRefreshFlags::None) reset();
    else if (!mEnableNRD && sceneChanged)
        // Progressive image accumulation cannot mix scene poses, but its
        // invalidation does not require restarting random samples.
        resetAccumulation();
    if (mOptionsChanged) mGRISTemporalFallbackReason.clear();
    mOptionsChanged = false;

    const uint2 frameDim(color->getWidth(), color->getHeight());
    if (any(frameDim != mFrameDim) || !mpAccumulation)
    {
        // Release old per-pixel records before allocating the new resolution.
        invalidateStages();
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
    bool stagesActive = false;
    bool diActive = false;
    auto prepareLightCatalog = [&]()
    {
        return mLightCatalog.prepare(*mpScene, *mpDevice, uint64_t(mRestirDIBudgetMB) << 20u);
    };
    if (mReGIREnabled)
    {
        // Publish one frame-local world-space light model before independent
        // training. Primary records and pixel reservoirs are not inputs here.
        mReGIRActive = false;
        stagesActive = prepareStages();
        FALCOR_CHECK(stagesActive && mEnableNRD && mSamplesPerPixel == 1u && (!mRestirDIEnabled || mUseNEE),
            "Cell-only ReGIR requires prepared Primary Surface and supported one-sample NRD/NEE inputs; global fallback is disabled.");
        const bool catalogReady = prepareLightCatalog();
        FALCOR_CHECK(catalogReady, "ReGIR cell-only light catalogue preparation failed; global sampling is disabled: {}", mLightCatalog.getFailure());
        if (mRestirDIEnabled)
        {
            diActive = prepareDirectLighting(catalogReady);
            FALCOR_CHECK(diActive, "ReGIR with ReSTIR DI requires prepared DI resources; global fallback is disabled: {}", mDIFallbackReason);
        }
        prepareReGIR(pRenderContext);
    }
    if (mEnableSHARC || mEnablePG)
    {
        // Complete SHaRC resolve before GRIS and MainRender query the current frame's cache.
        executeTraining(pRenderContext);
    }
    if (mSampleOffset > std::numeric_limits<uint32_t>::max() - mSamplesPerPixel ||
        mAccumulatedSamples > std::numeric_limits<uint32_t>::max() - mSamplesPerPixel)
        reset();

    mNRDHistoryResetThisFrame = (mEnableNRD || mEnablePG || mEnableSHARC) && mResetNRDHistory;
    mPGTranslationPreservedNRDThisFrame = mEnableNRD && pgCameraTranslated && mPGModelResetThisFrame && !mNRDHistoryResetThisFrame;
    if (mNRDHistoryResetThisFrame)
        dict[kRenderPassRefreshFlags] = refreshFlags | RenderPassRefreshFlags::RenderOptionsChanged;
    mResetNRDHistory = false;

    if (!mReGIREnabled) stagesActive = prepareStages();
    if (stagesActive) executePrimarySurface(pRenderContext);
    if (!mReGIREnabled)
    {
        const bool catalogReady = mRestirDIEnabled && stagesActive && mEnableNRD && mSamplesPerPixel == 1u && mUseNEE && prepareLightCatalog();
        diActive = prepareDirectLighting(catalogReady);
    }
    if (diActive) executeDirectLighting(pRenderContext);
    const auto& baseMainPass = diActive ? mpDIComputePass : (stagesActive ? mpStageComputePass : mpComputePass);
    const bool grisActive = prepareGRIS(baseMainPass, diActive);
    if (grisActive) executeGRIS(pRenderContext, renderData, diActive);
    const auto& mainPass = grisActive ? mpGRISMainPass : baseMainPass;
    auto var = mainPass->getRootVar();
    mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    mpSampleGenerator->bindShaderData(var);
    if (mpEnvMapSampler && var.hasMember("gEnvMapSampler")) mpEnvMapSampler->bindShaderData(var["gEnvMapSampler"]);
    bindMainParams(var);
    // In NRD mode the separate resolve owns all radiance/guide outputs. The
    // legacy pass still writes them directly when stage preparation fails.
    if (!stagesActive || !mEnableNRD)
    {
        var["gColor"] = color;
        var["gNoisyColor"] = noisyColor;
        var["gAccumulation"] = mpAccumulation;
    }
    if (mEnableNRD && !stagesActive) bindNRDOutputs(var, renderData);
    if (stagesActive)
    {
        bindPrimarySettings(var);
        var["gPrimarySurfaces"] = mpPrimarySurfaces;
        if (mEnableNRD) var["gSignalRecords"] = mpSignalRecords;
    }
    if (diActive) bindDIMainResources(var);
    bindReGIRTransport(var);
    if (mEnableSHARC)
    {
        bindSHARC(var);
        var["gSharcDebug"] = renderData.getTexture("sharcDebug");
        var["gSharcCacheRadiance"] = renderData.getTexture("sharcCacheRadiance");
        var["gSharcStats"] = renderData.getTexture("sharcStats");
    }
    if (mEnablePG)
        mpPG->bind(var, mpScene->getCamera()->getPosition(), mSHARCSceneScale, mPGFrameIndex, false, false, true);
    pRenderContext->uavBarrier(mpAccumulation.get());
    if (mPGAsyncRecorded)
    {
        // PGTrain is short. Start it after SHaRC/DI preparation, alongside Main,
        // rather than letting it finish entirely during those earlier passes.
        pRenderContext->submit(false);
        mPGInputsReadyValue = pRenderContext->signal(mpPGInputsReady.get());
    }
    {
        FALCOR_PROFILE(pRenderContext, "MainRender");
        writePGAsyncTimestamp(pRenderContext, 2);
        mainPass->execute(pRenderContext, uint3(frameDim, 1));
        writePGAsyncTimestamp(pRenderContext, 3);
    }
    if (stagesActive && mEnableNRD) executeFinalSignalResolve(pRenderContext, renderData);
    finishPGAsync(pRenderContext);
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
    if (mSHARCMotionResponsiveFrames) --mSHARCMotionResponsiveFrames;
}

void RTPT::renderUI(Gui::Widgets& widget)
{
    Properties baseProps;
    if (mEnableNRD)
        widget.text("NRD: 1 primary sample, one path per active diffuse/specular lobe.");
    else
    {
        uint32_t samplesPerPixel = mSamplesPerPixel;
        if (widget.var("Samples per pixel", samplesPerPixel, 1u, 1024u)) baseProps["samplesPerPixel"] = samplesPerPixel;
    }
    uint32_t maxBounces = mMaxBounces;
    if (widget.var("Max BSDF bounces", maxBounces, 1u, 64u)) baseProps["maxBounces"] = maxBounces;
    widget.tooltip("Number of BSDF scatter events. The final ray only collects emission or environment light.", true);
    bool useNEE = mUseNEE;
    if (widget.checkbox("Next-event estimation", useNEE)) baseProps["useNEE"] = useNEE;
    widget.tooltip("Sample analytic, mesh and environment lights. Analytic lights require NEE because rays cannot hit them.", true);
    bool useRussianRoulette = mUseRussianRoulette;
    if (widget.checkbox("Russian roulette", useRussianRoulette)) baseProps["useRussianRoulette"] = useRussianRoulette;
    uint32_t rrStartBounce = mRRStartBounce;
    if (widget.var("RR start bounce", rrStartBounce, 1u, 64u)) baseProps["rrStartBounce"] = rrStartBounce;
    uint32_t seed = mSeed;
    if (widget.var("Seed", seed)) baseProps["seed"] = seed;
    if (!mEnableNRD && !mEnableSHARC && !mEnablePG)
    {
        bool accumulate = mAccumulate;
        if (widget.checkbox("Progressive accumulation", accumulate)) baseProps["accumulate"] = accumulate;
        if (accumulate)
        {
            uint32_t maxAccumulationFrames = mMaxAccumulationFrames;
            if (widget.var("Max frames", maxAccumulationFrames, 0u)) baseProps["maxAccumulationFrames"] = maxAccumulationFrames;
            widget.tooltip("Maximum frames to accumulate. 0 means unlimited. At the limit, tracing stops and both outputs are held. Changing this limit restarts accumulation.", true);
            const std::string target = maxAccumulationFrames != 0 ? " / " + std::to_string(maxAccumulationFrames) : " (unlimited)";
            widget.text("Accumulated frames: " + std::to_string(mAccumulatedFrames) + target);
            if (maxAccumulationFrames != 0 && mAccumulatedFrames >= maxAccumulationFrames && baseProps.empty() && !mOptionsChanged)
                widget.text("Accumulation complete.");
        }
    }
    if (!baseProps.empty()) setProperties(baseProps);
    if (widget.button(mEnableNRD ? "Reset NRD history" : "Reset accumulation")) mOptionsChanged = true;
    if (!mEnableNRD)
        widget.text("Accumulated samples: " + std::to_string(mAccumulatedSamples));
    if (auto regirWidget = widget.group("ReGIR"))
    {
        Properties props;
        bool enabled = mReGIREnabled, secondary = mReGIRSecondaryEnabled, training = mReGIRTrainingEnabled, culling = mReGIRCullingEnabled;
        if (regirWidget.checkbox("Enabled", enabled)) props["regirEnabled"] = enabled;
        if (regirWidget.checkbox("Secondary lighting", secondary)) props["regirSecondaryEnabled"] = secondary;
        if (regirWidget.checkbox("Independent training", training)) props["regirTrainingEnabled"] = training;
        if (regirWidget.checkbox("Light culling", culling)) props["regirLightCullingEnabled"] = culling;
        uint32_t size = mReGIRGridSize, slots = mReGIRLightsPerCell, build = mReGIRBuildSamples, budget = mReGIRBudgetMB;
        if (regirWidget.var("Hash capacity cube root", size, 1u, 128u)) props["regirGridSize"] = size;
        if (regirWidget.var("Lights per cell", slots, 1u, 1024u)) props["regirLightsPerCell"] = slots;
        if (regirWidget.var("Build candidates per slot", build, 1u, 128u)) props["regirBuildSamples"] = build;
        float cellSize = mReGIRCellSize, distance = mReGIRCoarsenCellDistance, threshold = mReGIRBrightnessThreshold;
        if (regirWidget.var("Near cell edge", cellSize, 1e-6f, 1e6f)) props["regirCellSize"] = cellSize;
        if (regirWidget.var("Coarsen distance (cell edges)", distance, 1.f, 1024.f)) props["regirCoarsenCellDistance"] = distance;
        if (regirWidget.var("Weak-light threshold", threshold, 0.f, 1e12f, 0.00001f)) props["regirBrightnessThreshold"] = threshold;
        regirWidget.tooltip("Linear incident-light proxy cutoff. Zero disables weak-light distance culling. Tests cover the complete cell and query jitter.", true);
        if (regirWidget.var("LOD hash budget (MiB)", budget, 1u, 1024u)) props["regirBudgetMB"] = budget;
        if (!props.empty()) setProperties(props);
        regirWidget.text(mReGIRActive ? "Active: cell-only LOD candidates" : "Inactive");
        regirWidget.text("Candidate IDs persist until light membership changes.");
        if (!mReGIRFallbackReason.empty()) regirWidget.text(mReGIRFallbackReason.substr(0, mReGIRFallbackReason.find('\n')));
    }
    if (auto diWidget = widget.group("ReSTIR DI"))
    {
        Properties props;
        bool enabled = mRestirDIEnabled;
        if (diWidget.checkbox("Enabled", enabled)) props["restirDIEnabled"] = enabled;
        uint32_t count = mRestirDICandidateCount;
        if (diWidget.var("Initial candidates", count, 1u, 128u)) props["restirDICandidateCount"] = count;
        uint32_t budget = mRestirDIBudgetMB;
        if (diWidget.var("Resource budget (MiB)", budget, 16u, 2048u)) props["restirDIBudgetMB"] = budget;
        bool temporal = mRestirDITemporalEnabled, spatial = mRestirDISpatialEnabled;
        if (diWidget.checkbox("Temporal reuse", temporal)) props["restirDITemporalEnabled"] = temporal;
        if (diWidget.checkbox("Spatial reuse", spatial)) props["restirDISpatialEnabled"] = spatial;
        uint32_t history = mRestirDIHistoryLength, neighbors = mRestirDISpatialSamples;
        float radius = mRestirDISpatialRadius;
        if (diWidget.var("History length", history, 1u, 32u)) props["restirDIHistoryLength"] = history;
        if (diWidget.var("Spatial samples", neighbors, 1u, 32u)) props["restirDISpatialSamples"] = neighbors;
        if (diWidget.var("Spatial radius", radius, 1.f, 64.f)) props["restirDISpatialRadius"] = radius;
        if (!props.empty()) setProperties(props);
        diWidget.text(mDIActive ? (mReGIRInitialActive ? "Active: ReGIR Initial RIS" : "Active: global Initial RIS") : "Inactive");
        if (!mReGIRInitialFallbackReason.empty()) diWidget.text(mReGIRInitialFallbackReason.substr(0, mReGIRInitialFallbackReason.find('\n')));
        if (mDITemporalActive) diWidget.text(mDIHistoryReadValid ? "Temporal: history available" : "Temporal: current frame only");
        if (mDISpatialActive) diWidget.text("Spatial: active");
        if (mRestirDIEnabled && !mDIFallbackReason.empty())
            diWidget.text(mDIFallbackReason.substr(0, mDIFallbackReason.find('\n')));
        if (mRestirDIEnabled && !mDIReuseFallbackReason.empty())
            diWidget.text(mDIReuseFallbackReason.substr(0, mDIReuseFallbackReason.find('\n')));
        diWidget.text("Supported lights: " + std::to_string(mLightCatalog.getSnapshot().lightCount));
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
            if (canUseGRISAlternating())
            {
                float blend = mGRISSharcX1Blend;
                if (sharcWidget.var("GRIS x1 cache blend", blend, 0.f, std::nextafter(1.f, 0.f)))
                    props["grisSharcX1Blend"] = blend;
                sharcWidget.tooltip("Blend x1 cache radiance into eligible D/S paths while the scheduled path continues to x2.", true);
            }
            float roughness = mSHARCMinRoughness;
            if (sharcWidget.var("Minimum query roughness", roughness, 0.f, 1.f)) props["sharcMinRoughness"] = roughness;
            uint32_t frames = mSHARCAccumulationFrames;
            if (sharcWidget.var("Accumulation frames", frames, 1u, 1024u)) props["sharcAccumulationFrames"] = frames;
            frames = mSHARCStaleFrames;
            if (sharcWidget.var("Stale entry lifetime", frames, 8u, 1024u)) props["sharcStaleFrames"] = frames;
            uint32_t debugMode = mSHARCDebugMode;
            if (sharcWidget.dropdown("Visualization", kSHARCDebugModes, debugMode)) props["sharcDebugMode"] = debugMode;
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
            Properties props;
            bool value = mPGSettings.enabled;
            if (pgWidget.checkbox("Enabled", value)) props["pgEnabled"] = value;
            pgWidget.tooltip("Enable guiding and training independently of SHaRC. Switching resets NRD and final accumulation.", true);
            value = mPGSettings.useGuiding;
            if (pgWidget.checkbox("Use guiding", value)) props["pgUseGuiding"] = value;
            if (mGRISEnabled)
            {
                uint32_t depth = mGRISPGPrefixDepth;
                if (pgWidget.dropdown("GRIS guided prefix", kGRISPGPrefixDepths, depth)) props["grisPGPrefixDepth"] = depth;
                pgWidget.tooltip("Guide only the primary diffuse edge x0 to x1. x1 and deeper directions use BSDF sampling. Switching discards only GRIS history.", true);
            }
            value = !mPGSettings.trainingEnabled;
            if (pgWidget.checkbox("Freeze training", value)) props["pgFreeze"] = value;
            value = mPGAsyncTraining;
            if (pgWidget.checkbox("Independent PGTrain queue", value)) props["pgAsyncTraining"] = value;
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
            pgWidget.text("Fixed hemisphere regions: 4");
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
