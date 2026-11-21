#pragma once
#include "../RTPTFirstHit.slangh"

#ifndef RTPT_GRIS_SPATIAL
#define RTPT_GRIS_SPATIAL 0
#endif
#ifndef RTPT_GRIS_SPATIAL_DEEP_INCIDENT
#define RTPT_GRIS_SPATIAL_DEEP_INCIDENT 0
#endif
#ifndef RTPT_GRIS_ALTERNATING
#define RTPT_GRIS_ALTERNATING 0
#endif
#ifndef RTPT_GRIS_DUAL_FIRST_HIT
#define RTPT_GRIS_DUAL_FIRST_HIT 0
#endif
#ifndef RTPT_GRIS_SEPARATE_OWNER
#define RTPT_GRIS_SEPARATE_OWNER 0
#endif
#ifndef RTPT_GRIS_DUAL_SHARC
#define RTPT_GRIS_DUAL_SHARC 0
#endif
#ifndef RTPT_GRIS_SHARC_REPLAY
#define RTPT_GRIS_SHARC_REPLAY 0
#endif
#ifndef RTPT_GRIS_SUFFIX_REPLAY
#define RTPT_GRIS_SUFFIX_REPLAY 0
#endif
#ifndef RTPT_GRIS_CACHE_TAIL
#define RTPT_GRIS_CACHE_TAIL 0
#endif
#if RTPT_GRIS_SPATIAL
import Scene.HitInfo;
#endif
#if RTPT_GRIS_SPATIAL && (RTPT_GRIS_SUFFIX_REPLAY || RTPT_GRIS_DUAL_FIRST_HIT)
import Utils.Sampling.UniformSampleGenerator;
#endif

enum GrisRootComponent : uint { GrisNoRoot, GrisDiffuse, GrisSpecular };
enum GrisTerminalKind : uint
{
    GrisNoTerminal,
    GrisNee,
    GrisEmitter,
    GrisEnvironment,
    GrisCacheTerminal = 5,
    // Fixed incident factor from a generation-time SHaRC query (deep only).
    GrisSharcTail = 7,
    GrisDualPointNee,
    GrisDualEmissiveNee,
    GrisDualSharcTail = 11,
    GrisDualEnvironmentNee,
    GrisDualEmitter,
    GrisDualEnvironmentMiss,
};
enum GrisRecordState : uint { GrisUnprepared, GrisPreparedZero, GrisPreparedWinner };

struct GrisFirstHit
{
    float hitT;
    uint distanceState;
};

#if RTPT_GRIS_DUAL_FIRST_HIT
// Preserve the low 14 bits used by terminalKind and the existing analytic-light bit.
static const uint kGrisPackedTerminalMask = 0x3fffu;
static const uint kGrisPackedRootShift = 14u;
static const uint kGrisPackedPrepared = 1u << 16u;
static const uint kGrisPackedWinner = 1u << 17u;
static const uint kGrisPackedBounceShift = 18u; // maxBounces <= 64.
static const uint kGrisPackedBounceMask = 0x7fu;
#endif
static const uint kGrisHistoryAnalytic = 0x80000000u;

struct GrisCandidate
{
    float3 F;
    float W;
    float M;
#if RTPT_GRIS_DUAL_FIRST_HIT
    uint packedFlags;
    float3 dualF;
    property uint terminalKind
    {
        get { return packedFlags & kGrisPackedTerminalMask; }
        set { packedFlags = (packedFlags & ~kGrisPackedTerminalMask) | (newValue & kGrisPackedTerminalMask); }
    }
    property uint rootLobe
    {
        get { return (packedFlags >> kGrisPackedRootShift) & 3u; }
        set { packedFlags = (packedFlags & ~(3u << kGrisPackedRootShift)) | ((newValue & 3u) << kGrisPackedRootShift); }
    }
    property bool prepared
    {
        get { return (packedFlags & kGrisPackedPrepared) != 0u; }
        set { packedFlags = (packedFlags & ~kGrisPackedPrepared) | (newValue ? kGrisPackedPrepared : 0u); }
    }
    property bool hasWinner
    {
        get { return (packedFlags & kGrisPackedWinner) != 0u; }
        set { packedFlags = (packedFlags & ~kGrisPackedWinner) | (newValue ? kGrisPackedWinner : 0u); }
    }
#if RTPT_GRIS_ALTERNATING
    GrisFirstHit firstHit;
#endif
#else
    uint rootLobe;
    uint terminalKind;
    bool prepared;
    bool hasWinner;
    GrisFirstHit firstHit;
#endif
};

