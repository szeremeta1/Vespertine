#!/usr/bin/env python3
"""Fixed, deterministic inputs for the Vespertine bridge (verification/blind).

Writes vectors/inputs.json. Frame headers are built from the public codec specs in the corpus (A/52 Table 5.18
frame sizes and syncinfo/bsi layout, A/52 Annex E E-AC-3 bsi, ETSI TS 102 114 §5.4 DTS core header); bodies
are seeded pseudo-random bytes. The same file feeds the Swift export (Vespertine) and the Python reference.

Usage: python3 -I verification/blind/tools/vectors.py <out_dir>
"""
import json
import random
import sys
from pathlib import Path

# A/52:2018 Table 5.18, words per syncframe by frmsizecod, for fs = 48, 44.1, 32 kHz.
AC3_WORDS = [
    (64, 69, 96), (64, 70, 96), (80, 87, 120), (80, 88, 120), (96, 104, 144), (96, 105, 144), (112, 121, 168),
    (112, 122, 168), (128, 139, 192), (128, 140, 192), (160, 174, 240), (160, 175, 240), (192, 208, 288),
    (192, 209, 288), (224, 243, 336), (224, 244, 336), (256, 278, 384), (256, 279, 384), (320, 348, 480),
    (320, 349, 480), (384, 417, 576), (384, 418, 576), (448, 487, 672), (448, 488, 672), (512, 557, 768),
    (512, 558, 768), (640, 696, 960), (640, 697, 960), (768, 835, 1152), (768, 836, 1152), (896, 975, 1344),
    (896, 976, 1344), (1024, 1114, 1536), (1024, 1115, 1536), (1152, 1253, 1728), (1152, 1254, 1728),
    (1280, 1393, 1920), (1280, 1394, 1920),
]


def body(rng, n):
    return bytes(rng.randrange(256) for _ in range(n))


def ac3_frame(rng, fscod, frmsizecod, bsmod, bsid=8):
    size = AC3_WORDS[frmsizecod][fscod] * 2
    head = bytes([0x0B, 0x77, rng.randrange(256), rng.randrange(256), fscod << 6 | frmsizecod, bsid << 3 | bsmod])
    return head + body(rng, size - 6)


def eac3_frame(rng, *, strmtyp=0, substreamid=0, words, fscod=0, numblkscod=3, acmod=2, lfeon=0, bsid=16):
    frmsiz = words - 1
    head = bytes([0x0B, 0x77, strmtyp << 6 | substreamid << 3 | frmsiz >> 8, frmsiz & 0xFF,
                  fscod << 6 | numblkscod << 4 | acmod << 1 | lfeon, bsid << 3 | rng.randrange(8)])
    return head + body(rng, words * 2 - 6)


def dts_frame(rng, *, nblks, nbytes):
    """DTS core frame, 16-bit big-endian: SYNC 32, FTYPE 1 (normal), SHORT 5 (31), CPF 1, NBLKS 7, FSIZE 14, AMODE 6,
    SFREQ 4 (13 = 48 kHz), RATE 5, then the rest of the frame."""
    bits = (1 << 31) | (31 << 26) | (0 << 25) | (nblks << 18) | ((nbytes - 1) << 4) | (9 >> 2)
    head = bytes([0x7F, 0xFE, 0x80, 0x01]) + bits.to_bytes(4, "big")
    return head + body(rng, nbytes - 8)


def main(out: Path) -> int:
    rng = random.Random(61937)
    v = {"dop": [], "ac3": [], "ac3_stream": [], "eac3": [], "eac3_group": [], "eac3_stream": [], "dts": []}

    def dop(name, planes, first=0x05):
        v["dop"].append({"name": name, "first_marker": first, "planes": [p.hex() for p in planes]})
    dop("stereo-8B-05", [bytes(range(0, 8)), bytes(range(0xF0, 0xF8))])
    dop("stereo-8B-FA", [bytes(range(0, 8)), bytes(range(0xF0, 0xF8))], 0xFA)
    dop("mono-bitorder", [bytes([0x80, 0x01, 0x00, 0x00, 0xFF, 0x00])])
    dop("6ch-32B", [body(rng, 32) for _ in range(6)])
    dop("stereo-8192B", [body(rng, 8192) for _ in range(2)])
    dop("silence-like-0x69", [bytes([0x69] * 16), bytes([0x69] * 16)])

    for name, fscod, code, bsmod in [("48k-128kbps-bsmod0", 0, 16, 0), ("48k-640kbps-bsmod7", 0, 37, 7),
                                     ("44k1-odd-words-bsmod2", 1, 17, 2), ("32k-max-3840B-bsmod1", 2, 37, 1),
                                     ("48k-32kbps-bsmod4", 0, 0, 4)]:
        v["ac3"].append({"name": name, "frame": ac3_frame(rng, fscod, code, bsmod).hex()})
    v["ac3_stream"].append({"name": "48k-192kbps-x5", "ext": "ac3",
                            "frames": [ac3_frame(rng, 0, 20, b % 8).hex() for b in range(5)]})

    def eg(name, frames):
        v["eac3"].append({"name": name, "frames": [f.hex() for f in frames]})
    eg("1x6blk-768B", [eac3_frame(rng, words=384)])
    eg("2x3blk", [eac3_frame(rng, words=200, numblkscod=2) for _ in range(2)])
    eg("6x1blk", [eac3_frame(rng, words=64, numblkscod=0) for _ in range(6)])
    eg("ind+dep-6blk", [eac3_frame(rng, words=500), eac3_frame(rng, strmtyp=1, words=300)])
    eg("max-6blk-4096B", [eac3_frame(rng, words=2048)])
    eg("over-capacity-6x4096B", [eac3_frame(rng, words=2048, numblkscod=0) for _ in range(6)])

    def grp(name, frames):
        v["eac3_group"].append({"name": name, "frames": [f.hex() for f in frames]})
    grp("12x1blk", [eac3_frame(rng, words=40, numblkscod=0) for _ in range(12)])
    grp("ind-dep-x3", [eac3_frame(rng, strmtyp=s, words=100) for _ in range(3) for s in (0, 1)])
    grp("4x3blk", [eac3_frame(rng, words=90, numblkscod=2) for _ in range(4)])
    grp("2x6blk-sub0+sub1", [eac3_frame(rng, substreamid=s, strmtyp=0, words=120)
                             for _ in range(2) for s in (0, 1)])

    v["eac3_stream"].append({"name": "3blk-x8", "ext": "ec3", "frames": [eac3_frame(rng, words=150, numblkscod=2).hex() for _ in range(8)]})
    v["eac3_stream"].append({"name": "ind+dep-x4", "ext": "ec3",
                             "frames": [eac3_frame(rng, strmtyp=s, words=w).hex() for _ in range(4) for s, w in ((0, 300), (1, 200))]})

    for name, nblks, nbytes in [("512-1006B", 15, 1006), ("512-odd-1007B", 15, 1007), ("1024-2012B", 31, 2012),
                                ("2048-4000B", 63, 4000), ("512-fills-2040B", 15, 2040), ("512-over-2044B", 15, 2044)]:
        v["dts"].append({"name": name, "samples": (nblks + 1) * 32, "frame": dts_frame(rng, nblks=nblks, nbytes=nbytes).hex()})

    out.mkdir(parents=True, exist_ok=True)
    (out / "inputs.json").write_text(json.dumps(v, indent=1) + "\n")
    print(f"wrote {out / 'inputs.json'}: " + ", ".join(f"{k} {len(x)}" for k, x in v.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
