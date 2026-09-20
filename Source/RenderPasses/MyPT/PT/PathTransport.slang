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

/**
 * Custom path tracer (MyPT).
 *
 * This shader is a from-scratch brute-force path tracer used as a starting
 * point for experimentation. The algorithm mirrors the built-in
 * MinimalPathTracer so you can swap in your own sampling/shading/termination.
 *
 * At each hit point (including the primary hit loaded from the V-buffer),
 * analytic light sources (point, directional) are sampled uniformly using
 * 1 shadow ray, and 1 scatter ray is traced to sample the hemisphere.
 * At hit/miss the scatter ray includes light from emissive surface and
 * the environment map, respectively. Traversal stops at a fixed path length.
 *
 * The host sets the following defines:
 *
 * MAX_BOUNCES             Maximum number of indirect bounces (0 means no indirect).
 * COMPUTE_DIRECT          Nonzero if direct illumination should be included.
 * USE_IMPORTANCE_SAMPLING Nonzero if importance sampling should be used for sampling materials.
 * USE_ANALYTIC_LIGHTS     Nonzero if Falcor's analytic lights should be used.
 * USE_EMISSIVE_LIGHTS     Nonzero if emissive geometry should be used as lights.
 * USE_ENV_LIGHT           Nonzero if env map is available and should be used as light source.
 * USE_ENV_BACKGROUND      Nonzero if env map is available and should be used as background.
 * is_valid_<name>         1 if optional I/O buffer with this name should be used.
 */

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Utils.Color.ColorHelpers;
import RenderPasses.MyPT.MyPTCommon;
import Utils.Math.HashUtils;
import RenderPasses.MyPT.GRIS.Measurement;

#ifndef MYPT_NRC
#define MYPT_NRC 0
#endif
#ifndef MYPT_NRC_QUERY_RECORDS
#define MYPT_NRC_QUERY_RECORDS 0
#endif
#ifndef MYPT_PG
#define MYPT_PG 0
#endif
#if MYPT_PG && MYPT_NRC
#error PG and NRC are independent transport modes.
#endif

cbuffer CB
{
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gSeed;          // Independent run seed; zero preserves the original PT sequence.
    uint gPRNGDimension; // First available PRNG dimension.
    float gRRProbability; // Fixed probability for russian roulette path termination.
}

#if MYPT_NRC
#include "../NRC/NrcAdapter.slang"
#endif

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
Texture2D<float2> gMotionVector; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

// MyPTCommon declares the emissive sampler parameter block; execute() binds its alias table.

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseMIS = USE_MIS;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;

#if MYPT_PG
#include "../PG/Sampling.slang"
#include "../PG/PathRecording.slang"
#endif

/**
 * Payload for shadow ray.
 */
struct ShadowRayData
{
    bool visible;
};

/**
 * Payload for scatter ray (up to 72B).
 */
struct ScatterRayData
{
    float3 radiance;  ///< Accumulated outgoing radiance from path.
    bool terminated;  ///< Set to true when path is terminated.
    float3 thp;       ///< Current path throughput. This is updated at each path vertex.
    uint pathLength;  ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3 origin;    ///< Next path segment origin.
    float3 direction; ///< Next path segment direction.
    float pdf;        ///< Pdf of the BSDF-sampled direction (for MIS when the scatter ray hits an emissive surface).
    float3 normal;    ///< Oriented face normal at the previous path vertex (for emissive PDF evaluation).

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).
#if MYPT_PG
    PGRecording pgRecording;
    bool pgPreviousDelta;
#endif
#if MYPT_NRC
    NrcPathState nrcState;
    bool nrcDirectProbe;
    float3 nrcProbeRestoreThroughput;
    uint nrcProbeSegments;
    bool nrcPreviousDelta;
#if MYPT_NRC_QUERY_RECORDS
    NrcQueryRecording recording;
