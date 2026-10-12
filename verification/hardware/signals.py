#!/usr/bin/env python3
#
# Vespertine verification: test signals for the loopback procedure (LOOPBACK.md), and the checks that compare a
# capture with them. Standard library only.
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   signals.py make <dir>                      write the test files (WAV and DSDIFF) into <dir>
#   signals.py check <capture.wav> <src.wav>[+<src2.wav>...]
#                                              is the source (several files: played back to back) in the capture,
#                                              every sample unchanged?
#   signals.py checkdop <capture.wav> <src.dff>
#                                              does the capture hold DoP whose markers alternate and whose DSD bits
#                                              are exactly the file's?
#
# The PCM signals are seeded pseudo-random noise at about -20 dBFS: every bit below the top few changes from sample
# to sample, so a gain change, dither, truncation or resampling anywhere in the chain shows up, and the level is
# low enough not to hurt speakers left connected. The DSD signals are a quiet 1050 Hz tone from a first-order
# sigma-delta modulator: a legal DSD stream, deterministic in IEEE double arithmetic.

import struct
import sys
from pathlib import Path

PCM_SIGNALS = [(44_100, 16), (48_000, 24), (96_000, 24), (192_000, 24)]
DSD_SIGNALS = [2_822_400, 5_644_800]
SECONDS, DSD_SECONDS, TONE_HZ = 6, 4, 1050
# The gapless pair splits one signal at a frame count that lines up with no buffer size.
GAPLESS_RATE, GAPLESS_SPLIT = 48_000, 3 * 48_000 + 12_345


class XorShift:
    """xorshift64*: the same numbers on every platform."""

    def __init__(self, seed: int):
        self.state = seed & 0xFFFF_FFFF_FFFF_FFFF or 1

    def next(self) -> int:
        x = self.state
        x ^= (x >> 12)
        x ^= (x << 25) & 0xFFFF_FFFF_FFFF_FFFF
        x ^= (x >> 27)
        self.state = x
        return (x * 0x2545F4914F6CDD1D) & 0xFFFF_FFFF_FFFF_FFFF


def noise(frames: int, bits: int, seed: int) -> list[list[int]]:
    """Two channels of uniform noise at a tenth of full scale (about -20 dBFS)."""
    rng = XorShift(seed)
    peak = (1 << (bits - 1)) // 10
    return [[(rng.next() % (2 * peak + 1)) - peak for _ in range(frames)] for _ in range(2)]


def write_wav(path: Path, rate: int, bits: int, channels: list[list[int]]) -> None:
    width = bits // 8
    frames = len(channels[0])
    data = bytearray()
    for i in range(frames):
        for ch in channels:
            data += (ch[i] & ((1 << bits) - 1)).to_bytes(width, "little")
    fmt = struct.pack("<HHIIHH", 1, len(channels), rate, rate * width * len(channels), width * len(channels), bits)
    path.write_bytes(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(data)) + b"WAVE" +
                     b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(data)) + bytes(data))


def read_wav(path: Path) -> tuple[int, int, list[list[int]]]:
    """Rate, bits and channels of an integer PCM WAV (plain or WAVE_FORMAT_EXTENSIBLE), samples sign-extended."""
    raw = path.read_bytes()
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        sys.exit(f"{path}: not a WAV file")
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(raw):
        ck, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if ck == b"fmt ":
            fmt = body
        elif ck == b"data":
            data = body
        pos += 8 + size + (size & 1)
    if fmt is None or data is None:
        sys.exit(f"{path}: no fmt or data chunk")
    tag, nch, rate, _, align, bits = struct.unpack("<HHIIHH", fmt[:16])
    if tag == 0xFFFE and len(fmt) >= 26:
        tag = struct.unpack("<H", fmt[24:26])[0]       # the subformat GUID starts with the format tag
    if tag != 1:
        sys.exit(f"{path}: format tag {tag:#x} is not integer PCM; record the capture as integer PCM")
    width = align // nch
    channels = [[] for _ in range(nch)]
    for i in range(0, len(data) - align + 1, align):
        for c in range(nch):
            v = int.from_bytes(data[i + c * width:i + (c + 1) * width], "little", signed=True)
            channels[c].append(v)
    return rate, width * 8, channels