#if RTPT_GRIS_SPATIAL
static const float kGrisReferenceDirectionPdf = 0.079577471545947667f; // 1/(4*pi)

#if RTPT_GRIS_SUFFIX_REPLAY
// Compact membership filter. A collision can only reject an extra history
// path; every instance actually visited by the suffix sets its bit.
uint rtptGrisSuffixInstanceBit(uint instanceIndex)
{
    return 1u << (instanceIndex & 31u);
}
#endif

#if RTPT_GRIS_SUFFIX_REPLAY || RTPT_GRIS_DUAL_FIRST_HIT
uint4 rtptGrisCaptureReplayRng(UniformSampleGenerator sg)
{
    return uint4(sg.rng.state[0], sg.rng.state[1], sg.rng.state[2], sg.rng.state[3]);
}

UniformSampleGenerator rtptGrisRestoreReplayRng(uint4 state)
{
    UniformSampleGenerator sg;
    sg.rng.state[0] = state.x;
    sg.rng.state[1] = state.y;
    sg.rng.state[2] = state.z;
    sg.rng.state[3] = state.w;
    return sg;
}

// Keep NEE consumption separate from later BSDF draws. Generation and replay
// consume exactly two draws from the continuation stream at eligible vertices.
UniformSampleGenerator rtptGrisForkReplayNEERng(inout UniformSampleGenerator sg, uint bounce)
{
    const uint first = sg.next();
    const uint second = sg.next();
    return UniformSampleGenerator(uint2(first, second), bounce);
}
#endif

struct GrisLocalPrefix
{
    PackedHitInfo x1Hit;
    float3 firstDirW;
    float3 throughputToX1;
    float3 localRadiance;
    uint rootLobe; // Route local terms independently of the selected suffix.
#if RTPT_GRIS_DUAL_FIRST_HIT
    PackedHitInfo dualX1;
    float dualFirstPdf;
#endif
};

// Pixel-local estimates from both full root walks. Geometry belongs to the
// selected path record; each walk's GrisLocalPrefix remains invocation-local.
struct GrisLocalContributions
{
    float3 diffuse;
    float3 specular;
#if RTPT_GRIS_DUAL_FIRST_HIT
    GrisFirstHit firstHit[2];
#endif
};

// Each proposal keeps its own x1 anchor. Longer paths also retain their x2 hit
// and its continuation data for lighting replay.
struct GrisSpatialRecord
{
    GrisCandidate candidate;
    PackedHitInfo ownerPrimaryHit;
    PackedHitInfo sourceX1;
    PackedHitInfo reconnectHit; // x2 inside the suffix, invalid for a short x1 NEE.
    float areaPdf;          // Owner proposal/reference ratio, or conditional suffix density for dual proposals.
    float3 suffixDirection; // Fixed direction leaving x2, or light coordinates for direct NEE.
    float3 suffixLight;     // Tail factor or dual deep light UV.
    uint lightPdfOrIndex; // Light PDF bits or dual NEE light index.
#if RTPT_GRIS_DUAL_FIRST_HIT
    property bool lightIsAnalytic
    {
        get { return (candidate.packedFlags & kGrisHistoryAnalytic) != 0u; }
        set { candidate.packedFlags = (candidate.packedFlags & ~kGrisHistoryAnalytic) | (newValue ? kGrisHistoryAnalytic : 0u); }
    }
#else
    bool lightIsAnalytic;
#endif
#if RTPT_GRIS_SUFFIX_REPLAY
    uint suffixInstanceMask;
    uint terminalBounce; // Continuation bounce of the selected event; zero means unavailable.
    uint4 postX2RngState; // Before NEE for a direct x2 draw, after x2 BSDF for a continuation.
#endif
#if RTPT_GRIS_SHARC_REPLAY
    uint2 sharcKey;
    float3 sharcGain;
#endif
#if RTPT_GRIS_DUAL_FIRST_HIT
    uint4 dualExplicitRng; // Continuation stream after sampling x2's direction.
    property uint dualExplicitBounce
    {
        get { return (candidate.packedFlags >> kGrisPackedBounceShift) & kGrisPackedBounceMask; }
        set
        {
            candidate.packedFlags = (candidate.packedFlags & ~(kGrisPackedBounceMask << kGrisPackedBounceShift))
                | ((newValue & kGrisPackedBounceMask) << kGrisPackedBounceShift);
        }
    }
#endif
};

