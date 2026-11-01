#pragma once
import Scene.HitInfo;
import Utils.Math.Ray;

static const uint kRTPTPrimaryRecordReady = 1u;

/** Current-frame camera sample, never a material instance or path state.
    PackedHitInfo is copied directly from SceneRayQuery without extra quantization.
    Reflection determines the stride (112 bytes with uncompressed HitInfo).
*/
struct RTPTPrimarySurface
{
    PackedHitInfo packedHit;
    float hitT;
    uint sampleIndex;
    uint frameStamp;
    uint flags;
    float3 rayOrigin;
    float rayTMin;
    float3 rayDirection;
    float rayTMax;
    float3 position;
    uint materialID;
    float3 guideNormal;
    float roughness;
    float3 motionW;
    float viewZ;
};

struct RTPTPrimarySettings
{
    uint2 frameDim;
    uint sampleIndex; // Absolute sample index, including the existing seed stride.
    uint frameStamp;
    uint prepared;
};
