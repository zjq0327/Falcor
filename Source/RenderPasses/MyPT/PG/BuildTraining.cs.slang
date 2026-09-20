#include "Params.slang"

[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    uint slot = tid.x;
    if (slot >= gPGPathCapacity) return;
    PGPathHeader header = gPGPathHeaders[slot];
    if (header.flags != kPGPathComplete || header.vertexCount == 0u) return;
    if (header.vertexCount > gPGRecordsPerPath || header.generation != gPGTreeGeneration)
    {
        pgDiagnostic(kPGDiagInvalidPath);
        return;
    }

    float3 nextEmission = header.terminalEmission;
    float3 nextReflected = 0.f;
    float nextHitMIS = 1.f;
    for (uint remaining = header.vertexCount; remaining > 0u; remaining--)
    {
        uint vertexIndex = remaining - 1u;
        PGVertexRecord vertex = gPGVertexRecords[slot * gPGRecordsPerPath + vertexIndex];
        float3 incoming = nextEmission + nextReflected;
        if ((vertex.flags & (kPGVertexOutgoing | kPGVertexTrainable)) == (kPGVertexOutgoing | kPGVertexTrainable))
        {
            if (!(vertex.samplePdf > 0.f) || !isfinite(vertex.samplePdf)) pgDiagnostic(kPGDiagInvalidPdf);
            else if (!all(isfinite(incoming))) pgDiagnostic(kPGDiagNonfinite);
            else
            {
                float weight = dot(max(incoming, 0.f), float3(1.f / 3.f)) / vertex.samplePdf;
                if (!isfinite(weight)) pgDiagnostic(kPGDiagNonfinite);
                else if (pgRecordGuide(vertex.position, vertex.direction, weight))
                {
                    pgDiagnostic(kPGDiagTrainedSamples);
                    if (vertexIndex > 0u) pgDiagnostic(kPGDiagSecondarySamples);
                    if (weight == 0.f) pgDiagnostic(kPGDiagZeroSamples);
                }
                else pgDiagnostic(kPGDiagNonfinite);
            }
        }
        // Current training Li intentionally excludes both the current scatter
        // factor and its own emitter-hit MIS. Deeper suffix MIS stays intact.
        nextReflected = vertex.direct + vertex.transport * (nextHitMIS * nextEmission + nextReflected);
        nextEmission = vertex.emission;
        nextHitMIS = vertex.hitMIS;
    }
}
