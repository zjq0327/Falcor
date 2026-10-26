#include "Scene/SceneDefines.slangh"
import Scene.RaytracingInline;
#include "RTPTVXPGDistribution.slang"

RWTexture2D<float4> gVXPGDebug;

[numthreads(8, 8, 1)]
void debugGeometry(uint3 tid : SV_DispatchThreadID)
{
    if (any(tid.xy >= gVXPGParams.frameDim)) return;
    const Ray ray = gScene.camera.computeRayPinhole(tid.xy, gVXPGParams.frameDim);
    SceneRayQuery<true> query;
    float hitT;
    const HitInfo hit = query.traceRay(ray, hitT);
    float3 color = 0.f;
    if (hit.isValid())
    {
        const float3 position = gScene.getVertexData(hit.getTriangleHit()).posW;
        const uint cell = rtptVXPGOwner(position);
        if (cell != RTPT_VXPG_INVALID && gVXPGBoundMin[cell].w != 0)
        {
            const uint hash=rtptVXPGKeyHash(rtptVXPGCellIdentity(cell));
            color=float3(hash&255u,(hash>>8)&255u,(hash>>16)&255u)/255.f;
            if(gVXPGParams.debugMode==4)
            {
                const uint level=uint(rtptVXPGCellIdentity(cell).w);
                color=level==1?float3(0.2f,0.65f,1.f):level==2?float3(0.3f,1.f,0.3f):level==3?float3(1.f,0.6f,0.1f):float3(0.9f,0.2f,0.8f);
            }
            // Keep the level view readable on surfaces coplanar with a grid
            // boundary; the cell view retains its grid-line overlay.
            if (!(gVXPGParams.debugMode == 4))
            {
                const float3 local = frac((position - gVXPGParams.gridMin) / rtptVXPGCellSize(cell));
                if (min(local.x, min(local.y, local.z)) < 0.015f) color = 1.f;
            }
        }
    }
    if (gVXPGState[RTPT_VXPG_STATE_GEOMETRY_OVERFLOW] != 0) color = float3(1.f, 0.f, 1.f);
    gVXPGDebug[tid.xy] = float4(color, 1.f);
}

[numthreads(8,8,1)]
void debugDistribution(uint3 tid : SV_DispatchThreadID)
{
    if (any(tid.xy>=gVXPGParams.frameDim)) return;
    const float4 p=gVXPGPrimaryPosition[tid.xy];
    float3 color=0.f;
    uint id=RTPT_VXPG_INVALID;
    if (p.w!=0.f)
    {
        const uint cell=rtptVXPGOwner(p.xyz);
        if (gVXPGParams.debugMode==1)
        {
            const float4 weights=gVXPGFuzzyWeights[tid.xy];
            uint dominant=0;
            for(uint k=1;k<4;++k)if(weights[k]>weights[dominant])dominant=k;
            id=gVXPGFuzzyIds[tid.xy][dominant];
        }
        else if (cell!=RTPT_VXPG_INVALID)
        {
            const uint compact=gVXPGInverse[cell];
            if (compact!=RTPT_VXPG_INVALID && compact<gVXPGParams.activeCapacity)
            {
                id=gVXPGCluster[compact];
                if (gVXPGParams.debugMode==3)
                {
                    const uint4 v=countbits(gVXPGVisibility[compact]);
                    color=float3(float(v.x+v.y+v.z+v.w)/128.f);
                }
            }
        }
        if (gVXPGParams.debugMode!=3 && id!=RTPT_VXPG_INVALID)
            color=frac(float3(0.61803399f,0.41421356f,0.73205081f)*float(id+1));
    }
    gVXPGDebug[tid.xy]=float4(color,1.f);
}
