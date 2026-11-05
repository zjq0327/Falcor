#pragma once
#include "../Signal/RTPTSignalTypes.slang"

#ifndef RTPT_GRIS_SPATIAL
#define RTPT_GRIS_SPATIAL 0
#endif
#ifndef RTPT_GRIS_ALTERNATING
#define RTPT_GRIS_ALTERNATING 0
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

// Reusable events are direct-light samples or SHaRC terminations at x2.
// A zero area PDF denotes no suffix.
struct GrisSpatialRecord
{
    GrisCandidate candidate;
    PackedHitInfo reconnectHit;
    float areaPdf;          // Canonical x1 -> x2 proposal, in area measure.
    float3 suffixDirection; // ReGIR stores light-surface UV in xy.
    float3 suffixLight;     // Ordinary NEE stores Li / PDF. ReGIR stores RIS weight in x.
#if RTPT_REGIR_ONLY && RTPT_GRIS_ALTERNATING
    uint lightStableID;     // Uses the ordinary NEE lightPdf slot.
#else
    float lightPdf;
#endif
    bool lightIsAnalytic;
#if RTPT_REGIR_ONLY && !RTPT_GRIS_ALTERNATING
    uint lightStableID;
#endif
};

#if RTPT_GRIS_ALTERNATING
struct GrisAlternatingFresh
{
    GrisLocalPrefix prefix[2]; // D, S.
    GrisSpatialRecord raw;
    GrisFirstHit inactiveFirstHit;
    uint preparedMask;
};

uint rtptGrisSourceSlot(uint rootLobe)
{
    return uint(rootLobe == uint(GrisRootComponent::GrisSpecular));
}
#endif

// One raw proposal from Generate. A missing suffix can still have a valid x1
// prefix whose proposal must participate in the reverse MIS evaluation.
struct GrisTemporalFreshHistory
{
    PackedHitInfo sourceX1;
    float3 sourceFirstDir;
    uint rootLobe;
    PackedHitInfo reconnectHit;
    float sourceAreaPdf;
    float3 suffixDirection; // ReGIR stores the light UV in xy.
    float3 suffixLight;     // ReGIR stores the original RIS weight in x.
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
