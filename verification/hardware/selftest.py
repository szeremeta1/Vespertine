#!/usr/bin/env python3
#
# Vespertine verification: shows that the loopback and SACD comparison tools can tell right from wrong, on
# synthetic captures (CI runs this; no hardware needed). Each case states what the tool must answer.
# SPDX-License-Identifier: GPL-3.0-or-later

import contextlib
import io
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import signals as s  # noqa: E402

COMPARE = HERE.parent / "oracles" / "sacd" / "compare_dsd.py"


def quiet(f, *args) -> int:
    with contextlib.redirect_stdout(io.StringIO()):
        return f(*args)


def capture(path: Path, rate: int, channels, bits: int, pad: int = 777) -> None:
    """A 32-bit capture holding `channels` left-justified, with silence before and after."""
    s.write_wav(path, rate, 32, [[0] * pad + [v << (32 - bits) for v in ch] + [0] * pad for ch in channels])


def dop_words(dsd):
    """DoP 1.1 §2, written out independently of signals.checkdop: marker 0x05 first, then alternating."""
    return [[((0x05 if j % 2 == 0 else 0xFA) << 16) | (ch[2 * j] << 8) | ch[2 * j + 1] for j in range(len(ch) // 2)]
            for ch in dsd]


def main() -> int:
    failures = 0

    def expect(name: str, got: int, want: int) -> None:
        nonlocal failures
        ok = got == want
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}: exit {got}, expected {want}")

    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        src = s.noise(48_000, 24, 1)
        s.write_wav(d / "src.wav", 48_000, 24, src)
        capture(d / "ok.wav", 48_000, src, 24)
        expect("unchanged 24-bit source in a 32-bit capture", quiet(s.check, d / "ok.wav", [d / "src.wav"]), 0)
        changed = [list(c) for c in src]
        changed[1][30_000] ^= 1                                  # one LSB, one channel
        capture(d / "lsb.wav", 48_000, changed, 24)
        expect("one changed LSB", quiet(s.check, d / "lsb.wav", [d / "src.wav"]), 1)
        capture(d / "gain.wav", 48_000, [[v * 9 // 10 for v in c] for c in src], 24)
        expect("-0.9 dB of gain", quiet(s.check, d / "gain.wav", [d / "src.wav"]), 1)
        capture(d / "drop.wav", 48_000, [c[:20_000] + c[20_001:] for c in src], 24)
        expect("one frame dropped", quiet(s.check, d / "drop.wav", [d / "src.wav"]), 1)
        a, b = [c[:17_777] for c in src], [c[17_777:] for c in src]
        s.write_wav(d / "a.wav", 48_000, 24, a)
        s.write_wav(d / "b.wav", 48_000, 24, b)
        expect("gapless join", quiet(s.check, d / "ok.wav", [d / "a.wav", d / "b.wav"]), 0)
        capture(d / "gap.wav", 48_000, [x + [0] + y for x, y in zip(a, b)], 24)
        expect("one sample of silence at the join", quiet(s.check, d / "gap.wav", [d / "a.wav", d / "b.wav"]), 1)

        dsd = s.dsd_tone(2_822_400, 1)
        s.write_dff(d / "t.dff", 2_822_400, dsd)
        words = dop_words(dsd)
        signed = [[(w ^ 0x800000) - 0x800000 for w in ch] for ch in words]
        capture(d / "dop.wav", 176_400, signed, 24, pad=3)
        expect("DoP carrying the file", quiet(s.checkdop, d / "dop.wav", d / "t.dff"), 0)
        bad = [list(c) for c in signed]
        bad[0][1000] ^= 0x10                                     # one DSD bit
        capture(d / "dopbit.wav", 176_400, bad, 24, pad=3)
        expect("DoP with one DSD bit flipped", quiet(s.checkdop, d / "dopbit.wav", d / "t.dff"), 1)
        bad = [list(c) for c in signed]
        bad[1][2000] = (bad[1][2000] & 0xFFFF) | ((0xFA if (words[1][2000] >> 16) == 0x05 else 0x05) << 16)
        bad[1][2000] = (bad[1][2000] ^ 0x800000) - 0x800000
        capture(d / "dopmark.wav", 176_400, bad, 24, pad=3)
        expect("DoP with one wrong marker on one channel", quiet(s.checkdop, d / "dopmark.wav", d / "t.dff"), 1)

        half = len(dsd[0]) // 2
        s.write_dff(d / "h1.dff", 2_822_400, [c[:half] for c in dsd])
        s.write_dff(d / "h2.dff", 2_822_400, [c[half:] for c in dsd])
        flipped = bytearray((d / "h2.dff").read_bytes())
        flipped[-100] ^= 1
        (d / "h2bad.dff").write_bytes(flipped)

        def compare(*files) -> int:
            return subprocess.run([sys.executable, str(COMPARE), *map(str, files)], capture_output=True).returncode
        expect("SACD compare: area against its tracks", compare(d / "t.dff", d / "h1.dff", d / "h2.dff"), 0)
        expect("SACD compare: one bit differs", compare(d / "t.dff", d / "h1.dff", d / "h2bad.dff"), 1)
        expect("SACD compare: a track missing", compare(d / "t.dff", d / "h1.dff"), 1)

    print("all self-tests passed" if not failures else f"{failures} self-test(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
