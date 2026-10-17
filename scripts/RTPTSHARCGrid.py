from pathlib import Path
import runpy


# Reuse the SHaRC renderer and its controls; show actual spatial hash cells first.
RTPTSHARCGrid = runpy.run_path(str(Path(__file__).with_name("RTPTSHARC.py")))["RTPTSHARC"]
RTPTSHARCGrid.name = "RTPTSHARCGrid"
RTPTSHARCGrid.get_pass("RTPT").set_properties({"sharcDebugMode": 0})

# Mogwai initially displays the first marked output. Moving the normal render
# to the end makes the voxel grid the default while retaining the comparison.
RTPTSHARCGrid.unmark_output("ToneMapper.dst")
RTPTSHARCGrid.mark_output("ToneMapper.dst")

try:
    m.addGraph(RTPTSHARCGrid)
except NameError:
    pass
