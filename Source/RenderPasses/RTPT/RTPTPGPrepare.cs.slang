#include "RTPTPGTypes.slang"

[numthreads(64, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint path = dispatchThreadID.x;
    if (path >= gPGSettings.pathCapacity) return;
    RTPTPGPathHeader header = {};
    header.generation = gPGSettings.recordGeneration;
    header.sceneGeneration = gPGSettings.sceneGeneration;
    gPGPathHeaders[path] = header;
}
