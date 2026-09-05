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
#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Rendering/Lights/EmissiveLightSampler.h"

using namespace Falcor;

/**
 * Custom path tracer (MyPT).
 *
 * This is a minimal brute-force path tracer created from scratch as a
 * starting point for experimenting with new tracing algorithms. It follows
 * the same skeleton as the built-in MinimalPathTracer, so you can swap in
 * your own sampling, shading, or termination logic freely.
 *
 * Add new parameters in the "Configuration" section below, wire them through
 * parseProperties()/getProperties()/renderUI()/execute(), and consume them
 * via host-set defines in MyPT.rt.slang.
 */
class MyPT : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(MyPT, "MyPT", "Custom path tracer.");

    /** Rendering mode. */
    enum class Mode
    {
        PT,     ///< Brute-force path tracing (default).
        ReSTIR, ///< ReSTIR (placeholder, not yet implemented).
    };

    FALCOR_ENUM_INFO(
        Mode,
        {
            {Mode::PT, "PT"},
            {Mode::ReSTIR, "ReSTIR"},
        }
    );

    static ref<MyPT> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<MyPT>(pDevice, props);
    }

    MyPT(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    void parseProperties(const Properties& props);
    void prepareVars();

    // Internal state

    /// Current scene.
    ref<Scene> mpScene;
    /// GPU sample generator.
    ref<SampleGenerator> mpSampleGenerator;
    /// Emissive light sampler for NEE, or nullptr if the scene has no emissive lights.
    std::unique_ptr<EmissiveLightSampler> mpEmissiveSampler;

    // Configuration

    /// Rendering mode (path tracing or ReSTIR).
    Mode mMode = Mode::PT;

    /// Number of candidate light samples (M) used by ReSTIR DI RIS.
    uint mRISCandidateCount = 32;

    /// Number of candidate paths (M) used by ReSTIR GI RIS.
    uint mGIRISCandidateCount = 8;

    /// Check visibility of the RIS-selected sample before it enters the temporal/spatial reuse chain.
    /// When disabled, saves one shadow ray per pixel; visibility is then only measured at final shading.
    bool mUseInitialVisibility = true;

    /// Max accumulated sample count (M) for ReSTIR temporal reuse.
    uint mMaxHistoryLength = 20;
    /// Relative depth threshold for ReSTIR temporal reuse (fraction of depth).
    float mTemporalDepthThreshold = 0.1f;
    /// Min cosine between normals for ReSTIR temporal reuse.
    float mTemporalNormalThreshold = 0.5f;
    /// Number of spatial reuse neighbors (K) for ReSTIR spatial reuse.
    uint mSpatialNeighborCount = 4;
    /// Max pixel radius for spatial neighbor selection.
    float mSpatialRadius = 30.f;
    /// Relative depth threshold for ReSTIR spatial reuse (fraction of depth).
    float mSpatialDepthThreshold = 0.1f;
    /// Min cosine between normals for ReSTIR spatial reuse.
    float mSpatialNormalThreshold = 0.5f;

    /// Max number of indirect bounces (0 = none).
    uint mMaxBounces = 64;
    /// Compute direct illumination (otherwise indirect only).
    bool mComputeDirect = true;
    /// Use importance sampling for materials.
    bool mUseImportanceSampling = true;
    /// Use multiple importance sampling (MIS) to combine NEE and BSDF sampling.
    bool mUseMIS = true;
    /// Fixed probability for russian roulette path termination.
    float mRRProbability = 0.2f;

    // Runtime data

    /// Frame count since scene was loaded.
    uint mFrameCount = 0;
    bool mOptionsChanged = false;

    /// ReSTIR reservoir buffers (previous / temporal / spatial).
    ref<Buffer> mpReservoirPrev;     ///< Previous frame's final (spatially-reused) reservoir.
    ref<Buffer> mpReservoirTemporal; ///< This frame's temporally-reused reservoir.
    ref<Buffer> mpReservoirSpatial;  ///< This frame's spatially-reused reservoir.

    /// ReSTIR GI reservoir buffers (previous / temporal / spatial).
    ref<Buffer> mpGIReservoirPrev;     ///< Previous frame's final (spatially-reused) GI reservoir.
    ref<Buffer> mpGIReservoirTemporal; ///< This frame's temporally-reused GI reservoir.
    ref<Buffer> mpGIReservoirSpatial;  ///< This frame's spatially-reused GI reservoir.

    // Ray tracing program, shared by both the restirGen and rayGen passes.
    struct
    {
        ref<Program> pProgram;
        ref<RtBindingTable> pBindingTable;       ///< Full SBT (miss/hit groups) for the rayGen pass.
        ref<RtProgramVars> pVars;                ///< Vars for the rayGen pass.
        ref<RtBindingTable> pRestirBindingTable; ///< Raygen-only SBT for the restirGen pass.
        ref<RtProgramVars> pRestirVars;          ///< Vars for the restirGen pass.
    } mTracer;
};

FALCOR_ENUM_REGISTER(MyPT::Mode);
