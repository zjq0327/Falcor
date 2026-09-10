__exported import Scene.HitInfo;
import Utils.Math.ShadingFrame;

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
    uint rcBeforeFlags;        // bit 0: delta; bit 1: transmission; bit 2: unsupported material; bit 3: invalid reconstructed source.
    uint rcAfterFlags;         // Same bits for rc BSDF; zero for an NEE terminal at rc.
    PackedHitInfo rcHit;       // Fixed secondary vertex; invalid for shorter paths.
    // View-independent attributes of the fixed rc. Preserve their float values
    // across separately compiled passes; material setup remains view-dependent.
    float3 rcPositionW;
    float2 rcTexCoord;
    ShadingFrame rcFrame;
    float4 rcTangentW;
    float3 rcFaceN;
    uint rcIndex;              // Surface index; 0xffffffff when this contribution uses full replay.
    PackedHitInfo rcPrevHit;   // Source-domain endpoint of the connection (Hybrid may have a prefix).
    float3 rcPrevDirection;
    uint rcPrevSeed;           // Transport state before the connection BSDF, after its RR.
    uint prefixFlags;          // OR of events before the fixed rc (delta/transmission/material).
    uint rcSeed;               // RNG state after sampling the outgoing BSDF at rc.
    float3 rcWi;               // Outgoing direction at rc.
    float3 rcPrefix;           // Throughput arriving at rc (before local scattering).
    float3 rcIrradiance;       // Suffix excluding rc BSDF; terminal-at-rc excludes light PDF/MIS.
    float lightPdf;
    float3 cachedJacobian;     // Primary BSDF PDF, rc BSDF PDF, |n_rc.w| / distance^2.
};

// Retrace writes only the replayed prefix, never reservoir W/M or a new RIS choice.
// A no-rc path uses throughput for the complete replayed contribution.
struct HybridPrefix
{
    PackedHitInfo hit;
    float3 direction;
    float3 throughput;
    uint rngState;
    uint failure;
    PathTerminal terminal;
    PathLight light;
};

struct HybridPair
{
    uint neighborIndex;
    uint status; // Same geometric eligibility as Reuse. Zero means unused slot.
    HybridPrefix toNeighbor;
    HybridPrefix toCenter;
};
