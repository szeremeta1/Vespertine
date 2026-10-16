#!/usr/bin/env python3
"""Rebuild the blind round's spec corpus from the public URLs in corpus/sources.lock.json, refusing any file
whose SHA-256 differs, then normalize it (tools/normalize.py) and check the markdown hashes too.

The corpus text is not in the repository (SMPTE, ATSC and ETSI publish these free but keep the copyright; the
IEC files are the publisher's previews). Only the URLs and hashes are.

Usage: python3 -I verification/blind/tools/fetch_corpus.py      (writes verification/blind/corpus/{raw,md,index.json})
"""
import hashlib
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = HERE.parent / "corpus"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"


def main() -> int:
    lock = json.loads((CORPUS / "sources.lock.json").read_text())
    bad = 0
    for d in lock["docs"]:
        dest = CORPUS / "raw" / d["id"] / d["file"]
        if not (dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == d["sha256"]):
            dest.parent.mkdir(parents=True, exist_ok=True)
            data = urllib.request.urlopen(urllib.request.Request(d["url"], headers={"User-Agent": UA}), timeout=120).read()
            if hashlib.sha256(data).hexdigest() != d["sha256"]:
                print(f"{d['id']}/{d['file']}: SHA-256 differs from the lock; not used", file=sys.stderr)
                bad += 1
                continue
            dest.write_bytes(data)
        print(f"ok  {d['id']}/{d['file']}")
    if bad:
        return 1
    subprocess.run([sys.executable, "-I", str(HERE / "normalize.py"), str(CORPUS)], check=True)
    index = json.loads((CORPUS / "index.json").read_text())
    got = {e["id"]: e["md_sha256"] for e in index["docs"]}
    for n in lock["normalized"]:
        same = got.get(n["id"]) == n["md_sha256"]
        print(f"{'ok ' if same else 'DIFF'} md/{n['id']}" + ("" if same else f"  (pdftotext here: {index['pdftotext']}; "
                                                          f"locked with {lock['pdftotext']})"))
        bad += not same
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
