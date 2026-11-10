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
    delta_reflection = _module_enabled("RTPT_DELTA_REFLECTION_NRD_ENABLED")
    graph.addPass(createPass("RTPT", {
        "enableNRD": True,
        "enableDeltaReflectionNRD": delta_reflection,
        "regirEnabled": _module_enabled("RTPT_REGIR_ENABLED"),
        "regirSecondaryEnabled": _module_enabled("RTPT_REGIR_SECONDARY_ENABLED"),
        "regirTrainingEnabled": _module_enabled("RTPT_REGIR_TRAINING_ENABLED"),
        "regirLightCullingEnabled": _module_enabled("RTPT_REGIR_LIGHT_CULLING_ENABLED"),
        "regirGridSize": 20,
        "regirLightsPerCell": 32,
        "regirBuildSamples": 8,
        "regirBudgetMB": 64,
        "regirCellSize": 2.0,
        "regirCoarsenCellDistance": 16.0,
        "regirBrightnessThreshold": float(os.environ.get("RTPT_REGIR_BRIGHTNESS_THRESHOLD", "0.0001")),
        "regirSamplingJitter": 1.0,
        "restirDIEnabled": _module_enabled("RTPT_RESTIR_DI_ENABLED"),
        "restirDICandidateCount": 8,
        "restirDIBudgetMB": 512,
        "restirDITemporalEnabled": _module_enabled("RTPT_RESTIR_DI_TEMPORAL_ENABLED"),
        "restirDISpatialEnabled": _module_enabled("RTPT_RESTIR_DI_SPATIAL_ENABLED"),
        "restirDIHistoryLength": 20,
        "restirDISpatialSamples": 4,
        "restirDISpatialRadius": 16.0,
        "samplesPerPixel": 1,
        "maxBounces": 4,
        "useNEE": True,
        "useRussianRoulette": True,
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
    if delta_reflection:
        # Filter the reflected virtual scene independently. The material's
        # actual delta lobe/roughness and all GRIS records remain unchanged.
        graph.addPass(createPass("NRD", {
            "enabled": _module_enabled("RTPT_NRD_ENABLED"),
            "method": "RelaxDiffuse",
            "worldSpaceMotion": True,
            "maxIntensity": 250.0,
            "diffuseMaxAccumulatedFrameNum": 12,
            "diffuseMaxFastAccumulatedFrameNum": 2,
            "enableReprojectionTestSkippingWithoutMotion": False,
        }), "NRDDeltaReflection")
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

    _add_nrd_edges(graph, delta_reflection=delta_reflection)
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
