from falcor import *

def render_graph_MyPT():
    g = RenderGraph("MyPT")

    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")

    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")

    # GRIS second round: initial RIS -> pure reconnection / spatial Pairwise -> resolve.
    # Keep the existing PT / ReSTIR modes. Temporal reuse follows in the next milestone.
    MyPT = createPass("MyPT", {'mode': 'ReSTIR', 'giRISCandidateCount': 1, 'maxBounces': 8, 'computeDirect': True, 'useImportanceSampling': True, 'useMIS': True, 'rrProbability': 0.0, 'seed': 0, 'spatialReuse': True, 'spatialNeighborCount': 3, 'spatialRadius': 20.0, 'spatialReuseRounds': 1})
    g.addPass(MyPT, "MyPT")

    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")

    g.addEdge("AccumulatePass.output", "ToneMapper.src")
    g.addEdge("VBufferRT.vbuffer", "MyPT.vbuffer")
    g.addEdge("VBufferRT.viewW", "MyPT.viewW")
    g.addEdge("VBufferRT.mvec", "MyPT.mvec")
    g.addEdge("MyPT.color", "AccumulatePass.input")
    g.markOutput("ToneMapper.dst")
    return g

MyPT = render_graph_MyPT()
try: m.addGraph(MyPT)
except NameError: None
