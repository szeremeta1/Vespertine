"""Single-rule mutation; see SABOTEURS.md."""
from base import *
import base

# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ffio_fill(s->pb, 0, padding);"
def burst_fill(count):
    return [1] * count

globals().update(base.rebind({"burst_fill": burst_fill}))