#endif
#endif

    /**
     * Initializes ray payload with default parameters.
     */
    __init(SampleGenerator sg)
    {
        this.terminated = false;
        this.pathLength = 0;
        this.radiance = float3(0, 0, 0);
        this.thp = float3(1, 1, 1);
        this.origin = float3(0, 0, 0);
        this.direction = float3(0, 0, 0);
        this.pdf = 0.f;
        this.normal = float3(0, 0, 0);
        this.sg = sg;
#if MYPT_PG
        this.pgRecording = pgRecordInit(DispatchRaysIndex().xy);
        this.pgPreviousDelta = false;
#endif
#if MYPT_NRC
        this.nrcState = (NrcPathState)0;
        this.nrcDirectProbe = false;
        this.nrcProbeRestoreThroughput = 0.f;
        this.nrcProbeSegments = 0u;
        this.nrcPreviousDelta = false;
#if MYPT_NRC_QUERY_RECORDS
        this.recording = nrcRecordInit(DispatchRaysIndex().xy);
#endif
#endif
    }
};

/**
 * Returns the primary ray's direction.
 */
float3 getPrimaryRayDir(uint2 launchIndex, uint2 launchDim, const Camera camera)
{
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        return -gViewW[launchIndex].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        return camera.computeRayPinhole(launchIndex, launchDim).dir;
    }
}

/**
 * Traces a shadow ray towards a light source.
 * @param[in] origin Ray origin for the shadow ray.
 * @param[in] dir Direction from shading point towards the light source (normalized).
 * @param[in] distance Distance to the light source.
 * @return True if light is visible, false otherwise.
 */
bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = distance;

    ShadowRayData rayData;
    rayData.visible = false; // Set to true by miss shader if ray is not terminated before
    // DispatchRaysIndex stays the ray-generation owner even in nested hit shaders.
#if MYPT_NRC
    nrcMeasurementAdd(uint4(0u, 1u, 0u, 0u));
#else
    measurementInit(DispatchRaysIndex().xy, kMeasurePT);
    measurementShadowRay();
#endif
    TraceRay(
        gScene.rtAccel,
        RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
        0xff /* instanceInclusionMask */,
        1 /* hitIdx */,
        rayTypeCount,
        1 /* missIdx */,
        ray,
        rayData
    );

    return rayData.visible;
}

/**
 * Traces a scatter ray based on ray parameters stored in the ray payload.
 * @param[in] rayData Describes the ray parameters. The struct is modified based on the result.
 */
void traceScatterRay(inout ScatterRayData rayData)
{
    RayDesc ray;
    ray.Origin = rayData.origin;
    ray.Direction = rayData.direction;
    ray.TMin = 0.f;
    ray.TMax = kRayTMax;

    uint rayFlags = 0; // TODO: Set cull mode from the app
#if MYPT_NRC
    nrcMeasurementAdd(uint4(1u, 0u, 0u, 0u));
#else
    measurementInit(DispatchRaysIndex().xy, kMeasurePT);
    measurementScatterRay();
#endif
    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);
}

/**
 * Evaluates the direct illumination from analytic lights.
 * This function samples Falcor's light list uniformly with one shadow ray.
 * @param[in] sd Shading data.
 * @param[in] mi Material instance.
 * @param[in,out] sg SampleGenerator object.
 * @return Outgoing radiance in view direction.
 */
float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
#if MYPT_NRC
    // The scene's global light switch does not remove lights from its active
    // array. Honor it explicitly for NRC while retaining the PT bypass baseline.
    if (gNrcUseCache != 0 && !kUseAnalyticLights) return float3(0.f);
#endif
    AnalyticLightSample ls;
    float invPdf;
    if (!sampleMyPTAnalyticLight(sd, sg, ls, invPdf)) return 0.f;

    // Reject sample if not in the hemisphere of a BSDF lobe.
    const uint lobeTypes = mi.getLobeTypes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    float NdotL = dot(sd.getOrientedFaceNormal(), ls.dir);
    if ((NdotL <= kMinCosTheta && !hasTransmission) || (NdotL >= -kMinCosTheta && !hasReflection))
        return float3(0.f);

    // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
    const float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);

    // Test visibility by tracing a shadow ray.
    bool V = traceShadowRay(origin, ls.dir, ls.distance);
    if (!V)
        return float3(0.f);

    // Evaluate contribution.
    return mi.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

