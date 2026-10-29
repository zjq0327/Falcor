#pragma once
#include "Falcor.h"
#include "Utils/Sampling/SampleGenerator.h"

namespace RTPTPrimarySurface
{
/** The representative camera sample is s=0. Main rendering owns its RNG stream. */
struct FrameInputs
{
    Falcor::uint2 frameDim = {};
    uint32_t seed = 0;
    uint32_t sampleOffset = 0;
    bool useNRD = false;
};

/** Read-only current-frame geometry. Validity means production was submitted,
    not that the GPU has completed or that every pixel contains a surface hit.
    Consumers requiring frozen geometry retain their own model snapshot. */
struct View
{
    Falcor::ref<Falcor::Texture> position;
    // xyz is the oriented geometric face normal, never the material guide
    // normal used by NRD. w retains the material roughness for spatial users.
    Falcor::ref<Falcor::Texture> normalRoughness;
    Falcor::ref<Falcor::Texture> hit;
    Falcor::uint2 frameDim = {};
    uint64_t frameSerial = 0;
    uint32_t sceneGeneration = 0;
    uint32_t seed = 0;
    uint32_t sampleOffset = 0;
    bool useNRD = false;
    Falcor::float4x4 viewProj = Falcor::float4x4::identity();
    Falcor::float4x4 viewProjNoJitter = Falcor::float4x4::identity();

    bool isValid() const { return frameSerial != 0 && position && normalRoughness && hit; }
};

/** RTPT-owned primary producer, independent of any guiding/cache module. */
class Manager
{
public:
    explicit Manager(Falcor::ref<Falcor::Device> device);
    void setScene(const Falcor::ref<Falcor::Scene>& scene);
    // Invalidate the program/layout after scene shader changes. Texture storage
    // is retained when its dimensions and formats are still compatible.
    void invalidate();
    const View& prepare(Falcor::RenderContext* context, const FrameInputs& inputs);
    const View& getView() const { return mView; }
    bool matches(const View& view, const FrameInputs& inputs) const;
    uint64_t getPayloadBytes() const;

private:
    void ensureResources(Falcor::uint2 frameDim);
    void ensureProgram(bool useNRD);

    Falcor::ref<Falcor::Device> mpDevice;
    Falcor::ref<Falcor::Scene> mpScene;
    Falcor::ref<Falcor::ComputePass> mpPass;
    bool mProgramUsesNRD = false;
    Falcor::ref<Falcor::SampleGenerator> mpSampleGenerator;
    View mView;
    uint64_t mFrameSerial = 0;
    uint32_t mSceneGeneration = 1;
};
} // namespace RTPTPrimarySurface