def dsd_tone(rate: int, seconds: int) -> list[bytes]:
    """Two channels of DSD bytes, most significant bit oldest: a 1050 Hz tone at 0.1 of full scale (the right
    channel a quarter period later), from a first-order sigma-delta modulator. 1050 Hz divides both DSD rates
    exactly, so one period of the sine is computed once."""
    import math
    period = rate // TONE_HZ
    table = [0.1 * math.sin(2 * math.pi * k / period) for k in range(period)]
    out = []
    for lag in (0, period // 4):
        acc, bits, buf = 0.0, 0, bytearray()
        for n in range(rate * seconds):
            x = table[(n + lag) % period]
            y = 1 if acc >= 0 else 0
            acc += x - (2 * y - 1)
            bits = (bits << 1) | y
            if n % 8 == 7:
                buf.append(bits)
                bits = 0
        out.append(bytes(buf))
    return out


def write_dff(path: Path, rate: int, channels: list[bytes]) -> None:
    """A minimal DSDIFF 1.5 file (§3): FVER, PROP with FS, CHNL and CMPR, then the DSD sound data chunk with the
    channel bytes interleaved in channel order (§3.3). All numbers big-endian; odd chunks padded."""
    def chunk(ck: bytes, body: bytes) -> bytes:
        return ck + struct.pack(">Q", len(body)) + body + (b"\0" if len(body) & 1 else b"")
    name = b"not compressed"
    prop = b"SND " + chunk(b"FS  ", struct.pack(">I", rate)) + \
        chunk(b"CHNL", struct.pack(">H", 2) + b"SLFT" + b"SRGT") + \
        chunk(b"CMPR", b"DSD " + bytes([len(name)]) + name)
    sound = bytes(b for pair in zip(*channels) for b in pair)
    body = b"DSD " + chunk(b"FVER", struct.pack(">I", 0x01050000)) + chunk(b"PROP", prop) + chunk(b"DSD ", sound)
    path.write_bytes(chunk(b"FRM8", body))


def make(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for i, (rate, bits) in enumerate(PCM_SIGNALS):
        write_wav(out / f"pcm-{rate}-{bits}.wav", rate, bits, noise(rate * SECONDS, bits, 0x5EED + i))
    whole = noise(2 * GAPLESS_SPLIT, 24, 0x6A9)
    write_wav(out / f"gapless-a-{GAPLESS_RATE}-24.wav", GAPLESS_RATE, 24, [c[:GAPLESS_SPLIT] for c in whole])
    write_wav(out / f"gapless-b-{GAPLESS_RATE}-24.wav", GAPLESS_RATE, 24, [c[GAPLESS_SPLIT:] for c in whole])
    for rate in DSD_SIGNALS:
        write_dff(out / f"dsd{rate // 44_100}.dff", rate, dsd_tone(rate, DSD_SECONDS))
    for p in sorted(out.iterdir()):
        print(p)


def find(haystack: list[int], needle: list[int], start: int = 0) -> int:
    n = len(needle)
    for i in range(start, len(haystack) - n + 1):
        if haystack[i] == needle[0] and haystack[i:i + n] == needle:
            return i
    return -1


def check(capture: Path, sources: list[Path]) -> int:
    crate, cbits, cap = read_wav(capture)
    src, sbits = [[], []], None
    for s in sources:
        rate, bits, chans = read_wav(s)
        if rate != crate:
            print(f"capture is at {crate} Hz, {s.name} at {rate} Hz: the rate changed somewhere (not bit-perfect)")
            return 1
        sbits = bits if sbits is None else sbits
        for c in range(2):
            src[c] += chans[c]
    if cbits < sbits:
        print(f"capture has {cbits} bits, the source {sbits}: record at least {sbits} bits")
        return 1
    shift = cbits - sbits
    # Left-justify the source in the capture's word, the way a bit-perfect chain delivers it.
    want = [[v << shift for v in ch] for ch in src]
    at = find(cap[0], want[0][:64])
    if at < 0:
        print("FAIL: the source's first 64 samples don't appear unchanged anywhere in the capture's left channel.")
        print("      Usual causes: digital volume or EQ on, a different rate, dither, or the wrong input.")
        return 1
    frames = len(want[0])
    if at + frames > len(cap[0]):
        print(f"FAIL: the capture stops {at + frames - len(cap[0])} frames before the source ends")
        return 1
    bad = [(c, i) for c in range(2) for i in range(frames) if cap[c][at + i] != want[c][i]]
    if bad:
        c, i = bad[0]
        print(f"FAIL: {len(bad)} of {2 * frames} samples differ; first at frame {i}, channel {c}: "
              f"got {cap[c][at + i]}, expected {want[c][i]}")
        return 1
    print(f"BIT-EXACT: {frames} frames x 2 channels of {', '.join(s.name for s in sources)} found unchanged at "
          f"frame {at} of the capture ({sbits}-bit source in {cbits}-bit capture).")
    return 0


def read_dff(path: Path) -> tuple[int, list[bytes]]:
    raw = path.read_bytes()
    rate, nch, pos, sound = None, None, 16, None
    while pos + 12 <= len(raw):
        ck, size = raw[pos:pos + 4], struct.unpack(">Q", raw[pos + 4:pos + 12])[0]
        body = raw[pos + 12:pos + 12 + size]
        if ck == b"PROP":
            p = 4
            while p + 12 <= len(body):
                sck, ssize = body[p:p + 4], struct.unpack(">Q", body[p + 4:p + 12])[0]
                if sck == b"FS  ":
                    rate = struct.unpack(">I", body[p + 12:p + 16])[0]
                elif sck == b"CHNL":
                    nch = struct.unpack(">H", body[p + 12:p + 14])[0]
                p += 12 + ssize + (ssize & 1)
        elif ck == b"DSD ":
            sound = body
        pos += 12 + size + (size & 1)
    if not (rate and nch and sound is not None):
        sys.exit(f"{path}: not a plain DSDIFF file")
    return rate, [sound[c::nch] for c in range(nch)]


def checkdop(capture: Path, source: Path) -> int:
    crate, cbits, cap = read_wav(capture)
    rate, dsd = read_dff(source)
    if crate * 16 != rate:
        print(f"FAIL: capture at {crate} Hz; DoP for {rate} Hz DSD runs at {rate // 16} Hz")
        return 1
    if cbits < 24:
        print("FAIL: DoP needs a capture of at least 24 bits")
        return 1
    shift = cbits - 24
    words = [[(v >> shift) & 0xFFFFFF for v in ch] for ch in cap[:2]]
    # DoP 1.1 §2: the top 8 bits are the marker, 0x05 and 0xFA alternating, the same on every channel; the lower 16
    # bits are DSD, the older byte above the newer, most significant bit oldest.
    markers = [w >> 16 for w in words[0]]
    want = [bytes(b) for b in dsd]
    streams = [bytes(b for w in ch for b in ((w >> 8) & 0xFF, w & 0xFF)) for ch in words]
    at = streams[0].find(want[0][:64])
    if at < 0 or at % 2:
        print("FAIL: the file's first DSD bytes aren't in the capture's left channel as DoP data")
        return 1
    first, n = at // 2, len(want[0]) // 2
    if first + n > len(markers):
        print("FAIL: the capture ends before the file does")
        return 1
    for i in range(first, first + n):
        m = markers[i]
        if m not in (0x05, 0xFA) or (i > first and m == markers[i - 1]):
            print(f"FAIL: marker {m:#04x} at frame {i} breaks the 0x05/0xFA alternation")
            return 1
        if words[1][i] >> 16 != m:
            print(f"FAIL: at frame {i} the channels carry different markers")
            return 1
    for c in range(2):
        got = streams[c][at:at + len(want[c])]
        if got != want[c]:
            k = next(i for i in range(len(got)) if got[i] != want[c][i])
            print(f"FAIL: channel {c} DSD byte {k} is {got[k]:#04x}, the file has {want[c][k]:#04x}")
            return 1
    print(f"DOP-EXACT: {n} DoP frames x 2 channels, markers alternating, every DSD bit of {source.name} unchanged.")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "make":
        make(Path(args[1]))
        return 0
    if len(args) == 3 and args[0] == "check":
        return check(Path(args[1]), [Path(p) for p in args[2].split("+")])
    if len(args) == 3 and args[0] == "checkdop":
        return checkdop(Path(args[1]), Path(args[2]))
    print("usage: signals.py make <dir> | check <capture.wav> <src.wav>[+<src2.wav>...] | checkdop <capture.wav> <src.dff>")
    return 2


if __name__ == "__main__":
    sys.exit(main())
