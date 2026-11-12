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
#ifndef RTPT_GRIS_SUFFIX_REPLAY
#define RTPT_GRIS_SUFFIX_REPLAY 0
#endif
#ifndef RTPT_GRIS_REGIR_REPLAY
#define RTPT_GRIS_REGIR_REPLAY 0
#endif
#ifndef RTPT_GRIS_CACHE_TAIL
#define RTPT_GRIS_CACHE_TAIL 0
#endif
#ifndef RTPT_REGIR_ONLY
#define RTPT_REGIR_ONLY 0
#endif
#if RTPT_GRIS_SPATIAL
import Scene.HitInfo;
#endif
#if RTPT_GRIS_SPATIAL && RTPT_GRIS_SUFFIX_REPLAY
import Utils.Sampling.UniformSampleGenerator;
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

#if RTPT_GRIS_SUFFIX_REPLAY
// Compact membership filter. A collision can only reject an extra history
// path; every instance actually visited by the suffix sets its bit.
uint rtptGrisSuffixInstanceBit(uint instanceIndex)
{
    return 1u << (instanceIndex & 31u);
}

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
#if RTPT_GRIS_REGIR_REPLAY
float2 rtptGrisSplitReGIRReplayRng(inout UniformSampleGenerator directRng, uint bounce,
    out UniformSampleGenerator cellRng)
{
    const float2 uv = sampleNext2D(directRng);
    cellRng = rtptGrisForkReplayNEERng(directRng, bounce);
    return uv;
}
#endif
#endif

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
#if RTPT_GRIS_SUFFIX_REPLAY
    uint suffixInstanceMask;
    uint terminalBounce; // Continuation bounce of the selected event; zero means unavailable.
    uint4 postX2RngState; // Before NEE for a direct x2 draw, after x2 BSDF for a continuation.
#endif
#if RTPT_GRIS_SHARC_REPLAY
    uint2 sharcKey;
    float3 sharcGain; // SHaRC gain, or the ReGIR inner RIS weight in x when both are enabled.
#elif RTPT_GRIS_REGIR_REPLAY
    float innerRISWeight;
#endif
};

// Extend the existing terminal word, rather than storing a second flags field.
static const uint kGrisTerminalKindMask = 0xffu;
static const uint kGrisDeepTail = 0x100u;
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

#if RTPT_GRIS_REGIR_REPLAY
float rtptGrisGetInnerRISWeight(GrisSpatialRecord suffix)
{
#if RTPT_GRIS_SHARC_REPLAY
    const uint kind = rtptGrisTerminalKind(suffix.candidate.terminalKind);
    return kind == uint(GrisTerminalKind::GrisReGIRPath) ? suffix.sharcGain.x : 0.f;
#else
    return suffix.innerRISWeight;
#endif
}
#endif

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
#if RTPT_GRIS_SUFFIX_REPLAY
    uint suffixInstanceMask;
    uint terminalBounce;
    uint4 postX2RngState;
#endif
#if RTPT_GRIS_SHARC_REPLAY
    uint2 sharcKey;
    float3 sharcGain;
#elif RTPT_GRIS_REGIR_REPLAY
    float innerRISWeight;
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
