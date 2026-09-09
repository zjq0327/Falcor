__exported import PathReservoir;
import Utils.Math.HashUtils;

struct PathBuilder
{
    PathReservoir reservoir;
    PathSample descriptor;
    SampleGenerator selection;
    float3 radiance;

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
    }

    [mutating]
    void add(float3 F, float3 suffix, uint length, PathTerminal terminal, PathLight light,
        uint seed, float pdf, float3 direction, bool atRc)
    {
        if (!COMPUTE_DIRECT && length <= 1) return;
        PathSample candidate = descriptor;
        candidate.F = F;
        candidate.surfaceScatters = length;
        candidate.terminal = terminal;
        candidate.light = light;
        candidate.terminalSeed = seed;
        candidate.lightPdf = pdf;
        candidate.rcIrradiance = suffix;
        if (atRc) candidate.rcWi = direction;
        if (all(isfinite(F)) && all(F >= 0.f)) radiance += F;
        reservoir.addContribution(candidate, selection);
    }

    [mutating]
    void finalize() { reservoir.M = 1; }
};
