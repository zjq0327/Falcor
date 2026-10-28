#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveUniformSampler;
import Rendering.Lights.EmissiveLightSamplerInterface;
import Rendering.Lights.EmissiveLightSamplerHelpers;
struct RTPTLocalProbeParams { uint useNEE; };
ConstantBuffer<RTPTLocalProbeParams> gParams;
#include "../RTPTLighting.slang"

[numthreads(64,1,1)]
void main(uint3 tid:SV_DispatchThreadID)
{
    const uint node=tid.x;
    if(node>=gLocalLightParams.tileNodeCount || gLocalLightParams.useNEE==0u || !rtptLocalNodeIsLeaf(node))return;
    uint2 origin;uint size;rtptLocalTileBounds(node,origin,size);
    if(any(origin>=gLocalLightParams.frameDim))return;
    uint2 pixel=min(origin+size/2u,gLocalLightParams.frameDim-1u);
    // Prefer the center and try four quarter points when it is background.
    for(uint i=0u;i<4u && gLocalPrimaryPosition[pixel].w==0.f;++i)
        pixel=min(origin+(uint2(i&1u,i>>1u)*2u+1u)*size/4u,gLocalLightParams.frameDim-1u);
    const float4 primary=gLocalPrimaryPosition[pixel];
    if(primary.w==0.f)return;
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
#if HIT_INFO_USE_COMPRESSION
    const HitInfo hit=HitInfo(gLocalPrimaryHit[pixel].xy);
#else
    const HitInfo hit=HitInfo(gLocalPrimaryHit[pixel]);
#endif
    if(!hit.isValid() || hit.getType()!=HitType::Triangle)return;
    const TriangleHit triangle=hit.getTriangleHit();
    const uint materialID=gScene.getMaterialID(triangle.instanceID);
    const float3 view=gLocalLightParams.cameraPosition-primary.xyz;
    if(!(dot(view,view)>0.f))return;
    ShadingData sd=gScene.materials.prepareShadingData(gScene.getVertexData(triangle),materialID,normalize(view));
    sd.mtl.setActiveLobes(uint(LobeType::Reflection));
    const IMaterialInstance mi=gScene.materials.getMaterialInstance(sd,ExplicitLodTextureSampler(0.f));
    // Dedicated proposal-training stream. Main path RNG is never touched.
    const uint sampleIndex=rtptLocalHash(gLocalLightParams.frameSerial^gLocalLightParams.seed^0x7a372b19u);
    SampleGenerator sg=SampleGenerator(uint2(node,0u),sampleIndex);
    const RTPTLightingContext context=rtptSurfaceLightContext(sd,pixel,sampleIndex,0u,RTPT_LIGHT_QUERY_PROBE);
    RTPTLightSample sample;
    const bool sampled=rtptSampleLight(sd,context,sg,sample);
    if(sample.key.kind!=RTPT_LIGHT_KIND_EMISSIVE && sample.key.kind!=RTPT_LIGHT_KIND_ANALYTIC)return;
    if(sample.key.index==RTPT_LOCAL_LIGHT_INVALID)return;
    float score=0.f;
    if(sampled)
    {
        const float3 raw=mi.eval(sd,sample.dir,sg)*sample.LiOverPdf;
        if(!all(isfinite(raw)))return;
        if(any(raw>0.f))
        {
            SceneRayQuery<true> query;
            if(query.traceVisibilityRay(sample.visibilityRay))score=max(raw.x,max(raw.y,raw.z));
        }
    }
    RTPTLocalLightFeedbackRecord record={};
    record.positionScore=float4(sd.posW,min(max(0.f,score),1.e6f));
    record.normalWeight=float4(sd.getOrientedFaceNormal(),1.f);
    record.key=uint4(sample.key.kind,sample.key.index,gLocalLightParams.sceneGeneration,gLocalLightParams.frameSerial);
    record.pixelInfo=uint4(pixel,1u,1u);
    gLocalProbeFeedback[node]=record;
#endif
}
