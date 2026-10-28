#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

/** Optional display composition after tone mapping. It never changes the lighting signal. */
class RTPTLocalLightOverlay : public Falcor::RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(RTPTLocalLightOverlay, "RTPTLocalLightOverlay", "Local light sampling display overlay.");

    static Falcor::ref<RTPTLocalLightOverlay> create(Falcor::ref<Falcor::Device> device, const Falcor::Properties& properties)
    {
        return Falcor::make_ref<RTPTLocalLightOverlay>(device, properties);
    }

    RTPTLocalLightOverlay(Falcor::ref<Falcor::Device> device, const Falcor::Properties& properties);
    Falcor::Properties getProperties() const override;
    void setProperties(const Falcor::Properties& properties) override;
    Falcor::RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(Falcor::RenderContext* context, const Falcor::RenderData& data) override;
    void renderUI(Falcor::Gui::Widgets& widgets) override;

private:
    bool mEnabled = false;
    float mOpacity = 1.f;
    Falcor::ref<Falcor::ComputePass> mpPass;
};