/**
 * Evaluates the direct illumination from emissive geometry using NEE + MIS.
 * @param[in] sd Shading data.
 * @param[in] mi Material instance.
 * @param[in,out] sg SampleGenerator object.
 * @return Outgoing radiance in view direction.
 */
float3 evalDirectEmissive(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    if (!kUseEmissiveLights) return float3(0.f);

    // Sample an emissive triangle.
    TriangleLightSample tls;
    if (!sampleMyPTEmissiveLight(sd, sg, tls))
        return float3(0.f);

    if (tls.pdf <= 0.f) return float3(0.f);

    float3 Li = tls.Le / tls.pdf;

    // Apply MIS weight against the BSDF sampling strategy.
    if (kUseMIS)
    {
#if MYPT_PG
        const float scatterPdf = evalPGScatterPdf(sd, mi, tls.dir, kUseImportanceSampling);
#else
        const float scatterPdf = mi.evalPdf(sd, tls.dir, kUseImportanceSampling);
#endif
        Li *= evalMIS(tls.pdf, scatterPdf);
    }

    // Test visibility.
    float3 origin, visibilityDirection;
    float visibilityDistance;
    if (!getMyPTEmissiveVisibilityRay(sd, tls, origin, visibilityDirection, visibilityDistance))
        return float3(0.f);
    if (!traceShadowRay(origin, visibilityDirection, visibilityDistance))
        return float3(0.f);

    return mi.eval(sd, tls.dir, sg) * Li;
}

/**
 * Evaluates the total direct illumination (analytic lights + emissive geometry).
 * @param[in] sd Shading data.
 * @param[in] mi Material instance.
 * @param[in,out] sg SampleGenerator object.
 * @return Outgoing radiance in view direction.
 */
float3 evalDirect(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    float3 Lr = evalDirectAnalytic(sd, mi, sg);
    Lr += evalDirectEmissive(sd, mi, sg);
    return Lr;
}

/**
 * Generates the next scatter ray using the shared material sampling function.
 * @param[in] sd Shading data.
 * @param[in] mi Material instance.
 * @param[in,out] sg SampleGenerator object.
 * @return True if the scatter ray was generated.
 */
bool generateScatterRay(const ShadingData sd, const IMaterialInstance mi, float3 rayOrigin, inout ScatterRayData rayData)
{
    // Sample material.
    BSDFSample bsdfSample = {};
#if MYPT_PG
    if (samplePGScatter(sd, mi, rayData.sg, bsdfSample, kUseImportanceSampling,
        rayData.pgRecording.slot != kPGInvalid))
#else
    if (sampleMyPTBSDF(sd, mi, rayData.sg, bsdfSample, kUseImportanceSampling))
#endif
    {
        rayData.origin = rayOrigin;
        if (bsdfSample.isLobe(LobeType::Transmission))
        {
            rayData.origin = sd.computeRayOrigin(false);
        }
        rayData.direction = bsdfSample.wo;
        rayData.pdf = bsdfSample.pdf;
#if MYPT_PG
        rayData.pgPreviousDelta = bsdfSample.isLobe(LobeType::Delta);
#endif
#if MYPT_NRC
        if (gNrcUseCache != 0)
        {
            NrcSetBrdfPdf(rayData.nrcState, bsdfSample.pdf);
            rayData.nrcPreviousDelta = bsdfSample.isLobe(LobeType::Delta);
        }
#endif
        rayData.normal = sd.getOrientedFaceNormal();
        rayData.thp *= bsdfSample.weight;
#if MYPT_PG
        // Only directions whose actual scatter ray is followed have a measured
        // incident-radiance suffix. A zero-BSDF null event is not retraced just
        // for guiding; its preceding vertices retain the valid zero tail.
        if (any(rayData.thp > 0.f))
            pgRecordScatter(rayData.pgRecording, bsdfSample.wo, bsdfSample.pdf,
                bsdfSample.weight, pgSupportsMaterial(sd, mi) && !rayData.pgPreviousDelta);
#endif
#if MYPT_NRC_QUERY_RECORDS
        rayData.recording.beta *= bsdfSample.weight;
#endif
        return any(rayData.thp > 0.f);
    }

    return false;
}

