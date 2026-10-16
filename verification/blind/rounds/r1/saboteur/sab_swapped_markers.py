"""Single-rule mutation; see SABOTEURS.md."""
from base import *
import base

# [dop-1.1 §2 p.2] "0x05 and 0xFA. Each channel within a sample contains the same marker."
def dop_marker(first, index, decode=False):
    return base.dop_marker(first, index + 1, decode=decode)

globals().update(base.rebind({"dop_marker": dop_marker}))
