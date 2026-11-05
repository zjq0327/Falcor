#include "RTPTGRISTypes.slang"
#include "RTPTGRISSupport.slang"

StructuredBuffer<GrisSpatialRecord> gGRISSpatialInput;
#ifndef RTPT_GRIS_TEMPORAL_PASS
RWStructuredBuffer<GrisSpatialRecord> gGRISSpatialOutput;
#endif

float rtptGrisTarget(float3 F)
{
    return dot(abs(F), float3(0.2126f, 0.7152f, 0.0722f));
}

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
bool rtptGrisLoadRoot(RTPTPrimarySurface primary, uint frameStamp, out ShadingData sd)
{
    sd = {};
    if ((primary.flags & kRTPTPrimaryRecordReady) == 0u ||
        primary.frameStamp != frameStamp) return false;
    const HitInfo hit = HitInfo(primary.packedHit);
    if (hit.getType() != HitType::Triangle) return false;
    const TriangleHit triangle = hit.getTriangleHit();
    const uint material = gScene.getMaterialID(triangle.instanceID);
    sd = gScene.materials.prepareShadingData(gScene.getVertexData(triangle), material, -primary.rayDirection);
    sd.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance instance = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    return rtptGRISSupportsSurface(sd, instance.getLobeTypes(sd));
}

bool rtptGrisLoadRoot(RTPTPrimarySurface primary, out ShadingData sd)
{
    sd = {};
    if (primary.sampleIndex != gPrimarySettings.sampleIndex) return false;
    return rtptGrisLoadRoot(primary, gPrimarySettings.frameStamp, sd);
}

#if ENABLE_SHARC && SHARC_QUERY
bool rtptGrisQueryFirstVertexCache(ShadingData root, IMaterialInstance rootMaterial,
    ShadingData vertex, IMaterialInstance vertexMaterial, bool diffuse, out float3 radiance)
{
    RTPTSharcStats unusedStats = {};
    return rtptTrySharcQuery(vertex, vertexMaterial, vertexMaterial.getProperties(vertex),
        1u, false, false, diffuse, rootMaterial.getProperties(root).roughness,
        length(vertex.posW - root.posW), unusedStats, radiance);
}
#endif

