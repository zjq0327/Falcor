#include "RTPTPrimarySurface.h"
#include "Core/API/GFXAPI.h"
#include "Utils/Timing/Profiler.h"

using namespace Falcor;

namespace RTPTPrimarySurface
{
Manager::Manager(ref<Device> device) : mpDevice(device)
{
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

void Manager::setScene(const ref<Scene>& scene)
{
    mpScene = scene;
    invalidate();
    if (!mpScene) mView = {};
}

void Manager::invalidate()
{
    mpPass = nullptr;
    mView.frameSerial = 0;
    if (++mSceneGeneration == 0) ++mSceneGeneration;
}

void Manager::ensureResources(uint2 frameDim)
{
    if (mView.position && mView.normalRoughness && mView.hit && all(mView.frameDim == frameDim)) return;
    const auto flags = ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess;
    mView.position = mpDevice->createTexture2D(frameDim.x, frameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr, flags);
    mView.normalRoughness = mpDevice->createTexture2D(frameDim.x, frameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr, flags);
    mView.hit = mpDevice->createTexture2D(frameDim.x, frameDim.y, ResourceFormat::RGBA32Uint, 1, 1, nullptr, flags);
    mView.frameDim = frameDim;
}

void Manager::ensureProgram()
{
    if (mpPass) return;
    ProgramDesc desc;
    desc.addShaderModules(mpScene->getShaderModules());
    desc.addShaderLibrary("RenderPasses/RTPT/PrimarySurface/RTPTPrimarySurface.cs.slang").csEntry("main");
    desc.addTypeConformances(mpScene->getTypeConformances());
    desc.setShaderModel(ShaderModel::SM6_6);
    DefineList defines = mpScene->getSceneDefines();
    defines.add(mpSampleGenerator->getDefines());
    mpPass = ComputePass::create(mpDevice, desc, defines, true);
}

const View& Manager::prepare(RenderContext* context, const FrameInputs& inputs)
{
    mView.frameSerial = 0;
    if (!mpScene || any(inputs.frameDim == uint2(0))) return mView;
    FALCOR_PROFILE(context, "RTPTPrimarySurface");
    ensureResources(inputs.frameDim);
    ensureProgram();
    for (const auto& texture : {mView.position, mView.normalRoughness, mView.hit}) context->uavBarrier(texture.get());

    auto root = mpPass->getRootVar();
    mpScene->bindShaderDataForRaytracing(context, root["gScene"]);
    mpSampleGenerator->bindShaderData(root);
    root["gParams"]["frameDim"] = inputs.frameDim;
    root["gParams"]["seed"] = inputs.seed;
    root["gParams"]["sampleOffset"] = inputs.sampleOffset;
    root["gParams"]["useNRD"] = inputs.useNRD ? 1u : 0u;
    root["gPrimaryPosition"] = mView.position;
    root["gPrimaryNormalRoughness"] = mView.normalRoughness;
    root["gPrimaryHit"] = mView.hit;
    mpPass->execute(context, uint3(inputs.frameDim, 1));
    for (const auto& texture : {mView.position, mView.normalRoughness, mView.hit}) context->uavBarrier(texture.get());

    if (++mFrameSerial == 0) ++mFrameSerial;
    mView.frameSerial = mFrameSerial;
    mView.sceneGeneration = mSceneGeneration;
    mView.seed = inputs.seed;
    mView.sampleOffset = inputs.sampleOffset;
    mView.useNRD = inputs.useNRD;
    mView.viewProj = mpScene->getCamera()->getViewProjMatrix();
    mView.viewProjNoJitter = mpScene->getCamera()->getViewProjMatrixNoJitter();
    return mView;
}

uint64_t Manager::getPayloadBytes() const
{
    uint64_t bytes = 0;
    for (const auto& texture : {mView.position, mView.normalRoughness, mView.hit})
        if (texture) bytes += texture->getTextureSizeInBytes();
    return bytes;
}
} // namespace RTPTPrimarySurface
