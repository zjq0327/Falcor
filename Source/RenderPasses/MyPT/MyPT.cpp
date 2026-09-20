/***************************************************************************
 # Copyright (c) 2015-24, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "MyPT.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "Rendering/Lights/EmissivePowerSampler.h"

// Register this class with the plugin system. This is what makes the pass
// loadable from Python via `loadRenderPassLibrary("MyPT.dll")` followed by
// `createPass("MyPT", {...})`.
extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, MyPT>();
    ScriptBindings::registerBinding([](pybind11::module& m)
    {
        pybind11::class_<MyPT, RenderPass, ref<MyPT>> pass(m, "MyPT");
        pass.def_property_readonly("resourceStats", [](const MyPT& p) { return p.getResourceStats().toPython(); });
        pass.def("resetSampling", &MyPT::resetSampling, pybind11::arg("seed"));
        pass.def("resetNrcCache", &MyPT::resetNrcCache);
        pass.def("resetPGCache", &MyPT::resetPGCache);
        pass.def("reloadShaders", &MyPT::reloadShaders);
    });
}

namespace
{
const char kShaderFile[] = "RenderPasses/MyPT/MyPT.rt.slang";

// Ray tracing settings that affect the traversal stack size.
// These should be set as small as possible.
// The ScatterRayData payload packs: 5x float3 (radiance/thp/origin/direction/normal) + bool + uint + float + SampleGenerator (16B).
// With HLSL 16B alignment padding this stays under 112B; 128B leaves headroom for future fields.
const uint32_t kMaxPayloadSizeBytes = 128u;
const uint32_t kMaxRecursionDepth = 2u;

const char kInputViewDir[] = "viewW";

const ChannelList kInputChannels = {
    // clang-format off
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
    { kInputViewDir,    "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
    { "mvec",           "gMotionVector","Motion vector (screen space)", true /* optional */, ResourceFormat::RG32Float },
    // clang-format on
};