bool rtptGrisEvaluateShift(GrisSpatialRecord path, ShadingData src, ShadingData dst, bool reevalPGSource,
    inout SampleGenerator rng, out float3 F, out float J, out float hitT, out float3 sourceF)
{
    F = 0.f;
    J = 0.f;
    hitT = 0.f;
    sourceF = path.candidate.F;
    if (!path.candidate.hasWinner || path.reconnectCase == uint(GrisReconnectCase::CanonicalOnly)) return false;
#ifdef RTPT_GRIS_TEMPORAL_PASS
#if RTPT_REGIR_ONLY
    if (path.reconnectCase != uint(GrisReconnectCase::CacheAtX1) &&
        path.reconnectCase != uint(GrisReconnectCase::ReGIRAtX1)) return false;
#elif ENABLE_SHARC && SHARC_QUERY
    if (gSharcSettings.useCache != 0u && path.reconnectCase != uint(GrisReconnectCase::CacheAtX1)) return false;
#endif
#endif
    const uint rootLobe = path.candidate.rootLobe;
    if (rootLobe != uint(GrisRootComponent::GrisDiffuse) && rootLobe != uint(GrisRootComponent::GrisSpecular)) return false;
    const uint rootMask = rootLobe == uint(GrisRootComponent::GrisDiffuse)
        ? uint(LobeType::DiffuseReflection) : uint(LobeType::SpecularReflection);
    const uint srcRootLobes = gScene.materials.getMaterialInstance(src, ExplicitLodTextureSampler(0.f)).getLobeTypes(src);
    const uint dstRootLobes = gScene.materials.getMaterialInstance(dst, ExplicitLodTextureSampler(0.f)).getLobeTypes(dst);
    if ((srcRootLobes & dstRootLobes & rootMask) == 0u) return false;
    // The current mapping preserves the root selection interval size.
    const uint reflectionMask = uint(LobeType::DiffuseReflection) | uint(LobeType::SpecularReflection);
    const bool srcMixed = (srcRootLobes & reflectionMask) == reflectionMask;
    const bool dstMixed = (dstRootLobes & reflectionMask) == reflectionMask;
    if (srcMixed != dstMixed) return false;
    const float rootProbability = dstMixed ? 0.5f : 1.f;
    src.mtl.setActiveLobes(rootMask);
    dst.mtl.setActiveLobes(rootMask);

    const HitInfo hit = HitInfo(path.reconnectHit);
    if (hit.getType() != HitType::Triangle) return false;
    const TriangleHit triangle = hit.getTriangleHit();
    const VertexData vertex = gScene.getVertexData(triangle);
    const uint material = gScene.getMaterialID(triangle.instanceID);
    const float3 dstOrigin = dst.computeRayOrigin();
    const float3 srcEdge = vertex.posW - src.computeRayOrigin();
    const float3 dstEdge = vertex.posW - dstOrigin;
    const float srcR2 = dot(srcEdge, srcEdge);
    const float dstR2 = dot(dstEdge, dstEdge);
    if (!(srcR2 > 0.f && dstR2 > 0.f)) return false;
    const float3 srcDir = srcEdge * rsqrt(srcR2);
    const float3 dstDir = dstEdge * rsqrt(dstR2);
    ShadingData srcHit = gScene.materials.prepareShadingData(vertex, material, -srcDir);
    ShadingData dstHit = gScene.materials.prepareShadingData(vertex, material, -dstDir);
    srcHit.mtl.setActiveLobes(uint(LobeType::Reflection));
    dstHit.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance srcSuffix = gScene.materials.getMaterialInstance(srcHit, ExplicitLodTextureSampler(0.f));
    const IMaterialInstance dstSuffix = gScene.materials.getMaterialInstance(dstHit, ExplicitLodTextureSampler(0.f));
    if (!rtptGRISSupportsSurface(srcHit, srcSuffix.getLobeTypes(srcHit)) ||
        !rtptGRISSupportsSurface(dstHit, dstSuffix.getLobeTypes(dstHit))) return false;
    const float srcG = abs(dot(srcHit.faceN, srcDir)) / srcR2;
    const float dstG = abs(dot(dstHit.faceN, dstDir)) / dstR2;
    const IMaterialInstance srcRoot = gScene.materials.getMaterialInstance(src, ExplicitLodTextureSampler(0.f));
    const IMaterialInstance dstRoot = gScene.materials.getMaterialInstance(dst, ExplicitLodTextureSampler(0.f));
    RTPTSamplingContext srcSampling = rtptBSDFSamplingContext();
    RTPTSamplingContext dstSampling = rtptBSDFSamplingContext();
#if ENABLE_PG
    if (rootLobe == uint(GrisRootComponent::GrisDiffuse))
    {
        srcSampling = rtptMakeSamplingContext(src, srcRoot);
        dstSampling = rtptMakeSamplingContext(dst, dstRoot);
    }
#endif
    float srcRootBsdfPdf, srcRootGuidePdf, dstRootBsdfPdf, dstRootGuidePdf;
    const float srcRootPdf = rtptContinuationPdf(src, srcRoot, srcSampling, srcDir, srcRootBsdfPdf, srcRootGuidePdf);
    const float dstRootPdf = rtptContinuationPdf(dst, dstRoot, dstSampling, dstDir, dstRootBsdfPdf, dstRootGuidePdf);
    if (!(srcG > 0.f && dstG > 0.f && srcRootPdf > 0.f && dstRootPdf > 0.f)) return false;

    float rootProposalRatio = dstRootPdf / srcRootPdf;
#if ENABLE_SHARC && SHARC_QUERY
    const bool cacheAtX1 = path.reconnectCase == uint(GrisReconnectCase::CacheAtX1);
    float3 dstCachedRadiance = 0.f;
    if (gSharcSettings.useCache != 0u)
    {
        // Cache eligibility depends on the actual branch. Preserve it in the
        // shift, but keep the mixture PDF in the path's throughput below.
        const bool guide = path.rootGuideSelected;
        const float srcBranchPdf = guide ? srcSampling.alpha * srcRootGuidePdf : (1.f - srcSampling.alpha) * srcRootBsdfPdf;
        const float dstBranchPdf = guide ? dstSampling.alpha * dstRootGuidePdf : (1.f - dstSampling.alpha) * dstRootBsdfPdf;
        if (!(srcBranchPdf > 0.f && dstBranchPdf > 0.f)) return false;
        rootProposalRatio = dstBranchPdf / srcBranchPdf;

        if (guide)
        {
            if (cacheAtX1) return false;
        }
        else
        {
            const bool diffuse = rootMask == uint(LobeType::DiffuseReflection);
            float3 srcCachedRadiance;
            // Both roots must agree with the recorded termination decision.
            if (rtptGrisQueryFirstVertexCache(src, srcRoot, srcHit, srcSuffix, diffuse, srcCachedRadiance) != cacheAtX1 ||
                rtptGrisQueryFirstVertexCache(dst, dstRoot, dstHit, dstSuffix, diffuse, dstCachedRadiance) != cacheAtX1)
                return false;
#ifdef RTPT_GRIS_TEMPORAL_PASS
            // Re-evaluate the historical proxy in the current model. The
            // reservoir's carried UCW still came from the previous frame.
            if (cacheAtX1)
            {
                sourceF = srcRoot.eval(src, srcDir, rng) * srcCachedRadiance / (srcRootPdf * rootProbability);
                if (!all(isfinite(sourceF)) || !(rtptGrisTarget(sourceF) > 0.f)) return false;
            }
#endif
        }
    }
#endif

    float jacobian = (dstG / srcG) * rootProposalRatio;
    const float3 suffixDir = path.suffixDirection;
#if defined(RTPT_GRIS_TEMPORAL_PASS) && ENABLE_PG && !RTPT_REGIR_ONLY
    const bool reevalSource = reevalPGSource && path.reconnectCase != uint(GrisReconnectCase::CacheAtX1);
#else
    const bool reevalSource = false;
#endif
    SampleGenerator sourceRng = rng;
    float3 sourceC = 0.f;
    float3 C;
#if ENABLE_SHARC && SHARC_QUERY
    if (cacheAtX1)
    {
        if (gSharcSettings.useCache == 0u) return false;
        C = dstCachedRadiance;
    }
    else
#endif
#if RTPT_REGIR_ONLY
    if (path.reconnectCase == uint(GrisReconnectCase::ReGIRAtX1))
    {
        if (gParams.useNEE == 0u || rtptReGIRTransportCoverage(false) == 0u) return false;
        RTPTLightSample light;
        if (!rtptReGIRRebuildTransportSample(dstHit, path.suffixLobe, path.suffixDirection.xy, path.suffixLight.x, light) ||
            !(dot(srcHit.getOrientedFaceNormal(), light.dir) > 0.f)) return false;
        // The fixed x1 keeps the light sample and its carried RIS weight.
        // Spatial can use the original visibility; Temporal checks it again.
#ifdef RTPT_GRIS_TEMPORAL_PASS
        SceneRayQuery<true> shadowQuery;
        if (!shadowQuery.traceVisibilityRay(light.visibilityRay)) return false;
        const float3 sourceC = srcSuffix.eval(srcHit, light.dir, rng) * light.LiOverPdf;
        sourceF = srcRoot.eval(src, srcDir, rng) * sourceC / (srcRootPdf * rootProbability);
        if (!all(isfinite(sourceF)) || !(rtptGrisTarget(sourceF) > 0.f)) return false;
#endif
        C = dstSuffix.eval(dstHit, light.dir, rng) * light.LiOverPdf;
    }
    else
#endif
    if (path.reconnectCase == uint(GrisReconnectCase::NeeAtX1))
    {
        const RTPTSamplingContext dstSuffixSampling = rtptMakeSamplingContext(dstHit, dstSuffix);
        const float dstSuffixPdf = rtptContinuationPdf(dstHit, dstSuffix, dstSuffixSampling, suffixDir);
        C = dstSuffix.eval(dstHit, suffixDir, rng) * path.suffixLight;
        if (!path.lightIsAnalytic) C *= rtptPowerHeuristic(path.lightPdf, dstSuffixPdf);
        if (reevalSource)
        {
            sourceC = srcSuffix.eval(srcHit, suffixDir, sourceRng) * path.suffixLight;
            if (!path.lightIsAnalytic)
            {
                const RTPTSamplingContext srcSuffixSampling = rtptMakeSamplingContext(srcHit, srcSuffix);
                const float srcSuffixPdf = rtptContinuationPdf(srcHit, srcSuffix, srcSuffixSampling, suffixDir);
                sourceC *= rtptPowerHeuristic(path.lightPdf, srcSuffixPdf);
            }
        }
    }
    else if (path.reconnectCase == uint(GrisReconnectCase::BsdfHitLightAfterX1) ||
             path.reconnectCase == uint(GrisReconnectCase::PgHitLightAfterX1))
    {
        const RTPTSamplingContext dstSuffixSampling = rtptMakeSamplingContext(dstHit, dstSuffix);
        float dstBsdfPdf, dstGuidePdf;
        const float dstSuffixPdf = rtptContinuationPdf(dstHit, dstSuffix, dstSuffixSampling, suffixDir, dstBsdfPdf, dstGuidePdf);
        if (!(dstSuffixPdf > 0.f) || !isfinite(dstSuffixPdf)) return false;
        const RTPTSamplingContext srcSuffixSampling = rtptMakeSamplingContext(srcHit, srcSuffix);
        float srcBsdfPdf = 0.f;
        float srcGuidePdf = 0.f;
        float srcSuffixPdf = 0.f;
        if (reevalSource)
        {
            srcSuffixPdf = rtptContinuationPdf(srcHit, srcSuffix, srcSuffixSampling, suffixDir, srcBsdfPdf, srcGuidePdf);
            if (!(srcSuffixPdf > 0.f) || !isfinite(srcSuffixPdf)) return false;
        }
        float srcBranchPdf, dstBranchPdf;
#if ENABLE_PG
        if (path.reconnectCase == uint(GrisReconnectCase::PgHitLightAfterX1))
        {
            if (!(srcSuffixSampling.alpha > 0.f && dstSuffixSampling.alpha > 0.f)) return false;
            srcBranchPdf = srcSuffixSampling.alpha *
                (reevalSource ? srcGuidePdf : rtptPGGuidePdf(srcSuffixSampling.guide, suffixDir));
            dstBranchPdf = dstSuffixSampling.alpha * dstGuidePdf;
            C = (dstSuffix.eval(dstHit, suffixDir, rng) / dstSuffixPdf) * path.suffixLight;
            if (reevalSource) sourceC = (srcSuffix.eval(srcHit, suffixDir, sourceRng) / srcSuffixPdf) * path.suffixLight;
        }
        else
#endif
        {
            if (path.reconnectCase != uint(GrisReconnectCase::BsdfHitLightAfterX1)) return false;
            float3 srcB = 0.f;
            float3 dstB;
            float srcJointPdf;
            float dstJointPdf;
            if (dstHit.mtl.getMaterialType() == MaterialType::Standard)
            {
                if (!srcSuffix.evalReflectionLobe(srcHit, suffixDir, path.suffixLobe, rng, srcB, srcJointPdf)) return false;
                if (!dstSuffix.evalReflectionLobe(dstHit, suffixDir, path.suffixLobe, rng, dstB, dstJointPdf)) return false;
            }
            else
            {
                if (path.suffixLobe != uint(LobeType::DiffuseReflection)) return false;
                srcJointPdf = reevalSource ? srcBsdfPdf : srcSuffix.evalPdf(srcHit, suffixDir);
                dstJointPdf = dstBsdfPdf;
                dstB = dstSuffix.eval(dstHit, suffixDir, rng);
                if (reevalSource) srcB = srcSuffix.eval(srcHit, suffixDir, sourceRng);
            }
            if (!(srcJointPdf > 0.f && dstJointPdf > 0.f)) return false;
            srcBranchPdf = (1.f - srcSuffixSampling.alpha) * srcJointPdf;
            dstBranchPdf = (1.f - dstSuffixSampling.alpha) * dstJointPdf;
            C = dstB * path.suffixLight / dstJointPdf;
            if (dstSuffixSampling.alpha > 0.f) C *= dstBsdfPdf / dstSuffixPdf;
            if (reevalSource)
            {
                sourceC = srcB * path.suffixLight / srcJointPdf;
                if (srcSuffixSampling.alpha > 0.f) sourceC *= srcBsdfPdf / srcSuffixPdf;
            }
        }
        if (!(srcBranchPdf > 0.f && dstBranchPdf > 0.f)) return false;
        jacobian *= dstBranchPdf / srcBranchPdf;
        if (path.hadNeeCompetitor)
        {
            C *= rtptPowerHeuristic(dstSuffixPdf, path.lightPdf);
            if (reevalSource) sourceC *= rtptPowerHeuristic(srcSuffixPdf, path.lightPdf);
        }
    }
    else return false;

    const float3 targetF = dstRoot.eval(dst, dstDir, rng) * C / (dstRootPdf * rootProbability);
    if (!(jacobian > 0.f) || !isfinite(jacobian) || !all(isfinite(targetF))) return false;
    if (!(rtptGrisTarget(targetF) > 0.f)) return false;
    if (reevalSource)
    {
        // Use the current source contribution for MIS, carrying the historical UCW.
        sourceF = srcRoot.eval(src, srcDir, sourceRng) * sourceC / (srcRootPdf * rootProbability);
        if (!all(isfinite(sourceF)) || !(rtptGrisTarget(sourceF) > 0.f)) return false;
    }

    const float3 visibilityEdge = dstHit.computeRayOrigin() - dstOrigin;
    const float visibilityLength = length(visibilityEdge);
    if (!(visibilityLength > 0.f)) return false;
    SceneRayQuery<true> query;
    if (!query.traceVisibilityRay(Ray(dstOrigin, visibilityEdge / visibilityLength, 0.f, visibilityLength))) return false;

    J = jacobian;
    F = targetF;
    hitT = min(kRTPTNRDMissDistance, max(1e-5f, length(dstHit.posW - dst.posW)));
    return true;
}

