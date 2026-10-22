/** One compute thread per cache entry; no scene or ray-tracing pipeline. */
#include "RTPTSharc.slang"

[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    SharcResolveParameters resolve = {};
    resolve.cameraPositionPrev = gSharcSettings.cameraPositionPrev;
    resolve.accumulationFrameNum = gSharcSettings.accumulationFrames;
    resolve.responsiveFrameNum = 1u;
    resolve.staleFrameNumMax = gSharcSettings.staleFrames;
    resolve.frameIndex = gSharcSettings.frameIndex;
    SharcResolveEntry(dispatchThreadID.x, gSharc, resolve);
#if RTPT_SHARC_PAIR
    SharcResolveEntry(dispatchThreadID.x, gSharcLocal, resolve);
    SharcResolveEntry(dispatchThreadID.x, gSharcSuffix, resolve);
#endif
}
