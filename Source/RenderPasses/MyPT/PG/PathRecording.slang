#ifndef MYPT_PG_PATH_RECORDING_SLANG
#define MYPT_PG_PATH_RECORDING_SLANG

#include "Params.slang"

struct PGRecording
{
    uint slot;
    uint count;
    float survivalScale;
    uint flags;
};

uint pgOwnerHash(uint x)
{
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    return x ^ (x >> 16u);
}

PGRecording pgRecordInit(uint2 pixel)
{
    PGRecording rec = {};
    rec.slot = kPGInvalid;
    rec.survivalScale = 1.f;
    if (gPGTrain == 0u || gPGOwnerTileSize == 0u) return rec;
    uint2 tile = pixel / gPGOwnerTileSize;
    uint tilesX = (gPGFrameDim.x + gPGOwnerTileSize - 1u) / gPGOwnerTileSize;
    uint slot = tile.y * tilesX + tile.x;
    if (slot >= gPGPathCapacity) return rec;
    uint random = pgOwnerHash(slot ^ pgOwnerHash(gPGFrameIndex ^ pgOwnerHash(gPGOwnerSeed)));
    // Host chooses a power-of-two tile size: this bit mask is exactly uniform
    // over the integer hash domain and needs no floating-point/64-bit arithmetic.
    uint owner = random & (gPGOwnerTileSize * gPGOwnerTileSize - 1u);
    uint2 ownerPixel = tile * gPGOwnerTileSize + uint2(owner % gPGOwnerTileSize, owner / gPGOwnerTileSize);
    // An off-screen owner in a partial edge tile simply records no path. This
    // preserves the same inclusion probability for every on-screen pixel.
    if (any(pixel != ownerPixel)) return rec;
    rec.slot = slot;
    PGPathHeader header = {};
    header.ownerPixel = pixel.y * gPGFrameDim.x + pixel.x;
    header.generation = gPGTreeGeneration;
    gPGPathHeaders[slot] = header;
    pgDiagnostic(kPGDiagSelectedPaths);
    return rec;
}

void pgRecordVertex(inout PGRecording rec, float3 position, float3 emission, float hitMIS)
{
    rec.survivalScale = 1.f;
    if (rec.slot == kPGInvalid) return;
    if (rec.count >= gPGRecordsPerPath)
    {
        rec.flags |= kPGPathOverflow;
        pgDiagnostic(kPGDiagOverflow);
        return;
    }
    PGVertexRecord vertex = {};
    vertex.position = position;
    vertex.emission = emission;
    vertex.hitMIS = hitMIS;
    gPGVertexRecords[rec.slot * gPGRecordsPerPath + rec.count] = vertex;
    rec.count++;
    pgDiagnostic(kPGDiagRecordedVertices);
}

void pgRecordDirect(PGRecording rec, float3 direct)
{
    if (rec.slot == kPGInvalid || rec.count == 0u || rec.flags != 0u) return;
    gPGVertexRecords[rec.slot * gPGRecordsPerPath + rec.count - 1u].direct = direct;
}

void pgRecordScatter(PGRecording rec, float3 direction, float pdf, float3 weight, bool trainable)
{
    if (rec.slot == kPGInvalid || rec.count == 0u || rec.flags != 0u) return;
    uint index = rec.slot * gPGRecordsPerPath + rec.count - 1u;
    PGVertexRecord vertex = gPGVertexRecords[index];
    vertex.direction = direction;
    vertex.samplePdf = pdf;
    vertex.transport = weight * rec.survivalScale;
    vertex.flags = kPGVertexOutgoing;
    if (trainable) vertex.flags |= kPGVertexTrainable;
    else pgDiagnostic(kPGDiagUnsupported);
    gPGVertexRecords[index] = vertex;
}

void pgRecordEnd(PGRecording rec, uint reason, float3 terminalEmission)
{
    if (rec.slot == kPGInvalid) return;
    PGPathHeader header = gPGPathHeaders[rec.slot];
    header.terminationReason = reason;
    header.terminalEmission = terminalEmission;
    gPGPathHeaders[rec.slot] = header;
}

void pgRecordFinish(PGRecording rec)
{
    if (rec.slot == kPGInvalid) return;
    PGPathHeader header = gPGPathHeaders[rec.slot];
    header.vertexCount = rec.count;
    header.flags = rec.flags == 0u ? kPGPathComplete : rec.flags;
    if (header.terminationReason == 0u) header.terminationReason = kPGTerminationEnded;
    gPGPathHeaders[rec.slot] = header;
    if (rec.flags == 0u) pgDiagnostic(kPGDiagCompletePaths);
}

#endif
