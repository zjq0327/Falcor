// Shift mappings following ReSTIRPTPass/Shift.slang. Hybrid uses material-level
// roughness classification (the reference's separatePathBSDF=false branch).
// surfaceScatters counts the terminal connection (reference pathLength counts one less).
import PathTracer;
import RenderPasses.MyPT.MyPTCommon;
import Utils.Geometry.GeometryHelpers;
import Scene.RaytracingInline;
__exported import PathReservoir;

// Shared diagnostic codes. PathTracer's replay helpers return the same numeric
// values without importing this module (which would introduce an import cycle).
static const uint kShiftSuccess = 0;
static const uint kShiftGeometry = 1;
static const uint kShiftBeforeEvent = 2;
static const uint kShiftBeforePDF = 3;
static const uint kShiftAfterDenominator = 4;
static const uint kShiftAfterSourcePDF = 5;
static const uint kShiftAfterEvent = 6;
static const uint kShiftNumeric = 7;
static const uint kShiftVisibility = 8;
static const uint kShiftUnsupported = 9;
static const uint kShiftDelta = 10;
static const uint kShiftReplayTerminated = 11;
static const uint kShiftEarlierReconnection = 12;
static const uint kShiftRoughness = 13;
static const uint kShiftNearField = 14;
static const uint kShiftPartition = 15;
static const uint kShiftTerminal = 16;
static const uint kShiftZeroContribution = 17;
static const uint kShiftPrimary = 18;
static const uint kShiftRandomDimensions = 19;

bool supportsReconnection(PathSample sample)
{
    // The defensive canonical proposal retains these local-only contributions.
    return sample.rcIndex >= 1 && sample.surfaceScatters > sample.rcIndex && HitInfo(sample.rcHit).isValid() &&
        ((sample.rcBeforeFlags | sample.rcAfterFlags) & 13u) == 0;
}

struct ShiftResult
{
    PathSample sample;
    float jacobian;
    uint failure;
};

bool positiveFinite(float value) { return value > 0.f && isfinite(value); }

ShiftResult failedShift(uint failure)
{
    ShiftResult result = {};
    result.failure = failure;
    return result;
}

bool validShiftContribution(float3 F)
{
    return all(isfinite(F)) && all(F >= 0.f) && any(F > 0.f);
}

