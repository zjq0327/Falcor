#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Rendering/Lights/EnvMapSampler.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Utils/SampleGenerators/CPUSampleGenerator.h"
#include "RTPTVXPG.h"

using namespace Falcor;

/** Single-pass, inline-ray-query Monte Carlo surface path tracer. */
class RTPT : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(RTPT, "RTPT", "RayQuery path tracing with next-event estimation and MIS.");

    static ref<RTPT> create(ref<Device> pDevice, const Properties& props) { return make_ref<RTPT>(pDevice, props); }
    RTPT(ref<Device> pDevice, const Properties& props);

    Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    Properties getVXPGStatistics() const;
    Properties getVXPGTreeSnapshot() const;
    void resetVXPG() { mpVXPG->invalidate(); mOptionsChanged = true; }

private:
    void reset();
    void validateScene() const;
    void prepareProgram(RenderContext* pRenderContext);
    void bindSHARC(const ShaderVar& rootVar, bool resolve = false);
    bool usesPairedSharc() const;
    void clearSHARC(RenderContext* pRenderContext);
    void executeTraining(RenderContext* pRenderContext);
    void dispatchSparse(RenderContext* pRenderContext, uint32_t stride, uint32_t bounces, uint32_t frameIndex,
        bool sharc, bool vxpg = false);

    ref<Scene> mpScene;
    ref<ComputePass> mpComputePass;
    ref<ComputePass> mpSHARCResolve;
    ref<ComputePass> mpSparseUpdate;
    std::unique_ptr<RTPTVXPG::Manager> mpVXPG;
    RTPTVXPG::Settings mVXPGSettings;
    std::string mVXPGDiagnosticText;
    std::string mVXPGTreeDiagnosticText;
    bool mVXPGDiagnosticFrameAvailable = false;
    uint32_t mVXPGDiagnosticFrameSampleOffset = 0;
    uint32_t mVXPGDiagnosticFrameSamplesPerPixel = 0;
    uint32_t mVXPGDiagnosticFrameGeneration = 0;
    RTPTVXPG::GuidingMode mGuidingMode = RTPTVXPG::GuidingMode::BSDF;
    bool mEnableVXPG = false;
    bool mVXPGSharedTrainingThisFrame = false;
    bool mVXPGSharedWithSHARCThisFrame = false;
    ref<Buffer> mpSHARCHashEntries;
    ref<Buffer> mpSHARCAccumulation;
    ref<Buffer> mpSHARCResolved;
    ref<Buffer> mpSHARCHashSnapshot, mpSHARCResolvedNext;
    ref<Buffer> mpSHARCLocalAccumulation, mpSHARCLocalResolved, mpSHARCLocalNext;
    ref<Buffer> mpSHARCSuffixAccumulation, mpSHARCSuffixResolved, mpSHARCSuffixNext;
    ref<SampleGenerator> mpSampleGenerator;
    std::unique_ptr<EnvMapSampler> mpEnvMapSampler;
    ref<Texture> mpAccumulation;
    ref<CPUSampleGenerator> mpCameraPattern;
    ref<Camera> mpJitterCamera;

    uint32_t mSamplesPerPixel = 1;
    uint32_t mMaxBounces = 4;
    uint32_t mRRStartBounce = 3;
    uint32_t mSeed = 0;
    bool mUseNEE = true;
    bool mUseRussianRoulette = true;
    bool mAccumulate = true;
    uint32_t mMaxAccumulationFrames = 0; // 0 means unlimited.
    bool mEnableNRD = false;
    bool mResetNRDHistory = true;
    bool mEnableSHARC = false;
    bool mSHARCEnabled = true;
    bool mSHARCUseCache = true;
    bool mSHARCFreeze = false;
    bool mResetSHARCCache = true;
    uint32_t mSHARCEntries = 1u << 20;
    uint32_t mSHARCUpdateStride = 5;
    uint32_t mSHARCUpdateBounces = 8;
    uint32_t mSHARCMinBounce = 1;
    uint32_t mSHARCAccumulationFrames = 32;
    uint32_t mSHARCStaleFrames = 128;
    uint32_t mSHARCDebugMode = 0;
    uint32_t mSHARCFrameIndex = 0;
    float mSHARCSceneScale = 64.f;
    float mSHARCMinRoughness = 0.4f;
    float3 mSHARCCameraPositionPrev = float3(0.f);

    uint2 mFrameDim = uint2(0);
    uint32_t mSampleOffset = 0;
    uint32_t mAccumulatedSamples = 0;
    uint32_t mAccumulatedFrames = 0;
    uint32_t mLightingMask = ~0u;
    bool mOptionsChanged = true;
};
