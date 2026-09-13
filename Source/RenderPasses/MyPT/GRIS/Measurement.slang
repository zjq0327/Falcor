// Optional per-owner-pixel instrumentation. Each dispatch has one invocation per
// owner pixel; the host clears once per frame and inserts UAV barriers between
// passes. Spatial rounds accumulate. Typed uint4 UAVs do not support scalar
// InterlockedAdd, so updates use immediate load/modify/store with no shared owner.
#ifndef MYPT_HAS_RAY_STATS0
#define MYPT_HAS_RAY_STATS0 0
#endif
#ifndef MYPT_HAS_RAY_STATS1
#define MYPT_HAS_RAY_STATS1 0
#endif
#ifndef MYPT_HAS_RAY_STATS2
#define MYPT_HAS_RAY_STATS2 0
#endif
#ifndef MYPT_HAS_TEMPORAL_SHIFT_STATS
#define MYPT_HAS_TEMPORAL_SHIFT_STATS 0
#endif
#ifndef MYPT_HAS_SPATIAL_SHIFT_STATS
#define MYPT_HAS_SPATIAL_SHIFT_STATS 0
#endif

#define MYPT_HAS_MEASUREMENT (MYPT_HAS_RAY_STATS0 || MYPT_HAS_RAY_STATS1 || MYPT_HAS_RAY_STATS2 || MYPT_HAS_TEMPORAL_SHIFT_STATS || MYPT_HAS_SPATIAL_SHIFT_STATS)

#if MYPT_HAS_RAY_STATS0
RWTexture2D<uint4> gRayStats0; // generation closest/shadow, temporal-prefix closest/shadow.
#endif
#if MYPT_HAS_RAY_STATS1
RWTexture2D<uint4> gRayStats1; // temporal connection, spatial-prefix closest/shadow, spatial connection.
#endif
#if MYPT_HAS_RAY_STATS2
globallycoherent RWTexture2D<uint4> gRayStats2; // validation closest/shadow, ordinary PT closest/shadow.
#endif
#if MYPT_HAS_TEMPORAL_SHIFT_STATS
RWTexture2D<uint4> gTemporalShiftStats;
#endif
#if MYPT_HAS_SPATIAL_SHIFT_STATS
RWTexture2D<uint4> gSpatialShiftStats;
#endif

static const uint kMeasureGeneration = 0;
static const uint kMeasureTemporal = 1;
static const uint kMeasureSpatial = 2;
static const uint kMeasureValidation = 3;
static const uint kMeasurePT = 4;

#if MYPT_HAS_MEASUREMENT
static uint2 gMeasurementPixel;
static uint gMeasurementPhase;
#endif

void measurementInit(uint2 pixel, uint phase)
{
#if MYPT_HAS_MEASUREMENT
    gMeasurementPixel = pixel;
    gMeasurementPhase = phase;
#endif
}

uint measurementSetPhase(uint phase)
{
#if MYPT_HAS_MEASUREMENT
    uint previous = gMeasurementPhase;
    gMeasurementPhase = phase;
    return previous;
#else
    return 0;
#endif
}

#if MYPT_HAS_RAY_STATS0
void measurementAddRayStats0(uint4 delta)
{
    uint4 value = gRayStats0[gMeasurementPixel];
    gRayStats0[gMeasurementPixel] = value + delta;
}
#endif

#if MYPT_HAS_RAY_STATS1
void measurementAddRayStats1(uint4 delta)
{
    uint4 value = gRayStats1[gMeasurementPixel];
    gRayStats1[gMeasurementPixel] = value + delta;
}
#endif

