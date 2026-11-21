#pragma once
#include "RTPTGRISTypes.slang"

#if RTPT_GRIS_SPATIAL
#if RTPT_GRIS_SEPARATE_OWNER
// Persistent payload. The owner of a working record is its pixel's primary surface.
struct GrisStoredRecord
{
    GrisCandidate candidate;
    PackedHitInfo sourceX1;
    PackedHitInfo reconnectHit;
    float areaPdf;
    float3 suffixDirection;
    float3 suffixLight;
    uint lightPdfOrIndex;
    uint4 dualExplicitRng;
};

GrisStoredRecord rtptGrisStoreRecord(GrisSpatialRecord src)
{
    GrisStoredRecord dst;
    dst.candidate = src.candidate;
    dst.sourceX1 = src.sourceX1;
    dst.reconnectHit = src.reconnectHit;
    dst.areaPdf = src.areaPdf;
    dst.suffixDirection = src.suffixDirection;
    dst.suffixLight = src.suffixLight;
    dst.lightPdfOrIndex = src.lightPdfOrIndex;
    dst.dualExplicitRng = src.dualExplicitRng;
    return dst;
}

#if RTPT_USE_PRIMARY_SURFACE
GrisSpatialRecord rtptGrisLoadCurrentRecord(GrisStoredRecord src, uint index)
{
    GrisSpatialRecord dst = {};
    dst.ownerPrimaryHit = gPrimarySurfaces[index].packedHit;
    dst.candidate = src.candidate;
    dst.sourceX1 = src.sourceX1;
    dst.reconnectHit = src.reconnectHit;
    dst.areaPdf = src.areaPdf;
    dst.suffixDirection = src.suffixDirection;
    dst.suffixLight = src.suffixLight;
    dst.lightPdfOrIndex = src.lightPdfOrIndex;
    dst.dualExplicitRng = src.dualExplicitRng;
    return dst;
}
#endif
#else
typedef GrisSpatialRecord GrisStoredRecord;
GrisSpatialRecord rtptGrisStoreRecord(GrisSpatialRecord src) { return src; }
GrisSpatialRecord rtptGrisLoadCurrentRecord(GrisStoredRecord src, uint index) { return src; }
#endif
#endif