GrisSpatialRecord rtptGrisMerge(GrisSpatialRecord canonical, GrisSpatialRecord other,
    ShadingData dst, ShadingData src, inout SampleGenerator rng)
{
    float3 reverseF;
    float reverseJ;
    float unusedReverseHitT;
    float3 unusedReverseSourceF;
    const float canonicalH = rtptGrisTarget(canonical.candidate.F);
    float canonicalMis = 1.f;
    if (canonicalH > 0.f && rtptGrisEvaluateShift(canonical, dst, src, false, rng, reverseF, reverseJ, unusedReverseHitT, unusedReverseSourceF))
    {
        const float canonicalProxy = canonical.M * canonicalH;
        const float otherProxy = other.M * rtptGrisTarget(reverseF) * reverseJ;
        canonicalMis = canonicalProxy / (canonicalProxy + otherProxy);
    }
    const float canonicalWeight = canonicalMis * canonicalH * canonical.candidate.W;

    float3 shiftedF;
    float3 shiftedSourceF;
    float J;
    float shiftedHitT;
    float otherWeight = 0.f;
    if (rtptGrisEvaluateShift(other, src, dst, true, rng, shiftedF, J, shiftedHitT, shiftedSourceF))
    {
        const float otherProxy = other.M * rtptGrisTarget(shiftedSourceF) / J;
        const float shiftedH = rtptGrisTarget(shiftedF);
        const float otherMis = otherProxy / (canonical.M * shiftedH + otherProxy);
        otherWeight = otherMis * shiftedH * other.candidate.W * J;
    }

    const float weightSum = canonicalWeight + otherWeight;
    if (!isfinite(weightSum) || weightSum < 0.f) return canonical;
    const float mergedM = canonical.M + other.M;
    if (weightSum == 0.f)
    {
        // A valid zero still represents both inputs. Dropping its confidence
        // would make the next frame's MIS favor histories with positive samples.
        canonical.M = mergedM;
        return canonical;
    }
    GrisSpatialRecord winner = canonical;
    if (sampleNext1D(rng) * weightSum < otherWeight)
    {
        winner = other;
        winner.candidate.F = shiftedF;
        winner.candidate.firstHit.hitT = shiftedHitT;
        winner.candidate.firstHit.distanceState = kRTPTDistanceHit;
    }
    winner.candidate.W = weightSum / rtptGrisTarget(winner.candidate.F);
    if (!isfinite(winner.candidate.W) || !all(isfinite(winner.candidate.F * winner.candidate.W))) return canonical;
    winner.M = mergedM;
    return winner;
}
#endif

