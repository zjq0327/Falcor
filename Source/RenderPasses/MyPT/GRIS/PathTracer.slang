#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EnvMapSampler;
import RenderPasses.MyPT.MyPTCommon;
__exported import PathBuilder;
__exported import BSDF;

ParameterBlock<EnvMapSampler> gEnvSampler;

float balanceWeight(float sampledPdf, float otherPdf)
{
    return evalMIS(sampledPdf, otherPdf, false);
}

bool pathVisible(ShadingData sd, float3 direction, float distance)
{
    float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, direction) >= 0.f ? sd.faceN : -sd.faceN);
    SceneRayQuery<true> query;
    return query.traceVisibilityRay(Ray(origin, direction, 0.f, max(0.f, distance * (1.f - 1e-5f))));
}

bool reconnectionVisible(float3 origin, ShadingData rc, float3 connection)
{
    float3 target = computeRayOrigin(rc.posW, dot(rc.faceN, -connection) >= 0.f ? rc.faceN : -rc.faceN);
    float3 edge = target - origin;
    float distance = length(edge);
    if (!(distance > 0.f) || !isfinite(distance)) return false;
    SceneRayQuery<true> query;
    return query.traceVisibilityRay(Ray(origin, edge / distance, 0.f, distance * (1.f - 1e-5f)));
}

float hitMIS(float bsdfPdf, float lightPdf, bool previousDelta)
{
    if (!GRIS_USE_NEE || previousDelta || !isfinite(lightPdf) || lightPdf <= 0.f) return 1.f;
    // Without MIS, NEE owns sampleable lights after non-delta scattering.
    return GRIS_USE_MIS ? balanceWeight(bsdfPdf, lightPdf) : 0.f;
}

bool hybridRough(ShadingData sd, float threshold)
{
    if (gScene.materials.getMaterialType(sd.materialID) != MaterialType::Standard) return false;
    let material = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    // Reference separatePathBSDF=false: classify the material, not a sampled lobe
    // whose single-component PDF would differ from our full mixture PDF.
    return material.getProperties(sd).roughness > threshold;
}

struct PathTraceResult
{
    PathBuilder builder;
    HybridPrefix prefix;
};

