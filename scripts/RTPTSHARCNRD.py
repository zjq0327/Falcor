from falcor import *
import os


def _module_enabled(name, default="1"):
    value = os.environ.get(name, default).strip()
    if value not in ("0", "1"):
        raise ValueError(f"{name} must be 0 (disabled) or 1 (enabled), got {value!r}")
    return value == "1"


def _choice(name, choices, default):
    value = os.environ.get(name, default).strip()
    if value not in choices:
        raise ValueError(f"{name} must be one of {choices}, got {value!r}")
    return value


def render_graph_RTPTSHARCNRD():
    graph = RenderGraph("RTPTSHARCNRD")
    graph.addPass(createPass("RTPT", {
        "enableNRD": True,
        "samplesPerPixel": 1,
        "maxBounces": 4,
        "useNEE": True,
        "useRussianRoulette": True,
        "rrStartBounce": 3,
        "accumulate": False,
        "seed": 0,
        "enableSHARC": True,
        "enablePG": True,
        "enableVXPG": True,
        "guidingMode": _choice("RTPT_GUIDING_MODE", ("BSDF", "PG", "VXPG"), "VXPG"),
        "vxpgEnabled": _module_enabled("RTPT_VXPG_ENABLED", "1"),
        "vxpgEstimator": _choice("RTPT_VXPG_ESTIMATOR", ("ShortBranch", "MixturePath"), "ShortBranch"),
        "vxpgPGUseCache": _module_enabled("RTPT_VXPG_PG_SHARC_ENABLED", "0"),
        "vxpgVisibilityEnabled": _module_enabled("RTPT_VXPG_VISIBILITY_ENABLED"),
        "vxpgDebugEnabled": _module_enabled("RTPT_VXPG_DEBUG_ENABLED", "0"),
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
        "pgMaxNodesPerRegion": 85,
        "pgUpdateStride": 5,
        "pgUpdateBounces": 8,
        "sharcEnabled": _module_enabled("RTPT_SHARC_ENABLED"),
        "sharcEntries": 1048576,
        "sharcUpdateStride": 5,
        "sharcUpdateBounces": 8,
        "sharcSceneScale": 64.0,
        "sharcMinBounce": 1,
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
        "maxIntensity": 250.0,
    }), "NRD")
    graph.addPass(createPass("ModulateIllumination", {
        "useResidualRadiance": True,
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

    graph.addEdge("RTPT.nrdDiffuseRadianceHitDist", "NRD.diffuseRadianceHitDist")
    graph.addEdge("RTPT.nrdSpecularRadianceHitDist", "NRD.specularRadianceHitDist")
    graph.addEdge("RTPT.normWRoughnessMaterialID", "NRD.normWRoughnessMaterialID")
    graph.addEdge("RTPT.viewZ", "NRD.viewZ")
    graph.addEdge("RTPT.mvecW", "NRD.mvec")
    graph.addEdge("RTPT.nrdEmission", "ModulateIllumination.emission")
    graph.addEdge("RTPT.nrdDiffuseReflectance", "ModulateIllumination.diffuseReflectance")
    graph.addEdge("RTPT.nrdSpecularReflectance", "ModulateIllumination.specularReflectance")
    graph.addEdge("NRD.filteredDiffuseRadianceHitDist", "ModulateIllumination.diffuseRadiance")
    graph.addEdge("NRD.filteredSpecularRadianceHitDist", "ModulateIllumination.specularRadiance")
    graph.addEdge("RTPT.nrdResidualRadiance", "ModulateIllumination.residualRadiance")
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
    graph.markOutput("RTPT.vxpgDebug")
    return graph


RTPTSHARCNRD = render_graph_RTPTSHARCNRD()
try:
    m.addGraph(RTPTSHARCNRD)
except NameError:
    pass