/**
 * Apply russian roulette to terminate paths early.
 * @param[in,out] rayData Ray payload.
 * @param[in] u Uniform random number in [0,1).
 * @return True if the path was terminated.
 */
bool terminatePathByRussianRoulette(inout ScatterRayData rayData, float u)
{
    if (u < gRRProbability)
    {
        rayData.terminated = true;
#if MYPT_PG
        pgRecordEnd(rayData.pgRecording, kPGTerminationRR, 0.f);
#endif
#if MYPT_NRC_QUERY_RECORDS
        nrcRecordEnd(rayData.recording, kRecordRR);
        rayData.recording.beta = 0.f;
#endif
        return true;
    }
    rayData.thp /= (1.f - gRRProbability);
#if MYPT_PG
    rayData.pgRecording.survivalScale = 1.f / (1.f - gRRProbability);
#endif
#if MYPT_NRC_QUERY_RECORDS
    rayData.recording.beta /= (1.f - gRRProbability);
#endif
    return false;
}

/**
 * Process a hit.
 * Loads the shading data, samples analytic lights and samples a new scatter ray.
 * Terminates the path if maximum number of bounces is reached.
 * @param[in] hit Hit info.
 * @param[in,out] rayData Ray payload.
 */
void handleHit(const HitInfo hit, inout ScatterRayData rayData)
{
    // Load shading data.
    ShadingData sd = loadShadingData(hit, rayData.direction);

    // Create material instance.
    let lod = ExplicitLodTextureSampler(0.f);
    let mi = gScene.materials.getMaterialInstance(sd, lod);

#if MYPT_PG
    float3 pgEmission = 0.f;
    float pgHitMIS = 1.f;
#endif
#if MYPT_NRC
    nrcMeasurementAdd(uint4(0u, 0u, 1u, 0u));
#endif
    // Add emitted light.
    if (kUseEmissiveLights && (kComputeDirect || rayData.pathLength > 0))
    {
        float3 emission = mi.getProperties(sd).emission;
#if MYPT_PG
        pgEmission = emission;
#endif
        // This hit came from a BSDF-sampled scatter ray, and the previous vertex performed NEE
        // (the primary vertex does NEE when kComputeDirect, indirect vertices always do).
        // Apply the MIS weight to avoid double counting with the NEE strategy.
        // Note: the first scatter-ray hit has pathLength == 0, so the condition matches the
        // outer emission condition (kComputeDirect || pathLength > 0).
        if (kComputeDirect || rayData.pathLength > 0)
        {
            TriangleLightHit lightHit;
            TriangleHit triangleHit = hit.getTriangleHit();
            lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
            lightHit.posW = sd.posW;
            lightHit.normalW = sd.getOrientedFaceNormal();
            // With MIS disabled, keep the full emission (may double count with the NEE strategy).
            if (kUseMIS)
            {
#if MYPT_PG
                // Discrete delta events cannot compete with continuous NEE.
                if (!rayData.pgPreviousDelta)
                {
#endif
#if MYPT_NRC
                // Delta BSDF samples have zero solid-angle PDF in Falcor. NEE
                // cannot produce this discrete event, so its hit weight is one.
                // Keep the established ordinary-PT diagnostic baseline intact.
                if (gNrcUseCache == 0 || !rayData.nrcPreviousDelta)
                {
#endif
                const float lightPdf = gMyPTEmissiveSampler.evalPdf(rayData.origin, rayData.normal, false, lightHit);
#if MYPT_PG
                pgHitMIS = evalMIS(rayData.pdf, lightPdf);
                emission *= pgHitMIS;
#else
                emission *= evalMIS(rayData.pdf, lightPdf);
#endif
#if MYPT_NRC
                }
#endif
#if MYPT_PG
                }
#endif
            }
        }
        rayData.radiance += rayData.thp * emission;
#if MYPT_NRC_QUERY_RECORDS
        nrcRecordRadiance(rayData.recording, emission);
#endif
    }

#if MYPT_PG
    // Record even the depth/RR terminal surface: its raw emission and local NEE
    // are needed to recover the incident radiance at earlier vertices.
    pgRecordVertex(rayData.pgRecording, sd.posW, pgEmission, pgHitMIS);
#endif
#if MYPT_NRC
    // A cache termination needs the BSDF strategy's local-light contribution
    // as well as NEE (and the PT has no environment NEE). SDK-skipped vertices
    // belong to the same recorded segment: follow their real BSDF/NEE until the
    // next cacheable vertex, where only incoming emission belongs to this one.
    if (rayData.nrcDirectProbe)
    {
        bool stop = !nrcSurface(sd, mi).isDeltaLobe;
        if (rayData.nrcProbeSegments >= kNrcMaxDirectProbeSegments)
        {
            stop = true;
#if MYPT_NRC_QUERY_RECORDS
            nrcRecordEnd(rayData.recording, kRecordProbeLimit);
#endif
            NrcSetDebugPathTerminationReason(rayData.nrcState, NrcDebugPathTerminationReason::MaxPathVertices);
        }
        if (stop)
        {
            rayData.thp = rayData.nrcProbeRestoreThroughput;
            rayData.terminated = true;
            return;
        }
        // No NRC hit/miss state updates or RR within this separate estimator.
        // A skipped glass/unsupported material still uses its actual transport.
        if (kUseAnalyticLights || kUseEmissiveLights)
        {
            float3 direct = evalDirect(sd, mi, rayData.sg);
            rayData.radiance += rayData.thp * direct;
#if MYPT_NRC_QUERY_RECORDS
            nrcRecordRadiance(rayData.recording, direct);
#endif
        }
        if (!generateScatterRay(sd, mi, sd.computeRayOrigin(), rayData))
        {
            rayData.thp = rayData.nrcProbeRestoreThroughput;
            rayData.terminated = true;
        }
        else
        {
            rayData.nrcProbeSegments++;
            rayData.pathLength++;
        }
        return;
    }
#endif
    // Check whether to terminate based on max depth.
    if (rayData.pathLength >= kMaxBounces)
    {
        rayData.terminated = true;
#if MYPT_PG
        pgRecordEnd(rayData.pgRecording, kPGTerminationDepth, 0.f);
#endif
#if MYPT_NRC_QUERY_RECORDS
        nrcRecordEnd(rayData.recording, kRecordDepth);
#endif
        return;
    }

#if MYPT_NRC
    NrcProgressState nrcProgress = NrcProgressState::Continue;
    if (gNrcUseCache != 0)
    {
        // Attribute BSDF-hit emission to the previous segment BEFORE NRC
        // finalizes it. Features describe scattered radiance, not self emission.
        NrcSurfaceAttributes surface = nrcSurface(sd, mi);
#if MYPT_NRC_QUERY_RECORDS
        nrcRecordHit(rayData.recording, surface);
#endif
        nrcProgress = NrcUpdateOnHit(nrcContext(), rayData.nrcState, surface,
            RayTCurrent(), rayData.pathLength + 1u, rayData.thp, rayData.radiance);
        if (nrcProgress == NrcProgressState::TerminateImmediately)
        {
            rayData.terminated = true;
            return;
        }
    }
#endif
    // Compute ray origin for new rays spawned from the hit.
    const float3 rayOrigin = sd.computeRayOrigin();

    // Add contribution of direct light (analytic lights + emissive NEE).
    if (kUseAnalyticLights || kUseEmissiveLights)
    {
        float3 Lr = evalDirect(sd, mi, rayData.sg);
        rayData.radiance += rayData.thp * Lr;
#if MYPT_PG
        pgRecordDirect(rayData.pgRecording, Lr);
#endif
#if MYPT_NRC_QUERY_RECORDS
        nrcRecordRadiance(rayData.recording, Lr);
#endif
    }

#if MYPT_NRC
    if (gNrcUseCache != 0 && nrcProgress == NrcProgressState::TerminateAfterDirectLighting)
    {
#if MYPT_NRC_QUERY_RECORDS
        nrcRecordEnd(rayData.recording, kRecordCache);
#endif
        // This is a direct-light probe, not a transition to a bootstrap vertex.
        // Preserve the query/last training vertex throughput across the probe.
        rayData.nrcProbeRestoreThroughput = rayData.thp;
        rayData.nrcDirectProbe = true;
        rayData.nrcProbeSegments = 1u;
        if (!generateScatterRay(sd, mi, rayOrigin, rayData))
        {
            rayData.thp = rayData.nrcProbeRestoreThroughput;
            rayData.terminated = true;
        }
        else rayData.pathLength++;
        return;
    }
#endif
    // Apply russian roulette to terminate paths early.
#if MYPT_NRC
    // Falcor compiles with DisableShortCircuit: the RR call mutates both RNG
    // and path state, so a boolean && guard would still execute it when denied.
    if (gNrcUseCache == 0 || NrcCanUseRussianRoulette(rayData.nrcState))
    {
#endif
    if (terminatePathByRussianRoulette(rayData, sampleNext1D(rayData.sg)))
    {
        return;
    }
#if MYPT_NRC
    }
#endif

    // Generate scatter ray for the next path segment.
    // The raygen shader will continue the path based on the returned payload.
    if (!generateScatterRay(sd, mi, rayOrigin, rayData))
    {
#if MYPT_PG
        pgRecordEnd(rayData.pgRecording, kPGTerminationAbsorbed, 0.f);
#endif
#if MYPT_NRC_QUERY_RECORDS
        nrcRecordEnd(rayData.recording, kRecordAbsorbed);
        rayData.recording.beta = 0.f;
#endif
        rayData.terminated = true;
        return;
    }

    rayData.pathLength++;
}