PathTraceResult tracePathImpl(PrimaryPathContext primary, uint seed, uint maxScatters, float rrProbability,
    uint traceMode, PathSample target, float roughnessThreshold, float nearFieldDistance)
{
    PathBuilder builder = PathBuilder(seed);
    builder.replayEnabled = traceMode != 0;
    builder.replayTarget = target;
    HybridPrefix prefix = {};
    prefix.hit = HitInfo().pack();
    prefix.failure = 11; // Ended before the requested prefix endpoint.
    SampleGenerator sg = SampleGenerator(seed);
    HitInfo hit = HitInfo(primary.hit);
    float3 direction = primary.direction;
    float3 throughput = 1.f;
    float3 suffix = 1.f;
    float3 previousPosition = 0.f;
    float3 previousNormal = 0.f;
    float3 previousOrigin = 0.f;
    float previousPdf = 0.f;
    bool previousDelta = true;
    PackedHitInfo previousHit = HitInfo().pack();
    float3 previousDirection = 0.f;
    float3 previousScatterPrefix = 1.f;
    uint previousScatterSeed = seed;
    uint previousFlags = 0;
    bool previousRough = false;
    SceneRayQuery<true> query;

    // Like the reference TracePass: complete each path in one dispatch, including
    // emission/miss at the last depth BEFORE the depth-termination check.
    for (uint depth = 0; depth <= maxScatters; ++depth)
    {
        if (!hit.isValid())
        {
            float3 emission = 0.f;
            float lightPdf = 0.f;
            float mis = 1.f;
#if USE_ENV_BACKGROUND
            if (depth == 0) emission = gScene.envMap.eval(direction);
#endif
#if USE_ENV_LIGHT
            if (depth > 0)
            {
                emission = gEnvSampler.eval(direction);
                lightPdf = gEnvSampler.evalPdf(direction);
                mis = hitMIS(previousPdf, lightPdf, previousDelta);
            }
#endif
            // The rc BSDF PDF changes during reconnection. Reevaluate its terminal MIS in Shift.
            builder.add(throughput * emission * mis, suffix * emission * (depth == builder.descriptor.rcIndex + 1 ? 1.f : mis), depth,
                PathTerminal::Environment, PathLight::Environment, sg.rng.state, lightPdf, direction, false);
            break;
        }

        ShadingData sd = loadShadingData(hit, direction);
        bool atRc = depth == 1;
#if GRIS_SHIFT_STRATEGY == 2
        bool currentRough = hybridRough(sd, roughnessThreshold);
        bool canConnect = depth > 0 && previousRough && currentRough && (builder.descriptor.prefixFlags & 4u) == 0 &&
            length(sd.posW - previousOrigin) >= nearFieldDistance;
        if (traceMode == 2 && canConnect && depth < target.rcIndex)
        {
            prefix.failure = 12; // The destination would choose an earlier rc.
            break;
        }
        atRc = builder.descriptor.rcIndex == 0xffffffff && canConnect;
        if (traceMode == 2) atRc = false;
#endif
        if (atRc)
        {
            builder.descriptor.rcHit = hit.pack();
            builder.descriptor.rcPositionW = sd.posW;
            builder.descriptor.rcTexCoord = sd.uv;
            builder.descriptor.rcFrame = sd.frame;
            builder.descriptor.rcTangentW = sd.tangentW;
            builder.descriptor.rcFaceN = sd.faceN;
            builder.descriptor.rcIndex = depth;
            builder.descriptor.rcPrevHit = previousHit;
            builder.descriptor.rcPrevDirection = previousDirection;
            builder.descriptor.rcPrevSeed = previousScatterSeed;
            builder.descriptor.rcBeforeFlags = previousFlags;
            builder.descriptor.cachedJacobian.x = previousPdf;
            float3 edge = sd.posW - previousOrigin;
            // Use the stored hit positions for geometry on both sides of a later shift.
            // The sampled direction can differ slightly at grazing angles after hit reconstruction.
            float3 connection = edge * rsqrt(dot(edge, edge));
            builder.descriptor.cachedJacobian.z = abs(dot(sd.faceN, -connection)) / dot(edge, edge);
            if (gScene.materials.getMaterialType(sd.materialID) != MaterialType::Standard)
                builder.descriptor.rcBeforeFlags |= 4u;
            if ((builder.descriptor.rcBeforeFlags & 5u) == 0)
            {
                // Pure reconnection in the reference reevaluates the SOURCE PDF using
                // the geometric connection too. Cache that value, not the sampled-ray PDF.
                ShadingData firstSd = loadShadingData(HitInfo(previousHit), previousDirection);
                let firstMaterial = gScene.materials.getMaterialInstance(firstSd, ExplicitLodTextureSampler(0.f));
                float p1 = evalGRISBSDFPdf(firstSd, firstMaterial, connection, bool(USE_IMPORTANCE_SAMPLING));
                if (p1 > 0.f)
                {
                    // Parameterize the candidate by its stored vertices, just as Shift does.
                    // This only removes the floating-point discrepancy between the sampled
                    // ray direction and the direction reconstructed from its hit position.
                    SampleGenerator evaluation = sg;
                    throughput = previousScatterPrefix * evalGRISBSDF(firstSd, firstMaterial, connection, evaluation) / p1;
                    builder.descriptor.cachedJacobian.x = p1;
                    previousPdf = p1;
                    direction = connection;
                    sd = loadRcShadingData(builder.descriptor, direction);
                }
                else builder.descriptor.rcBeforeFlags |= 8u;
                // A reconstructed source segment must itself be in the mapping's support.
                // Retain numerically non-invertible paths in the canonical reservoir.
                if (!reconnectionVisible(previousOrigin, sd, connection)) builder.descriptor.rcBeforeFlags |= 8u;
            }
            builder.descriptor.rcPrefix = throughput;
            suffix = 1.f;
        }
        let mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

        uint emissionSeed = sg.rng.state;
        // Preserve MyPT's scene light switch while still showing camera-visible emitters.
        float3 emission = depth == 0 || USE_EMISSIVE_LIGHTS ? mi.getProperties(sd).emission : float3(0.f);
        float emissionPdf = 0.f;
#if USE_EMISSIVE_LIGHTS
        if (depth > 0 && any(emission > 0.f) && GRIS_USE_NEE && !previousDelta)
        {
            TriangleHit triangle = hit.getTriangleHit();
            TriangleLightHit lightHit;
            lightHit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangle.instanceID, triangle.primitiveIndex);
            lightHit.posW = sd.posW;
            lightHit.normalW = sd.getOrientedFaceNormal();
            emissionPdf = gMyPTEmissiveSampler.evalPdf(previousPosition, previousNormal, false, lightHit);
        }
#endif
        float emissionMIS = depth == 0 ? 1.f : hitMIS(previousPdf, emissionPdf, previousDelta);
        // Unlike the reference's external-DI branch, the baseline owns primary/direct emission too.
        builder.add(throughput * emission * emissionMIS, suffix * emission * (depth <= builder.descriptor.rcIndex + 1 ? 1.f : emissionMIS), depth,
            PathTerminal::Emission, PathLight::Emissive, emissionSeed, emissionPdf, direction, atRc);

        if (depth == maxScatters) break;

#if USE_ANALYTIC_LIGHTS
        // Analytic delta lights cannot be hit by BSDF rays and have no MIS competitor.
        {
            uint lightSeed = sg.rng.state;
            AnalyticLightSample ls;
            float invPdf;
            if (sampleMyPTAnalyticLight(sd, sg, ls, invPdf))
            {
                float3 Li = ls.Li * invPdf;
                float3 local = evalGRISBSDF(sd, mi, ls.dir, sg) * Li;
                if (any(local > 0.f) && pathVisible(sd, ls.dir, ls.distance))
                    builder.add(throughput * local, atRc ? ls.Li : suffix * local, depth + 1,
                        PathTerminal::NEE, PathLight::Analytic, lightSeed, 1.f / invPdf, ls.dir, atRc);
            }
        }
#endif
#if USE_EMISSIVE_LIGHTS && GRIS_USE_NEE
        {
            uint lightSeed = sg.rng.state;
            TriangleLightSample ls;
            if (sampleMyPTEmissiveLight(sd, sg, ls) && ls.pdf > 0.f)
            {
                float mis = GRIS_USE_MIS ? balanceWeight(ls.pdf, evalGRISBSDFPdf(sd, mi, ls.dir, bool(USE_IMPORTANCE_SAMPLING))) : 1.f;
                float3 local = evalGRISBSDF(sd, mi, ls.dir, sg) * ls.Le * (mis / ls.pdf);
                if (any(local > 0.f) && pathVisible(sd, ls.dir, ls.distance))
                    builder.add(throughput * local, atRc ? ls.Le : suffix * local, depth + 1,
                        PathTerminal::NEE, PathLight::Emissive, lightSeed, ls.pdf, ls.dir, atRc);
            }
        }
#endif
#if USE_ENV_LIGHT && GRIS_USE_NEE
        {
            uint lightSeed = sg.rng.state;
            EnvMapSample ls;
            if (gEnvSampler.sample(sampleNext2D(sg), ls) && ls.pdf > 0.f)
            {
                float mis = GRIS_USE_MIS ? balanceWeight(ls.pdf, evalGRISBSDFPdf(sd, mi, ls.dir, bool(USE_IMPORTANCE_SAMPLING))) : 1.f;
                float3 local = evalGRISBSDF(sd, mi, ls.dir, sg) * ls.Le * (mis / ls.pdf);
                if (any(local > 0.f) && pathVisible(sd, ls.dir, 1e30f))
                    builder.add(throughput * local, atRc ? ls.Le : suffix * local, depth + 1,
                        PathTerminal::NEE, PathLight::Environment, lightSeed, ls.pdf, ls.dir, atRc);
            }
        }
#endif
        BSDFSample bs;
        // Preserve the existing RR control. Baseline scripts explicitly use zero.
        // Here RR reciprocals are carried in F; reservoir proposals therefore still use p=1.
        if (depth > 0 && rrProbability > 0.f)
        {
            if (sampleNext1D(sg) < rrProbability) break;
            throughput /= 1.f - rrProbability;
            if (builder.descriptor.rcIndex != 0xffffffff && depth > builder.descriptor.rcIndex) suffix /= 1.f - rrProbability;
        }
        if (traceMode == 2 && depth + 1 == target.rcIndex)
        {
            if (!hybridRough(sd, roughnessThreshold)) { prefix.failure = 13; break; }
            if ((builder.descriptor.prefixFlags & 4u) != 0) { prefix.failure = 9; break; }
            prefix.hit = hit.pack();
            prefix.direction = direction;
            prefix.throughput = throughput;
            prefix.rngState = sg.rng.state;
            prefix.failure = 0;
            break; // RR for the connection is included; the connection BSDF is not.
        }
        previousScatterPrefix = throughput;
        previousScatterSeed = sg.rng.state;
        if (!sampleMyPTBSDF(sd, mi, sg, bs, bool(USE_IMPORTANCE_SAMPLING))) break;
        if (!bs.isLobe(LobeType::Delta) && gScene.materials.getMaterialType(sd.materialID) == MaterialType::Standard)
        {
            // Falcor StandardBSDF.sample returns a selected-lobe weight but a mixture PDF.
            // Reconnection evaluates the full continuous BSDF, so use the same estimator
            // here (marginalize the lobe choice). Keep the transport random stream intact.
            SampleGenerator evaluation = sg;
            bs.pdf = evalGRISBSDFPdf(sd, mi, bs.wo, bool(USE_IMPORTANCE_SAMPLING));
            if (bs.pdf <= 0.f) break;
            bs.weight = evalGRISBSDF(sd, mi, bs.wo, evaluation) / bs.pdf;
        }
        throughput *= bs.weight;
        if (any(!isfinite(throughput))) { builder.reservoir.invalidCount++; break; }
        if (!any(throughput > 0.f)) break;
        if (atRc)
        {
            builder.descriptor.rcSeed = sg.rng.state;
            builder.descriptor.rcWi = bs.wo;
            builder.descriptor.cachedJacobian.y = bs.pdf;
            if ((builder.descriptor.rcBeforeFlags & 13u) == 0 && !bs.isLobe(LobeType::Delta))
            {
                float3 sourceConnection = normalize(sd.posW - previousOrigin);
                ShadingData sourceRc = loadRcShadingData(builder.descriptor, sourceConnection);
                let sourceRcMaterial = gScene.materials.getMaterialInstance(sourceRc, ExplicitLodTextureSampler(0.f));
                builder.descriptor.cachedJacobian.y = evalGRISBSDFPdf(sourceRc, sourceRcMaterial, bs.wo, bool(USE_IMPORTANCE_SAMPLING));
            }
            builder.descriptor.rcAfterFlags = (bs.isLobe(LobeType::Delta) ? 1u : 0u) |
                (bs.isLobe(LobeType::Transmission) ? 2u : 0u);
            suffix = rrProbability > 0.f ? 1.f / (1.f - rrProbability) : 1.f;
            // Exclude the rc BSDF but retain its RR survival reciprocal.
        }
        else if (depth == 0)
        {
            builder.descriptor.cachedJacobian.x = bs.pdf;
            builder.descriptor.rcBeforeFlags = (bs.isLobe(LobeType::Delta) ? 1u : 0u) |
                (bs.isLobe(LobeType::Transmission) ? 2u : 0u) |
                (gScene.materials.getMaterialType(sd.materialID) != MaterialType::Standard ? 4u : 0u);
        }
        else if (builder.descriptor.rcIndex != 0xffffffff && depth > builder.descriptor.rcIndex) suffix *= bs.weight;
        previousFlags = (bs.isLobe(LobeType::Delta) ? 1u : 0u) |
            (bs.isLobe(LobeType::Transmission) ? 2u : 0u) |
            (gScene.materials.getMaterialType(sd.materialID) != MaterialType::Standard ? 4u : 0u);
        if (builder.descriptor.rcIndex == 0xffffffff) builder.descriptor.prefixFlags |= previousFlags;
        previousHit = hit.pack();
        previousDirection = direction;
        previousRough = hybridRough(sd, roughnessThreshold);
        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        previousPdf = bs.pdf;
        previousDelta = bs.isLobe(LobeType::Delta);
        direction = bs.wo;
        float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, direction) >= 0.f ? sd.faceN : -sd.faceN);
        previousOrigin = origin;
        float hitT;
        hit = query.traceRay(Ray(origin, direction, 0.f, 1e30f), hitT);
    }
    builder.finalize();
    PathTraceResult result;
    result.builder = builder;
    result.prefix = prefix;
    return result;
}

