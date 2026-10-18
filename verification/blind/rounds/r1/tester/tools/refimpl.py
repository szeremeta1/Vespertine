"""Throwaway reference implementation, written from the same reading as the tests, ONLY to shake bugs out of the
suite itself (builders, expectations). Not a deliverable; the suite is judged on other implementations."""
from __future__ import annotations
import sys
from dataclasses import dataclass
sys.path.insert(0, __import__("os").path.join(__import__("os").path.dirname(__file__), "..", "stub"))  # made relative on commit
from vblind import DoPError, BurstError, Burst  # noqa: F401  (the stub's classes; same names)


def dop_pack(dsd, first_marker=0x05):
    if first_marker not in (0x05, 0xFA):
        raise DoPError("marker")
    if len({len(c) for c in dsd}) > 1 or any(len(c) % 2 for c in dsd):
        raise DoPError("len")
    n = len(dsd[0]) // 2 if dsd else 0
    out, m = [], first_marker
    for i in range(n):
        out.append([(m << 16) | (c[2 * i] << 8) | c[2 * i + 1] for c in dsd])
        m = 0xFA if m == 0x05 else 0x05
    return out


def dop_unpack(frames):
    if not frames:
        return [], 0x05
    nch = len(frames[0])
    first = frames[0][0] >> 16
    m = first
    chans = [bytearray() for _ in range(nch)]
    for fr in frames:
        if len(fr) != nch:
            raise DoPError("ragged")
        for c, w in enumerate(fr):
            if w < 0 or w > 0xFFFFFF or (w >> 16) != m or m not in (0x05, 0xFA):
                raise DoPError("marker")
            chans[c] += bytes([(w >> 8) & 0xFF, w & 0xFF])
        m = 0xFA if m == 0x05 else 0x05
    return [bytes(c) for c in chans], first


def _words(data):
    return [(data[i] << 8) | (data[i + 1] if i + 1 < len(data) else 0) for i in range(0, len(data), 2)]


def _burst(dt, dtd, pd, payload, period_words):
    w = [0xF872, 0x4E1F, dt | (dtd << 8), pd] + _words(payload)
    if len(w) > period_words:
        raise BurstError("too big")
    return w + [0] * (period_words - len(w))


_AC3 = {(0, 16): 256, (0, 17): 256, (1, 0): 69, (1, 1): 70, (2, 2): 120}


def ac3_burst(frame):
    if frame[:2] != b"\x0b\x77":
        raise BurstError("sync")
    key = (frame[4] >> 6, frame[4] & 0x3F)
    if key not in _AC3 or len(frame) != 2 * _AC3[key]:
        raise BurstError("size")
    return _burst(1, frame[5] & 7, 8 * len(frame), frame, 3072)


def _eac3_blocks(f):
    if f[:2] != b"\x0b\x77":
        raise BurstError("sync")
    return {0: 1, 1: 2, 2: 3, 3: 6}[(f[4] >> 4) & 3]


def eac3_burst(frames):
    if not frames or sum(_eac3_blocks(f) for f in frames) != 6:
        raise BurstError("blocks")
    p = b"".join(frames)
    return _burst(21, 0, len(p), p, 12288)


def eac3_group(frames):
    groups, cur, blocks = [], [], 0
    for i, f in enumerate(frames):
        cur.append(i)
        blocks += _eac3_blocks(f)
        if blocks >= 6:
            groups.append(cur)
            cur, blocks = [], 0
    if cur:
        groups.append(cur)
    return groups


def dts_burst(frame):
    if len(frame) < 9 or frame[:4] != bytes.fromhex("7ffe8001"):
        raise BurstError("sync")
    nblks = ((frame[4] & 1) << 6) | (frame[5] >> 2)
    samples = (nblks + 1) * 32
    dt = {512: 11, 1024: 12, 2048: 13}.get(samples)
    if dt is None:
        raise BurstError("samples")
    return _burst(dt, 0, 8 * len(frame), frame, 2 * samples)


def parse_bursts(words):
    out, i = [], 0
    while i + 1 < len(words):
        if i % 2 == 0 and words[i] == 0xF872 and words[i + 1] == 0x4E1F:
            if i + 3 >= len(words):
                raise BurstError("preamble")
            pc, pd = words[i + 2], words[i + 3]
            dt = pc & 0x1F
            nbytes = pd if dt == 21 else (pd + 7) // 8
            nw = (nbytes + 1) // 2
            if i + 4 + nw > len(words):
                raise BurstError("length")
            data = b"".join(w.to_bytes(2, "big") for w in words[i + 4:i + 4 + nw])[:nbytes]
            out.append(Burst(i, dt, (pc >> 8) & 31, (pc >> 7) & 1, (pc >> 13) & 7, pd, data))
            i += 4 + nw
        else:
            i += 1
    return out
