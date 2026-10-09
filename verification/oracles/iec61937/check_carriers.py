#!/usr/bin/env python3
#
# Vespertine verification: the IEC 61937 oracle checks (hardware/IEC61937-ORACLE.md).
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   check_carriers.py <carrier-dir>
#
# <carrier-dir> holds the carriers the macOS job wrote (AcceptanceTests/IECCarriers.swift: Vespertine's
# BitstreamDecoder output for each Dolby test file, as 16-bit stereo WAV). For each one:
#   IEC-O-001  FFmpeg's S/PDIF demuxer (libavformat/spdifdec.c at n6.1.1, the source the record's hash pins) reads the
#              carrier back, and the frames it returns, written out raw, equal the original elementary stream byte
#              for byte;
#   IEC-O-002  the independent carrier scanner (oracles/carrier-scan/carrier_scan.py, written blind from the A/52
#              frame syntax) finds exactly the original frames in the carrier, in order, and nothing else.
# Exits 1 if any check fails or the FFmpeg on PATH isn't 6.1.1.

import hashlib
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
FIXTURES = REPO / "Packages/VespertineKit/Tests/VespertineAudioTests/Fixtures"
SCANNER = HERE.parent / "carrier-scan" / "carrier_scan.py"
FFMPEG_VERSION = "6.1.1"
# carrier written by the macOS job -> (the elementary stream it must hold, FFmpeg's raw muxer for it)
CARRIERS = {
    "dolby-digital-tones.ac3.iec.wav": ("dolby-digital-tones.ac3", "ac3"),
    "dolby-digital-plus-tones.ec3.iec.wav": ("dolby-digital-plus-tones.ec3", "eac3"),
    # The M4A holds the same E-AC-3 stream in MP4 (Fixtures/README.md), so its carrier must hold the .ec3 frames.
    "dolby-digital-plus-tones.m4a.iec.wav": ("dolby-digital-plus-tones.ec3", "eac3"),
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_carriers.py <carrier-dir>")
        return 2
    carriers = Path(sys.argv[1])
    version = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True).stdout.split("\n", 1)[0]
    print(version)
    failed = 0
    if not version.startswith(f"ffmpeg version {FFMPEG_VERSION}"):
        print(f"FAIL the oracle is FFmpeg {FFMPEG_VERSION} (the reviewed spdifdec.c); this is not it")
        failed += 1
    for name, (original, muxer) in CARRIERS.items():
        carrier, want = carriers / name, (FIXTURES / original).read_bytes()
        if not carrier.exists():
            print(f"FAIL {name}: missing (the macOS job didn't write it)")
            failed += 1
            continue
        # REQ: IEC-O-001
        got = subprocess.run(["ffmpeg", "-v", "error", "-f", "spdif", "-i", str(carrier), "-c", "copy", "-f", muxer, "-"],
                             capture_output=True)
        if got.returncode != 0 or got.stdout != want:
            print(f"FAIL IEC-O-001 {name}: FFmpeg's S/PDIF demuxer returned {len(got.stdout)} bytes ({sha(got.stdout)}), "
                  f"the original {original} is {len(want)} bytes ({sha(want)}) {got.stderr.decode(errors='replace')[:300]}")
            failed += 1
        else:
            print(f"ok   IEC-O-001 {name}: FFmpeg returns {original} byte for byte ({len(want)} bytes, {sha(want)})")
        # REQ: IEC-O-002
        scan = subprocess.run([sys.executable, str(SCANNER), "compare", str(carrier), str(FIXTURES / original)],
                              capture_output=True, text=True)
        if scan.returncode != 0:
            print(f"FAIL IEC-O-002 {name}: {(scan.stdout + scan.stderr).strip()[:600]}")
            failed += 1
        else:
            print(f"ok   IEC-O-002 {name}: the carrier scanner finds exactly the frames of {original}")
    print("all carrier checks passed" if not failed else f"{failed} check(s) failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
