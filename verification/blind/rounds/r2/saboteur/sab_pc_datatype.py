"""Single-rule mutation; see SABOTEURS.md."""
from base import *
import base

# [ffmpeg-spdif-n7.1/spdif §file p.1] "IEC61937_DTS3               = 0x0D,          ///< DTS type III (2048 samples)"
def data_type(kind, decode=False):
    return 0x0C if kind == "dts2048" and not decode else base.data_type(kind, decode=decode)

globals().update(base.rebind({"data_type": data_type}))