#if MYPT_NRC
float3 traceNrcPath(uint2 pixel, uint2 frameDim)
{
    uint sampleFrame = gSeed == 0 ? gFrameCount : jenkinsHash(gFrameCount ^ jenkinsHash(gSeed));
    SampleGenerator sg = SampleGenerator(pixel, sampleFrame);
    for (uint i = 0; i < gPRNGDimension; i++) sampleNext1D(sg);
    ScatterRayData rayData = ScatterRayData(sg);
    rayData.nrcState = nrcInitialPathState(pixel);
    float3 primaryDirection = getPrimaryRayDir(pixel, frameDim, gScene.camera);
    HitInfo hit = HitInfo(gVBuffer[pixel]);
    float3 primaryEmission = 0.f;
    if (hit.isValid())
    {
        nrcMeasurementAdd(uint4(0u, 0u, 1u, 0u));
        ShadingData sd = loadShadingData(hit, primaryDirection);
        let mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        // Always establish the primary spread radius. Keep
        // primary shading explicit even in diagnostic heuristic configurations.
        NrcContext context = nrcContext();
        context.constants.enableTerminationHeuristic = 1u;
#if MYPT_NRC_QUERY_RECORDS
        // When camera direct is hidden, start recording at the next supported
        // surface: do not fabricate the primary's unobserved direct lighting.
        if (kComputeDirect) nrcRecordHit(rayData.recording, nrcSurface(sd, mi));
#endif
        NrcUpdateOnHit(context, rayData.nrcState, nrcSurface(sd, mi),
            length(sd.posW - gScene.camera.getPosition()), 0u, rayData.thp, rayData.radiance);
        if (kComputeDirect)
        {
            primaryEmission = mi.getProperties(sd).emission;
            float3 direct = evalDirect(sd, mi, rayData.sg);
            rayData.radiance += direct;
#if MYPT_NRC_QUERY_RECORDS
            nrcRecordRadiance(rayData.recording, direct);
#endif
        }
        if (!generateScatterRay(sd, mi, sd.computeRayOrigin(), rayData))
        {
            rayData.terminated = true;
#if MYPT_NRC_QUERY_RECORDS
            nrcRecordEnd(rayData.recording, kRecordAbsorbed);
            rayData.recording.beta = 0.f;
#endif
        }
        uint traceLimit = kMaxBounces;
        // The terminal local-light estimator may cross skipped delta/unsupported
        // vertices. Its separate finite safety budget bounds reflective cycles.
        for (uint depth = 0u; depth <= traceLimit + kNrcMaxDirectProbeSegments && !rayData.terminated; depth++)
            traceScatterRay(rayData);
    }
    else
    {
        NrcUpdateOnMiss(rayData.nrcState);
        primaryEmission = kUseEnvBackground ? gScene.envMap.eval(primaryDirection) : kDefaultBackgroundColor;
    }
    NrcWriteFinalPathInfo(nrcContext(), rayData.nrcState, rayData.thp, rayData.radiance);
#if MYPT_NRC_QUERY_RECORDS
    nrcRecordFinish(rayData.recording);
#endif
    nrcMeasurementAdd(uint4(0u, 0u, 0u, rayData.nrcState.queryBufferIndex != 0xffffffffu ? 1u : 0u));
    return primaryEmission + rayData.radiance;
}
#endif