#ifndef RTPT_GRIS_TEMPORAL_PASS
[numthreads(8, 8, 1)]
void main(uint3 threadID : SV_DispatchThreadID)
{
    const uint2 pixel = threadID.xy;
    if (any(pixel >= gParams.frameDim)) return;
    const uint index = pixel.y * gParams.frameDim.x + pixel.x;
    const GrisSpatialRecord canonical = gGRISSpatialInput[index];
    GrisSpatialRecord result = canonical;

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (canonical.candidate.prepared && gPrimarySettings.prepared != 0u && gParams.frameDim.x > 1u)
    {
        // Fixed adjacent pairs, independent of both reservoirs and their radiance.
        const uint neighborX = pixel.x ^ 1u;
        if (neighborX < gParams.frameDim.x)
        {
            const uint neighborIndex = pixel.y * gParams.frameDim.x + neighborX;
            const GrisSpatialRecord neighbor = gGRISSpatialInput[neighborIndex];
            ShadingData dst;
            ShadingData src;
            if (neighbor.candidate.prepared &&
                rtptGrisLoadRoot(gPrimarySurfaces[index], dst) && rtptGrisLoadRoot(gPrimarySurfaces[neighborIndex], src))
            {
                SampleGenerator rng = SampleGenerator(pixel, gPrimarySettings.sampleIndex ^ 0x76b5a2d1u);
                result = rtptGrisMerge(canonical, neighbor, dst, src, rng);
            }
        }
    }
#endif
    gGRISSpatialOutput[index] = result;
}
#endif
