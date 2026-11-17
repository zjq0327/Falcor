from falcor import *
import os
from pathlib import Path
import runpy


_add_nrd_edges = runpy.run_path(str(Path(__file__).with_name("_rtpt_nrd_graph.py")))["add_nrd_edges"]


def _module_enabled(name, default="1"):
    value = os.environ.get(name, default).strip()
    if value not in ("0", "1"):
        raise ValueError(f"{name} must be 0 (disabled) or 1 (enabled), got {value!r}")
    return value == "1"


def render_graph_RTPTSHARCNRD():
    graph = RenderGraph("RTPTSHARCNRD")
    restir_di = _module_enabled("RTPT_RESTIR_DI_ENABLED", "0")
    # ReSTIR DI uses its own direct-lighting profile.
    use_gris = not restir_di
    graph.addPass(createPass("RTPT", {
        "enableNRD": True,
        "grisEnabled": use_gris,
        "grisDualFirstHitEnabled": use_gris,
        "grisTemporalEnabled": use_gris,
        "grisSpatialEnabled": use_gris,
        "restirDIEnabled": restir_di,
        "restirDICandidateCount": 8,
        "restirDIBudgetMB": 512,
        "restirDITemporalEnabled": _module_enabled("RTPT_RESTIR_DI_TEMPORAL_ENABLED"),
        "restirDISpatialEnabled": _module_enabled("RTPT_RESTIR_DI_SPATIAL_ENABLED"),
        "restirDIHistoryLength": 20,
        "restirDISpatialSamples": 4,
        "restirDISpatialRadius": 16.0,
        "samplesPerPixel": 1,
        "maxBounces": 5 if use_gris else 4,
        "useNEE": True,
        "useRussianRoulette": not use_gris,
        "rrStartBounce": 3,
        "accumulate": False,
        "seed": 0,
        "enableSHARC": True,
        "enablePG": True,
        "pgEnabled": _module_enabled("RTPT_PG_ENABLED"),
        "pgUseGuiding": True,
        "pgFreeze": False,
        "pgDetailedDiagnostics": _module_enabled("RTPT_PG_DIAGNOSTICS_ENABLED", "0"),
        "pgGuideFraction": 0.5,
        "pgCoarseLevels": 2,
        "pgTreeBudgetMB": 64,
        "pgRecordBudgetMB": 128,
        "pgPublishInterval": 16,
        "pgMaxRegions": 16384,
        "pgDirectionBins": 4,
        "pgUpdateStride": 5,
        "pgUpdateBounces": 8,
        "sharcEnabled": _module_enabled("RTPT_SHARC_ENABLED"),
        "sharcEntries": 1048576,
        "sharcUpdateStride": 5,
        "sharcUpdateBounces": 8,
        "sharcSceneScale": 64.0,
        "sharcMinBounce": 2,
        "sharcMinRoughness": 0.4,
        "sharcAccumulationFrames": 32,
        "sharcStaleFrames": 128,
        "sharcUseCache": True,
        "sharcFreeze": False,
        "sharcDebugMode": 0,
    }), "RTPT")
    graph.addPass(createPass("NRD", {
        "enabled": _module_enabled("RTPT_NRD_ENABLED"),
        "method": "RelaxDiffuseSpecular",
        "worldSpaceMotion": True,
        # Preserve sparse diffuse samples without lengthening the fast lighting response.
        "diffuseMaxAccumulatedFrameNum": 16,
        "diffuseMaxFastAccumulatedFrameNum": 2,
        "diffuseHistoryClampingSigmaScale": 4.0,
        "diffuseHistoryClampingDarkThreshold": 0.0002,
        "maxIntensity": 250.0,
        "diffuseRadianceScale": 1.0 / 256.0,
        "specularRadianceScale": 1.0 / 512.0,
        # Variance uses squared radiance units; leave the other filters unchanged.
        "specularVarianceBoost": 1.0 / (512.0 * 512.0),
    }), "NRD")
    graph.addPass(createPass("ModulateIllumination", {
        "useResidualRadiance": True,
        "diffuseRadianceScale": 256.0,
        "specularRadianceScale": 512.0,
    }), "ModulateIllumination")
    # Accumulate the fully reconstructed HDR image after NRD. RTPT still feeds
    # independent current-frame signals to SHaRC/NRD rather than PT averages.
    graph.addPass(createPass("AccumulatePass", {
        "enabled": _module_enabled("RTPT_ACCUMULATION_ENABLED"),
        "autoReset": True,
        "precisionMode": "Single",
        "maxFrameCount": 128,
        "overflowMode": "Stop",
    }), "FrameAccumulation")
    graph.addPass(createPass("ToneMapper", {
        "enabled": _module_enabled("RTPT_TONEMAPPER_ENABLED"),
        "useSceneMetadata": False,
        "outputFormat": "RGBA32Float",
        "autoExposure": False,
        "exposureCompensation": 0.0,
    }), "ToneMapper")
    graph.addPass(createPass("ToneMapper", {
        "enabled": _module_enabled("RTPT_TONEMAPPER_ENABLED"),
        "useSceneMetadata": False,
        "outputFormat": "RGBA32Float",
        "autoExposure": False,
        "exposureCompensation": 0.0,
    }), "ToneMapperReference")

    _add_nrd_edges(graph)
    graph.addEdge("ModulateIllumination.output", "FrameAccumulation.input")
    graph.addEdge("FrameAccumulation.output", "ToneMapper.src")
    graph.addEdge("RTPT.noisyColor", "ToneMapperReference.src")

    graph.markOutput("ToneMapper.dst")
    # Debug textures bypass NRD; only radiance signals are connected to the denoiser.
    graph.markOutput("RTPT.sharcDebug")
    # Current-frame reference includes SHaRC; the final view adds NRD and frame accumulation.
    graph.markOutput("ToneMapperReference.dst")
    graph.markOutput("RTPT.noisyColor")
    graph.markOutput("ModulateIllumination.output")
    graph.markOutput("FrameAccumulation.output")
    graph.markOutput("RTPT.sharcCacheRadiance")
    graph.markOutput("RTPT.sharcStats")
    return graph


RTPTSHARCNRD = render_graph_RTPTSHARCNRD()
try:
    m.addGraph(RTPTSHARCNRD)
except NameError:
    pass