/**
 * This is the main entry point for the custom path tracer.
 *
 * One path per pixel is generated, which is traced into the scene.
 * The path tracer is written as a for-loop over path segments.
 *
 * @param[in] pixel Pixel to trace a path for.
 * @param[in] frameDim Dimension of the frame in pixels.
 * @return Returns the estimated color (radiance).
 */
float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
#if MYPT_NRC
    if (gNrcUseCache != 0 && kMaxBounces > 0u) return traceNrcPath(pixel, frameDim);
    // Define the no-query result on every path, including zero depth and
    // background. A diagnostic cache bypass must not reuse a prior frame slot.
    NrcPathState emptyState = nrcInitialPathState(pixel);
    NrcWriteFinalPathInfo(nrcContext(), emptyState, float3(0.f), float3(0.f));
#endif
    float3 outColor = float3(0.f);

    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        // Pixel represents a valid primary hit. Compute its contribution.

        // Load shading data.
        ShadingData sd = loadShadingData(hit, primaryRayDir);

        // Create material instance at shading point.
        let lod = ExplicitLodTextureSampler(0.f);
        let mi = gScene.materials.getMaterialInstance(sd, lod);

        // Create sample generator.
        uint sampleFrame = gSeed == 0 ? gFrameCount : jenkinsHash(gFrameCount ^ jenkinsHash(gSeed));
        SampleGenerator sg = SampleGenerator(pixel, sampleFrame);

        // Advance the generator to the first available dimension.
        for (uint i = 0; i < gPRNGDimension; i++)
            sampleNext1D(sg);

        // Compute ray origin for new rays spawned from the G-buffer.
        const float3 rayOrigin = sd.computeRayOrigin();

