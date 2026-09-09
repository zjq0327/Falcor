#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EnvMapSampler;
import RenderPasses.MyPT.MyPTCommon;
__exported import PathBuilder;

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

float hitMIS(float bsdfPdf, float lightPdf, bool previousDelta)
{
    if (!GRIS_USE_NEE || previousDelta || !isfinite(lightPdf) || lightPdf <= 0.f) return 1.f;
    // Without MIS, NEE owns sampleable lights after non-delta scattering.
    return GRIS_USE_MIS ? balanceWeight(bsdfPdf, lightPdf) : 0.f;
}

PathBuilder tracePathTree(PrimaryPathContext primary, uint seed, uint maxScatters, float rrProbability)
{
    PathBuilder builder = PathBuilder(seed);
    SampleGenerator sg = SampleGenerator(seed);
    HitInfo hit = HitInfo(primary.hit);
    float3 direction = primary.direction;
    float3 throughput = 1.f;
    float3 suffix = 1.f;
    float3 previousPosition = 0.f;
    float3 previousNormal = 0.f;
    float previousPdf = 0.f;
    bool previousDelta = true;
    bool previousTransmission = false;
    SceneRayQuery<true> query;

    // Like the reference TracePass: complete each path in one dispatch, including
    // emission/miss at the last depth BEFORE the depth-termination check.
    for (uint depth = 0; depth <= maxScatters; ++depth)
    {
        builder.descriptor.flags = (previousDelta ? 1u : 0u) | (previousTransmission ? 2u : 0u);
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
            builder.add(throughput * emission * mis, suffix * emission * mis, depth,
                PathTerminal::Environment, PathLight::Environment, sg.rng.state, lightPdf, direction, false);
            break;
        }

        ShadingData sd = loadShadingData(hit, direction);
        let mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        bool atRc = depth == 1;
        if (atRc)
        {
            builder.descriptor.rcHit = hit.pack();
            builder.descriptor.rcIndex = 1;
            builder.descriptor.rcPrefix = throughput;
            suffix = 1.f;
        }

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
        builder.add(throughput * emission * emissionMIS, suffix * emission * (atRc ? 1.f : emissionMIS), depth,
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
                float3 local = mi.eval(sd, ls.dir, sg) * Li;
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
                float mis = GRIS_USE_MIS ? balanceWeight(ls.pdf, mi.evalPdf(sd, ls.dir, bool(USE_IMPORTANCE_SAMPLING))) : 1.f;
                float3 local = mi.eval(sd, ls.dir, sg) * ls.Le * (mis / ls.pdf);
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
                float mis = GRIS_USE_MIS ? balanceWeight(ls.pdf, mi.evalPdf(sd, ls.dir, bool(USE_IMPORTANCE_SAMPLING))) : 1.f;
                float3 local = mi.eval(sd, ls.dir, sg) * ls.Le * (mis / ls.pdf);
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
            if (depth > 1) suffix /= 1.f - rrProbability;
        }
        if (!sampleMyPTBSDF(sd, mi, sg, bs, bool(USE_IMPORTANCE_SAMPLING))) break;
        throughput *= bs.weight;
        if (any(!isfinite(throughput))) { builder.reservoir.invalidCount++; break; }
        if (!any(throughput > 0.f)) break;
        if (atRc)
        {
            builder.descriptor.rcSeed = sg.rng.state;
            builder.descriptor.rcWi = bs.wo;
            suffix = rrProbability > 0.f ? 1.f / (1.f - rrProbability) : 1.f;
            // Exclude the rc BSDF but retain its RR survival reciprocal.
        }
        else if (depth > 1) suffix *= bs.weight;
        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        previousPdf = bs.pdf;
        previousDelta = bs.isLobe(LobeType::Delta);
        previousTransmission = bs.isLobe(LobeType::Transmission);
        direction = bs.wo;
        float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, direction) >= 0.f ? sd.faceN : -sd.faceN);
        float hitT;
        hit = query.traceRay(Ray(origin, direction, 0.f, 1e30f), hitT);
    }
    builder.finalize();
    return builder;
}
