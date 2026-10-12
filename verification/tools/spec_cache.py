#!/usr/bin/env python3
#
# Vespertine verification: the local specification cache.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Requirement records cite a clause and carry the SHA-256 of its text. The text itself lives only in
# verification/spec-cache/ (git-ignored), so paywalled standards never enter the repository. This tool builds
# that cache from the public sources and checks a record's hash against it.
#
#   spec_cache.py fetch                 download the public PDFs (checked against the SHA-256 below) and extract
#                                       one text file per page with pdftotext; copy the Core Audio headers on macOS
#   spec_cache.py add <doc> <file.pdf>  add a document you bought (an IEC part, for example): extracts it the same
#                                       way; the PDF and its text stay in spec-cache/
#   spec_cache.py clause <doc> <page> <from> <to>
#                                       print the clause between two phrases and its hash (for writing a record)
#   spec_cache.py verify                recompute every record's hash from the cache (maintainer check; CI only
#                                       checks that hashes are present, see check_registry.py)
#
# The hash is over a canonical form of the clause: Unicode NFKC, case-folded, keeping only the letters a-z and the
# digits 0-9. Different PDF text extractors break lines, hyphenate and space differently; they agree on this form.

import hashlib
import os
import shutil
import subprocess
import sys
import unicodedata
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]          # verification/
REPO = ROOT.parent
CACHE = ROOT / "spec-cache"

# Public documents: where to get them and the exact file the records were written against.
PUBLIC = {
    "dop-1.1": {
        "url": "https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf",
        "sha256": "640ff447f1456186927365cf422622e3665634b99dbd7c56b39f77e6720f1a4c",
    },
    "dsdiff-1.5": {
        "url": "https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf",
        "sha256": "fba0c3053c81f7af93eb8bb3ea70b6f78bb1188578a844c054988af2ff2f0b01",
    },
    "dsf-1.01": {
        "url": "https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf",
        "sha256": "2c154f3e82ea835a8023d08308adc26344b0fcec627c14e585640e0111740da4",
    },
    "atsc-a52-2018": {
        "url": "https://www.atsc.org/wp-content/uploads/2021/04/A52-2018.pdf",
        "sha256": "4580b631f5ac1aafdd31034f28d5fc9c29bce72a3d3f6367e3d9746906e0ffa1",
    },
    "etsi-ts-102114-1.6.1": {
        "url": "https://www.etsi.org/deliver/etsi_ts/102100_102199/102114/01.06.01_60/ts_102114v010601p.pdf",
        "sha256": "29f9e50575e48bfe55222c5f004088af379bc9a6c65274ed975a81dca10647ba",
    },
    "etsi-ts-102366-1.4.1": {
        "url": "https://www.etsi.org/deliver/etsi_ts/102300_102399/102366/01.04.01_60/ts_102366v010401p.pdf",
        "sha256": "0229e151dfd9f8cec427f234798cac679a66fdec096feecc4d5ce455bbe3cadf",
    },
}

# Apple's Core Audio headers, macOS 27.0 SDK (build 26A425). Records cite the header comment for a property.
HEADERS = {
    "AudioHardware.h": ("CoreAudio", "a699437248e079d9ebe47078ef3861492d8253fef1a6007e476031031d3535ca"),
    "AudioHardwareBase.h": ("CoreAudio", "cbac54e8edb7ee99bf10c18a2db044e01c47645985b2f2824623f3f8371a7c4e"),
    "CoreAudioBaseTypes.h": ("CoreAudioTypes", "f58c4e2bccc86193afa89160bba76ab57989138e8885bed1c068d41ebe2b5c86"),
}


def canonical(text: str) -> str:
    folded = unicodedata.normalize("NFKC", text).casefold()
    return "".join(c for c in folded if ("a" <= c <= "z") or ("0" <= c <= "9"))


def digest(text: str) -> str:
    return hashlib.sha256(canonical(text).encode("ascii")).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def page_text(doc: str, page: int) -> str:
    """The text of one page of a cached document (1-based)."""
    path = CACHE / "txt" / doc / f"page-{page:03d}.txt"
    if not path.exists():
        raise FileNotFoundError(f"{path} (run spec_cache.py fetch, or add the document you bought)")
    return path.read_text(encoding="utf-8")


def source_text(cache: dict) -> str:
    """The text a record's `source.cache` points at: a page of a cached document, a header, or a repo file."""
    if "repo" in cache:
        lines = (REPO / cache["repo"]).read_text(encoding="utf-8").splitlines()
        first, last = cache["lines"] if isinstance(cache["lines"], list) else (cache["lines"], cache["lines"])
        return "\n".join(lines[first - 1:last])
    if "header" in cache:
        return (CACHE / "headers" / cache["header"]).read_text(encoding="utf-8")
    pages = cache["pages"] if isinstance(cache["pages"], list) else [cache["pages"], cache["pages"]]
    return "\n".join(page_text(cache["doc"], p) for p in range(pages[0], pages[1] + 1))


