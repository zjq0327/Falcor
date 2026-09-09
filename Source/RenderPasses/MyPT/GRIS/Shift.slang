// Pure reconnection, following ReSTIRPTPass/Shift.slang::computeShiftedIntegrandReconnection.
// surfaceScatters counts the terminal connection (reference pathLength counts one less).
import PathTracer;
import RenderPasses.MyPT.MyPTCommon;
import Utils.Geometry.GeometryHelpers;
import Scene.RaytracingInline;
__exported import PathReservoir;

bool supportsReconnection(PathSample sample)
{
    // The defensive canonical proposal retains these local-only contributions.
    return sample.surfaceScatters >= 2 && sample.rcIndex == 1 && HitInfo(sample.rcHit).isValid() &&
        ((sample.rcBeforeFlags | sample.rcAfterFlags) & 13u) == 0;
}

struct ShiftResult
{
    PathSample sample;
    float jacobian;
    uint failure;
};

bool positiveFinite(float value) { return value > 0.f && isfinite(value); }

ShiftResult reconnectPath(PathSample source, ShadingData sourcePrimary, ShadingData destination, bool samePixel = false)
{
    ShiftResult result = {};
    if (!supportsReconnection(source) || !any(source.F > 0.f)) return result;
    if (gScene.materials.getMaterialType(destination.materialID) != MaterialType::Standard) return result;

    bool transmission = (source.rcBeforeFlags & 2u) != 0;
    float3 origin = computeRayOrigin(destination.posW,
        transmission ? -destination.getOrientedFaceNormal() : destination.getOrientedFaceNormal());
    HitInfo rcHit = HitInfo(source.rcHit);
    float3 rcPosition = gScene.getVertexData(rcHit.getTriangleHit()).posW;
    float3 edge = rcPosition - origin;
    float distance2 = dot(edge, edge);
    if (!positiveFinite(distance2)) { result.failure = 1; return result; }
    float3 connection = edge * rsqrt(distance2);
    float3 sourceOrigin = computeRayOrigin(sourcePrimary.posW,
        transmission ? -sourcePrimary.getOrientedFaceNormal() : sourcePrimary.getOrientedFaceNormal());
    float3 sourceEdge = rcPosition - sourceOrigin;
    float sourceDistance2 = dot(sourceEdge, sourceEdge);
    if (!positiveFinite(sourceDistance2)) return result;
    float3 sourceConnection = sourceEdge * rsqrt(sourceDistance2);
    // Preserve the discrete reflection/transmission event so reverse mapping has the same support.
    if ((dot(destination.getOrientedFaceNormal(), connection) < 0.f) != transmission) { result.failure = 2; return result; }

    ShadingData rc = loadShadingData(rcHit, connection);
    let primaryMaterial = gScene.materials.getMaterialInstance(destination, ExplicitLodTextureSampler(0.f));
    let rcMaterial = gScene.materials.getMaterialInstance(rc, ExplicitLodTextureSampler(0.f));
    ShadingData sourceRc = loadShadingData(rcHit, sourceConnection);
    let sourceFirstMaterial = gScene.materials.getMaterialInstance(sourcePrimary, ExplicitLodTextureSampler(0.f));
    float geometry = abs(dot(rc.faceN, -connection)) / distance2;
    float sourceGeometry = abs(dot(sourceRc.faceN, -sourceConnection)) / sourceDistance2;
    float sourceP1 = evalMyPTBSDFPdf(sourcePrimary, sourceFirstMaterial, sourceConnection, bool(USE_IMPORTANCE_SAMPLING));
    float p1 = evalMyPTBSDFPdf(destination, primaryMaterial, connection, bool(USE_IMPORTANCE_SAMPLING));
    if (!positiveFinite(geometry) || !positiveFinite(p1) ||
        !positiveFinite(sourceP1) || !positiveFinite(sourceGeometry)) { result.failure = 3; return result; }
    // Like the reference pure-reconnection branch, evaluate the source in the same
    // geometric parameterization. Cached values are updated for later shift strategies.
    float logJacobian = log2(geometry) - log2(sourceGeometry) + log2(p1) - log2(sourceP1);
    SampleGenerator evaluation = SampleGenerator(source.rcSeed);
    float3 first = primaryMaterial.eval(destination, connection, evaluation) / p1;

    bool neeAtRc = source.terminal == PathTerminal::NEE && source.surfaceScatters == 2;
    bool hitAfterRc = source.terminal != PathTerminal::NEE && source.surfaceScatters == 2;
    float p2 = evalMyPTBSDFPdf(rc, rcMaterial, source.rcWi, bool(USE_IMPORTANCE_SAMPLING));
    float denominator = neeAtRc ? source.lightPdf : p2;
    if (!positiveFinite(denominator)) { result.failure = 4; return result; }
    if (!neeAtRc)
    {
        let sourceRcMaterial = gScene.materials.getMaterialInstance(sourceRc, ExplicitLodTextureSampler(0.f));
        float sourceP2 = evalMyPTBSDFPdf(sourceRc, sourceRcMaterial, source.rcWi, bool(USE_IMPORTANCE_SAMPLING));
        if (!positiveFinite(sourceP2)) { result.failure = 5; return result; }
        bool rcTransmission = (source.rcAfterFlags & 2u) != 0;
        if ((dot(rc.getOrientedFaceNormal(), source.rcWi) < 0.f) != rcTransmission) { result.failure = 6; return result; }
        logJacobian += log2(p2) - log2(sourceP2);
    }
    float3 second = rcMaterial.eval(rc, source.rcWi, evaluation) / denominator;
    float mis = 1.f;
    if (neeAtRc && source.light != PathLight::Analytic && GRIS_USE_MIS)
        mis = balanceWeight(source.lightPdf, p2);
    else if (hitAfterRc)
        mis = hitMIS(p2, source.lightPdf, false);

    float3 F = first * second * source.rcIrradiance * mis;
    // The identity map has analytic J=1. Still reconstruct F for consistency checks;
    // do not divide separately optimized, ill-conditioned PDFs at the same context.
    if (samePixel) logJacobian = 0.f;
    // Reference rejectShiftBasedOnJacobian with jacobianRejectionThreshold=10.
    // Restrict BOTH directions symmetrically; the canonical proposal retains rejected paths.
    // This avoids ill-conditioned near-critical transmission PDFs in this Falcor version.
    // Log ratios also avoid overflow in intermediate PDF/geometry quotients.
    // Include a small relative comparison tolerance at the boundary: e.g. a true
    // J=1/11 may round to an inverse just above 11 in the backward evaluation.
    if (!isfinite(logJacobian) || abs(logJacobian) > log2(11.f * (1.f + 1e-5f))) { result.failure = 7; return result; }
    float jacobian = exp2(logJacobian);
    if (!positiveFinite(jacobian) || any(!isfinite(F)) || any(F < 0.f) || !any(F > 0.f)) { result.failure = 7; return result; }
    if (!reconnectionVisible(origin, rc, connection)) { result.failure = 8; return result; }
    result.sample = source;
    result.sample.F = F;
    result.sample.rcPrefix = first;
    result.sample.cachedJacobian = float3(p1, p2, geometry);
    result.jacobian = jacobian;
    return result;
}

float relativeContributionError(float3 a, float3 b)
{
    return max(max(abs(a.x - b.x), abs(a.y - b.y)), abs(a.z - b.z)) /
        max(max(max(abs(b.x), abs(b.y)), abs(b.z)), 1e-8f);
}