// destination is the endpoint immediately before rc, which need not be a primary
// hit. prefix excludes its connection BSDF but includes its RR reciprocal.
// The wrappers below also store that endpoint's PackedHitInfo in the result.
ShiftResult reconnectPath(PathSample source, ShadingData sourcePrimary, ShadingData destination,
    bool samePixel = false, float3 prefix = float3(1.f))
{
    ShiftResult result = {};
    if (!validShiftContribution(source.F)) return failedShift(kShiftZeroContribution);
    if (((source.rcBeforeFlags | source.rcAfterFlags) & 1u) != 0) return failedShift(kShiftDelta);
    if (!supportsReconnection(source)) return failedShift(kShiftUnsupported);
    if (source.rcIndex > 1)
    {
        if (!HitInfo(source.rcPrevHit).isValid()) return failedShift(kShiftPrimary);
        sourcePrimary = loadShadingData(HitInfo(source.rcPrevHit), source.rcPrevDirection);
    }
    if (gScene.materials.getMaterialType(destination.materialID) != MaterialType::Standard ||
        gScene.materials.getMaterialType(sourcePrimary.materialID) != MaterialType::Standard)
        return failedShift(kShiftUnsupported);

    bool transmission = (source.rcBeforeFlags & 2u) != 0;
    float3 origin = computeRayOrigin(destination.posW,
        transmission ? -destination.getOrientedFaceNormal() : destination.getOrientedFaceNormal());
    float3 rcPosition = source.rcPositionW;
    float3 edge = rcPosition - origin;
    float distance2 = dot(edge, edge);
    if (!positiveFinite(distance2)) return failedShift(kShiftGeometry);
    float3 connection = edge * rsqrt(distance2);
    float3 sourceOrigin = computeRayOrigin(sourcePrimary.posW,
        transmission ? -sourcePrimary.getOrientedFaceNormal() : sourcePrimary.getOrientedFaceNormal());
    float3 sourceEdge = rcPosition - sourceOrigin;
    float sourceDistance2 = dot(sourceEdge, sourceEdge);
    if (!positiveFinite(sourceDistance2)) return failedShift(kShiftGeometry);
    float3 sourceConnection = sourceEdge * rsqrt(sourceDistance2);
    // Preserve the discrete reflection/transmission event so reverse mapping has the same support.
    if ((dot(destination.getOrientedFaceNormal(), connection) < 0.f) != transmission)
        return failedShift(kShiftBeforeEvent);

    ShadingData rc = loadRcShadingData(source, connection);
    if (gScene.materials.getMaterialType(rc.materialID) != MaterialType::Standard)
        return failedShift(kShiftUnsupported);
    let primaryMaterial = gScene.materials.getMaterialInstance(destination, ExplicitLodTextureSampler(0.f));
    let rcMaterial = gScene.materials.getMaterialInstance(rc, ExplicitLodTextureSampler(0.f));
    ShadingData sourceRc = loadRcShadingData(source, sourceConnection);
    let sourceFirstMaterial = gScene.materials.getMaterialInstance(sourcePrimary, ExplicitLodTextureSampler(0.f));
    float geometry = abs(dot(rc.faceN, -connection)) / distance2;
    float sourceGeometry = abs(dot(sourceRc.faceN, -sourceConnection)) / sourceDistance2;
    float sourceP1 = evalGRISBSDFPdf(sourcePrimary, sourceFirstMaterial, sourceConnection, bool(USE_IMPORTANCE_SAMPLING));
    float p1 = evalGRISBSDFPdf(destination, primaryMaterial, connection, bool(USE_IMPORTANCE_SAMPLING));
    if (!positiveFinite(geometry) || !positiveFinite(p1) ||
        !positiveFinite(sourceP1) || !positiveFinite(sourceGeometry)) return failedShift(kShiftBeforePDF);
    // Like the reference pure-reconnection branch, evaluate the source in the same
    // geometric parameterization. Cached values are updated for later shift strategies.
    // Pair each ratio before summing: reversing the map must negate each term
    // exactly, including at the symmetric Jacobian rejection boundary.
    float logJacobian = (log2(geometry) - log2(sourceGeometry)) + (log2(p1) - log2(sourceP1));
    SampleGenerator evaluation = SampleGenerator(source.rcSeed);
    float3 first = evalGRISBSDF(destination, primaryMaterial, connection, evaluation) / p1;

    bool neeAtRc = source.terminal == PathTerminal::NEE && source.surfaceScatters == source.rcIndex + 1;
    bool hitAfterRc = source.terminal != PathTerminal::NEE && source.surfaceScatters == source.rcIndex + 1;
    precise float p2 = evalGRISBSDFPdf(rc, rcMaterial, source.rcWi, bool(USE_IMPORTANCE_SAMPLING));
    float denominator = neeAtRc ? source.lightPdf : p2;
    if (!positiveFinite(denominator)) return failedShift(kShiftAfterDenominator);
    if (!neeAtRc)
    {
        let sourceRcMaterial = gScene.materials.getMaterialInstance(sourceRc, ExplicitLodTextureSampler(0.f));
        float sourceP2 = evalGRISBSDFPdf(sourceRc, sourceRcMaterial, source.rcWi, bool(USE_IMPORTANCE_SAMPLING));
        if (!positiveFinite(sourceP2)) return failedShift(kShiftAfterSourcePDF);
        bool rcTransmission = (source.rcAfterFlags & 2u) != 0;
        if ((dot(rc.getOrientedFaceNormal(), source.rcWi) < 0.f) != rcTransmission)
            return failedShift(kShiftAfterEvent);
        logJacobian += log2(p2) - log2(sourceP2);
    }
    precise float3 second = evalGRISBSDF(rc, rcMaterial, source.rcWi, evaluation) / denominator;
    float mis = 1.f;
    if (neeAtRc && source.light != PathLight::Analytic && GRIS_USE_MIS)
        mis = balanceWeight(source.lightPdf, p2);
    else if (hitAfterRc)
        mis = hitMIS(p2, source.lightPdf, false);

    float3 F = prefix * first * second * source.rcIrradiance * mis;
    // The identity map has analytic J=1. Still reconstruct F for consistency checks;
    // do not divide separately optimized, ill-conditioned PDFs at the same context.
    if (samePixel) logJacobian = 0.f;
    // Reference rejectShiftBasedOnJacobian with jacobianRejectionThreshold=10.
    // Restrict BOTH directions symmetrically; the canonical proposal retains rejected paths.
    // This avoids ill-conditioned near-critical transmission PDFs in this Falcor version.
    // Log ratios also avoid overflow in intermediate PDF/geometry quotients.
    // Include a small relative comparison tolerance at the boundary: e.g. a true
    // J=1/11 may round to an inverse just above 11 in the backward evaluation.
    if (!isfinite(logJacobian) || abs(logJacobian) > log2(11.f * (1.f + 1e-5f)))
        return failedShift(kShiftNumeric);
    float jacobian = exp2(logJacobian);
    if (!positiveFinite(jacobian) || !validShiftContribution(F))
        return failedShift(kShiftNumeric);
    if (!reconnectionVisible(origin, rc, connection)) return failedShift(kShiftVisibility);
    result.sample = source;
    result.sample.F = F;
    result.sample.rcPrefix = prefix * first;
    result.sample.rcPrevDirection = -destination.V;
    result.sample.cachedJacobian = float3(p1, p2, geometry);
    result.jacobian = jacobian;
    return result;
}

