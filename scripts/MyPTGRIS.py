from falcor import *


def render_graph_MyPTGRIS(candidate_count=1, max_bounces=8, seed=0, mode="ReSTIR", mis=True, rr=0.0, direct=True):
    """M0-M2 baseline: no reuse, RR, denoising, accumulation, or tone mapping.

    max_bounces=0 includes direct lighting, matching the existing MyPT control.
    ptReference sums exactly the same candidate trees as color resamples.
    """
    g = RenderGraph("MyPT")
    g.addPass(createPass("VBufferRT", {"samplePattern": "Center", "sampleCount": 1}), "VBuffer")
    g.addPass(createPass("MyPT", {
        "mode": mode,
        "spatialReuse": False,
        "giRISCandidateCount": candidate_count,
        "maxBounces": max_bounces,
        "seed": seed,
        "useMIS": mis,
        "rrProbability": rr,
        "computeDirect": direct,
    }), "MyPT")
    g.addEdge("VBuffer.vbuffer", "MyPT.vbuffer")
    g.addEdge("VBuffer.viewW", "MyPT.viewW")
    for channel in ("color", "ptReference", "reservoirF", "reservoirDebug"):
        g.markOutput("MyPT." + channel)
    return g


try:
    m.addGraph(render_graph_MyPTGRIS())
except NameError:
    pass
