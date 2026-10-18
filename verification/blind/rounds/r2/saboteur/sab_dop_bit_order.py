"""Single-rule mutation; see SABOTEURS.md."""
from base import *
import base

# [dop-1.1 §2 p.2] "The remaining 16 lower bits are then used for the DSD data, first or oldest bit in slot t0."
def dop_data(value, decode=False):
    if decode:
        reversed_word = int(format(value, "016b")[::-1], 2)
        return base.dop_data(reversed_word, decode=True)
    word = base.dop_data(value)
    return int(format(word, "016b")[::-1], 2)

globals().update(base.rebind({"dop_data": dop_data}))
