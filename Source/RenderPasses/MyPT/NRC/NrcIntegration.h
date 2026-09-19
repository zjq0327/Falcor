#pragma once
#include "Falcor.h"
#include <memory>
#include <string>

namespace Falcor
{
/** Optional D3D12 NRC bridge. No SDK declarations escape this header. */
class NrcIntegration
{
public:
    struct Configuration
    {
        uint2 frameDimensions = {0, 0};
        uint2 trainingDimensions = {0, 0}; // Zero selects the SDK's recommendation.
        float3 sceneBoundsMin = {-1.f, -1.f, -1.f};
        float3 sceneBoundsMax = {1.f, 1.f, 1.f};
        float smallestResolvableFeatureSize = 0.01f;
        uint32_t samplesPerPixel = 1;
        uint32_t maxPathVertices = 9;
        uint32_t trainingIterations = 4;
        bool requestReset = false;
    };
    struct FrameSettings
    {
        bool trainTheCache = true;
        bool skipDeltaVertices = true;
        float terminationThreshold = 0.1f;
        float maxExpectedAverageRadiance = 1.f;
        float selfTrainingAttenuation = 1.f;
        float unbiasedTrainingRatio = 0.0625f;
        uint32_t trainingIterations = 4;
        uint32_t resolveMode = 0;
    };

    explicit NrcIntegration(ref<Device> device);
    ~NrcIntegration();
    NrcIntegration(const NrcIntegration&) = delete;
    NrcIntegration& operator=(const NrcIntegration&) = delete;

    static bool isCompiled();
    static std::string getBuildStatus();
    // The constructor does not load the SDK. initialize() handles missing dependencies.
    bool initialize();
    bool configure(RenderContext* context, const Configuration& settings);
    bool beginFrame(RenderContext* context, const FrameSettings& settings);
    bool queryAndTrain(RenderContext* context, bool calculateTrainingLoss = false);
    bool resolve(RenderContext* context, const ref<Texture>& output);
    // Submits pending commands on this context's queue before SDK EndFrame. Does not CPU-wait.
    bool endFrame(RenderContext* context);
    // On resize/reset/destruction, waits for recorded work before destroying SDK-owned internals.
    void shutdown();

    // All SDK buffers remain at their SDK initial states across SDK calls. The bridge
    // restores those states before external calls. After native SDK commands it
    // submits without waiting to reset all gfx bindings for the next Falcor pass.
    void prepareForPathTracing(RenderContext* context);
    void bindShaderData(const ShaderVar& root) const;
    void bindResolveData(const ShaderVar& root) const;
    // No-op unless MYPT_NRC_DIAGNOSTICS=1. An additional
    // MYPT_NRC_DIAGNOSTICS_SYNC=1 submits and waits at this checkpoint.
    void diagnosticCheckpoint(RenderContext* context, const char* stage);
    uint2 getTrainingDimensions() const;
    uint64_t getPublicBufferBytes() const;
    uint64_t getFramesCompleted() const;
    float getTrainingLoss() const;
    bool isInitialized() const;
    const std::string& getError() const;
    ref<Buffer> getCounterBuffer() const;

private:
    struct Impl;
    std::unique_ptr<Impl> mpImpl;
};
}
