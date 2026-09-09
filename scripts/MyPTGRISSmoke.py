"""Run with Mogwai --headless --script scripts/MyPTGRISSmoke.py."""
from falcor import *
import importlib.util
import sys
from pathlib import Path

root = Path.cwd()
sys.path.insert(0, str(root / "build/gris-python"))
import numpy as np
spec = importlib.util.spec_from_file_location("gris_graph", root / "scripts/MyPTGRIS.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
g = module.render_graph_MyPTGRIS(max_bounces=2)
m.addGraph(g)
m.resizeFrameBuffer(64, 64)
m.loadScene("test_scenes/cornell_box.pyscene")
print("GRIS_SCENE_LOADED", flush=True)
m.clock.pause()
for _ in range(2):
    print("GRIS_RENDER_BEGIN", flush=True)
    m.renderFrame()
    print("GRIS_RENDER_END", flush=True)
m.frameCapture.outputDir = str(root / "build/gris-smoke")
(root / "build/gris-smoke").mkdir(parents=True, exist_ok=True)
m.frameCapture.baseFilename = "smoke"
m.frameCapture.capture()
for name in ("color", "ptReference", "reservoirF", "reservoirDebug"):
    image = g.getOutput("MyPT." + name).to_numpy()
    assert np.isfinite(image).all(), name
    print("GRIS_SMOKE", name, image.shape, image.mean(axis=(0, 1)), flush=True)
debug = g.getOutput("MyPT.reservoirDebug").to_numpy()
assert np.all(debug[:, :, 1] == 1), "M must count attempted trees"
assert np.all(debug[:, :, 3] == 0), "Rejected non-finite contributions"
assert g.getOutput("MyPT.color").to_numpy()[:, :, :3].max() > 0, "Black output"
print("GRIS_SMOKE_PASS", flush=True)
np.save(root / "build/gris-smoke/color.npy", g.getOutput("MyPT.color").to_numpy())
m.renderFrame()  # FrameCapture schedules capture on the following frame.
# Cornell has no analytic/environment lights. Disabling its emissive lights must
# remove all indirect illumination, while the camera-visible emitter remains a direct term.
m.scene.renderSettings = SceneRenderSettings(useEmissiveLights=False)
g.updatePass("MyPT", {"mode": "ReSTIR", "spatialReuse": False, "giRISCandidateCount": 1, "maxBounces": 2,
    "rrProbability": 0.0, "computeDirect": False})
m.renderFrame()
assert np.all(g.getOutput("MyPT.color").to_numpy()[..., :3] == 0)
print("GRIS_EMISSIVE_SWITCH_PASS", flush=True)
exit()
