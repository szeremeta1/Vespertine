#!/usr/bin/env python3
#
# Vespertine verification: checks every DST fixture against the reference decoder.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds dst_oracle.c with libdstdec (tools/fetch_oracles.py fetches it), decodes each fixtures/dst/*.dst and
# requires exactly the fixture's .dsd. A fixture is the expected answer in the DST group's tests only because this
# check passes. libdstdec needs x86 (SSE2), so this runs on Linux x86-64 in CI.
#
#   check_fixtures.py [--cc cc]

import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERIFICATION = HERE.parents[1]
LIB = VERIFICATION / "oracles" / "fetched" / "libdstdec"
FIXTURES = VERIFICATION / "fixtures" / "dst"
SOURCES = ["ccp_calc.c", "dst_ac.c", "dst_data.c", "dst_fram.c", "dst_init.c", "unpack_dst.c"]


def main(argv: list[str]) -> int:
    cc = argv[argv.index("--cc") + 1] if "--cc" in argv else "cc"
    if not (LIB / "dst_fram.c").exists():
        print(f"{LIB} is missing: run tools/fetch_oracles.py libdstdec first")
        return 2
    index = json.loads((FIXTURES / "fixtures.json").read_text())
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        exe = Path(tmp) / "dst_oracle"
        # The reference code predates modern warnings; build it as it is, without -Werror.
        subprocess.run([cc, "-std=gnu99", "-O2", "-w", "-I", str(LIB), str(HERE / "dst_oracle.c"),
                        *[str(LIB / s) for s in SOURCES], "-o", str(exe)], check=True)
        for fx in index:
            name = fx["name"]
            out = Path(tmp) / f"{name}.dsd"
            run = subprocess.run([str(exe), str(fx["channels"]), str(FIXTURES / f"{name}.dst"), str(out)],
                                 capture_output=True, text=True)
            expected = (FIXTURES / f"{name}.dsd").read_bytes()
            got = out.read_bytes() if out.exists() else b""
            if run.returncode != 0:
                failures += 1
                print(f"FAIL {name}: libdstdec rejected the frame ({run.stderr.strip()})")
            elif got != expected:
                diff = next(i for i, (a, b) in enumerate(zip(got, expected)) if a != b) if len(got) == len(expected) else -1
                failures += 1
                print(f"FAIL {name}: libdstdec's output differs from the fixture (first difference at byte {diff})")
            else:
                print(f"ok   {name}: {fx['channels']} channels, {fx['coding']}, {len(expected)} bytes")
    print(f"{len(index)} fixtures, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