#if MYPT_HAS_RAY_STATS2
void measurementAddRayStats2(uint4 delta)
{
    // PT raygen/closest-hit invocations share the owner. Complete each update
    // before another TraceRay call or return can hand that owner to a shader.
    // Never retain this uint4 across TraceRay, which may update another lane.
    // These barriers exist only in the optional PT instrumentation variant.
    if (gMeasurementPhase == kMeasurePT) DeviceMemoryBarrier();
    uint4 value = gRayStats2[gMeasurementPixel];
    gRayStats2[gMeasurementPixel] = value + delta;
    if (gMeasurementPhase == kMeasurePT) DeviceMemoryBarrier();
}
#endif

void measurementAddShiftStats(uint4 delta)
{
#if MYPT_HAS_TEMPORAL_SHIFT_STATS
    if (gMeasurementPhase == kMeasureTemporal)
    {
        uint4 value = gTemporalShiftStats[gMeasurementPixel];
        gTemporalShiftStats[gMeasurementPixel] = value + delta;
    }
#endif
#if MYPT_HAS_SPATIAL_SHIFT_STATS
    if (gMeasurementPhase == kMeasureSpatial)
    {
        uint4 value = gSpatialShiftStats[gMeasurementPixel];
        gSpatialShiftStats[gMeasurementPixel] = value + delta;
    }
#endif
}

void measurementScatterRay()
{
#if MYPT_HAS_RAY_STATS0
    if (gMeasurementPhase == kMeasureGeneration) measurementAddRayStats0(uint4(1u, 0u, 0u, 0u));
    if (gMeasurementPhase == kMeasureTemporal) measurementAddRayStats0(uint4(0u, 0u, 1u, 0u));
#endif
#if MYPT_HAS_RAY_STATS1
    if (gMeasurementPhase == kMeasureSpatial) measurementAddRayStats1(uint4(0u, 1u, 0u, 0u));
#endif
#if MYPT_HAS_RAY_STATS2
    if (gMeasurementPhase == kMeasureValidation) measurementAddRayStats2(uint4(1u, 0u, 0u, 0u));
    if (gMeasurementPhase == kMeasurePT) measurementAddRayStats2(uint4(0u, 0u, 1u, 0u));
#endif
}

void measurementShadowRay(bool connection = false)
{
#if MYPT_HAS_RAY_STATS0
    if (gMeasurementPhase == kMeasureGeneration) measurementAddRayStats0(uint4(0u, 1u, 0u, 0u));
    if (gMeasurementPhase == kMeasureTemporal && !connection) measurementAddRayStats0(uint4(0u, 0u, 0u, 1u));
#endif
#if MYPT_HAS_RAY_STATS1
    if (gMeasurementPhase == kMeasureTemporal && connection) measurementAddRayStats1(uint4(1u, 0u, 0u, 0u));
    if (gMeasurementPhase == kMeasureSpatial && !connection) measurementAddRayStats1(uint4(0u, 0u, 1u, 0u));
    if (gMeasurementPhase == kMeasureSpatial && connection) measurementAddRayStats1(uint4(0u, 0u, 0u, 1u));
#endif
#if MYPT_HAS_RAY_STATS2
    if (gMeasurementPhase == kMeasureValidation) measurementAddRayStats2(uint4(0u, 1u, 0u, 0u));
    if (gMeasurementPhase == kMeasurePT) measurementAddRayStats2(uint4(0u, 0u, 0u, 1u));
#endif
}

void measurementGeometryPair()
{
    measurementAddShiftStats(uint4(1u, 0u, 0u, 0u));
}

// Count each non-identity direction consumed by the algorithm once, including a
// cached prefix failure. Diagnostics, exact-context temporal copies and spatial
// self pairs do not call this function; their actual rays are still counted.
// Zero-source directions are outside the failure-rate denominator. Zero target
// support may have neither a failure nor positive contribution, so failed plus
// positive can be strictly less than attempts.
void measurementShiftOutcome(bool positiveSource, uint failure, bool positiveResult)
{
    if (!positiveSource) return;
    measurementAddShiftStats(uint4(0u, 1u, failure != 0 ? 1u : 0u, failure == 0 && positiveResult ? 1u : 0u));
}