def clause(cache: dict) -> str:
    """The canonical clause: from the first occurrence of `from` through the end of the next `to`."""
    text = canonical(source_text(cache))
    start_key, end_key = canonical(cache["from"]), canonical(cache["to"])
    start = text.find(start_key)
    if start < 0:
        raise ValueError(f"start phrase not found: {cache['from']!r}")
    end = text.find(end_key, start)
    if end < 0:
        raise ValueError(f"end phrase not found after the start: {cache['to']!r}")
    return text[start:end + len(end_key)]


def clause_digest(cache: dict) -> str:
    return hashlib.sha256(clause(cache).encode("ascii")).hexdigest()


def extract(doc: str, pdf: Path) -> None:
    if not shutil.which("pdftotext"):
        sys.exit("pdftotext (poppler) is needed to extract the text")
    out = CACHE / "txt" / doc
    out.mkdir(parents=True, exist_ok=True)
    info = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, text=True, check=True).stdout
    pages = int(next(l.split()[-1] for l in info.splitlines() if l.startswith("Pages:")))
    for p in range(1, pages + 1):
        subprocess.run(["pdftotext", "-enc", "UTF-8", "-f", str(p), "-l", str(p), str(pdf),
                        str(out / f"page-{p:03d}.txt")], check=True)
    print(f"{doc}: {pages} pages")


def fetch() -> None:
    (CACHE / "pdf").mkdir(parents=True, exist_ok=True)
    for doc, info in PUBLIC.items():
        pdf = CACHE / "pdf" / f"{doc}.pdf"
        if not pdf.exists() or sha256_file(pdf) != info["sha256"]:
            print(f"downloading {info['url']}")
            urllib.request.urlretrieve(info["url"], pdf)
        got = sha256_file(pdf)
        if got != info["sha256"]:
            sys.exit(f"{doc}: SHA-256 {got} is not the edition the records cite ({info['sha256']})")
        extract(doc, pdf)
    if sys.platform == "darwin":
        sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
        (CACHE / "headers").mkdir(parents=True, exist_ok=True)
        for name, (framework, expected) in HEADERS.items():
            src = Path(sdk) / "System/Library/Frameworks" / f"{framework}.framework/Headers" / name
            dst = CACHE / "headers" / name
            shutil.copyfile(src, dst)
            got = sha256_file(dst)
            note = "" if got == expected else f" (differs from the SDK the records cite: {got}; clause hashes may still match)"
            print(f"{name}{note}")
    else:
        print("Core Audio headers: run on a Mac with Xcode to copy them (records citing them can't be verified here)")


def verify() -> int:
    sys.path.insert(0, str(Path(__file__).parent))
    from check_registry import load_records
    failures = checked = 0
    for path, rec in load_records():
        cache = (rec.get("source") or {}).get("cache")
        if not cache or rec.get("quote_sha256") in (None, "BLOCKED") or rec.get("kind") == "oracle":
            continue
        try:
            got = clause_digest(cache)
        except (FileNotFoundError, ValueError) as e:
            print(f"SKIP {rec['id']}: {e}")
            continue
        checked += 1
        if got != rec["quote_sha256"]:
            failures += 1
            print(f"FAIL {rec['id']}: cache gives {got}, record says {rec['quote_sha256']}")
    print(f"{checked} clause hashes checked, {failures} mismatched")
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__ or "", end="")
        print("usage: spec_cache.py fetch | add <doc> <file.pdf> | clause <doc> <page> <from> <to> | verify")
        return 2
    cmd = argv[1]
    if cmd == "fetch":
        fetch()
    elif cmd == "add" and len(argv) == 4:
        dst = CACHE / "pdf" / f"{argv[2]}.pdf"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(argv[3], dst)
        print(f"{argv[2]}: SHA-256 {sha256_file(dst)} (record it in the document's SOURCES.md entry)")
        extract(argv[2], dst)
    elif cmd == "clause" and len(argv) == 6:
        cache = {"doc": argv[2], "pages": int(argv[3]), "from": argv[4], "to": argv[5]}
        print(clause(cache))
        print(clause_digest(cache))
    elif cmd == "verify":
        return verify()
    else:
        print("usage: spec_cache.py fetch | add <doc> <file.pdf> | clause <doc> <page> <from> <to> | verify")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