bool sameReplaySlot(PathSample source, PathTerminal terminal, PathLight light)
{
    if (source.terminal == PathTerminal::NEE) return terminal == PathTerminal::NEE && light == source.light;
    // BSDF arrival is one slot, whether that ray reaches a finite emitter or the
    // environment. NEE light families remain distinct independent proposals.
    bool sourceArrival = source.terminal == PathTerminal::Emission || source.terminal == PathTerminal::Environment;
    bool destinationArrival = terminal == PathTerminal::Emission || terminal == PathTerminal::Environment;
    return sourceArrival && destinationArrival;
}

ShiftResult replayPath(PathSample source, PrimaryPathContext destination, uint maxScatters, float rr)
{
    PathSample replayed = traceReplayContribution(destination, source, maxScatters, rr);
    if (replayed.surfaceScatters != source.surfaceScatters || !sameReplaySlot(source, replayed.terminal, replayed.light))
        return failedShift(kShiftTerminal);
    if (!validShiftContribution(replayed.F)) return failedShift(kShiftReplayTerminated);
    ShiftResult result = {};
    result.sample = replayed;
    result.sample.initialSeed = source.initialSeed;
    result.jacobian = 1.f;
    return result;
}

ShiftResult hybridPathCached(PathSample source, PrimaryPathContext sourcePrimary, PrimaryPathContext destinationPrimary,
    float roughnessThreshold, float nearFieldDistance, HybridPrefix prefix, bool identity = false)
{
    if (prefix.failure != kShiftSuccess) return failedShift(prefix.failure);
    if (!validShiftContribution(prefix.throughput)) return failedShift(kShiftReplayTerminated);

    if (source.rcIndex == 0xffffffffu)
    {
        // The tracer has verified that the destination remains in the no-rc
        // partition and has selected the identical terminal contribution slot.
        if (HitInfo(source.rcHit).isValid()) return failedShift(kShiftPartition);
        if (!sameReplaySlot(source, prefix.terminal, prefix.light)) return failedShift(kShiftTerminal);
        ShiftResult result = {};
        result.sample.initialSeed = source.initialSeed;
        result.sample.surfaceScatters = source.surfaceScatters;
        result.sample.terminal = prefix.terminal;
        result.sample.light = prefix.light;
        result.sample.F = prefix.throughput;
        result.sample.rcIndex = 0xffffffffu;
        result.sample.rcHit = HitInfo().pack();
        result.sample.rcPrevHit = HitInfo().pack();
        result.jacobian = 1.f;
        return result;
    }

    if (((source.rcBeforeFlags | source.rcAfterFlags) & 1u) != 0) return failedShift(kShiftDelta);
    if (!supportsReconnection(source) || (source.prefixFlags & 4u) != 0) return failedShift(kShiftUnsupported);
    // The unchanged replay prefix must consume the same random dimensions before
    // the connection is replaced; otherwise the local Jacobian is insufficient.
    if (source.rcPrevSeed != prefix.rngState) return failedShift(kShiftRandomDimensions);
    if (!HitInfo(sourcePrimary.hit).isValid() || !HitInfo(prefix.hit).isValid()) return failedShift(kShiftPrimary);
    ShadingData sourceSd = loadShadingData(HitInfo(sourcePrimary.hit), sourcePrimary.direction);
    ShadingData destinationSd = loadShadingData(HitInfo(prefix.hit), prefix.direction);
    ShadingData sourceEndpoint = sourceSd;
    if (source.rcIndex > 1)
    {
        if (!HitInfo(source.rcPrevHit).isValid()) return failedShift(kShiftPrimary);
        sourceEndpoint = loadShadingData(HitInfo(source.rcPrevHit), source.rcPrevDirection);
    }
    // Repeat the final connection conditions on both sides. Earlier candidate
    // vertices and the prefix's event sequence were checked by the retrace pass.
    if (!hybridRough(sourceEndpoint, roughnessThreshold) || !hybridRough(destinationSd, roughnessThreshold))
        return failedShift(kShiftRoughness);
    bool transmission = (source.rcBeforeFlags & 2u) != 0;
    float3 sourceOrigin = computeRayOrigin(sourceEndpoint.posW,
        transmission ? -sourceEndpoint.getOrientedFaceNormal() : sourceEndpoint.getOrientedFaceNormal());
    float3 destinationOrigin = computeRayOrigin(destinationSd.posW,
        transmission ? -destinationSd.getOrientedFaceNormal() : destinationSd.getOrientedFaceNormal());
    float3 rcPosition = source.rcPositionW;
    float sourceDistance = length(rcPosition - sourceOrigin);
    float destinationDistance = length(rcPosition - destinationOrigin);
    if (!positiveFinite(sourceDistance) || !positiveFinite(destinationDistance)) return failedShift(kShiftGeometry);
    if (sourceDistance < nearFieldDistance || destinationDistance < nearFieldDistance) return failedShift(kShiftNearField);
    ShadingData rcSource = loadRcShadingData(source, (rcPosition - sourceOrigin) / sourceDistance);
    ShadingData rcDestination = loadRcShadingData(source, (rcPosition - destinationOrigin) / destinationDistance);
    if (!hybridRough(rcSource, roughnessThreshold) || !hybridRough(rcDestination, roughnessThreshold))
        return failedShift(kShiftRoughness);

    ShiftResult result = reconnectPath(source, sourceSd, destinationSd, identity, prefix.throughput);
    if (result.jacobian > 0.f)
    {
        result.sample.rcPrevHit = prefix.hit;
        result.sample.rcPrevDirection = prefix.direction;
        result.sample.rcPrevSeed = prefix.rngState;
    }
    return result;
}

