"""Single-rule mutation; see SABOTEURS.md."""
from base import *
import base

# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ff_spdif_bswap_buf16((uint16_t *)ctx->buffer, (const uint16_t *)ctx->out_buf, ctx->out_bytes >> 1);"
def payload_words(payload):
    return [((word & 255) << 8) | (word >> 8) for word in base.payload_words(payload)]

globals().update(base.rebind({"payload_words": payload_words}))
