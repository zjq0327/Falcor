#include "RTPTLocalLights.h"
#include <algorithm>
#include <cmath>

using namespace Falcor;
namespace RTPTLocalLights
{
void Manager::ensureResources(RenderContext* context,bool full)
{
    const uint64_t pixels=uint64_t(mInputs.frameDim.x)*mInputs.frameDim.y;
    mFullBudgetReduced=false;
    const bool fullGrid=mSettings.gridEnabled;
    const auto bounds=mpScene->getSceneBounds();
    mFullOrigin=bounds.valid()?bounds.minPoint:float3(0);
    const float3 extent=bounds.valid()?max(bounds.extent(),float3(.001f)):float3(1);
    mFullEmissiveCapacity=mpScene->useEmissiveLights()?mpScene->getILightCollection(context)->getTotalLightCount():0u;
    mFullAnalyticCapacity=mpScene->useAnalyticLights()?mpScene->getLightCount():0u;
    const uint64_t catalogCount=uint64_t(mFullEmissiveCapacity)+mFullAnalyticCapacity;
    uint32_t resolution=mSettings.gridResolution;
    auto sizeFullGrid=[&]()
    {
        const float longest=std::max(extent.x,std::max(extent.y,extent.z));
        mFullDim=max(uint3(ceil(extent*(float(resolution)/longest))),uint3(1));
        mFullCells=mFullDim.x*mFullDim.y*mFullDim.z;
        mFullCellExtent=extent/float3(mFullDim);
        return uint64_t(mFullCells)*(48u+4u*catalogCount)+32u*std::max(uint64_t(1),catalogCount)+140u;
    };
    const uint64_t tileBytes=mSettings.tileEnabled?uint64_t(mTileNodeCount)*(80u+12u*mSettings.tileCandidates)+uint64_t(mFeedbackCount)*324u+pixels*4u:0u;
    uint64_t gridBytes=fullGrid?sizeFullGrid():0u;
    const uint64_t budget=uint64_t(mSettings.budgetMiB)*1024u*1024u;
    while(fullGrid&&gridBytes+tileBytes>budget&&resolution>1u)
    {
        --resolution;gridBytes=sizeFullGrid();mFullBudgetReduced=true;
    }
    mBudgetFallback=full&&(gridBytes+tileBytes>budget ||
        (fullGrid&&(mFullEmissiveCapacity>(1u<<24u)||mFullAnalyticCapacity>(1u<<24u))));
    full=full&&!mBudgetFallback;
    uint64_t key=1469598103934665603ull;
    auto hash=[&](uint64_t value){key=(key^value)*1099511628211ull;};
    hash(full);if(full)
    {
        hash(mInputs.frameDim.x);hash(mInputs.frameDim.y);hash(mSettings.gridEnabled);hash(mSettings.tileEnabled);
        hash(mFullCells);hash(mFullEmissiveCapacity);hash(mFullAnalyticCapacity);
        hash(mSettings.tileCandidates);hash(mFeedbackCount);
    }
    const auto flags=ResourceBindFlags::ShaderResource|ResourceBindFlags::UnorderedAccess;
    auto buffer=[&](uint32_t stride,uint32_t count){return mpDevice->createStructuredBuffer(stride,std::max(1u,count));};
    if(key!=mResourceKey)
    {
        const bool grid=full&&mSettings.gridEnabled,tile=full&&mSettings.tileEnabled;
        const uint32_t cellCount=grid?mFullCells:1u;
        const uint32_t fullEntries=grid&&fullGrid?uint32_t(uint64_t(mFullCells)*catalogCount):1u;
        const uint32_t nodes=tile?mTileNodeCount:1u,entries=tile?nodes*mSettings.tileCandidates:1u;
        const uint32_t feedback=tile?mFeedbackCount:1u;
        mResources.gridKeys=buffer(16,cellCount);mResources.gridCount=buffer(16,cellCount);
        mResources.gridState=buffer(16,cellCount);mResources.gridStats=buffer(4,24u);
        mResources.fullCdf=buffer(4,fullEntries);mResources.fullCatalog=buffer(32,grid&&fullGrid?uint32_t(catalogCount):1u);
        mResources.tileState=buffer(16,nodes);mResources.tileLights=buffer(8,entries);mResources.tileWeights=buffer(4,entries);
        mResources.history=buffer(64,feedback);mResources.reprojectedHistory=buffer(64,feedback);
        mResources.projectionRecords=buffer(64,feedback);mResources.historyWinners=buffer(4,feedback);
        mResources.currentFeedback=buffer(64,feedback);mResources.historyNext=buffer(64,feedback);
        mResources.probeFeedback=buffer(64,nodes);
        const uint2 mapDim=tile?mInputs.frameDim:uint2(1);
        mResources.pixelToTile=mpDevice->createTexture2D(mapDim.x,mapDim.y,ResourceFormat::R32Uint,1,1,nullptr,flags);
        context->clearUAV(mResources.pixelToTile->getUAV().get(),uint4(RTPT_LOCAL_LIGHT_INVALID));
        // Dummy banks are initialized as well: diagnostics can inspect a global
        // frame without reading indeterminate metadata.
        for(const auto& b:{mResources.gridKeys,mResources.gridCount,
            mResources.gridState,mResources.gridStats,mResources.fullCdf,mResources.fullCatalog,
            mResources.tileState,mResources.tileLights,
            mResources.tileWeights,mResources.history,mResources.reprojectedHistory,mResources.projectionRecords,
            mResources.historyWinners,mResources.currentFeedback,mResources.historyNext,mResources.probeFeedback})
            context->clearUAV(b->getUAV().get(),uint4(0));
        mResourceKey=key;mResourcesFull=full;mResetHistory=true;mHistoryValid=false;mResetGrid=true;
    }
    if(!mResources.dummyPosition)
    {
        mResources.dummyPosition=mpDevice->createTexture2D(1,1,ResourceFormat::RGBA32Float,1,1,nullptr,flags);
        mResources.dummyNormal=mpDevice->createTexture2D(1,1,ResourceFormat::RGBA32Float,1,1,nullptr,flags);
        mResources.dummyHit=mpDevice->createTexture2D(1,1,ResourceFormat::RGBA32Uint,1,1,nullptr,flags);
        context->clearUAV(mResources.dummyPosition->getUAV().get(),float4(0));
        context->clearUAV(mResources.dummyNormal->getUAV().get(),float4(0));
        context->clearUAV(mResources.dummyHit->getUAV().get(),uint4(0));
    }
    const uint2 debugDim=mSettings.debugEnabled?mInputs.frameDim:uint2(1);
    if(!mResources.debugEvents||any(debugDim!=mDebugFrameDim))
    {
        mResources.debugEvents=mpDevice->createTexture2D(debugDim.x,debugDim.y,ResourceFormat::RGBA32Uint,1,1,nullptr,flags);
        mDebugFrameDim=debugDim;
    }
    if(!mResources.debugSelected)mResources.debugSelected=buffer(112,1);
}

ref<ComputePass> Manager::getPass(const std::string& file,const std::string& entry,bool lighting)
{
    const std::string key=file+":"+entry;
    auto found=mPasses.find(key);if(found!=mPasses.end())return found->second;
    if(!mpSampleGenerator)mpSampleGenerator=SampleGenerator::create(mpDevice,SAMPLE_GENERATOR_UNIFORM);
    ProgramDesc desc;
    if(mpScene){desc.addShaderModules(mpScene->getShaderModules());desc.addTypeConformances(mpScene->getTypeConformances());}
    desc.addShaderLibrary("RenderPasses/RTPT/LocalLights/"+file).csEntry(entry);
    desc.setShaderModel(ShaderModel::SM6_6);
    DefineList defines=mpScene?mpScene->getSceneDefines():DefineList();
    defines.add(mpSampleGenerator->getDefines());
    defines.add("USE_EMISSIVE_LIGHTS",mpScene&&mpScene->useEmissiveLights()?"1":"0");
    defines.add("USE_ANALYTIC_LIGHTS",mpScene&&mpScene->useAnalyticLights()?"1":"0");
    defines.add("USE_ENV_LIGHT","0");defines.add("USE_ENV_BACKGROUND","0");defines.add("ENABLE_NRD","0");
    auto pass=ComputePass::create(mpDevice,desc,defines,true);
    mPasses[key]=pass;return pass;
}

void Manager::bindCommon(const ShaderVar& root,QueryKind kind)const
{
    const auto p=root.findMember("gLocalLightParams");
    if(p.isValid())
    {
        auto set=[&](const std::string& key,const auto& value){const auto v=p.findMember(key);if(v.isValid())v=value;};
        const bool primaryValid=mInputs.primary.isValid()&&all(mInputs.primary.frameDim==mInputs.frameDim);
        set("frameDim",mInputs.frameDim);set("frameSerial",mFrame.frameSerial);set("sceneGeneration",mSceneGeneration);
        set("proposalGeneration",mProposalGeneration);set("sampleOffset",mInputs.sampleOffset);set("seed",mInputs.seed);set("queryKind",uint32_t(kind));
        set("gridEnabled",mFrameModelValid&&mSettings.gridEnabled?1u:0u);set("tileEnabled",mFrameModelValid&&mSettings.tileEnabled&&primaryValid?1u:0u);
        set("cdfEnabled",mSettings.cdfEnabled?1u:0u);set("persistentEnabled",mSettings.persistentEnabled?1u:0u);
        set("gridGeneration",mGridGeneration);
        set("adaptiveEnabled",mSettings.adaptiveEnabled?1u:0u);set("debugEnabled",mSettings.debugEnabled?1u:0u);
        set("fullDim",mFullDim);set("fullOrigin",mFullOrigin);set("fullCellExtent",mFullCellExtent);
        set("fullEmissiveCapacity",mFullEmissiveCapacity);set("fullAnalyticCapacity",mFullAnalyticCapacity);
        set("gridCellCount",mResourcesFull?mFullCells:1u);
        set("tileCandidates",mSettings.tileCandidates);set("historyFrames",mSettings.historyFrames);set("historyStaleFrames",mSettings.historyStaleFrames);
        set("mergeFrames",mSettings.mergeFrames);set("feedbackStride",mFeedbackStride);set("feedbackCount",mFeedbackCount);
        set("feedbackDim",mFeedbackDim);set("baseTileDim",mBaseTileDim);set("tileNodeCount",mTileNodeCount);
        set("primaryValid",primaryValid?1u:0u);set("historyValid",mFrameModelValid&&mHistoryValid?1u:0u);
        set("debugMode",mSettings.debugMode);set("debugPixel",min(mSettings.debugPixel,mInputs.frameDim-uint2(1)));
        set("depthThreshold",mSettings.depthThreshold);
        set("normalCosThreshold",std::cos(mSettings.normalThresholdDegrees*3.14159265358979323846f/180.f));
        set("useNEE",mInputs.useNEE?1u:0u);
        set("cameraPosition",mpScene?mpScene->getCamera()->getPosition():float3(0));
        set("viewProjNoJitter",primaryValid?mInputs.primary.viewProjNoJitter:float4x4::identity());
        set("previousViewProjNoJitter",mPreviousViewProjNoJitter);
    }
    auto bind=[&](const char* name,const auto& resource){const auto var=root.findMember(name);if(var.isValid())var=resource;};
    const bool primary=mInputs.primary.isValid()&&all(mInputs.primary.frameDim==mInputs.frameDim);
    bind("gLocalPrimaryPosition",primary?mInputs.primary.position:mResources.dummyPosition);
    bind("gLocalPrimaryNormalRoughness",primary?mInputs.primary.normalRoughness:mResources.dummyNormal);
    bind("gLocalPrimaryHit",primary?mInputs.primary.hit:mResources.dummyHit);
    bind("gLocalGridKeys",mResources.gridKeys);bind("gLocalGridCount",mResources.gridCount);
    bind("gLocalFullCdf",mResources.fullCdf);bind("gLocalFullCatalog",mResources.fullCatalog);
    bind("gLocalGridState",mResources.gridState);bind("gLocalGridStats",mResources.gridStats);
    bind("gLocalTileState",mResources.tileState);bind("gLocalTileLights",mResources.tileLights);bind("gLocalTileWeights",mResources.tileWeights);
    bind("gLocalPixelToTile",mResources.pixelToTile);bind("gLocalHistory",mResources.history);bind("gLocalReprojectedHistory",mResources.reprojectedHistory);
    bind("gLocalProjectionRecords",mResources.projectionRecords);bind("gLocalHistoryWinners",mResources.historyWinners);
    bind("gLocalCurrentFeedback",mResources.currentFeedback);bind("gLocalHistoryNext",mResources.historyNext);
    bind("gLocalProbeFeedback",mResources.probeFeedback);bind("gLocalDebugEvents",mResources.debugEvents);bind("gLocalDebugSelected",mResources.debugSelected);
    const auto scene=root.findMember("gScene");
    if(scene.isValid()&&mpScene)mpScene->bindShaderDataForRaytracing(mpDevice->getRenderContext(),scene);
}

void Manager::dispatch(RenderContext* context,const std::string& file,const std::string& entry,uint3 dimensions,bool lighting)
{
    auto pass=getPass(file,entry,lighting);auto root=pass->getRootVar();
    bindCommon(root,lighting?QueryKind::Probe:QueryKind::Secondary);
    if(lighting)
    {
        mpSampleGenerator->bindShaderData(root);
        if(root.findMember("gParams").isValid())root["gParams"]["useNEE"]=mInputs.useNEE?1u:0u;
    }
    pass->execute(context,dimensions);barrier(context);
}

void Manager::barrier(RenderContext* context)const
{
    for(const auto& b:{mResources.gridKeys,mResources.gridCount,
        mResources.gridState,mResources.gridStats,mResources.fullCdf,mResources.fullCatalog,
        mResources.tileState,mResources.tileLights,
        mResources.tileWeights,mResources.history,mResources.reprojectedHistory,mResources.projectionRecords,
        mResources.historyWinners,mResources.currentFeedback,mResources.historyNext,mResources.probeFeedback,mResources.debugSelected})
        if(b)context->uavBarrier(b.get());
    for(const auto& t:{mResources.pixelToTile,mResources.debugEvents})if(t)context->uavBarrier(t.get());
}

uint64_t Manager::getPayloadBytes()const
{
    uint64_t bytes=0;
    for(const auto& b:{mResources.gridKeys,mResources.gridCount,
        mResources.gridState,mResources.gridStats,mResources.fullCdf,mResources.fullCatalog,
        mResources.tileState,mResources.tileLights,
        mResources.tileWeights,mResources.history,mResources.reprojectedHistory,mResources.projectionRecords,
        mResources.historyWinners,mResources.currentFeedback,mResources.historyNext,mResources.probeFeedback,mResources.debugSelected})
        if(b)bytes+=b->getSize();
    for(const auto& t:{mResources.pixelToTile,mResources.debugEvents,mResources.dummyPosition,mResources.dummyNormal,mResources.dummyHit})
        if(t)bytes+=t->getTextureSizeInBytes();
    return bytes;
}
} // namespace RTPTLocalLights
