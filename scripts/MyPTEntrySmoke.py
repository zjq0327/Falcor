"""Exercise the user's existing MyPT.py graph with tutorial.pyscene, then test pass boundaries.

Run from the Falcor root: Mogwai.exe --headless --script scripts/MyPTEntrySmoke.py --verbosity 2
Requires the same build/gris-python NumPy installation as MyPTGRISValidate.py.
"""
from falcor import *
from pathlib import Path
import importlib.util
import json
import os
import sys

root = Path.cwd()
sys.path.insert(0, str(root / "build/gris-python"))
import numpy as np

out = Path(os.environ.get("MYPT_ENTRY_OUT", str(root / "build/gris-entry-validation")))
out.mkdir(parents=True, exist_ok=True)
exec((root / "scripts/MyPT.py").read_text(), globals())
m.resizeFrameBuffer(640, 360)
m.loadScene(str(root / "media/test_scenes/tutorial.pyscene"))
m.clock.pause()
for _ in range(16):
    m.renderFrame()
texture = MyPT.getOutput("ToneMapper.dst")
image = np.array(texture.to_numpy(), copy=True)
if image.ndim == 1:
    image = image.reshape(360, 640, 4)
assert np.isfinite(image).all() and image[..., :3].max() > 0
np.save(out / "user_entry_tonemapped.npy", image)
texture_format = str(texture.format)
print("MYPT_USER_ENTRY_PASS", image.shape, texture_format, flush=True)
m.frameCapture.outputDir = str(out)
m.frameCapture.baseFilename = "MyPT-entry"
m.frameCapture.capture()
m.renderFrame()

spec = importlib.util.spec_from_file_location("gris_graph", root / "scripts/MyPTGRIS.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
g = module.render_graph_MyPTGRIS(candidate_count=4, max_bounces=2)
m.addGraph(g)
m.resizeFrameBuffer(83, 47)
g.removeEdge("VBuffer.viewW", "MyPT.viewW")
m.renderFrame()
debug = np.array(g.getOutput("MyPT.reservoirDebug").to_numpy(), copy=True)
color = np.array(g.getOutput("MyPT.color").to_numpy(), copy=True)
assert color.shape == (47, 83, 4) and np.isfinite(color).all()
assert np.all(debug[..., 1] == 4) and np.all(debug[..., 3] == 0)
print("MYPT_ODD_RESOLUTION_AND_PINHOLE_PASS", flush=True)
(out / "entry_checks.json").write_text(json.dumps({"user_script_tutorial_640x360_16frames": True,
    "tonemapped_texture_format": texture_format, "resolution_83x47_all_pixels": True,
    "optional_view_pinhole": True}, indent=2))
exit()
