#include "RTPTLocalLightModel.slang"

[numthreads(64,1,1)]
void reproject(uint3 tid:SV_DispatchThreadID)
{
    const uint index=tid.x;
    if(index>=gLocalLightParams.feedbackCount || gLocalLightParams.historyValid==0 || gLocalLightParams.primaryValid==0)return;
    RTPTLocalLightFeedbackRecord r=gLocalHistory[index];
    if(!rtptLocalFeedbackValid(r))return;
    const float4 clip=mul(gLocalLightParams.viewProjNoJitter,float4(r.positionScore.xyz,1.f));
    if(!(clip.w>0.f)||!all(isfinite(clip)))return;
    const float2 uv=clip.xy/clip.w*float2(.5f,-.5f)+.5f;
    if(any(uv<0.f)||any(uv>=1.f))return;
    const uint2 pixel=uint2(uv*gLocalLightParams.frameDim);
    const float4 p=gLocalPrimaryPosition[pixel];
    const float3 normal=gLocalPrimaryNormalRoughness[pixel].xyz;
    const float tolerance=max(.01f,length(gLocalLightParams.fullCellExtent*float3(gLocalLightParams.fullDim))*(.1f/16.f)+abs(clip.w)*gLocalLightParams.depthThreshold);
    if(p.w==0.f||distance(p.xyz,r.positionScore.xyz)>tolerance||dot(normal,r.normalWeight.xyz)<.85f)return;
    r.pixelInfo.xy=pixel;
    gLocalProjectionRecords[index]=r;
    const uint2 tile=pixel/gLocalLightParams.feedbackStride;
    const uint destination=tile.x+tile.y*gLocalLightParams.feedbackDim.x;
    uint unused;
    // Deterministic collision selection. No float atomics or model mutations.
    InterlockedMin(gLocalHistoryWinners[destination],index,unused);
}

[numthreads(64,1,1)]
void gather(uint3 tid:SV_DispatchThreadID)
{
    const uint index=tid.x;
    if(index>=gLocalLightParams.feedbackCount)return;
    RTPTLocalLightFeedbackRecord record={};
    const uint winner=gLocalHistoryWinners[index];
    if(winner<gLocalLightParams.feedbackCount)record=gLocalProjectionRecords[winner];
    gLocalReprojectedHistory[index]=record;
}

[numthreads(64,1,1)]
void finishHistory(uint3 tid:SV_DispatchThreadID)
{
    const uint index=tid.x;
    if(index>=gLocalLightParams.feedbackCount)return;
    RTPTLocalLightFeedbackRecord old=gLocalReprojectedHistory[index],fresh=gLocalCurrentFeedback[index],result={};
    const bool oldValid=rtptLocalFeedbackValid(old),newValid=rtptLocalFeedbackValid(fresh);
    if(newValid)
    {
        result=fresh;
        if(oldValid && all(old.key.xyz==fresh.key.xyz))
        {
            const uint count=min(gLocalLightParams.historyFrames,old.pixelInfo.w+1u);
            result.positionScore.w=lerp(old.positionScore.w,fresh.positionScore.w,1.f/float(max(1u,count)));
            result.pixelInfo.w=count;
            result.normalWeight.w=float(count);
        }
        else if(oldValid)
        {
            const float age=float(gLocalLightParams.frameSerial-old.key.w);
            const float a=max(1.e-8f,old.positionScore.w)*exp2(-age/float(max(1u,gLocalLightParams.historyFrames)));
            const float b=max(1.e-8f,fresh.positionScore.w);
            if(rtptLocalUniform(index^gLocalLightParams.frameSerial^gLocalLightParams.seed)*(a+b)<a)result=old;
        }
    }
    else if(oldValid)result=old;
    gLocalHistoryNext[index]=result;
}
