#include "RTPTLocalLightModel.slang"

uint2 fullCounts()
{
    uint2 counts = 0u;
#if USE_EMISSIVE_LIGHTS
    counts.x = gScene.lightCollection.getActiveTriangleCount();
#endif
#if USE_ANALYTIC_LIGHTS
    counts.y = gScene.getLightCount();
#endif
    return counts;
}

[numthreads(64,1,1)]
void catalog(uint3 tid : SV_DispatchThreadID)
{
    const uint eCapacity = gLocalLightParams.fullEmissiveCapacity;
    if (tid.x >= eCapacity + gLocalLightParams.fullAnalyticCapacity) return;
    const uint2 counts = fullCounts();
    const bool analytic = tid.x >= eCapacity;
    const uint ordered = analytic ? tid.x-eCapacity : tid.x;
    RTPTFullLightDescriptor d = {};
    if (ordered < (analytic ? counts.y : counts.x))
    {
        const uint kind = analytic ? RTPT_LIGHT_KIND_ANALYTIC : RTPT_LIGHT_KIND_EMISSIVE;
        const uint index = rtptLocalGridLightIndex(0u,kind,ordered);
        float3 center, lo, hi; float power;
        rtptLocalCatalogData(kind,index,center,lo,hi,power);
#if USE_ANALYTIC_LIGHTS
        if (analytic)
        {
            const LightData light = gScene.getLight(index);
            if (light.type == LightType::Directional || light.type == LightType::Distant)
            {
                power = max(light.intensity.x,max(light.intensity.y,light.intensity.z));
                d.extentInfinite.w = 1.f;
            }
        }
#endif
        d.centerPower = float4(all(isfinite(center)) ? center : float3(0),rtptFullSanitizeWeight(power));
        d.extentInfinite.xyz = all(isfinite(hi-lo)) ? max((hi-lo)*.5f,0.f) : float3(0);
    }
    gLocalFullCatalog[tid.x] = d;
}

float fullWeight(uint ordered, float3 position)
{
    const RTPTFullLightDescriptor d = gLocalFullCatalog[ordered];
    if (d.extentInfinite.w != 0.f) return d.centerPower.w;
    const float3 distance = max(abs(position-d.centerPower.xyz)-d.extentInfinite.xyz,0.f);
    // Finite importance estimate only, never an eligibility or radius test.
    const float denominator = max(dot(distance,distance),max(1.e-6f,dot(gLocalLightParams.fullCellExtent,gLocalLightParams.fullCellExtent)*.0625f));
    return rtptFullSanitizeWeight(d.centerPower.w/denominator);
}

[numthreads(64,1,1)]
void build(uint3 tid : SV_DispatchThreadID)
{
    const uint cell = tid.x;
    if (cell >= gLocalLightParams.gridCellCount) return;
    const uint2 counts = fullCounts();
    if (counts.x > gLocalLightParams.fullEmissiveCapacity || counts.y > gLocalLightParams.fullAnalyticCapacity ||
        any(counts > RTPT_FULL_CDF_BINS))
    {
        gLocalGridState[cell] = 0u;
        uint ignored; InterlockedAdd(gLocalGridStats[3],1u,ignored);
        return;
    }
    const uint3 dim = gLocalLightParams.fullDim;
    const uint3 key = uint3(cell%dim.x,(cell/dim.x)%dim.y,cell/(dim.x*dim.y));
    const float3 position = gLocalLightParams.fullOrigin+(float3(key)+.5f)*gLocalLightParams.fullCellExtent;
    for (uint category=0u; category<2u; ++category)
    {
        const uint count = category == 0u ? counts.x : counts.y;
        const uint kind = category == 0u ? RTPT_LIGHT_KIND_EMISSIVE : RTPT_LIGHT_KIND_ANALYTIC;
        const uint catalogBase = category == 0u ? 0u : gLocalLightParams.fullEmissiveCapacity;
        const uint base = rtptLocalGridBase(cell,kind);
        float maximum = 0.f;
        for (uint i=0u; i<count; ++i) maximum=max(maximum,fullWeight(catalogBase+i,position));
        float total=0.f;
        for (uint i=0u; i<count; ++i) total+=maximum>0.f ? fullWeight(catalogBase+i,position)/maximum : 1.f;
        uint previous=0u; float cumulative=0.f;
        for (uint i=0u; i<count; ++i)
        {
            cumulative+=maximum>0.f ? fullWeight(catalogBase+i,position)/maximum : 1.f;
            const uint prefix=rtptFullCdfPrefix(i,count,cumulative,total,previous);
            gLocalFullCdf[base+i]=gLocalLightParams.cdfEnabled!=0u ? prefix : prefix-previous;
            previous=prefix;
        }
    }
    gLocalGridCount[cell]=uint4(counts,asuint(float(RTPT_FULL_CDF_BINS)),asuint(float(RTPT_FULL_CDF_BINS)));
    gLocalGridKeys[cell]=int4(int3(key),2);
    gLocalGridState[cell]=uint4(gLocalLightParams.frameSerial,gLocalLightParams.gridGeneration,1u,gLocalLightParams.frameSerial);
    uint ignored; InterlockedAdd(gLocalGridStats[0],1u,ignored);
}

// Diagnostic-only exhaustive support certificate. It inspects the stored
// representation, including lights that no finite random test is likely to hit.
[numthreads(64,1,1)]
void audit(uint3 tid : SV_DispatchThreadID)
{
    const uint cell=tid.x;
    if(cell>=gLocalLightParams.gridCellCount)return;
    const uint2 counts=fullCounts();
    uint failures=0u,entries=0u;
    for(uint category=0u;category<2u;++category)
    {
        const uint kind=category==0u ? RTPT_LIGHT_KIND_EMISSIVE : RTPT_LIGHT_KIND_ANALYTIC;
        const uint count=rtptLocalGridSize(cell,kind),expected=category==0u ? counts.x : counts.y;
        if(count!=expected)++failures;
        const uint base=rtptLocalGridBase(cell,kind);
        uint sum=0u;
        for(uint i=0u;i<count;++i)
        {
            const uint mass=rtptFullCdfMass(gLocalFullCdf,base,i,gLocalLightParams.cdfEnabled!=0u);
            if(mass==0u || mass>RTPT_FULL_CDF_BINS)++failures;
            sum+=mass;++entries;
        }
        if(count>0u&&sum!=RTPT_FULL_CDF_BINS)++failures;
    }
    uint ignored;
    InterlockedAdd(gLocalGridStats[20],1u,ignored);
    if(gLocalGridState[cell].y!=gLocalLightParams.gridGeneration)InterlockedAdd(gLocalGridStats[21],1u,ignored);
    InterlockedAdd(gLocalGridStats[22],failures,ignored);
    InterlockedAdd(gLocalGridStats[23],entries,ignored);
}
