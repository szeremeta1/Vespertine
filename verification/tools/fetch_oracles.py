#!/usr/bin/env python3
#
# Vespertine verification: fetches the oracles' source at the pinned versions the oracle records reviewed.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# An oracle is a second implementation that results are compared with. It is never the source of a spec record
# (see requirements/README.md). The source of each oracle is fetched rather than vendored, into
# verification/oracles/fetched/ (git-ignored), and checked against the digest in its record before anything is
# built from it. A digest mismatch means the upstream file changed under a pinned name: stop and re-review.
#
#   fetch_oracles.py            fetch every oracle and check it
#   fetch_oracles.py libdstdec  fetch one
#
# The digest is check_registry.tree_digest: SHA-256 over each file's name and contents, in sorted order.

import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from check_registry import REPO, load_records, tree_digest  # noqa: E402

ORACLES = {
    # The MPEG-4 Audio reference module for DST, by Philips, as distributed with SACD Ripper (sacd_extract).
    "libdstdec": {
        "record": "DST-003",
        "base": "https://raw.githubusercontent.com/sacd-ripper/sacd-ripper/"
                "a3d981c935c3224217e2842cd492f9351106c81e/libs/libdstdec/",
    },
    # FFmpeg's S/PDIF (IEC 61937) demuxer, the version Ubuntu 24.04 ships (CI runs that build of ffmpeg).
    "ffmpeg-spdif": {
        "record": "IEC-O-001",
        "base": "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n6.1.1/libavformat/",
    },
}


def fetch(name: str) -> None:
    oracle = ORACLES[name]
    rec = next(r for _, r in load_records() if r.get("id") == oracle["record"])
    cache = rec["source"]["cache"]
    dest = REPO / cache["oracle"]
    dest.mkdir(parents=True, exist_ok=True)
    for rel in cache["files"]:
        target = dest / rel
        if not target.exists():
            with urllib.request.urlopen(oracle["base"] + rel, timeout=60) as response:
                target.write_bytes(response.read())
    got = tree_digest(dest, cache["files"])
    if got != rec["quote_sha256"]:
        sys.exit(f"{name}: the fetched source has digest {got}, but {oracle['record']} reviewed "
                 f"{rec['quote_sha256']}. Delete {dest} and fetch again; if it still differs, re-review the oracle.")
    print(f"{name}: {len(cache['files'])} files, digest matches {oracle['record']}")


def main(argv: list[str]) -> int:
    names = argv[1:] or list(ORACLES)
    for name in names:
        if name not in ORACLES:
            print(f"unknown oracle {name!r}; known: {', '.join(ORACLES)}")
            return 2
        fetch(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
