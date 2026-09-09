__exported import Scene.HitInfo;

// One camera context per pixel; a complete candidate is replayed from this plus its seed.
struct PrimaryPathContext
{
    PackedHitInfo hit;
    float3 direction;
    uint seed;
};

enum PathTerminal : uint { None = 0, Emission = 1, Environment = 2, NEE = 3 };
enum PathLight : uint { None = 0, Emissive = 1, Environment = 2, Analytic = 3 };

struct PathSample
{
    float3 F;                  // PSS contribution, including sampling reciprocals and MIS.
    uint initialSeed;          // Before any light/BSDF sampling in this candidate tree.
    uint terminalSeed;         // Before terminal light sampling (or emission evaluation).
    uint surfaceScatters;      // NEE includes its final connection; primary emission is zero.
    PathTerminal terminal;
    PathLight light;
    uint flags;                // bit 0: preceding delta; bit 1: preceding transmission.
    PackedHitInfo rcHit;       // Fixed secondary vertex; invalid for shorter paths.
    uint rcIndex;              // 1 for a secondary surface, 0xffffffff when unavailable.
    uint rcSeed;               // RNG state after sampling the outgoing BSDF at rc.
    float3 rcWi;               // Outgoing direction at rc.
    float3 rcPrefix;           // Throughput arriving at rc (before local scattering).
    float3 rcIrradiance;       // Suffix excluding rc BSDF; terminal-at-rc excludes light PDF/MIS.
    float lightPdf;
};