#if MYPT_PG
        float3 pgPrimaryEmission = 0.f;
        float3 pgPrimaryDirect = 0.f;
#endif
        if (kComputeDirect)
        {
            // Always output directly emitted light, independent of whether emissive materials are treated as light sources or not.
#if MYPT_PG
            pgPrimaryEmission = mi.getProperties(sd).emission;
            pgPrimaryDirect = evalDirect(sd, mi, sg);
            outColor += pgPrimaryEmission;
            outColor += pgPrimaryDirect;
#else
            outColor += mi.getProperties(sd).emission;

            outColor += evalDirect(sd, mi, sg);
#endif
        }

        {
            // Prepare ray payload.
            ScatterRayData rayData = ScatterRayData(sg);
#if MYPT_PG
            pgRecordVertex(rayData.pgRecording, sd.posW, pgPrimaryEmission, 1.f);
            pgRecordDirect(rayData.pgRecording, pgPrimaryDirect);
#endif

            // Generate scatter ray.
            if (!generateScatterRay(sd, mi, rayOrigin, rayData))
            {
                rayData.terminated = true;
#if MYPT_PG
                pgRecordEnd(rayData.pgRecording, kPGTerminationAbsorbed, 0.f);
#endif
            }

            // Follow path into the scene and compute its total contribution.
            for (uint depth = 0; depth <= kMaxBounces && !rayData.terminated; depth++)
            {
                traceScatterRay(rayData);
            }

            // Store contribution from scatter ray.
            outColor += rayData.radiance;
#if MYPT_PG
            pgRecordFinish(rayData.pgRecording);
#endif
        }
    }
    else
    {
        // Background pixel.
        outColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }

    // Final NaN/Inf guard. A single NaN pixel poisons the whole AccumulatePass
    // running average, so we drop pathological values here instead of letting them
    // accumulate over hundreds of frames.
    if (isnan(outColor.x) || isnan(outColor.y) || isnan(outColor.z) ||
        isinf(outColor.x) || isinf(outColor.y) || isinf(outColor.z))
    {
        outColor = float3(0.f);
    }

    return outColor;
}