PathBuilder tracePathTree(PrimaryPathContext primary, uint seed, uint maxScatters, float rrProbability,
    float roughnessThreshold = 0.2f, float nearFieldDistance = 0.1f)
{
    PathSample target = {};
    return tracePathImpl(primary, seed, maxScatters, rrProbability, 0, target, roughnessThreshold, nearFieldDistance).builder;
}

PathSample traceReplayContribution(PrimaryPathContext primary, PathSample source, uint maxScatters, float rrProbability,
    float roughnessThreshold = 0.2f, float nearFieldDistance = 0.1f)
{
    PathTraceResult result = tracePathImpl(primary, source.initialSeed, min(maxScatters, source.surfaceScatters),
        rrProbability, 1, source, roughnessThreshold, nearFieldDistance);
    PathSample sample = result.builder.replaySample;
    if (!result.builder.replayFound) sample = {};
    return sample;
}

HybridPrefix traceHybridPrefix(PrimaryPathContext primary, PathSample source, uint maxScatters, float rrProbability,
    float roughnessThreshold, float nearFieldDistance)
{
    if (source.rcIndex != 0xffffffff)
        return tracePathImpl(primary, source.initialSeed, maxScatters, rrProbability, 2, source,
            roughnessThreshold, nearFieldDistance).prefix;
    PathTraceResult result = tracePathImpl(primary, source.initialSeed, min(maxScatters, source.surfaceScatters),
        rrProbability, 1, source, roughnessThreshold, nearFieldDistance);
    HybridPrefix prefix = {};
    prefix.hit = HitInfo().pack();
    if (!result.builder.replayFound) prefix.failure = 16;
    else if (result.builder.replaySample.rcIndex != 0xffffffff) prefix.failure = 15;
    else
    {
        prefix.throughput = result.builder.replaySample.F;
        prefix.terminal = result.builder.replaySample.terminal;
        prefix.light = result.builder.replaySample.light;
    }
    return prefix;
}