#if RTPT_GRIS_DUAL_FIRST_HIT
struct GrisDualNeeTerminal
{
    float3 coordinates; // Light sample coordinates.
    uint terminalKind;
    uint lightPdfOrIndex;
    bool lightIsAnalytic;
    bool hasWinner;
};

// Invocation-local state for short x1 NEE and the longer events from one root walk.
struct GrisDualX2Sample
{
    PackedHitInfo hit;
    float areaPdf;
    float deepPdf;
    float3 direction;
    uint4 replayRng;
    GrisDualNeeTerminal directLight;
    GrisDualNeeTerminal deepLight;
    float3 rootDirection;
    GrisDualNeeTerminal firstNee;
};

struct GrisDualExplicitTerminal
{
    float3 suffixLight;
    uint bounce;
    uint terminalKind;
    uint lightPdfOrIndex;
    bool lightIsAnalytic;
};
#endif

// Extend the existing terminal word, rather than storing a second flags field.
static const uint kGrisTerminalKindMask = 0xffu;
static const uint kGrisDeepTail = 0x100u;
static const uint kGrisFixedX1Nee = 0x1000u;
static const uint kGrisDeltaRoot = 0x2000u;
#if RTPT_GRIS_SUFFIX_REPLAY
static const uint kGrisEmissiveNee = 0x200u;
static const uint kGrisPointNee = 0x400u;
static const uint kGrisEnvironmentNee = 0x800u;

bool rtptGrisIsEmissiveNee(GrisSpatialRecord suffix)
{
    return (suffix.candidate.terminalKind & kGrisEmissiveNee) != 0u;
}

bool rtptGrisIsPointNee(GrisSpatialRecord suffix)
{
    return (suffix.candidate.terminalKind & kGrisPointNee) != 0u;
}

bool rtptGrisIsEnvironmentNee(GrisSpatialRecord suffix)
{
    return (suffix.candidate.terminalKind & kGrisEnvironmentNee) != 0u;
}

bool rtptGrisHasReplayableNee(GrisSpatialRecord suffix)
{
    return (suffix.candidate.terminalKind & (kGrisEmissiveNee | kGrisPointNee | kGrisEnvironmentNee)) != 0u;
}
#endif

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
#if RTPT_GRIS_DUAL_FIRST_HIT
    if (kind == uint(GrisTerminalKind::GrisDualPointNee) || kind == uint(GrisTerminalKind::GrisDualEmissiveNee) ||
        kind == uint(GrisTerminalKind::GrisDualEnvironmentNee)) return true;
    if (kind == uint(GrisTerminalKind::GrisDualEmitter) || kind == uint(GrisTerminalKind::GrisDualEnvironmentMiss))
        return rtptGrisIsDeepTail(suffix);
#if RTPT_GRIS_DUAL_SHARC
    if (kind == uint(GrisTerminalKind::GrisDualSharcTail)) return rtptGrisIsDeepTail(suffix);
#endif
#endif
    return suffix.areaPdf > 0.f && (kind == uint(GrisTerminalKind::GrisNee) ||
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
#if !RTPT_GRIS_SEPARATE_OWNER
    PackedHitInfo ownerPrimaryHit; // Replaces the reconstructible first-edge direction.
#endif
#if !RTPT_GRIS_DUAL_FIRST_HIT
    uint rootLobe;
#endif
    PackedHitInfo reconnectHit;
    float sourceAreaPdf;
    float3 suffixDirection; // Direction leaving x2, or light UV for dual direct NEE.
    float3 suffixLight;     // Weighted tail factor, or light UV for dual deep NEE.
    uint lightPdfOrIndex; // Light PDF bits or dual NEE light index.
    uint terminalAndFlags;
    float3 F;
    float W;
    float M;
#if RTPT_GRIS_DUAL_FIRST_HIT
    float3 dualF;
#endif
#if RTPT_GRIS_SUFFIX_REPLAY
    uint suffixInstanceMask;
    uint terminalBounce;
    uint4 postX2RngState;
#endif
#if RTPT_GRIS_SHARC_REPLAY
    uint2 sharcKey;
    float3 sharcGain;
#endif
#if RTPT_GRIS_DUAL_FIRST_HIT
    uint4 dualExplicitRng;
#endif
};

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
#if RTPT_GRIS_DUAL_FIRST_HIT
    float3 radiance[2];
#else
    float3 radiance;
    uint rootLobe;
#endif
    float3 localDiffuse;
    float3 localSpecular;
    uint state;
#if RTPT_GRIS_DUAL_FIRST_HIT
    GrisFirstHit firstHit[2];
#else
    GrisFirstHit firstHit;
#endif
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
