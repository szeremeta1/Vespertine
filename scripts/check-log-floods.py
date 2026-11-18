#!/usr/bin/env python3
"""Fails when a test log holds a flood of one of the system warnings below.

    scripts/check-log-floods.py build/app-tests.log

The app's tests run inside the app, so what macOS logs for them lands in the CI log and, on the project's own Macs, in
that Mac's system log. One test helper once set a cover's pixels one by one in a way AppKit warns about, two lines a
pixel: 6.3 million lines and 830 MB of CI log a run, at about 12,000 lines a second in the Mac's log, and three minutes
of test time. A handful of these lines can come from macOS itself; a flood is a test (or the app) doing it in a loop.
"""
import sys

# What macOS writes, and how many lines of it a whole run may hold.
FLOODS = {
    # AppKit, for a colour it can't map to a bitmap's colour space (NSBitmapImageRep.setColor: an sRGB colour on a
    # device RGB bitmap). Logged once or twice per call.
    "Unrecognized colorspace number": 200,
    "Unknown number of components for colorspace model": 200,
}


def floods(lines):
    """Each warning seen more often than it may be, with its count."""
    counts = dict.fromkeys(FLOODS, 0)
    for line in lines:
        for warning in FLOODS:
            if warning in line:
                counts[warning] += 1
    return {warning: n for warning, n in counts.items() if n > FLOODS[warning]}


def main(path):
    with open(path, errors="replace") as log:
        found = floods(log)
    for warning, n in found.items():
        print(f"::error::{n} lines of \"{warning}\" in {path} (at most {FLOODS[warning]}): something logs it in a loop",
              file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    sys.exit(main(sys.argv[1]))
