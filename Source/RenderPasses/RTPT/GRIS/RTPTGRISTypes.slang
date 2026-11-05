#pragma once
#include "../Signal/RTPTSignalTypes.slang"

#ifndef RTPT_GRIS_SPATIAL
#define RTPT_GRIS_SPATIAL 0
#endif
#if RTPT_GRIS_SPATIAL
import Scene.HitInfo;
#endif

enum GrisRootComponent : uint { GrisNoRoot, GrisDiffuse, GrisSpecular };
enum GrisTerminalKind : uint
{
    GrisNoTerminal,
    GrisNee,
    GrisEmitter,
    GrisEnvironment,
    GrisReGIR,
    GrisCacheTerminal,
};
enum GrisRecordState : uint { GrisUnprepared, GrisPreparedZero, GrisPreparedWinner };

struct GrisFirstHit
{
    float hitT;
    uint distanceState;
};

struct GrisCandidate
{
    float3 F;
    float W;
    uint rootLobe;
    uint terminalKind;
    bool prepared;
    bool hasWinner;
    GrisFirstHit firstHit;
};

#if RTPT_GRIS_SPATIAL
enum GrisReconnectCase : uint
{
    CanonicalOnly,
    NeeAtX1,
    BsdfHitLightAfterX1,
    PgHitLightAfterX1,
    ReGIRAtX1,
    CacheAtX1,
};

struct GrisSpatialRecord
{
    GrisCandidate candidate;
    float M;
    uint reconnectCase;
    PackedHitInfo reconnectHit; // Hit at x1.
    bool rootGuideSelected; // Actual guide/BSDF branch on the edge to x1.
    float3 suffixDirection; // Light UV in xy for ReGIRAtX1, otherwise world-space direction from x1.
    uint suffixLobe; // Stable light ID for ReGIRAtX1, selected lobe for BSDF light hits.
    float3 suffixLight; // RIS weight in x for ReGIRAtX1, LiOverPdf for NeeAtX1, or Le for a continuation light hit.
    float lightPdf; // Directional density for ordinary light MIS.
    bool lightIsAnalytic;
    bool hadNeeCompetitor;
};
#endif

struct TerminalPicker
{
    float sumH;
    float winnerH;
    float3 winnerF;
    uint winnerKind;
#if RTPT_GRIS_SPATIAL
    GrisSpatialRecord winnerSpatial;
#endif
};

struct GrisShadedIndirect
{
    float3 radiance;
    uint rootLobe;
    uint state;
    GrisFirstHit firstHit;
};
