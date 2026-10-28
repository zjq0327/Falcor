#include "RTPTLocalLightOverlay.h"
#include <algorithm>
#include <cmath>

using namespace Falcor;

RTPTLocalLightOverlay::RTPTLocalLightOverlay(ref<Device> device, const Properties& properties) : RenderPass(device)
{
    setProperties(properties);
}

void RTPTLocalLightOverlay::setProperties(const Properties& properties)
{
    bool enabled = mEnabled;
    float opacity = mOpacity;
    for (const auto& [key, value] : properties)
    {
        if (key == "enabled") enabled = value;
        else if (key == "opacity") opacity = value;
        else logWarning("Unknown RTPTLocalLightOverlay property '{}'.", key);
    }
    FALCOR_CHECK(std::isfinite(opacity), "RTPTLocalLightOverlay opacity must be finite.");
    mEnabled = enabled;
    mOpacity = std::clamp(opacity, 0.f, 1.f);
}

Properties RTPTLocalLightOverlay::getProperties() const
{
    Properties properties;
    properties["enabled"] = mEnabled;
    properties["opacity"] = mOpacity;
    return properties;
}

RenderPassReflection RTPTLocalLightOverlay::reflect(const CompileData& compileData)
{
    RenderPassReflection reflection;
    reflection.addInput("color", "Display color after tone mapping").bindFlags(ResourceBindFlags::ShaderResource);
    reflection.addInput("debug", "Local light diagnostic color and alpha mask")
        .bindFlags(ResourceBindFlags::ShaderResource)
        .flags(RenderPassReflection::Field::Flags::Optional);
    reflection.addOutput("output", "Optional local light display overlay")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource | ResourceBindFlags::RenderTarget);
    return reflection;
}

void RTPTLocalLightOverlay::execute(RenderContext* context, const RenderData& data)
{
    const auto color = data.getTexture("color");
    const auto debug = data.getTexture("debug");
    const auto output = data.getTexture("output");
    if (!color || !output) return;
    const bool debugEnabled = data.getDictionary().getValue("rtptLocalLightDebugEnabled", true);
    if (!mEnabled || !debugEnabled || !debug || mOpacity <= 0.f)
    {
        context->blit(color->getSRV(), output->getRTV());
        return;
    }
    if (!mpPass)
        mpPass = ComputePass::create(mpDevice, "RenderPasses/RTPT/LocalLights/Debug/RTPTLocalLightOverlay.cs.slang", "main");
    const uint2 dimensions(output->getWidth(), output->getHeight());
    auto root = mpPass->getRootVar();
    root["CB"]["frameDim"] = dimensions;
    root["CB"]["opacity"] = mOpacity;
    root["gColor"] = color;
    root["gDebug"] = debug;
    root["gOutput"] = output;
    mpPass->execute(context, uint3(dimensions, 1));
}

void RTPTLocalLightOverlay::renderUI(Gui::Widgets& widgets)
{
    widgets.checkbox("Enabled", mEnabled);
    widgets.var("Opacity", mOpacity, 0.f, 1.f, .01f);
    widgets.text("Select LocalLightOverlay.output to view the overlay.\nEnable RTPT local light Debug to produce its mask.");
}
