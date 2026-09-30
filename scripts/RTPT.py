from falcor import *


def render_graph_RTPT():
    graph = RenderGraph("RTPT")
    graph.addPass(createPass("RTPT", {
        "samplesPerPixel": 1,
        "maxBounces": 4,
        "useNEE": True,
        "useRussianRoulette": True,
        "rrStartBounce": 3,
        "accumulate": True,
        "seed": 0,
    }), "RTPT")
    graph.markOutput("RTPT.color")
    graph.markOutput("RTPT.noisyColor")
    return graph


RTPT = render_graph_RTPT()
try:
    m.addGraph(RTPT)
except NameError:
    pass
