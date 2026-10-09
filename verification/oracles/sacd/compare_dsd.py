#!/usr/bin/env python3
#
# Vespertine verification: compares the DSD Vespertine reads from an SACD image with what sacd_extract writes
# (hardware/SACD-ORACLE.md). Standard library only; streams, so whole areas of several GB are fine.
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   compare_dsd.py <vespertine.dff> <other.dff|.dsf> [<other2> ...]
#
# The first file is Vespertine's (a track, or `<area>-all.dff` for a whole area); the others are sacd_extract's,
# read one after another as a single stream (pass every track of an area, in order, to compare against the whole
# area). Only the DSD is compared: channel count, rate and every channel byte, after putting both into DSDIFF's
# layout (DSDIFF 1.5 §3.3: channel bytes interleaved, most significant bit oldest). DSF is converted from its own
# layout (DSF 1.01: 4096-byte blocks per channel, least significant bit oldest when bits per sample is 1).
# Exit 0 when identical; otherwise prints the first difference (channel, byte, 1/75 s frame) and exits 1.

import struct
import sys
from pathlib import Path

CHUNK = 1 << 20
REVERSE = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))


def dff_stream(path: Path):
    """(rate, channels, generator of interleaved DSD bytes) for a plain DSDIFF file."""
    f = path.open("rb")
    if f.read(4) != b"FRM8":
        sys.exit(f"{path}: not DSDIFF")
    f.read(8)
    if f.read(4) != b"DSD ":
        sys.exit(f"{path}: not a DSD form")
    rate = channels = None
    while True:
        head = f.read(12)
        if len(head) < 12:
            sys.exit(f"{path}: no DSD sound data chunk")
        ck, size = head[:4], struct.unpack(">Q", head[4:])[0]
        if ck == b"PROP":
            body = f.read(size + (size & 1))
            p = 4
            while p + 12 <= size:
                sck, ssize = body[p:p + 4], struct.unpack(">Q", body[p + 4:p + 12])[0]
                if sck == b"FS  ":
                    rate = struct.unpack(">I", body[p + 12:p + 16])[0]
                elif sck == b"CHNL":
                    channels = struct.unpack(">H", body[p + 12:p + 14])[0]
                elif sck == b"CMPR" and body[p + 12:p + 16] != b"DSD ":
                    sys.exit(f"{path}: compressed ({body[p + 12:p + 16]!r}); extract with DST converted to DSD")
                p += 12 + ssize + (ssize & 1)
        elif ck == b"DSD ":
            def gen(left=size):
                while left > 0:
                    data = f.read(min(CHUNK, left))
                    if not data:
                        sys.exit(f"{path}: truncated")
                    left -= len(data)
                    yield data
            return rate, channels, gen()
        else:
            f.seek(size + (size & 1), 1)


def dsf_stream(path: Path):
    """(rate, channels, generator of interleaved MSB-first DSD bytes) for a DSF file with 1 bit per sample."""
    f = path.open("rb")
    head = f.read(28)
    if head[:4] != b"DSD ":
        sys.exit(f"{path}: not DSF")
    fmt = f.read(52)
    if fmt[:4] != b"fmt ":
        sys.exit(f"{path}: no fmt chunk")
    channels, rate, bits = struct.unpack("<III", fmt[24:36])
    samples, block = struct.unpack("<QI", fmt[36:48])
    if bits != 1:
        sys.exit(f"{path}: {bits} bits per sample; only 1 (LSB first) is handled")
    data = f.read(12)
    if data[:4] != b"data":
        sys.exit(f"{path}: no data chunk")
    per_channel = (samples + 7) // 8

    def gen():
        done = 0
        while done < per_channel:
            blocks = [f.read(block) for _ in range(channels)]
            n = min(block, per_channel - done)
            yield bytes(REVERSE[blocks[c][i]] for i in range(n) for c in range(channels))
            done += n
    return rate, channels, gen()


def stream(path: Path):
    return dsf_stream(path) if path.suffix.lower() == ".dsf" else dff_stream(path)


def chain(paths):
    first = None
    gens = []
    for p in paths:
        rate, channels, g = stream(p)
        if first and first != (rate, channels):
            sys.exit(f"{p}: {rate} Hz {channels} ch differs from the files before it {first}")
        first = (rate, channels)
        gens.append(g)

    def gen():
        for g in gens:
            yield from g
    return first[0], first[1], gen()


def rechunk(gen):
    buf = b""
    for data in gen:
        buf += data
        while len(buf) >= CHUNK:
            yield buf[:CHUNK]
            buf = buf[CHUNK:]
    if buf:
        yield buf


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: compare_dsd.py <vespertine.dff> <other.dff|.dsf> [<other2> ...]")
        return 2
    rate_a, ch_a, a = stream(Path(sys.argv[1]))
    rate_b, ch_b, b = chain([Path(p) for p in sys.argv[2:]])
    if (rate_a, ch_a) != (rate_b, ch_b):
        print(f"DIFFERENT: {rate_a} Hz {ch_a} ch against {rate_b} Hz {ch_b} ch")
        return 1
    frame_bytes = rate_a // 75 // 8          # per channel, one 1/75 s frame (4704 at DSD64)
    offset = 0
    a, b = rechunk(a), rechunk(b)
    for x in a:
        y = next(b, b"")
        if x != y:
            k = next((i for i in range(min(len(x), len(y))) if x[i] != y[i]), min(len(x), len(y)))
            at = offset + k
            per_channel = at // ch_a
            print(f"DIFFERENT at interleaved byte {at}: channel {at % ch_a}, byte {per_channel} of the channel, "
                  f"frame {per_channel // frame_bytes} (1/75 s frames from the start of the first file)")
            return 1
        offset += len(x)
    rest = sum(len(y) for y in b)
    if rest:
        print(f"DIFFERENT: the other files hold {rest} more bytes after the {offset} that match")
        return 1
    print(f"IDENTICAL: {offset // ch_a} bytes per channel x {ch_a} channels at {rate_a} Hz "
          f"({offset // ch_a / frame_bytes:.2f} frames)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
