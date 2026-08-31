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
#include "Rendering/Lights/EmissiveUniformSampler.h"

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
        else if (key == kRISCandidateCount)
            mRISCandidateCount = value;
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
        else if (key == kTemporalDepthThreshold)
            mTemporalDepthThreshold = value;
        else if (key == kTemporalNormalThreshold)
            mTemporalNormalThreshold = value;
        else if (key == kSpatialNeighborCount)
            mSpatialNeighborCount = value;
        else if (key == kSpatialRadius)
            mSpatialRadius = value;
        else if (key == kSpatialDepthThreshold)
            mSpatialDepthThreshold = value;
        else if (key == kSpatialNormalThreshold)
            mSpatialNormalThreshold = value;
        else
            logWarning("Unknown property '{}' in MyPT properties.", key);
    }
}

Properties MyPT::getProperties() const
{
    Properties props;
    props[kMode] = mMode;
    props[kRISCandidateCount] = mRISCandidateCount;
    props[kMaxBounces] = mMaxBounces;
    props[kComputeDirect] = mComputeDirect;
    props[kUseImportanceSampling] = mUseImportanceSampling;
    props[kUseMIS] = mUseMIS;
    props[kRRProbability] = mRRProbability;
    props[kMaxHistoryLength] = mMaxHistoryLength;
    props[kTemporalDepthThreshold] = mTemporalDepthThreshold;
    props[kTemporalNormalThreshold] = mTemporalNormalThreshold;
    props[kSpatialNeighborCount] = mSpatialNeighborCount;
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
    }

    // If we have no scene, just clear the outputs and return.
    if (!mpScene)
    {
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

    // Specialize program.
    // These defines should not modify the program vars. Do not trigger program vars re-creation.
    mTracer.pProgram->addDefine("USE_RESTIR", mMode == Mode::ReSTIR ? "1" : "0");
    mTracer.pProgram->addDefine("RIS_CANDIDATE_COUNT", std::to_string(mRISCandidateCount));
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

    // Set constants and bind all resources (CB + I/O + reservoirs) for a pass's vars.
    auto setupVars = [&](const ref<RtProgramVars>& pVars)
    {
        auto var = pVars->getRootVar();

        // Constants.
        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
        var["CB"]["gRRProbability"] = mRRProbability;
        var["CB"]["gMaxHistoryLength"] = mMaxHistoryLength;
        var["CB"]["gTemporalDepthThreshold"] = mTemporalDepthThreshold;
        var["CB"]["gTemporalNormalThreshold"] = mTemporalNormalThreshold;
        var["CB"]["gSpatialNeighborCount"] = mSpatialNeighborCount;
        var["CB"]["gSpatialRadius"] = mSpatialRadius;
        var["CB"]["gSpatialDepthThreshold"] = mSpatialDepthThreshold;
        var["CB"]["gSpatialNormalThreshold"] = mSpatialNormalThreshold;

        // I/O buffers (bound per-frame as they may change).
        for (const auto& channel : kInputChannels)
        {
            if (!channel.texname.empty())
                var[channel.texname] = renderData.getTexture(channel.name);
        }
        for (const auto& channel : kOutputChannels)
        {
            if (!channel.texname.empty())
                var[channel.texname] = renderData.getTexture(channel.name);
        }

        // Reservoir buffers.
        var["gReservoirPrev"] = mpReservoirPrev;
        var["gReservoirTemporal"] = mpReservoirTemporal;
        var["gReservoirSpatial"] = mpReservoirSpatial;
    };

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Manage ReSTIR reservoir buffers (previous / temporal / spatial).
    const uint32_t pixelCount = targetDim.x * targetDim.y;
    const uint32_t kReservoirSize = 64u; // Must match the Reservoir struct (4 x float4) in MyPTRestir.slang.
    if (!mpReservoirPrev || mpReservoirPrev->getElementCount() < pixelCount)
    {
        mpReservoirPrev = mpDevice->createStructuredBuffer(kReservoirSize, pixelCount);
        mpReservoirTemporal = mpDevice->createStructuredBuffer(kReservoirSize, pixelCount);
        mpReservoirSpatial = mpDevice->createStructuredBuffer(kReservoirSize, pixelCount);
    }

    // Set constants and bind resources for both passes.
    setupVars(mTracer.pVars);
    setupVars(mTracer.pRestirVars);

    // Clear the buffers written this frame (invalid pixels stay at M == 0).
    pRenderContext->clearUAV(mpReservoirTemporal->getUAV().get(), uint4(0));
    pRenderContext->clearUAV(mpReservoirSpatial->getUAV().get(), uint4(0));

    // Pass 1: RIS initial sampling + temporal reuse (writes gReservoirTemporal).
    if (mMode == Mode::ReSTIR)
    {
        mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pRestirVars, uint3(targetDim, 1));
    }

    // Pass 2: spatial reuse + shading + indirect (reads gReservoirTemporal, writes gReservoirSpatial).
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(targetDim, 1));

    // Swap: this frame's spatial result becomes next frame's temporal input.
    if (mMode == Mode::ReSTIR)
    {
        std::swap(mpReservoirPrev, mpReservoirSpatial);
    }

    mFrameCount++;
}