const ChannelList kOutputChannels = {
    // clang-format off
    { "color",          "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

const char kMode[] = "mode";
const char kShiftStrategy[] = "shiftStrategy";
const char kSpecularRoughnessThreshold[] = "specularRoughnessThreshold";
const char kNearFieldDistance[] = "nearFieldDistance";
const char kRISCandidateCount[] = "risCandidateCount";
const char kGIRISCandidateCount[] = "giRISCandidateCount";
const char kUseInitialVisibility[] = "useInitialVisibility";
const char kMaxBounces[] = "maxBounces";
const char kComputeDirect[] = "computeDirect";
const char kUseImportanceSampling[] = "useImportanceSampling";
const char kUseMIS[] = "useMIS";
const char kRRProbability[] = "rrProbability";
const char kMaxHistoryLength[] = "maxHistoryLength";
const char kTemporalDepthThreshold[] = "temporalDepthThreshold";
const char kTemporalNormalThreshold[] = "temporalNormalThreshold";
const char kSpatialNeighborCount[] = "spatialNeighborCount";
const char kSpatialRadius[] = "spatialRadius";
const char kSpatialDepthThreshold[] = "spatialDepthThreshold";
const char kSpatialNormalThreshold[] = "spatialNormalThreshold";
} // namespace

MyPT::MyPT(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void MyPT::parseProperties(const Properties& props)
{
    // Resolve the target mode before its cache toggle, independent of key order.
    mMode = props.get(kMode, mMode);
    for (const auto& [key, value] : props)
    {
        if (key == kMode)
            mMode = value;
        else if (key == "pgUseGuiding") mPGUseGuiding = value;
        else if (key == "pgTrain") mPGTrain = value;
        else if (key == "pgGuideFraction") mPGGuideFraction = value;
        else if (key == "pgTrainingFraction") mPGTrainingFraction = value;
        else if (key == "pgTrainingIterations") mPGTrainingIterations = value;
        else if (key == "pgInitialEpochSpp") mPGInitialEpochSpp = value;
        else if (key == "pgTreeBudgetMB") mPGTreeBudgetMB = value;
        else if (key == "pgRecordBudgetMB") mPGRecordBudgetMB = value;
        else if (key == "pgSpatialThreshold") mPGSpatialThreshold = value;
        else if (key == "pgDirectionalThreshold") mPGDirectionalThreshold = value;
        else if (key == "pgMaxSpatialDepth") mPGMaxSpatialDepth = value;
        else if (key == "pgMaxDirectionalDepth") mPGMaxDirectionalDepth = value;
        else if (key == "nrcUseCache") nrcUseCache() = value;
        else if (key == "nrcTrainCache") mNrcTrainCache = value;
        else if (key == "nrcQueryDepth") mNrcQueryDepth = value;
        else if (key == "nrcRecordWhileFrozen") mNrcRecordWhileFrozen = value;
        else if (key == "nrcTrainingSource" || key == "nrcTrainingMaxBounces" || key == "nrcUnbiasedTrainingRatio")
            FALCOR_THROW("NRC option '{}' was removed. NRC now trains only from QueryPT; remove this option and use nrcQueryTrainingMaxVertices for record capacity.", key);
        else if (key == "nrcQueryTrainingMaxVertices") mNrcQueryTrainingMaxVertices = value;
        else if (key == "nrcTrainingIterations") mNrcTrainingIterations = value;
        else if (key == "nrcTerminationThreshold") mNrcTerminationThreshold = value;
        else if (key == "nrcFeatureSize") mNrcFeatureSize = value;
        else if (key == kShiftStrategy)
            mShiftStrategy = value;
        else if (key == kSpecularRoughnessThreshold)
            mSpecularRoughnessThreshold = value;
        else if (key == kNearFieldDistance)
            mNearFieldDistance = value;
        else if (key == "seed")
            mSeed = value;
        else if (key == "referenceLambertian")
            mReferenceLambertian = value;
        else if (key == kRISCandidateCount)
            mRISCandidateCount = value;
        else if (key == kGIRISCandidateCount)
            mGIRISCandidateCount = value;
        else if (key == kUseInitialVisibility)
            mUseInitialVisibility = value;
        else if (key == kMaxBounces)
            mMaxBounces = value;
        else if (key == kComputeDirect)
            mComputeDirect = value;
        else if (key == kUseImportanceSampling)
            mUseImportanceSampling = value;
        else if (key == kUseMIS)
            mUseMIS = value;
        else if (key == kRRProbability)
            mRRProbability = value;
        else if (key == kMaxHistoryLength)
            mMaxHistoryLength = value;
        else if (key == "temporalReuse")
            mTemporalReuse = value;
        else if (key == "temporalReprojection")
            mTemporalReprojection = value;
        else if (key == kTemporalDepthThreshold)
            mTemporalDepthThreshold = value;
        else if (key == kTemporalNormalThreshold)
            mTemporalNormalThreshold = value;
        else if (key == kSpatialNeighborCount)
            mSpatialNeighborCount = value;
        else if (key == "spatialReuse")
            mSpatialReuse = value;
        else if (key == "spatialReuseRounds")
            mSpatialReuseRounds = value;
        else if (key == "spatialNeighborOffset")
            mSpatialNeighborOffset = value;
        else if (key == kSpatialRadius)
            mSpatialRadius = value;
        else if (key == kSpatialDepthThreshold)
            mSpatialDepthThreshold = value;
        else if (key == kSpatialNormalThreshold)
            mSpatialNormalThreshold = value;
        else
            logWarning("Unknown property '{}' in MyPT properties.", key);
    }
    FALCOR_CHECK(mGIRISCandidateCount <= 64, "giRISCandidateCount must be in [0, 64].");
    FALCOR_CHECK(std::isfinite(mPGGuideFraction) && mPGGuideFraction >= 0.f && mPGGuideFraction < 1.f,
        "pgGuideFraction must be in [0, 1) to retain BSDF support.");
    FALCOR_CHECK(std::isfinite(mPGTrainingFraction) && mPGTrainingFraction > 0.f && mPGTrainingFraction <= 1.f,
        "pgTrainingFraction must be in (0, 1].");
    FALCOR_CHECK(mPGTrainingIterations >= 1 && mPGTrainingIterations <= 24 && mPGInitialEpochSpp >= 1 && mPGInitialEpochSpp <= 1024,
        "PG training iterations must be in [1,24], initial epoch spp in [1,1024].");
    FALCOR_CHECK(mPGTreeBudgetMB >= 1 && mPGTreeBudgetMB <= 4096 && mPGRecordBudgetMB >= 1 && mPGRecordBudgetMB <= 4096,
        "PG memory budgets must be in [1,4096] MiB.");
    FALCOR_CHECK(mPGSpatialThreshold >= 1 && std::isfinite(mPGDirectionalThreshold) && mPGDirectionalThreshold > 0.f &&
        mPGDirectionalThreshold <= 1.f && mPGMaxSpatialDepth >= 1 && mPGMaxSpatialDepth <= 24 && mPGMaxDirectionalDepth >= 1 && mPGMaxDirectionalDepth <= 16,
        "Invalid PG subdivision threshold or maximum depth.");
    FALCOR_CHECK(mNrcQueryDepth >= 2 && mNrcQueryDepth < 65536, "nrcQueryDepth must be in [2, 65535].");
    FALCOR_CHECK(mMode != Mode::ReSTIR || !nrcUseCache() || mMaxBounces == 0 || mGIRISCandidateCount == 0 ||
        mShiftStrategy == ShiftStrategy::Reconnection, "ReSTIR with NRC enabled currently supports Reconnection only.");
    FALCOR_CHECK(mNrcQueryTrainingMaxVertices >= 2 && mNrcQueryTrainingMaxVertices <= 65,
        "nrcQueryTrainingMaxVertices must be in [2, 65].");
    FALCOR_CHECK(mNrcTrainingIterations >= 1 && mNrcTrainingIterations <= 16, "nrcTrainingIterations must be in [1, 16].");
    FALCOR_CHECK(std::isfinite(mNrcTerminationThreshold) && mNrcTerminationThreshold > 0.f && mNrcTerminationThreshold <= 10.f,
        "nrcTerminationThreshold must be in (0, 10].");
    FALCOR_CHECK(std::isfinite(mNrcFeatureSize) && mNrcFeatureSize > 0.f, "nrcFeatureSize must be positive and finite.");
    FALCOR_CHECK(mSpecularRoughnessThreshold >= 0.f && mSpecularRoughnessThreshold <= 1.f,
        "specularRoughnessThreshold must be in [0, 1].");
    FALCOR_CHECK(mNearFieldDistance >= 0.f && mNearFieldDistance <= 100.f, "nearFieldDistance must be in [0, 100].");
    FALCOR_CHECK(mMaxBounces < 65536, "maxBounces must be less than 65536.");
    FALCOR_CHECK(mRRProbability >= 0.f && mRRProbability <= 0.95f, "rrProbability must be in [0, 0.95].");
    FALCOR_CHECK(mMaxHistoryLength <= 128, "maxHistoryLength must be in [0, 128].");
    FALCOR_CHECK(mTemporalDepthThreshold >= 0.f && mTemporalDepthThreshold <= 1.f, "temporalDepthThreshold must be in [0, 1].");
    FALCOR_CHECK(mTemporalNormalThreshold >= -1.f && mTemporalNormalThreshold <= 1.f, "temporalNormalThreshold must be in [-1, 1].");
    FALCOR_CHECK(mSpatialNeighborCount <= 16 && mSpatialReuseRounds <= 8, "Spatial neighbors must be in [0, 16], rounds in [0, 8].");
    FALCOR_CHECK(mSpatialRadius >= 0.f && mSpatialRadius <= 128.f, "spatialRadius must be in [0, 128].");
    FALCOR_CHECK(mSpatialDepthThreshold >= 0.f && mSpatialDepthThreshold <= 1.f, "spatialDepthThreshold must be in [0, 1].");
    FALCOR_CHECK(mSpatialNormalThreshold >= -1.f && mSpatialNormalThreshold <= 1.f, "spatialNormalThreshold must be in [-1, 1].");
    FALCOR_CHECK(all(mSpatialNeighborOffset >= int2(-65536)) && all(mSpatialNeighborOffset <= int2(65536)),
        "spatialNeighborOffset components must be in [-65536, 65536].");
}

Properties MyPT::getProperties() const
{
    Properties props;
    props[kMode] = mMode;
    props["pgUseGuiding"] = mPGUseGuiding;
    props["pgTrain"] = mPGTrain;
    props["pgGuideFraction"] = mPGGuideFraction;
    props["pgTrainingFraction"] = mPGTrainingFraction;
    props["pgTrainingIterations"] = mPGTrainingIterations;
    props["pgInitialEpochSpp"] = mPGInitialEpochSpp;
    props["pgTreeBudgetMB"] = mPGTreeBudgetMB;
    props["pgRecordBudgetMB"] = mPGRecordBudgetMB;
    props["pgSpatialThreshold"] = mPGSpatialThreshold;
    props["pgDirectionalThreshold"] = mPGDirectionalThreshold;
    props["pgMaxSpatialDepth"] = mPGMaxSpatialDepth;
    props["pgMaxDirectionalDepth"] = mPGMaxDirectionalDepth;
    props["nrcUseCache"] = nrcUseCache();
    props["nrcTrainCache"] = mNrcTrainCache;
    props["nrcQueryDepth"] = mNrcQueryDepth;
    props["nrcRecordWhileFrozen"] = mNrcRecordWhileFrozen;
    props["nrcQueryTrainingMaxVertices"] = mNrcQueryTrainingMaxVertices;
    props["nrcTrainingIterations"] = mNrcTrainingIterations;
    props["nrcTerminationThreshold"] = mNrcTerminationThreshold;
    props["nrcFeatureSize"] = mNrcFeatureSize;
    props[kShiftStrategy] = mShiftStrategy;
    props[kSpecularRoughnessThreshold] = mSpecularRoughnessThreshold;
    props[kNearFieldDistance] = mNearFieldDistance;
    props["seed"] = mSeed;
    props["referenceLambertian"] = mReferenceLambertian;
    props[kRISCandidateCount] = mRISCandidateCount;
    props[kGIRISCandidateCount] = mGIRISCandidateCount;
    props[kUseInitialVisibility] = mUseInitialVisibility;
    props[kMaxBounces] = mMaxBounces;
    props[kComputeDirect] = mComputeDirect;
    props[kUseImportanceSampling] = mUseImportanceSampling;
    props[kUseMIS] = mUseMIS;
    props[kRRProbability] = mRRProbability;
    props[kMaxHistoryLength] = mMaxHistoryLength;
    props["temporalReuse"] = mTemporalReuse;
    props["temporalReprojection"] = mTemporalReprojection;
    props[kTemporalDepthThreshold] = mTemporalDepthThreshold;
    props[kTemporalNormalThreshold] = mTemporalNormalThreshold;
    props[kSpatialNeighborCount] = mSpatialNeighborCount;
    props["spatialReuse"] = mSpatialReuse;
    props["spatialReuseRounds"] = mSpatialReuseRounds;
    props["spatialNeighborOffset"] = mSpatialNeighborOffset;
    props[kSpatialRadius] = mSpatialRadius;
    props[kSpatialDepthThreshold] = mSpatialDepthThreshold;
    props[kSpatialNormalThreshold] = mSpatialNormalThreshold;
    return props;
}

void MyPT::setProperties(const Properties& props)
{
    const bool optionsWereChanged = mOptionsChanged;
    const auto previous = getProperties();
    const bool previousNrcUseCache = mNrcUseCache;
    const bool previousRestirUseNrc = mRestirUseNrc;
    try { parseProperties(props); }
    catch (...)
    {
        mNrcUseCache = previousNrcUseCache;
        mRestirUseNrc = previousRestirUseNrc;
        parseProperties(previous);
        throw;
    }
    bool trainingOnly = mMode == Mode::ReSTIR;
    for (const auto& [key, value] : props)
        if (key != "nrcTrainCache" && key != "nrcRecordWhileFrozen") trainingOnly = false;
    mOptionsChanged |= !trainingOnly;
    if (mMode == Mode::PG)
    {
        bool pgTrainingOnly = true;
        for (const auto& [key, value] : props)
        {
            if (key != "pgTrain" && key != "pgTrainingIterations") pgTrainingOnly = false;
            // These change the transport target or the layout/refinement contract.
            if (key == kMaxBounces || key == kComputeDirect || key == kUseImportanceSampling || key == kRRProbability ||
                key == "referenceLambertian" || key == "pgInitialEpochSpp" || key == "pgTreeBudgetMB" ||
                key == "pgSpatialThreshold" || key == "pgDirectionalThreshold" || key == "pgMaxSpatialDepth" ||
                key == "pgMaxDirectionalDepth") mPGResetRequested = true;
        }
        // Freeze/resume does not change the estimated image or discard its accumulation.
        if (pgTrainingOnly) mOptionsChanged = optionsWereChanged;
    }
    // Freezing training preserves the learned state; only retry failed initialization.
    if (mNRC.failed) mNrcResetRequested = true;
}

RenderPassReflection MyPT::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    reflector.addOutput("ptReference", "Mean of the GRIS path trees before RIS").format(ResourceFormat::RGBA32Float)
        .flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("reservoirF", "Selected PSS contribution F; alpha is terminal type").format(ResourceFormat::RGBA32Float)
        .flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("reservoirDebug", "GRIS reservoir: W, M, surface-scatter count, rejected non-finite contributions")
        .format(ResourceFormat::RGBA32Float).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("initialColor", "Initial RIS before spatial reuse").format(ResourceFormat::RGBA32Float)
        .flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("spatialDebug", "Last-round eligible/successful neighbors; max identity/round-trip error over all rounds")
        .format(ResourceFormat::RGBA32Float).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("temporalColor", "RIS after temporal reuse and before spatial reuse")
        .format(ResourceFormat::RGBA32Float).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("temporalDebug", "Temporal status, clamped history M, accepted incoming sample, round-trip error")
        .format(ResourceFormat::RGBA32Float).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("shiftDebug", "Replay and shift consistency diagnostics")
        .format(ResourceFormat::RGBA32Float).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("pathDebug", "Initial rc index (0 if none), surface scatters, prefix flags, rc event flags")
        .format(ResourceFormat::RGBA32Float).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("rayStats0", "Actual rays: generation closest/shadow, temporal prefix closest/shadow")
        .format(ResourceFormat::RGBA32Uint).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("rayStats1", "Actual rays: temporal connection, spatial prefix closest/shadow, spatial connection")
        .format(ResourceFormat::RGBA32Uint).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("rayStats2", "Actual rays: validation closest/shadow, ordinary PT closest/shadow")
        .format(ResourceFormat::RGBA32Uint).flags(RenderPassReflection::Field::Flags::Optional);
    for (const char* name : {"temporalShiftStats", "spatialShiftStats"})
        reflector.addOutput(name, "Eligible pairs, nonzero source direction attempts, failed directions, positive directions")
            .format(ResourceFormat::RGBA32Uint).flags(RenderPassReflection::Field::Flags::Optional);

    for (const char* name : {"nrcExplicit", "nrcCached", "nrcSdkReference"})
        reflector.addOutput(name, "NRC explicit or cached linear radiance")
            .format(ResourceFormat::RGBA32Float).flags(RenderPassReflection::Field::Flags::Optional);
    for (const char* name : {"nrcQueryDebug", "nrcTrainingDebug"})
        reflector.addOutput(name, "NRC actual scatter rays, shadow rays, visited vertices, cache queries/training records")
            .format(ResourceFormat::RGBA32Uint).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("nrcQueryTrainingDebug", "NRC QueryOnly: termination reason, recorded vertices, accepted vertices, bootstrap queries")
        .format(ResourceFormat::RGBA32Uint).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("initialEstimate", "Mean of completed candidate trees, including cached tails")
        .format(ResourceFormat::RGBA32Float).flags(RenderPassReflection::Field::Flags::Optional);
    reflector.addOutput("nrcCandidateDebug", "GRIS NRC: render queries, negative predictions, invalid predictions, owner candidate plus one")
        .format(ResourceFormat::RGBA32Uint).flags(RenderPassReflection::Field::Flags::Optional);
    return reflector;
}

void MyPT::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mLastExecutedMode != mMode)
    {
        if (mLastExecutedMode == Mode::NRC || mLastExecutedMode == Mode::ReSTIR) resetNRC();
        if (mLastExecutedMode == Mode::PG || mMode == Mode::PG) resetPG();
        resetGRIS();
        mLastExecutedMode = mMode;
        mOptionsChanged = true;
    }
    for (const char* name : {"nrcExplicit", "nrcCached", "nrcSdkReference", "initialEstimate"})
        if (auto output = renderData.getTexture(name)) pRenderContext->clearTexture(output.get(), float4(0.f));
    // Optional measurements are accumulated across passes and spatial rounds in this frame.
    for (const char* name : {"rayStats0", "rayStats1", "rayStats2", "temporalShiftStats", "spatialShiftStats", "nrcQueryDebug", "nrcTrainingDebug", "nrcQueryTrainingDebug", "nrcCandidateDebug"})
        if (auto output = renderData.getTexture(name))
        {
            pRenderContext->uavBarrier(output.get());
            pRenderContext->clearUAV(output->getUAV().get(), uint4(0));
        }
    // Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
        mGRIS.frameIndex = 0;
        mGRIS.historyValid = false;
    }

    // Resolve writes every diagnostic pixel in ReSTIR. PT/no-scene diagnostics are explicitly zero.
    if (!mpScene || mMode != Mode::ReSTIR)
        for (const char* name : {"ptReference", "reservoirF", "reservoirDebug", "initialColor", "spatialDebug", "temporalColor", "temporalDebug", "shiftDebug", "pathDebug"})
            if (auto output = renderData.getTexture(name)) pRenderContext->clearTexture(output.get(), float4(0.f));

    // If we have no scene, just clear the outputs and return.
    if (!mpScene)
    {
        mGRIS.historyValid = false;
        for (auto it : kOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        return;
    }

    if (is_set(mpScene->getUpdates(), IScene::UpdateFlags::RecompileNeeded) ||
        is_set(mpScene->getUpdates(), IScene::UpdateFlags::GeometryChanged))
    {
        FALCOR_THROW("This render pass does not support scene changes that require shader recompilation.");
    }

    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    // Configure depth-of-field.
    const bool useDOF = mpScene->getCamera()->getApertureRadius() > 0.f;
    if (useDOF && renderData[kInputViewDir] == nullptr)
    {
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", kInputViewDir);
    }

    if (mMode == Mode::PG)
    {
        executePG(pRenderContext, renderData);
        return;
    }

    if (mMode == Mode::ReSTIR)
    {
        try { executeGRIS(pRenderContext, renderData); }
        catch (...)
        {
            // An SDK frame cannot survive a failed shader compile/dispatch.
            if (nrcUseCache()) { resetNRC(); mGRIS.historyValid = false; }
            throw;
        }
        return;
    }

    if (mMode == Mode::NRC && nrcUseCache() && mMaxBounces > 0)
    {
        executeNRC(pRenderContext, renderData);
        return;
    }

    // Specialize program.
    mGRIS.historyValid = false; // PT must never leave reusable ReSTIR history behind.
    // These defines should not modify the program vars. Do not trigger program vars re-creation.
    mTracer.pProgram->addDefine("MAX_BOUNCES", std::to_string(mMaxBounces));
    mTracer.pProgram->addDefine("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    mTracer.pProgram->addDefine("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    mTracer.pProgram->addDefine("USE_MIS", mUseMIS ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    bool layoutChanged = mTracer.pProgram->addDefine("MYPT_HAS_RAY_STATS2", renderData.getTexture("rayStats2") ? "1" : "0");
    if (mReferenceLambertian) layoutChanged |= mTracer.pProgram->addDefine("DiffuseBrdf", "0");
    else layoutChanged |= mTracer.pProgram->removeDefine("DiffuseBrdf");
    if (layoutChanged) mTracer.pVars = nullptr;

    // Update the emissive light sampler and inject its defines before program vars are created.
    // The light collection may not be ready during setScene(). Create lazily
    // after getLightCollection() above so ordinary PT and PG use the same NEE.
    if (!mpEmissiveSampler && mpScene->useEmissiveLights())
        mpEmissiveSampler = std::make_unique<EmissivePowerSampler>(pRenderContext, mpScene->getILightCollection(pRenderContext));
    if (mpEmissiveSampler)
    {
        mpEmissiveSampler->update(pRenderContext, mpScene->getILightCollection(pRenderContext));
        mTracer.pProgram->addDefines(mpEmissiveSampler->getDefines());
    }

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    mTracer.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracer.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    // Prepare program vars. This may trigger shader compilation.
    if (!mTracer.pVars)
        prepareVars();
    FALCOR_ASSERT(mTracer.pVars);

    auto var = mTracer.pVars->getRootVar();
    if (mpEmissiveSampler) mpEmissiveSampler->bindShaderData(var["gMyPTEmissiveSampler"]);
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gSeed"] = mSeed;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    var["CB"]["gRRProbability"] = mRRProbability;
    for (const auto& channel : kInputChannels)
        if (!channel.texname.empty()) var[channel.texname] = renderData.getTexture(channel.name);
    var["gOutputColor"] = renderData.getTexture("color");
    if (auto output = renderData.getTexture("rayStats2")) var["gRayStats2"] = output;
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(renderData.getDefaultTextureDims(), 1));

    if (mMode == Mode::NRC)
    {
        mNRC.status = mMaxBounces == 0 ? "Direct lighting only; cache bypassed" : "Cache disabled; ordinary PT";
        if (auto output = renderData.getTexture("nrcExplicit"))
            pRenderContext->copyResource(output.get(), renderData.getTexture("color").get());
    }

    mFrameCount++;
}

void MyPT::renderUI(Gui::Widgets& widget)
{
    bool dirty = widget.dropdown("Mode", mMode);
    if (mMode == Mode::PG) renderPGUI(widget);
    if (mMode == Mode::ReSTIR)
    {
        if (nrcUseCache())
        {
            if (mShiftStrategy != ShiftStrategy::Reconnection) { mShiftStrategy = ShiftStrategy::Reconnection; dirty = true; }
            widget.text("NRC shift: Reconnection");
        }
        else dirty |= widget.dropdown("Shift strategy", mShiftStrategy);
        if (mShiftStrategy == ShiftStrategy::Hybrid)
        {
            dirty |= widget.var("Specular roughness threshold", mSpecularRoughnessThreshold, 0.f, 1.f);
            dirty |= widget.var("Near-field distance", mNearFieldDistance, 0.f, 100.f);
            widget.tooltip("Replay the prefix until a compatible rough surface is far enough away to reconnect.");
        }
        dirty |= widget.var("GI RIS candidate count", mGIRISCandidateCount, 0u, 64u);
        widget.tooltip("Complete candidate path trees. 0 retains direct-only rendering using one tree.");
        dirty |= widget.var("Seed", mSeed);
        if (widget.button("Reset sampling")) dirty = true;
        dirty |= widget.checkbox("Temporal reuse", mTemporalReuse);
        if (mTemporalReuse)
        {
            dirty |= widget.checkbox("Temporal reprojection", mTemporalReprojection);
            dirty |= widget.var("History length", mMaxHistoryLength, 0u, 128u);
            dirty |= widget.var("Temporal depth threshold", mTemporalDepthThreshold, 0.f, 1.f);
            dirty |= widget.var("Temporal normal threshold", mTemporalNormalThreshold, -1.f, 1.f);
            widget.tooltip("Talbot MIS with the selected shift strategy. History length 0 or depth of field bypasses temporal reuse.");
        }
        dirty |= widget.checkbox("Spatial reuse", mSpatialReuse);
        if (mSpatialReuse)
        {
            dirty |= widget.var("Spatial neighbors", mSpatialNeighborCount, 0u, 16u);
            dirty |= widget.var("Spatial radius", mSpatialRadius, 0.f, 128.f);
            dirty |= widget.var("Spatial rounds", mSpatialReuseRounds, 0u, 8u);
            dirty |= widget.var("Spatial depth threshold", mSpatialDepthThreshold, 0.f, 1.f);
            dirty |= widget.var("Spatial normal threshold", mSpatialNormalThreshold, -1.f, 1.f);
            widget.tooltip("Defensive Pairwise MIS with the selected shift strategy. Reconnection Jacobian ratios are limited to 11 in either direction. Zero neighbors or rounds bypass reuse.");
        }
    }
    if (mMode == Mode::NRC || mMode == Mode::ReSTIR)
    {
        widget.text(mNRC.status);
        dirty |= widget.checkbox("Use radiance cache", nrcUseCache());
        // The cache may have been enabled below the shift controls this frame.
        // Apply the restriction now, before execute() validates the combination.
        if (mMode == Mode::ReSTIR && nrcUseCache() && mShiftStrategy != ShiftStrategy::Reconnection)
        {
            mShiftStrategy = ShiftStrategy::Reconnection;
            dirty = true;
        }
        const bool trainingChanged = widget.checkbox("Train cache", mNrcTrainCache);
        if (mMode != Mode::ReSTIR) dirty |= trainingChanged;
        dirty |= widget.var("Recorded vertices", mNrcQueryTrainingMaxVertices, 2u, 65u);
        widget.tooltip("Train from existing path segments only (GRIS initial candidates in ReSTIR). No training rays. Incomplete/overflow paths are excluded.");
        if (mMode == Mode::ReSTIR)
        {
            dirty |= widget.var("Cache query depth", mNrcQueryDepth, 2u, 65535u);
            widget.tooltip("Primary is depth 0. Unsupported surfaces at this fixed depth continue explicit tracing.");
        }
        else
        {
            dirty |= widget.var("Cache termination threshold", mNrcTerminationThreshold, 0.001f, 10.f, 0.01f);
            widget.tooltip("Lower values end paths earlier. This trades detail for less tracing and noise.");
        }
        dirty |= widget.var("Training iterations", mNrcTrainingIterations, 1u, 16u);
        if (widget.button("Reset cache")) resetNrcCache();
    }
    dirty |= widget.var(mMode == Mode::NRC ? "Max explicit bounces" : "Max bounces", mMaxBounces, 0u, 65535u);
    widget.tooltip(mMode == Mode::NRC ? "0 = direct lighting only. The cache can predict illumination beyond the explicit tracing limit."
        : "0 = direct lighting; 1 = one indirect bounce. Shared by PT and ReSTIR.");
    dirty |= widget.checkbox("Evaluate direct illumination", mComputeDirect);
    dirty |= widget.checkbox("Use importance sampling", mUseImportanceSampling);
    if (mMode == Mode::PG) widget.text("MIS enabled for PG");
    else if ((mMode == Mode::NRC || (mMode == Mode::ReSTIR && mGIRISCandidateCount > 0)) && nrcUseCache() && mMaxBounces > 0) widget.text("MIS enabled for NRC");
    else dirty |= widget.checkbox("Use MIS", mUseMIS);
    dirty |= widget.var("RR Probability", mRRProbability, 0.f, 0.95f);
    widget.tooltip("Termination probability. Use 0 for the first-round comparison.");
    mOptionsChanged |= dirty;
    if (mMode == Mode::PG && dirty) mPGResetRequested = true;
}

void MyPT::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    resetPG();
    mPGPendingSceneUpdates = Scene::UpdateFlags::None;
    resetNRC();
    mNrcPendingSceneUpdates = Scene::UpdateFlags::None;
    resetGRIS();
    mPendingSceneUpdates = Scene::UpdateFlags::None;
    // Clear data for previous scene.
    mTracer.pProgram = nullptr;
    mTracer.pBindingTable = nullptr;
    mTracer.pVars = nullptr;
    mFrameCount = 0;

    // Set new scene.
    mpScene = pScene;

    // Create the emissive light sampler if the scene has emissive lights.
    if (mpScene && mpScene->useEmissiveLights())
    {
        mpEmissiveSampler = std::make_unique<EmissivePowerSampler>(pRenderContext, mpScene->getILightCollection(pRenderContext));
    }
    else
    {
        mpEmissiveSampler = nullptr;
    }

    if (mpScene)
    {
        // Create ray tracing program.
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFile);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

        auto rayGenID = desc.addRayGen("rayGen");
        auto scatterMissID = desc.addMiss("scatterMiss");
        auto shadowMissID = desc.addMiss("shadowMiss");
        mTracer.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
        mTracer.pBindingTable->setRayGen(rayGenID);
        mTracer.pBindingTable->setMiss(0, scatterMissID);
        mTracer.pBindingTable->setMiss(1, shadowMissID);
        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            auto scatterHitID = desc.addHitGroup("scatterTriangleMeshClosestHit", "scatterTriangleMeshAnyHit");
            auto shadowHitID = desc.addHitGroup("", "shadowTriangleMeshAnyHit");
            mTracer.pBindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), scatterHitID);
            mTracer.pBindingTable->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), shadowHitID);
        }

        // Merge the emissive light sampler's defines (including _EMISSIVE_LIGHT_SAMPLER_TYPE)
        // into the program at creation time so the shader's EmissiveLightSampler typedef resolves
        // to the correct concrete sampler type.
        DefineList defines = mpScene->getSceneDefines();
        if (mpEmissiveSampler)
            defines.add(mpEmissiveSampler->getDefines());

        mTracer.pProgram = Program::create(mpDevice, desc, defines);
    }
}

void MyPT::onSceneUpdates(RenderContext*, Scene::UpdateFlags updates)
{
    // RenderGraph retains changes made while another graph was active.
    mPendingSceneUpdates |= updates;
    mNrcPendingSceneUpdates |= updates;
    mPGPendingSceneUpdates |= updates;
}

void MyPT::resetSampling(uint32_t seed)
{
    mSeed = seed;
    mFrameCount = 0;
    mGRIS.frameIndex = 0;
    mGRIS.historyValid = false;
    mOptionsChanged = true;
}

void MyPT::prepareVars()
{
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mTracer.pProgram);

    // Configure program.
    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    // Create program variables for the existing PT pass.
    mTracer.pVars = RtProgramVars::create(mpDevice, mTracer.pProgram, mTracer.pBindingTable);

    // Bind utility classes into shared data.
    mpSampleGenerator->bindShaderData(mTracer.pVars->getRootVar());
    // Bind the emissive power sampler's alias table each frame in execute().
    // gScene is bound automatically by Scene::raytrace() each frame.
}
