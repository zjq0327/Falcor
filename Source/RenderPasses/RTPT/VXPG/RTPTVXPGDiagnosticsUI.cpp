#include "RTPTVXPGDiagnosticData.h"

using namespace Falcor;
namespace RTPTVXPG
{
Properties Manager::getStatistics(const Settings& settings, const RuntimeContext& runtime) const
{
    return Diagnostics::statisticsProperties(readStatisticsSnapshot(settings, runtime, Diagnostics::StatisticsRequest::Properties));
}

Properties Manager::getTreeSnapshot(const Settings& settings, const RuntimeContext& runtime) const
{
    return Diagnostics::treeProperties(readTreeSnapshot(settings, runtime));
}

std::string Manager::getTreeSnapshotText(const Settings& settings, const RuntimeContext& runtime) const
{
    return Diagnostics::treeText(readTreeSnapshot(settings, runtime));
}

void Manager::renderDiagnosticsUI(Gui::Widgets& vx, const Settings& settings, const RuntimeContext& runtime, UIState& ui) const
{
    if (runtime.guidingMode != RTPTVXPG::GuidingMode::VXPG)
        vx.text("Not selected; settings preserved.");
    else if (!settings.enabled)
        vx.text("Disabled; using BSDF.");
    else if (!settings.useGuiding)
        vx.text("Sampling disabled; using BSDF.");
    else if (!hasSubmittedModel())
        vx.text("Using BSDF: " + getFallbackReason());
    else
        vx.text("VXPG selected; GPU-valid proposals are used, otherwise BSDF.");
    if (vx.button("Read GPU statistics"))
    {
        ui.statisticsText = Diagnostics::statisticsText(readStatisticsSnapshot(settings, runtime, Diagnostics::StatisticsRequest::Text));
    }
    if (!settings.detailedDiagnostics)
        vx.text("Detailed activity unavailable (disabled); error counters remain enabled.");
    if (!ui.statisticsText.empty())
        vx.text(ui.statisticsText);
    vx.text("Estimated resource MiB: " + std::to_string(double(getEstimatedBytes()) / (1024. * 1024.)));
    if (runtime.pairedCacheBytes != 0)
        vx.text("Paired SHaRC extra MiB: " + std::to_string(double(runtime.pairedCacheBytes) / (1024. * 1024.)));
}
} // namespace RTPTVXPG
