#include "RTPTLocalLights.h"
#include "Utils/Timing/Profiler.h"
#include <algorithm>
#include <cmath>

using namespace Falcor;
namespace RTPTLocalLights
{
void Manager::advanceGeneration(uint32_t& generation) { if(++generation==0)generation=1; }

void Manager::setScene(const ref<Scene>& scene)
{
    mpScene=scene;
    invalidate(Invalidation::Catalog);
}

void Manager::configure(const Settings& settings)
{
    validate(settings);
    const auto changes=compareSettings(mSettings,settings);
    const bool gridChanged=settings.gridResolution!=mSettings.gridResolution || settings.gridEnabled!=mSettings.gridEnabled ||
        settings.cdfEnabled!=mSettings.cdfEnabled || settings.persistentEnabled!=mSettings.persistentEnabled;
    if(gridChanged)mResetGrid=true;
    mSettings=settings;
    // A diagnostic-only allocation must not reset the proposal or its history.
    if(changes.history)invalidate(changes.resources?Invalidation::Resources:Invalidation::History);
    else if(changes.signal)invalidate(Invalidation::Proposal);
}

void Manager::invalidate(Invalidation scope)
{
    mFrame.prepared=false;
    advanceGeneration(mProposalGeneration);
    if(scope>=Invalidation::Grid)mResetGrid=true;
    if(scope>=Invalidation::History){mResetHistory=true;mHistoryValid=false;}
    if(scope>=Invalidation::Catalog){advanceGeneration(mSceneGeneration);mPasses.clear();mpDebug.reset();}
    if(scope>=Invalidation::Resources)mResourceKey=0;
}

FrameToken Manager::prepareFrame(RenderContext* context,const FrameInputs& inputs)
{
    FALCOR_PROFILE(context,"LocalLightPrepare");
    mInputs=inputs;advanceGeneration(mFrameSerial);
    mFrame={mFrameSerial,mSceneGeneration,mProposalGeneration,false};
    mFrameModelValid=false;
    if(!mpScene || any(inputs.frameDim==uint2(0)))return mFrame;
    mBaseTileDim=(inputs.frameDim+31u)/32u;
    mFeedbackStride=4u;
    do
    {
        mFeedbackDim=(inputs.frameDim+mFeedbackStride-1u)/mFeedbackStride;
        if(uint64_t(mFeedbackDim.x)*mFeedbackDim.y<=mSettings.feedbackRecords)break;
        mFeedbackStride*=2u;
    }while(mFeedbackStride<65536u);
    mFeedbackCount=mFeedbackDim.x*mFeedbackDim.y;
    mTileNodeCount=mSettings.tileEnabled?mBaseTileDim.x*mBaseTileDim.y*RTPT_LOCAL_TILE_NODES_PER_ROOT:1u;
    const bool primaryValid=inputs.primary.isValid()&&all(inputs.primary.frameDim==inputs.frameDim);
    const bool requested=mSettings.gridEnabled;
    try { ensureResources(context,requested); }
    catch(const std::exception& error)
    {
        logWarning("RTPT light model allocation failed; using Global: {}",error.what());
        mResourceKey=0;ensureResources(context,false);mBudgetFallback=true;
    }
    mFrameModelValid=requested&&mResourcesFull&&!mBudgetFallback;
    mFrame.prepared=true;
    if(mFrameModelValid)advanceGeneration(mProposalGeneration);
    mFrame.proposalGeneration=mProposalGeneration;
    auto clearBuffer=[&](const ref<Buffer>& buffer,uint32_t value=0u){context->clearUAV(buffer->getUAV().get(),uint4(value));};
    clearBuffer(mResources.debugSelected);
    context->clearUAV(mResources.debugEvents->getUAV().get(),uint4(0));
    clearBuffer(mResources.gridStats);
    if(!mFrameModelValid){barrier(context);return mFrame;}
    clearBuffer(mResources.currentFeedback);
    clearBuffer(mResources.reprojectedHistory);
    clearBuffer(mResources.projectionRecords);
    clearBuffer(mResources.historyWinners,RTPT_LOCAL_LIGHT_INVALID);
    clearBuffer(mResources.probeFeedback);
    if(mResetHistory)
    {
        clearBuffer(mResources.history);clearBuffer(mResources.historyNext);
        clearBuffer(mResources.tileState);
        mHistoryValid=false;mResetHistory=false;
    }
    barrier(context);
    if(mSettings.gridEnabled)
    {
        const bool rebuild=mResetGrid || !mSettings.persistentEnabled;
        if(rebuild)
        {
            clearBuffer(mResources.gridKeys);clearBuffer(mResources.gridCount);clearBuffer(mResources.gridState);
            advanceGeneration(mGridGeneration);++mGridResetCount;mResetGrid=false;
            barrier(context);
        }
        if(rebuild)
        {
            if(mFullEmissiveCapacity+mFullAnalyticCapacity>0u)dispatch(context,"RTPTFullLightGrid.cs.slang","catalog",uint3(mFullEmissiveCapacity+mFullAnalyticCapacity,1,1));
            dispatch(context,"RTPTFullLightGrid.cs.slang","build",uint3(mFullCells,1,1));
        }
        if(mSettings.debugEnabled)dispatch(context,"RTPTFullLightGrid.cs.slang","audit",uint3(mFullCells,1,1));
    }
    if(mSettings.tileEnabled&&primaryValid)
    {
        if(mHistoryValid)dispatch(context,"RTPTLightFeedback.cs.slang","reproject",uint3(mFeedbackCount,1,1));
        dispatch(context,"RTPTLightFeedback.cs.slang","gather",uint3(mFeedbackCount,1,1));
        dispatch(context,"RTPTAdaptiveTile.cs.slang","analyzeNodes",uint3(mTileNodeCount,1,1));
        dispatch(context,"RTPTAdaptiveTile.cs.slang","mapPixels",uint3(inputs.frameDim,1));
        if(inputs.useNEE)dispatch(context,"RTPTLocalLightProbe.cs.slang","main",uint3(mTileNodeCount,1,1),true);
        dispatch(context,"RTPTAdaptiveTile.cs.slang","buildCandidates",uint3(mTileNodeCount,1,1));
    }
    return mFrame;
}

void Manager::bindSampling(const ShaderVar& root,QueryKind kind)const {bindCommon(root,kind);}
void Manager::bindFeedback(const ShaderVar& root,QueryKind kind)const {bindCommon(root,kind);}
void Manager::bindDebug(const ShaderVar& root)const {bindCommon(root,QueryKind::MainPrimary);}

void Manager::renderHeldDebug(RenderContext* context,const ref<Texture>& output,const RTPTPrimarySurface::View& primary)
{
    if(primary.isValid()&&all(primary.frameDim==mInputs.frameDim)&&primary.seed==mInputs.seed&&primary.sampleOffset==mInputs.sampleOffset)
        mInputs.primary=primary;
    if(mFrame.prepared&&mpScene&&mSettings.debugEnabled)
    {
        const uint2 previousDebugDim=mDebugFrameDim;
        const bool previousBudgetFallback=mBudgetFallback;
        // The sampling switches, dimensions, and model key are unchanged in a
        // held frame. This only ensures the independently sized debug banks.
        ensureResources(context,mResourcesFull);
        mBudgetFallback=previousBudgetFallback;
        if(any(previousDebugDim!=mDebugFrameDim))
        {
            // Newly enabled diagnostics have no captured NEE event. Never
            // manufacture one by replaying RNG or issuing a probe.
            context->clearUAV(mResources.debugEvents->getUAV().get(),uint4(0));
            context->clearUAV(mResources.debugSelected->getUAV().get(),uint4(0));
        }
    }
    renderDebug(context,output);
}

void Manager::finishFrame(RenderContext* context)
{
    if(!mFrame.prepared)return;
    if(mFrameModelValid)
    {
        barrier(context);
        if(mSettings.tileEnabled&&mInputs.primary.isValid()&&mInputs.useNEE)
        {
            dispatch(context,"RTPTLightFeedback.cs.slang","finishHistory",uint3(mFeedbackCount,1,1));
            std::swap(mResources.history,mResources.historyNext);mHistoryValid=true;
        }
    }
    if(mInputs.primary.isValid())mPreviousViewProjNoJitter=mInputs.primary.viewProjNoJitter;
}

Properties Manager::getStatistics()const
{
    Properties p;
    p["mode"]=std::string(mFrameModelValid?(mSettings.tileEnabled?"GridTile":"Grid"):"GlobalUniform");
    p["framePrepared"]=mFrame.prepared;p["modelReady"]=mFrameModelValid;
    p["budgetFallback"]=mBudgetFallback;p["historyValid"]=mHistoryValid;
    p["frameSerial"]=mFrame.frameSerial;p["sceneGeneration"]=mSceneGeneration;p["proposalGeneration"]=mProposalGeneration;
    p["resourceBytes"]=getPayloadBytes();p["gridResolution"]=mSettings.gridResolution;
    p["cdfEnabled"]=mSettings.cdfEnabled;p["persistentGridEnabled"]=mSettings.persistentEnabled;
    p["gridGeneration"]=mGridGeneration;p["gridResetCount"]=mGridResetCount;
    p["tileNodes"]=mTileNodeCount;p["feedbackCount"]=mFeedbackCount;p["feedbackStride"]=mFeedbackStride;
    p["fullGridDimensions"]=mFullDim;
    p["fullGridCells"]=mFullCells;p["fullGridBudgetReduced"]=mFullBudgetReduced;
    p["fullGridEmissiveCapacity"]=mFullEmissiveCapacity;p["fullGridAnalyticCapacity"]=mFullAnalyticCapacity;
    p["normalGlobalFraction"]=mFrameModelValid?0.f:1.f;
    uint64_t gridBytes=0;
    for(const auto& buffer:{mResources.gridKeys,mResources.gridCount,mResources.gridState,
        mResources.fullCdf,mResources.fullCatalog,mResources.gridStats})if(buffer)gridBytes+=buffer->getSize();
    p["gridResourceBytes"]=gridBytes;
    p["useNEE"]=mInputs.useNEE;
    return p;
}
} // namespace RTPTLocalLights