void MyPT::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.dropdown("Mode", mMode);
    widget.tooltip("Rendering mode.\nPT = brute-force path tracing.\nReSTIR = ReSTIR direct illumination (RIS).", true);

    dirty |= widget.var("RIS candidate count", mRISCandidateCount, 1u, 256u);
    widget.tooltip("Number of candidate light samples (M) used by ReSTIR DI RIS.", true);

    dirty |= widget.var("Max history length", mMaxHistoryLength, 1u, 64u);
    widget.tooltip("Maximum accumulated sample count (M) for ReSTIR temporal reuse.", true);

    dirty |= widget.var("Temporal depth threshold", mTemporalDepthThreshold, 0.f, 1.f);
    widget.tooltip("Maximum world-space position difference for ReSTIR temporal reuse.", true);

    dirty |= widget.var("Temporal normal threshold", mTemporalNormalThreshold, -1.f, 1.f);
    widget.tooltip("Minimum cosine between normals for ReSTIR temporal reuse.", true);

    dirty |= widget.var("Spatial neighbor count", mSpatialNeighborCount, 0u, 16u);
    widget.tooltip("Number of spatial reuse neighbors (K) sampled per pixel.", true);

    dirty |= widget.var("Spatial radius", mSpatialRadius, 0.f, 128.f);
    widget.tooltip("Maximum pixel radius for spatial neighbor selection.", true);

    dirty |= widget.var("Spatial depth threshold", mSpatialDepthThreshold, 0.f, 1.f);
    widget.tooltip("Maximum world-space position difference for ReSTIR spatial reuse.", true);

    dirty |= widget.var("Spatial normal threshold", mSpatialNormalThreshold, -1.f, 1.f);
    widget.tooltip("Minimum cosine between normals for ReSTIR spatial reuse.", true);

    dirty |= widget.var("Max bounces", mMaxBounces, 0u, 1u << 16);
    widget.tooltip("Maximum path length for indirect illumination.\n0 = direct only\n1 = one indirect bounce etc.", true);

    dirty |= widget.checkbox("Evaluate direct illumination", mComputeDirect);
    widget.tooltip("Compute direct illumination.\nIf disabled only indirect is computed (when max bounces > 0).", true);

    dirty |= widget.checkbox("Use importance sampling", mUseImportanceSampling);
    widget.tooltip("Use importance sampling for materials", true);

    dirty |= widget.checkbox("Use MIS", mUseMIS);
    widget.tooltip("Use multiple importance sampling to combine NEE and BSDF sampling.\n"
        "When disabled, NEE samples are added unweighted (may double count with BSDF hits on emissive surfaces).", true);

    dirty |= widget.var("RR Probability", mRRProbability, 0.f, 0.95f);
    widget.tooltip("Probability of terminating a path by russian roulette at each indirect bounce.", true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
    }
}

void MyPT::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    mTracer.pProgram = nullptr;
    mTracer.pBindingTable = nullptr;
    mTracer.pVars = nullptr;
    mTracer.pRestirBindingTable = nullptr;
    mTracer.pRestirVars = nullptr;
    mFrameCount = 0;

    // Reset ReSTIR reservoirs so old-scene history is not reused.
    mpReservoirPrev = nullptr;
    mpReservoirTemporal = nullptr;
    mpReservoirSpatial = nullptr;

    // Set new scene.
    mpScene = pScene;

    // Create the emissive light sampler if the scene has emissive lights.
    if (mpScene && mpScene->useEmissiveLights())
    {
        mpEmissiveSampler = std::make_unique<EmissiveUniformSampler>(pRenderContext, mpScene->getILightCollection(pRenderContext));
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

        // Add the entry points. The ShaderIDs are shared between the two binding tables.
        auto restirGenID = desc.addRayGen("restirGen");
        auto rayGenID = desc.addRayGen("rayGen");
        auto scatterMissID = desc.addMiss("scatterMiss");
        auto shadowMissID = desc.addMiss("shadowMiss");

        // Create the restirGen binding table. It reuses the same miss/hit groups as the main
        // pass for a consistent ray-type layout; restirGen simply never calls TraceRay.
        mTracer.pRestirBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
        mTracer.pRestirBindingTable->setRayGen(restirGenID);
        mTracer.pRestirBindingTable->setMiss(0, scatterMissID);
        mTracer.pRestirBindingTable->setMiss(1, shadowMissID);

        // Create the main rayGen binding table (full SBT).
        mTracer.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
        mTracer.pBindingTable->setRayGen(rayGenID);
        mTracer.pBindingTable->setMiss(0, scatterMissID);
        mTracer.pBindingTable->setMiss(1, shadowMissID);

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            auto scatterHitGroupID = desc.addHitGroup("scatterTriangleMeshClosestHit", "scatterTriangleMeshAnyHit");
            auto shadowHitGroupID = desc.addHitGroup("", "shadowTriangleMeshAnyHit");

            mTracer.pRestirBindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), scatterHitGroupID);
            mTracer.pRestirBindingTable->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), shadowHitGroupID);
            mTracer.pBindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), scatterHitGroupID);
            mTracer.pBindingTable->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), shadowHitGroupID);
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

void MyPT::prepareVars()
{
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mTracer.pProgram);

    // Configure program.
    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    // Create program variables for both passes (shared program, separate binding tables).
    mTracer.pVars = RtProgramVars::create(mpDevice, mTracer.pProgram, mTracer.pBindingTable);
    mTracer.pRestirVars = RtProgramVars::create(mpDevice, mTracer.pProgram, mTracer.pRestirBindingTable);

    // Bind utility classes into shared data.
    mpSampleGenerator->bindShaderData(mTracer.pVars->getRootVar());
    mpSampleGenerator->bindShaderData(mTracer.pRestirVars->getRootVar());
    // Note: The emissive sampler is stateless (all data comes from gScene.lightCollection), so it
    // does not need to be bound here. The sampler struct is instantiated locally in the shader.
    // gScene is bound automatically by Scene::raytrace() each frame.
}
