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
#ifndef RTPT_GRIS_CACHE_TAIL
#define RTPT_GRIS_CACHE_TAIL 0
#endif
#ifndef RTPT_GRIS_PG_PREFIX_DEPTH
#define RTPT_GRIS_PG_PREFIX_DEPTH 1
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
    // Fixed-x2 explicit paths store a weighted incident factor, never the
    // legacy GrisReGIR UV/RIS reconstruction payload.
    GrisReGIRPath,
    // Fixed incident factor from a generation-time SHaRC query (deep only).
    GrisSharcTail,
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
    float M;
    uint rootLobe;
    uint terminalKind;
    bool prepared;
    bool hasWinner;
    GrisFirstHit firstHit;
};

#if RTPT_GRIS_SPATIAL
static const float kGrisReferenceDirectionPdf = 0.079577471545947667f; // 1/(4*pi)

struct GrisLocalPrefix
{
    PackedHitInfo x1Hit;
    float3 firstDirW;
    float3 throughputToX1;
    float3 localRadiance;
    uint rootLobe; // Route local terms independently of the selected suffix.
};

// Pixel-local estimates from both full root walks. Geometry belongs to the
// selected path record; each walk's GrisLocalPrefix remains invocation-local.
struct GrisLocalContributions
{
    float3 diffuse;
    float3 specular;
};

// A positive area PDF identifies a sampled x2. Its terminal may be empty.
struct GrisSpatialRecord
{
    GrisCandidate candidate;
    PackedHitInfo ownerPrimaryHit;
    PackedHitInfo sourceX1;
    PackedHitInfo reconnectHit;
    float areaPdf;          // Owner proposal/reference ratio R after Generate normalization.
    float3 suffixDirection; // Fixed direction leaving x2; legacy ReGIR records use UV in xy.
    float3 suffixLight;     // Selected tail factor, excluding x2 scatter and terminal-picker weight.
    uint lightPdfOrStableID; // Ordinary light PDF bits, or stable light ID for ReGIR terminals.
    bool lightIsAnalytic;
};

// Extend the existing terminal word, rather than storing a second flags field.
static const uint kGrisTerminalKindMask = 0xffu;
static const uint kGrisDeepTail = 0x100u;

uint rtptGrisTerminalKind(uint terminalAndFlags)
{
    return terminalAndFlags & kGrisTerminalKindMask;
}

bool rtptGrisIsDeepTail(GrisSpatialRecord suffix)
{
    return (suffix.candidate.terminalKind & kGrisDeepTail) != 0u;
}

bool rtptGrisHasTerminal(GrisSpatialRecord suffix)
{
    const uint kind = rtptGrisTerminalKind(suffix.candidate.terminalKind);
    return suffix.areaPdf > 0.f && (kind == uint(GrisTerminalKind::GrisNee) ||
        kind == uint(GrisTerminalKind::GrisReGIR) || kind == uint(GrisTerminalKind::GrisReGIRPath) ||
        kind == uint(GrisTerminalKind::GrisCacheTerminal) ||
#if RTPT_GRIS_CACHE_TAIL
        (kind == uint(GrisTerminalKind::GrisSharcTail) && rtptGrisIsDeepTail(suffix)) ||
#endif
        kind == uint(GrisTerminalKind::GrisEmitter) || kind == uint(GrisTerminalKind::GrisEnvironment));
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

// The selected reservoir in its current owner's domain. The prefix and path
// payload must be published together with the normalized F/W/M state.
struct GrisTemporalFreshHistory
{
    PackedHitInfo sourceX1;
    PackedHitInfo ownerPrimaryHit; // Replaces the reconstructible first-edge direction.
    uint rootLobe;
    PackedHitInfo reconnectHit;
    float sourceAreaPdf;
    float3 suffixDirection; // Fixed x2 direction; only legacy GrisReGIR stores UV in xy.
    float3 suffixLight;     // Weighted tail factor; only legacy GrisReGIR stores RIS/domain weights.
    uint lightPdfOrStableID; // Preserve the winning terminal's PDF bits / stable ReGIR light ID.
    uint terminalAndFlags;
    float3 F;
    float W;
    float M;
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
    float3 localDiffuse;
    float3 localSpecular;
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
