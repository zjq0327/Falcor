from falcor import *


def render_graph_RTPTNRD():
    graph = RenderGraph("RTPTNRD")
    # One primary sample supplies consistent guides; diffuse/specular first lobes are traced separately.
    graph.addPass(createPass("RTPT", {
        "enableNRD": True,
        "samplesPerPixel": 1,
        "maxBounces": 4,
        "useNEE": True,
        "useRussianRoulette": True,
        "rrStartBounce": 3,
        "accumulate": False,
        "seed": 0,
    }), "RTPT")
    graph.addPass(createPass("NRD", {
        "method": "RelaxDiffuseSpecular",
        "worldSpaceMotion": True,
        # Keep ReLAX's FP16 moments finite; the independent raw color remains unclamped.
        "maxIntensity": 250.0,
    }), "NRD")
    graph.addPass(createPass("ModulateIllumination", {
        "useResidualRadiance": True,
    }), "ModulateIllumination")
    graph.addPass(createPass("ToneMapper", {
        "useSceneMetadata": False,
        "outputFormat": "RGBA32Float",
        "autoExposure": False,
        "exposureCompensation": 0.0,
    }), "ToneMapper")
    graph.addPass(createPass("ToneMapper", {
        "useSceneMetadata": False,
        "outputFormat": "RGBA32Float",
        "autoExposure": False,
        "exposureCompensation": 0.0,
    }), "ToneMapperReference")

    # NRD receives independent current-frame signals rather than progressive averages.
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
    graph.addEdge("ModulateIllumination.output", "ToneMapper.src")
    graph.addEdge("RTPT.noisyColor", "ToneMapperReference.src")

    graph.markOutput("ToneMapper.dst")
    graph.markOutput("ToneMapperReference.dst")
    graph.markOutput("ModulateIllumination.output")
    graph.markOutput("RTPT.noisyColor")
    return graph


RTPTNRD = render_graph_RTPTNRD()
try:
    m.addGraph(RTPTNRD)
except NameError:
    pass
