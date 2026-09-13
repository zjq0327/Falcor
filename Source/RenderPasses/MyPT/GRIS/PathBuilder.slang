__exported import PathReservoir;
import Utils.Math.HashUtils;

struct PathBuilder
{
    PathReservoir reservoir;
    PathSample descriptor;
    SampleGenerator selection;
    float3 radiance;
    bool replayEnabled;
    PathSample replayTarget;
    PathSample replaySample;
    bool replayFound;

    __init(uint seed)
    {
        reservoir = {};
        descriptor = {};
        descriptor.initialSeed = seed;
        descriptor.rcHit = HitInfo().pack();
        descriptor.rcIndex = 0xffffffff;
        // Like the reference builder, hash the selection stream seed. An XOR alone
        // leaves a strong relationship between the two small LCG transport/selection streams.
        selection = SampleGenerator(jenkinsHash(seed ^ 0x68bc21ebu));
        radiance = 0.f;
        replayEnabled = false;
        replayTarget = {};
        replaySample = {};
        replayFound = false;
    }

    bool acceptsContribution(uint length, PathTerminal terminal, PathLight light)
    {
        if (!COMPUTE_DIRECT && length <= 1) return false;
        if (!replayEnabled) return true;
        // NEE light families are separate slots. A BSDF arrival can change
        // between emission and environment under replay.
        bool arrival = terminal == PathTerminal::Emission || terminal == PathTerminal::Environment;
        bool targetArrival = replayTarget.terminal == PathTerminal::Emission ||
            replayTarget.terminal == PathTerminal::Environment;
        bool sameBranch = (terminal == PathTerminal::NEE && replayTarget.terminal == PathTerminal::NEE &&
            light == replayTarget.light) || (arrival && targetArrival);
        return length == replayTarget.surfaceScatters && sameBranch;
    }

    [mutating]
    void add(float3 F, float3 suffix, uint length, PathTerminal terminal, PathLight light,
        uint seed, float pdf, float3 direction, bool atRc)
    {
        if (!acceptsContribution(length, terminal, light)) return;
        PathSample candidate = descriptor;
        candidate.F = F;
        candidate.surfaceScatters = length;
        candidate.terminal = terminal;
        candidate.light = light;
        candidate.terminalSeed = seed;
        candidate.lightPdf = pdf;
        candidate.rcIrradiance = suffix;
        if (atRc) candidate.rcWi = direction;
#if GRIS_SHIFT_STRATEGY == 2
        // Emission on the first eligible rc has no outgoing rc event to reconnect.
        // Classify this contribution as full replay without changing the descriptor
        // used by longer contributions of the same tree.
        if (terminal != PathTerminal::NEE && length == candidate.rcIndex)
        {
            candidate.rcIndex = 0xffffffff;
            candidate.rcHit = HitInfo().pack();
        }
#endif
        if (replayEnabled)
        {
            replaySample = candidate;
            replayFound = true;
            // Transport still executes the ordinary sampling code. Only reservoir
            // selection is bypassed, preserving the original transport random stream.
            return;
        }
        if (all(isfinite(F)) && all(F >= 0.f)) radiance += F;
        reservoir.addContribution(candidate, selection);
    }

    [mutating]
    void finalize() { reservoir.M = 1; }
};
