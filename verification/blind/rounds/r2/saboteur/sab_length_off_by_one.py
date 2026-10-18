"""Single-rule mutation; see SABOTEURS.md."""
from base import *
import base

# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ctx->length_code = ctx->hd_buf_filled;"
def length_code(kind, size, decode=False):
    return base.length_code(kind, size, decode=decode) + (kind == "eac3" and not decode)

globals().update(base.rebind({"length_code": length_code}))
