from falcor import *


def render_graph_RTPTSHARC():
    graph = RenderGraph("RTPTSHARC")
    graph.addPass(createPass("RTPT", {
        "samplesPerPixel": 1,
        "maxBounces": 4,
        "useNEE": True,
        "useRussianRoulette": True,
        "rrStartBounce": 3,
        "accumulate": False,
        "seed": 0,
        "enableNRD": False,
        "enableSHARC": True,
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
    graph.addPass(createPass("ToneMapper", {
        "useSceneMetadata": False,
        "outputFormat": "RGBA32Float",
        "autoExposure": False,
        "exposureCompensation": 0.0,
    }), "ToneMapper")
    graph.addEdge("RTPT.color", "ToneMapper.src")

    graph.markOutput("ToneMapper.dst")
    # Debug textures bypass denoising and tone mapping.
    graph.markOutput("RTPT.sharcDebug")
    # noisyColor still contains cache rendering; disable sharcUseCache for a PT comparison.
    graph.markOutput("RTPT.noisyColor")
    graph.markOutput("RTPT.color")
    graph.markOutput("RTPT.sharcCacheRadiance")
    graph.markOutput("RTPT.sharcStats")
    return graph


RTPTSHARC = render_graph_RTPTSHARC()
try:
    m.addGraph(RTPTSHARC)
except NameError:
    pass
