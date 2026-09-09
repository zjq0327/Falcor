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
    for (const auto& [key, value] : props)
    {
        if (key == kMode)
            mMode = value;
        else if (key == "seed")
            mSeed = value;
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
    props["seed"] = mSeed;
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

    return reflector;
}

void MyPT::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
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
    if (!mpScene || mMode == Mode::PT)
        for (const char* name : {"ptReference", "reservoirF", "reservoirDebug", "initialColor", "spatialDebug", "temporalColor", "temporalDebug"})
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

    if (mMode == Mode::ReSTIR)
    {
        executeGRIS(pRenderContext, renderData);
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

    // Update the emissive light sampler and inject its defines before program vars are created.
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
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    var["CB"]["gRRProbability"] = mRRProbability;
    for (const auto& channel : kInputChannels)
        if (!channel.texname.empty()) var[channel.texname] = renderData.getTexture(channel.name);
    var["gOutputColor"] = renderData.getTexture("color");
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(renderData.getDefaultTextureDims(), 1));

    mFrameCount++;
}

void MyPT::renderUI(Gui::Widgets& widget)
{
    bool dirty = widget.dropdown("Mode", mMode);
    if (mMode == Mode::ReSTIR)
    {
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
            widget.tooltip("Talbot MIS with pure reconnection. History length 0 bypasses temporal reuse. Depth of field bypasses temporal reuse in this version.");
        }
        dirty |= widget.checkbox("Spatial reuse", mSpatialReuse);
        if (mSpatialReuse)
        {
            dirty |= widget.var("Spatial neighbors", mSpatialNeighborCount, 0u, 16u);
            dirty |= widget.var("Spatial radius", mSpatialRadius, 0.f, 128.f);
            dirty |= widget.var("Spatial rounds", mSpatialReuseRounds, 0u, 8u);
            dirty |= widget.var("Spatial depth threshold", mSpatialDepthThreshold, 0.f, 1.f);
            dirty |= widget.var("Spatial normal threshold", mSpatialNormalThreshold, -1.f, 1.f);
            widget.tooltip("Pure reconnection with defensive Pairwise MIS. Jacobian ratio is limited to 11 in either direction. Zero neighbors or rounds bypass reuse.");
        }
    }
    dirty |= widget.var("Max bounces", mMaxBounces, 0u, 65535u);
    widget.tooltip("0 = direct lighting; 1 = one indirect bounce. Shared by PT and ReSTIR.");
    dirty |= widget.checkbox("Evaluate direct illumination", mComputeDirect);
    dirty |= widget.checkbox("Use importance sampling", mUseImportanceSampling);
    dirty |= widget.checkbox("Use MIS", mUseMIS);
    dirty |= widget.var("RR Probability", mRRProbability, 0.f, 0.95f);
    widget.tooltip("Termination probability. Use 0 for the first-round comparison.");
    mOptionsChanged |= dirty;
}

void MyPT::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
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
