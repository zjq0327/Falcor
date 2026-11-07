#pragma once
#include "../RTPTFirstHit.slangh"

#ifndef RTPT_GRIS_SPATIAL
#define RTPT_GRIS_SPATIAL 0
#endif
#ifndef RTPT_GRIS_ALTERNATING
#define RTPT_GRIS_ALTERNATING 0
#endif
#ifndef RTPT_GRIS_SHARC_REPLAY
#define RTPT_GRIS_SHARC_REPLAY 0
#endif
#ifndef RTPT_REGIR_ONLY
#define RTPT_REGIR_ONLY 0
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
struct GrisLocalPrefix
{
    PackedHitInfo x1Hit;
    float3 firstDirW;
    float3 throughputToX1;
    float3 localRadiance;
};

// A positive area PDF identifies a sampled x2. Its terminal may be empty.
struct GrisSpatialRecord
{
    GrisCandidate candidate;
    PackedHitInfo reconnectHit;
    float areaPdf;          // Canonical x1 -> x2 proposal, in area measure.
    float3 suffixDirection; // ReGIR stores light-surface UV in xy.
    float3 suffixLight;     // Weighted Li/PDF for NEE, RIS weight and inverse domain probability in xy for ReGIR.
    uint lightPdfOrStableID; // Interpret by terminalKind.
    bool lightIsAnalytic;
};

bool rtptGrisHasTerminal(GrisSpatialRecord suffix)
{
    const uint kind = suffix.candidate.terminalKind;
    return suffix.areaPdf > 0.f && (kind == uint(GrisTerminalKind::GrisNee) ||
        kind == uint(GrisTerminalKind::GrisReGIR) || kind == uint(GrisTerminalKind::GrisCacheTerminal));
}

#if RTPT_GRIS_ALTERNATING
static const uint kGrisPreparedLobesMask = 0x3u;
static const uint kGrisX1CacheBlendShift = 2u;

struct GrisAlternatingFresh
{
    GrisLocalPrefix prefix[2]; // D, S.
    GrisSpatialRecord raw;
    GrisFirstHit inactiveFirstHit;
    uint preparedMask; // Low bits are prepared D/S; bits 2/3 are mixed x1 cache D/S.
};

uint rtptGrisSourceSlot(uint rootLobe)
{
    return uint(rootLobe == uint(GrisRootComponent::GrisSpecular));
}
#endif

// One raw proposal from Generate. A missing x2 or terminal can still have a
// valid x1 prefix whose proposal participates in reverse MIS.
struct GrisTemporalFreshHistory
{
    PackedHitInfo sourceX1;
    float3 sourceFirstDir;
    uint rootLobe;
    PackedHitInfo reconnectHit;
    float sourceAreaPdf;
    float3 suffixDirection; // ReGIR stores the light UV in xy.
    float3 suffixLight;     // ReGIR stores RIS weight and inverse domain probability in xy.
    uint lightPdfOrStableID;
    uint terminalAndFlags;
#if defined(HIT_INFO_USE_COMPRESSION) && HIT_INFO_USE_COMPRESSION
    uint4 padding; // Keep the history stride fixed when each packed hit is 8 bytes.
#endif
};

static const uint kGrisHistoryAnalytic = 0x80000000u;
#endif

struct TerminalPicker
{
    float sumH;
    float winnerH;
    float3 winnerF;
    uint winnerKind;
};

struct GrisShadedIndirect
{
    float3 radiance;
    uint rootLobe;
    uint state;
    GrisFirstHit firstHit;
};

#if RTPT_GRIS_ALTERNATING
struct GrisDualWinner
{
    float3 F_D;
    float3 F_S;
    float W;
    uint hasWinner;
};

struct GrisDualShadedIndirect
{
    float3 radiance[2];
    GrisFirstHit firstHit[2];
    uint preparedMask;
};
#endif
