#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Rendering/Lights/EnvMapSampler.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Utils/SampleGenerators/CPUSampleGenerator.h"
#include "RTPTPG.h"
#include <unordered_map>

namespace Falcor { class Light; }
using namespace Falcor;

/** Compute-based, inline-ray-query Monte Carlo surface path tracer. */
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
    Properties getPGStatistics() const;
    Properties getStageStatistics() const;
    Properties getDIStatistics() const;
    void resetPG() { mResetPG = true; mOptionsChanged = true; }

private:
    void reset();
    void validateScene() const;
    void prepareProgram(RenderContext* pRenderContext);
    void invalidateStages();
    bool prepareStages();
    void bindPrimarySettings(const ShaderVar& rootVar) const;
    void bindNRDOutputs(const ShaderVar& rootVar, const RenderData& renderData) const;
    void executePrimarySurface(RenderContext* pRenderContext);
    void executeFinalSignalResolve(RenderContext* pRenderContext, const RenderData& renderData);
    void invalidateDirectLighting();
    bool prepareDirectLighting();
    void bindDISettings(const ShaderVar& rootVar) const;
    void bindDIMainResources(const ShaderVar& rootVar) const;
    void executeDirectLighting(RenderContext* pRenderContext);
    void invalidateDIReuse();
    void resetDIHistory(const std::string& reason);
    bool prepareDIReuse();
    void bindDIReuseSettings(const ShaderVar& rootVar, uint32_t inputBank, uint32_t outputBank) const;
    void publishDIHistory(RenderContext* pRenderContext);
    void bindSHARC(const ShaderVar& rootVar);
    void clearSHARC(RenderContext* pRenderContext);
    void executeTraining(RenderContext* pRenderContext, bool preserveNRDHistoryOnPGReset = false);
    void dispatchSparse(RenderContext* pRenderContext, uint32_t stride, uint32_t bounces, uint32_t frameIndex, bool sharc, bool pg);

    ref<Scene> mpScene;
    ref<ComputePass> mpComputePass;
    ref<ComputePass> mpStageComputePass;
    ref<ComputePass> mpPrimarySurfacePass;
    ref<ComputePass> mpFinalSignalResolve;
    ref<Buffer> mpPrimarySurfaces;
    ref<Buffer> mpSignalRecords;
    uint2 mStageResourceDim = uint2(0u);
    uint32_t mPrimaryFrameStamp = 0u;
    bool mStagesActive = false;
    bool mStagePreparationFailed = false;
    std::string mStageFallbackReason;
    ref<ComputePass> mpDIComputePass;
    ref<ComputePass> mpDIInitialPass;
    ref<ComputePass> mpDIShadePass;
    ref<Buffer> mpDILightCatalog;
    ref<Buffer> mpDIUncoveredAnalyticIndices;
    ref<Buffer> mpDIReservoirs;
    ref<Buffer> mpDISampleRecords;
    ref<Buffer> mpDIResults;
    std::vector<uint64_t> mDICatalogSignature;
    std::unordered_map<const Light*, uint32_t> mDILightIdentities;
    uint32_t mDINextIdentity = 1u;
    uint32_t mDICatalogGeneration = 1u;
    uint32_t mDILightCount = 0u;
    uint32_t mDIEmissiveCount = 0u;
    uint32_t mDIPointCount = 0u;
    uint32_t mDIUncoveredAnalyticCount = 0u;
    uint32_t mDICoverageMask = 0u;
    bool mRestirDIEnabled = false;
    uint32_t mRestirDICandidateCount = 8u;
    uint32_t mRestirDIBudgetMB = 512u;
    bool mRestirDITemporalEnabled = false;
    bool mRestirDISpatialEnabled = false;
    uint32_t mRestirDIHistoryLength = 20u;
    uint32_t mRestirDISpatialSamples = 4u;
    float mRestirDISpatialRadius = 16.f;
    bool mDIPrepared = false;
    bool mDIActive = false;
    bool mDIPreparationFailed = false;
    std::string mDIFallbackReason;
    ref<ComputePass> mpDIReuseInitialPass;
    ref<ComputePass> mpDITemporalPass;
    ref<ComputePass> mpDISpatialPass;
    ref<ComputePass> mpDIReuseShadePass;
    ref<Buffer> mpDIPreviousPrimarySurfaces;
    ref<Buffer> mpDINeighborOffsets;
    bool mDIReusePrepared = false;
    bool mDIReusePreparationFailed = false;
    bool mDITemporalActive = false;
    bool mDISpatialActive = false;
    bool mDIHistoryAvailable = false;
    bool mDIHistoryReadValid = false;
    uint32_t mDIFinalInputBank = 0u;
    uint32_t mDIHistoryFrameStamp = 0u;
    uint32_t mDIHistorySampleIndex = 0u;
    uint32_t mDIHistoryGeneration = 0u;
    uint32_t mDIHistoryFrames = 0u;
    float4x4 mDIPreviousViewProj = float4x4::identity();
    float3 mDIPreviousCameraPosition = float3(0.f);
    float3 mDIPreviousCameraForward = float3(0.f, 0.f, -1.f);
    std::string mDIHistoryResetReason;
    std::string mDIReuseFallbackReason;
    ref<ComputePass> mpSHARCResolve;
    ref<ComputePass> mpSparseUpdate;
    ref<ComputePass> mpPGPrepare;
    ref<ComputePass> mpPGTrain;
    std::unique_ptr<RTPTPG::Manager> mpPG;
    RTPTPG::Settings mPGSettings;
    bool mEnablePG = false;
    bool mResetPG = true;
    bool mPGTrainingThisFrame = false;
    bool mSharedTrainingThisFrame = false;
    uint32_t mPGUpdateStride = 5;
    uint32_t mPGUpdateBounces = 8;
    uint32_t mPGFrameIndex = 0;
    float3 mPGCameraPosition = float3(0.f);
    ref<Buffer> mpSHARCHashEntries;
    ref<Buffer> mpSHARCAccumulation;
    ref<Buffer> mpSHARCResolved;
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
    bool mNRDHistoryResetThisFrame = false;
    bool mPGTranslationPreservedNRDThisFrame = false;
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
