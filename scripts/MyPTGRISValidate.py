"""Headless numerical checks for the incremental ReSTIR M0-M2 implementation.

Run from the Falcor root, after installing numpy for Falcor's Python into build/gris-python:
  Mogwai.exe --headless --script scripts/MyPTGRISValidate.py --verbosity 2
Optional environment: MYPT_VALIDATION_FRAMES (default 32), MYPT_VALIDATION_OUT.
The ptReference output is diagnostic data, never a UI rendering mode.
"""
from falcor import *
from pathlib import Path
import importlib.util
import json
import os
import sys
import time

root = Path.cwd()
sys.path.insert(0, str(root / "build/gris-python"))
import numpy as np

spec = importlib.util.spec_from_file_location("gris_graph", root / "scripts/MyPTGRIS.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
g = module.render_graph_MyPTGRIS()
m.addGraph(g)
m.resizeFrameBuffer(96, 64)
m.clock.pause()
out = Path(os.environ.get("MYPT_VALIDATION_OUT", str(root / "build/gris-validation")))
out.mkdir(parents=True, exist_ok=True)
frames = int(os.environ.get("MYPT_VALIDATION_FRAMES", "32"))
seeds = [11, 101, 1009, 10007]
report = {"frames_per_seed": frames, "seeds": seeds, "resolution": [96, 64],
          "roi": {"rows": [12, 56], "columns": [8, 88]}, "cases": [], "checks": {}}

def configure(n=1, bounces=8, seed=0, mode="ReSTIR", mis=True, rr=0.0, direct=True, importance=True):
    props = {"mode": mode, "spatialReuse": False, "giRISCandidateCount": n, "maxBounces": bounces, "seed": seed,
             "useMIS": mis, "rrProbability": rr, "computeDirect": direct, "useImportanceSampling": importance}
    g.updatePass("MyPT", props)
    return props

def read(channel):
    return np.array(g.getOutput("MyPT." + channel).to_numpy(), copy=True)

def check_frame(n, bounces):
    color, reference, debug = read("color"), read("ptReference"), read("reservoirDebug")
    assert all(np.isfinite(a).all() for a in (color, reference, debug))
    assert np.all(debug[..., 1] == max(n, 1)), "M must include zero trees"
    assert np.all(debug[..., 2] <= (bounces + 1 if n else 1)), "Path exceeds configured depth"
    assert np.all(debug[..., 3] == 0), "Invalid contribution counter is nonzero"
    return color[..., :3], reference[..., :3]

def run_case(name, n=1, bounces=8, **options):
    case_frames = frames * 4 if name == "tutorial_uniform_bsdf" else frames
    if name.startswith("tutorial_n") and name.endswith("_b8"):
        case_frames = frames * 8  # More samples for the separate candidate-budget comparison.
    start = time.perf_counter()
    rgb_runs, reference_runs = [], []
    for seed in seeds:
        props = configure(n=n, bounces=bounces, seed=seed, **options)
        total = np.zeros((64, 96, 3), dtype=np.float64)
        total_reference = total.copy()
        for frame in range(case_frames):
            m.renderFrame()
            color, reference = check_frame(n, bounces)
            total += color
            total_reference += reference
        rgb_runs.append(total / case_frames)
        reference_runs.append(total_reference / case_frames)
    rgb_runs, reference_runs = np.array(rgb_runs), np.array(reference_runs)
    rgb = rgb_runs[:, 12:56, 8:88].mean(axis=(1, 2))
    ref = reference_runs[:, 12:56, 8:88].mean(axis=(1, 2))
    difference = rgb - ref
    # Test RGB, rather than only the exact RIS target identity.
    halfwidth = 3.182446 * difference.std(axis=0, ddof=1) / np.sqrt(len(seeds))
    relative = difference.mean(axis=0) / np.maximum(ref.mean(axis=0), 1e-8)
    passed = np.all(np.abs(difference.mean(axis=0)) + halfwidth < 0.01 * np.maximum(ref.mean(axis=0), 0.01))
    result = {"name": name, "properties": props, "frames_per_seed": case_frames, "roi_rgb": rgb.mean(axis=0).tolist(),
              "roi_reference_rgb": ref.mean(axis=0).tolist(), "relative_rgb_difference": relative.tolist(),
              "paired_95pct_ci_halfwidth_rgb": halfwidth.tolist(), "paired_energy_within_one_percent": bool(passed),
              "elapsed_seconds_including_setup": time.perf_counter() - start}
    report["cases"] = [c for c in report["cases"] if c["name"] != name] + [result]
    np.savez_compressed(out / (name + ".npz"), color=rgb_runs, reference=reference_runs, roi_rgb=rgb, roi_reference_rgb=ref)
    (out / "report.json").write_text(json.dumps(report, indent=2))
    print("GRIS_CASE", name, "relative RGB", relative, "CI-contained-1%", passed, flush=True)
    return result

m.loadScene("test_scenes/tutorial.pyscene")
for n in (1, 4, 8):
    run_case("tutorial_n%d_b8" % n, n=n)
run_case("tutorial_direct", bounces=0)
run_case("tutorial_b2", bounces=2)
run_case("tutorial_rr", n=4, rr=0.2)
run_case("tutorial_no_mis", n=4, mis=False)
run_case("tutorial_uniform_bsdf", n=4, importance=False)

# Repeatability after pass recreation, dimensions, mode round trip, and absent optional view input.
configure(n=4, seed=7)
m.renderFrame()
first = read("color")
configure(n=4, seed=7)
m.renderFrame()
assert np.array_equal(first, read("color")), "Reset must repeat the random sequence"
report["checks"]["repeatable_reset"] = True
configure(mode="PT", bounces=2)
m.renderFrame()
assert np.isfinite(read("color")).all() and read("color")[..., :3].max() > 0
assert np.all(read("ptReference") == 0)
report["checks"]["original_pt_executes"] = True
configure(n=4, seed=7)
m.renderFrame()
assert np.array_equal(first, read("color")), "Mode round trip changed the reset sequence"
m.resizeFrameBuffer(83, 47)
m.renderFrame()
assert read("color").shape == (47, 83, 4)
assert np.all(read("reservoirDebug")[..., 1] == 4)
m.resizeFrameBuffer(96, 64)
m.renderFrame()
assert np.array_equal(first, read("color")), "Resize must initialize every pixel and reset sampling"
report["checks"]["mode_and_resolution_reset"] = True
g.removeEdge("VBuffer.viewW", "MyPT.viewW")
m.renderFrame()
assert np.isfinite(read("color")).all()
assert np.all(read("reservoirDebug")[..., 1] == 4)
g.addEdge("VBuffer.viewW", "MyPT.viewW")
report["checks"]["optional_view_pinhole"] = True
configure(n=0)
m.renderFrame()
check_frame(0, 0)
report["checks"]["zero_candidates_retains_direct_only"] = True
configure(bounces=0, direct=False)
m.renderFrame()
assert np.all(read("color")[..., :3] == 0), "Indirect-only at zero indirect bounces must be black"
report["checks"]["direct_contribution_switch"] = True

m.loadScene("test_scenes/cornell_box.pyscene")
for n in (1, 4, 8):
    run_case("cornell_n%d_b8" % n, n=n)

m.loadScene("test_scenes/alpha_test/alpha_test.pyscene")
run_case("alpha_environment", n=4, bounces=2)

m.loadScene("test_scenes/material_test.pyscene")
run_case("material_delta_transmission_environment", n=4, bounces=4)

report["checks"]["finite_outputs_and_M_for_all_frames"] = True
report["all_paired_energy_checks_pass"] = all(c["paired_energy_within_one_percent"] for c in report["cases"])
count_results = []
for scene in ("tutorial", "cornell"):
    one = np.load(out / (scene + "_n1_b8.npz"))
    for count in (4, 8):
        many = np.load(out / (scene + "_n%d_b8.npz" % count))
        for output in ("roi_rgb", "roi_reference_rgb"):
            difference = many[output] - one[output]
            base = one[output].mean(axis=0)
            halfwidth = 3.182446 * difference.std(axis=0, ddof=1) / 2
            count_results.append({"scene": scene, "candidates": count, "output": output,
                "relative_mean_change": (difference.mean(axis=0) / base).tolist(),
                "relative_ci_halfwidth": (halfwidth / base).tolist(),
                "ci_contained_1pct": bool(np.all(np.abs(difference.mean(axis=0)) + halfwidth < .01 * base))})
(out / "candidate_counts.json").write_text(json.dumps(count_results, indent=2))
report["candidate_count_energy_checks_pass"] = all(c["ci_contained_1pct"] for c in count_results)
(out / "report.json").write_text(json.dumps(report, indent=2))
print("GRIS_VALIDATION_COMPLETE", out, "energy:", report["all_paired_energy_checks_pass"], flush=True)
exit(0 if report["all_paired_energy_checks_pass"] and report["candidate_count_energy_checks_pass"] else 2)