ShiftResult shiftPathCached(PathSample source, PrimaryPathContext sourcePrimary, PrimaryPathContext destinationPrimary,
    uint maxScatters, float rr, float roughnessThreshold, float nearFieldDistance, HybridPrefix prefix, bool identity = false)
{
    if (!validShiftContribution(source.F)) return failedShift(kShiftZeroContribution);
#if GRIS_SHIFT_STRATEGY == 0
    // Preserve the M3/M4 fixed-secondary strategy, even though the local kernel
    // also supports the more general endpoints supplied by Hybrid.
    if (source.rcIndex != 1) return failedShift(kShiftUnsupported);
    if (!HitInfo(sourcePrimary.hit).isValid() || !HitInfo(destinationPrimary.hit).isValid()) return failedShift(kShiftPrimary);
    ShadingData sourceSd = loadShadingData(HitInfo(sourcePrimary.hit), sourcePrimary.direction);
    ShadingData destinationSd = loadShadingData(HitInfo(destinationPrimary.hit), destinationPrimary.direction);
    ShiftResult result = reconnectPath(source, sourceSd, destinationSd, identity);
    if (result.jacobian > 0.f)
    {
        result.sample.rcPrevHit = destinationPrimary.hit;
        result.sample.rcPrevDirection = destinationPrimary.direction;
    }
    return result;
#elif GRIS_SHIFT_STRATEGY == 1
    return replayPath(source, destinationPrimary, maxScatters, rr);
#else
    return hybridPathCached(source, sourcePrimary, destinationPrimary, roughnessThreshold, nearFieldDistance, prefix, identity);
#endif
}

ShiftResult shiftPath(PathSample source, PrimaryPathContext sourcePrimary, PrimaryPathContext destinationPrimary,
    uint maxScatters, float rr, float roughnessThreshold, float nearFieldDistance, bool identity = false)
{
    if (!validShiftContribution(source.F)) return failedShift(kShiftZeroContribution);
    HybridPrefix prefix = {};
#if GRIS_SHIFT_STRATEGY == 2
    prefix = traceHybridPrefix(destinationPrimary, source, maxScatters, rr, roughnessThreshold, nearFieldDistance);
#endif
    return shiftPathCached(source, sourcePrimary, destinationPrimary, maxScatters, rr,
        roughnessThreshold, nearFieldDistance, prefix, identity);
}

float relativeContributionError(float3 a, float3 b)
{
    return max(max(abs(a.x - b.x), abs(a.y - b.y)), abs(a.z - b.z)) /
        max(max(max(abs(b.x), abs(b.y)), abs(b.z)), 1e-8f);
}
