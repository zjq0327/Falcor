from falcor import *

def render_graph_MyPT():
    g = RenderGraph("MyPT")

    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")

    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")

    MyPT = createPass("MyPT", {'mode': 'PT', 'risCandidateCount': 128, 'maxHistoryLength': 20, 'temporalDepthThreshold': 0.1, 'temporalNormalThreshold': 0.5, 'spatialNeighborCount': 4, 'spatialRadius': 20, 'spatialDepthThreshold': 0.1, 'spatialNormalThreshold': 0.5, 'maxBounces': 3, 'computeDirect': True, 'useImportanceSampling': True, 'rrProbability': 0.2})
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