//
// Shader entry points for miss shaders.
//

[shader("miss")]
void scatterMiss(inout ScatterRayData rayData)
{
#if MYPT_PG
    float3 pgTerminalEmission = 0.f;
#endif
#if MYPT_NRC
    // A visibility/direct-light probe missing the scene says nothing about the
    // untraced indirect tail at its parent vertex. Do not disable bootstrap.
    if (gNrcUseCache != 0 && !rayData.nrcDirectProbe) NrcUpdateOnMiss(rayData.nrcState);
#endif
    // Ray missed the scene. Mark the ray as terminated.
    rayData.terminated = true;

    // Add contribution from distant light (env map) in this direction.
    if (kUseEnvLight && (kComputeDirect || rayData.pathLength > 0))
    {
        float3 Le = gScene.envMap.eval(WorldRayDirection());
        rayData.radiance += rayData.thp * Le;
#if MYPT_PG
        pgTerminalEmission = Le;
#endif
#if MYPT_NRC_QUERY_RECORDS
        nrcRecordRadiance(rayData.recording, Le);
#endif
    }
#if MYPT_PG
    pgRecordEnd(rayData.pgRecording, kPGTerminationMiss, pgTerminalEmission);
#endif
#if MYPT_NRC
    if (rayData.nrcDirectProbe) rayData.thp = rayData.nrcProbeRestoreThroughput;
#if MYPT_NRC_QUERY_RECORDS
    if (!rayData.nrcDirectProbe)
    {
        nrcRecordEnd(rayData.recording, kRecordMiss);
        rayData.recording.beta = 0.f;
    }
#endif
#endif
}

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    // The miss shader is executed if the ray misses all geometry. Mark as visible.
    rayData.visible = true;
}

//
// Shader entry points for TriangleMesh hit groups.
//

[shader("anyhit")]
void scatterTriangleMeshAnyHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
        IgnoreHit();
}

[shader("closesthit")]
void scatterTriangleMeshClosestHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    handleHit(HitInfo(triangleHit), rayData);
}

[shader("anyhit")]
void shadowTriangleMeshAnyHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
        IgnoreHit();
}

//
// Main PT ray generation entry point.
//

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
#if MYPT_NRC
    frameDim = gNrcFrameDim;
#endif

    float3 color = tracePath(pixel, frameDim);

    gOutputColor[pixel] = float4(color, 1.f);
}

