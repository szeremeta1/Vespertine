#!/usr/bin/env python3
#
# Vespertine verification: checks the requirement registry and everything that points into it.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fails (exit 1) when:
#   - a record lacks a source or a hash, or has a malformed field;
#   - a `spec` record cites an implementation (FFmpeg, sacd_extract/SACD Ripper, Apple sample code, …);
#   - a test, check or mutant references a requirement ID that doesn't exist;
#   - a record's claim anchor isn't in CLAIMS.md;
#   - a quote in CLAIMS.md is no longer on the line it cites;
#   - a record citing Vespertine's own docs no longer matches them (its hash is recomputed from the repository);
#   - an oracle record's hash doesn't match the oracle file kept in the repository.
# Hashes of public and paywalled standards are checked for presence and form only: their text is in the git-ignored
# spec cache, never in the repository (tools/spec_cache.py verify recomputes them where the cache exists).
#
# Needs PyYAML.

import hashlib
import re
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent                      # verification/
REPO = ROOT.parent
sys.path.insert(0, str(HERE))
import spec_cache  # noqa: E402

ID = re.compile(r"^[A-Z]+(-[A-Z])?-\d{3}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
KINDS = {"spec", "oracle", "vespertine-rule"}
AVAILABILITY = {"public", "paywalled", "not-public", "repository"}
# An implementation can be an oracle; it can never be the source of a `spec` record.
IMPLEMENTATIONS = re.compile(
    r"ffmpeg|libav|sacd[ _-]?extract|sacd[ _-]?ripper|libdstdec|sample code|samplecode|sox\b|github\.com",
    re.IGNORECASE)
# Where tests, checks and mutants live, and how they name requirements.
SCANNED = [ROOT / "harness", ROOT / "oracles", REPO / "Packages" / "VespertineKit" / "Tests"]
REQ_TAG = re.compile(r"REQ:\s*([A-Z]+(?:-[A-Z])?-\d{3}(?:\s*,\s*[A-Z]+(?:-[A-Z])?-\d{3})*)")
REQ_STRING = re.compile(r"\"((?:DOP|DOPS|FLT|INT|BPV|RATE|DST|IEC)(?:-[A-Z])?-\d{3})\"")
CLAIM_TEXT = re.compile(r"^- \*\*Text:\*\* `([^`:]+):(\d+)` — \"(.*)\"$")
ANCHOR = re.compile(r'<a id="([a-z0-9-]+)"></a>')


def load_records():
    for path in sorted((ROOT / "requirements").glob("*.yaml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or []
        for rec in data:
            yield path, rec


def words(s: str) -> int:
    return len(s.split())


def tree_digest(base: Path, files) -> str:
    """SHA-256 over an oracle's source files: each file's path (relative to `base`) and contents, in sorted order.
    tools/fetch_oracles.py computes the same digest when it fetches an oracle."""
    h = hashlib.sha256()
    for rel in sorted(files):
        h.update(rel.encode() + b"\0" + (base / rel).read_bytes() + b"\0")
    return h.hexdigest()


def check_records(errors: list, claims_anchors: set) -> dict:
    records = {}
    for path, rec in load_records():
        where = f"{path.name}:{rec.get('id', '?')}"
        rid = rec.get("id", "")
        if not ID.match(rid):
            errors.append(f"{where}: id {rid!r} is not like DOP-001")
        if rid in records:
            errors.append(f"{where}: duplicate id")
        records[rid] = rec
        for field in ("claim", "source", "requirement", "quote_sha256", "kind", "testable", "gap", "interface"):
            if field not in rec:
                errors.append(f"{where}: missing {field}")
        src = rec.get("source") or {}
        if not src:
            errors.append(f"{where}: no source")
            continue
        for field in ("doc", "version", "section", "availability"):
            if not src.get(field):
                errors.append(f"{where}: source.{field} is empty")
        avail = src.get("availability")
        if avail not in AVAILABILITY:
            errors.append(f"{where}: source.availability {avail!r} is not one of {sorted(AVAILABILITY)}")
        if avail in ("public", "paywalled") and not src.get("url"):
            errors.append(f"{where}: a {avail} source needs the URL it was opened at")
        kind = rec.get("kind")
        if kind not in KINDS:
            errors.append(f"{where}: kind {kind!r} is not one of {sorted(KINDS)}")
        if kind == "spec":
            cited = " ".join(str(src.get(k, "")) for k in ("doc", "url", "section"))
            if IMPLEMENTATIONS.search(cited):
                errors.append(f"{where}: a spec record cites an implementation ({cited!r}); make it an oracle record")
        if kind == "vespertine-rule" and avail != "repository":
            errors.append(f"{where}: a vespertine-rule record cites Vespertine's own docs (availability: repository)")
        if not isinstance(rec.get("testable"), bool):
            errors.append(f"{where}: testable must be true or false")
        req = str(rec.get("requirement", ""))
        if not req.strip():
            errors.append(f"{where}: empty requirement")
        elif words(req) > 40:
            errors.append(f"{where}: requirement is {words(req)} words (at most 40)")
        if "quote" in rec:
            if avail not in ("public",):
                errors.append(f"{where}: verbatim quotes are allowed only from public standards")
            if words(str(rec["quote"])) > 25:
                errors.append(f"{where}: quote is {words(str(rec['quote']))} words (at most 25)")
        claim = str(rec.get("claim", ""))
        if not claim.startswith("CLAIMS.md#") or claim.split("#", 1)[1] not in claims_anchors:
            errors.append(f"{where}: claim {claim!r} is not an anchor in CLAIMS.md")

        digest = rec.get("quote_sha256")
        if digest == "BLOCKED":
            if avail not in ("paywalled", "not-public"):
                errors.append(f"{where}: BLOCKED is only for paywalled or not-public sources")
            if rec.get("testable") is not False or rec.get("status") != "blocked-on-source":
                errors.append(f"{where}: a BLOCKED record must be testable: false and status: blocked-on-source")
            continue
        if not isinstance(digest, str) or not HEX64.match(digest):
            errors.append(f"{where}: quote_sha256 {digest!r} is not a SHA-256 (or BLOCKED)")
            continue
        cache = src.get("cache")
        if not cache:
            errors.append(f"{where}: no source.cache saying where the hashed text is")
            continue
        if "repo" in cache:
            try:
                got = spec_cache.clause_digest(cache)
            except (OSError, ValueError) as e:
                errors.append(f"{where}: can't find the cited text in {cache['repo']}: {e}")
                continue
            if got != digest:
                errors.append(f"{where}: {cache['repo']} no longer says what this record cites "
                              f"(hash {got}); review the record against the doc")
        elif "oracle" in cache:
            if kind != "oracle":
                errors.append(f"{where}: only an oracle record may point at an oracle's source")
                continue
            files = cache.get("files")
            if not isinstance(files, list) or not files:
                errors.append(f"{where}: source.cache.files must list the oracle's source files")
                continue
            # The oracle's source is checked where it is present: kept in the repository, or fetched by
            # tools/fetch_oracles.py (CI fetches before running this). Elsewhere only the hash's form is checked.
            local = REPO / cache["oracle"]
            if all((local / f).is_file() for f in files):
                got = tree_digest(local, files)
                if got != digest:
                    errors.append(f"{where}: {cache['oracle']} isn't the source this record reviewed "
                                  f"(digest {got}); re-review the oracle before changing the hash")
        elif "doc" in cache or "header" in cache:
            for field in ("from", "to"):
                if not cache.get(field):
                    errors.append(f"{where}: source.cache.{field} is empty")
            if "doc" in cache and "pages" not in cache:
                errors.append(f"{where}: source.cache needs the pages the clause is on")
        else:
            errors.append(f"{where}: source.cache has no repo, doc, header or oracle key")
    return records


def check_claims(errors: list) -> set:
    text = (ROOT / "CLAIMS.md").read_text(encoding="utf-8")
    anchors = set(ANCHOR.findall(text))
    for n, line in enumerate(text.splitlines(), 1):
        m = CLAIM_TEXT.match(line)
        if line.startswith("- **Text:**") and not m:
            errors.append(f"CLAIMS.md:{n}: Text line isn't `path:line` — \"quote\"")
            continue
        if not m:
            continue
        path, lineno, quote = m.group(1), int(m.group(2)), m.group(3).replace('\\"', '"')
        target = REPO / path
        if not target.exists():
            errors.append(f"CLAIMS.md:{n}: {path} doesn't exist")
            continue
        lines = target.read_text(encoding="utf-8").splitlines()
        if lineno > len(lines) or quote not in lines[lineno - 1]:
            errors.append(f"CLAIMS.md:{n}: {path}:{lineno} no longer says “{quote[:60]}…”")
    return anchors


def check_references(errors: list, records: dict) -> dict:
    """Every requirement ID mentioned by a test, check or mutant must exist. Returns ID -> files using it."""
    used = {}
    for base in SCANNED:
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.suffix not in (".swift", ".c", ".py", ".yaml", ".yml") or ".build" in path.parts:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            ids = set()
            for m in REQ_TAG.finditer(text):
                ids.update(i.strip() for i in m.group(1).split(","))
            ids.update(REQ_STRING.findall(text))
            if path.name == "mutants.yaml":
                for entry in yaml.safe_load(text) or []:
                    ids.add(str(entry.get("targets", "")))
            for i in ids:
                used.setdefault(i, set()).add(str(path.relative_to(REPO)))
                if i not in records:
                    errors.append(f"{path.relative_to(REPO)}: references unknown requirement {i}")
                elif records[i].get("testable") is False:
                    errors.append(f"{path.relative_to(REPO)}: tests {i}, which is not testable ({records[i].get('status', '')})")
    return used


def main() -> int:
    errors: list[str] = []
    anchors = check_claims(errors)
    records = check_records(errors, anchors)
    used = check_references(errors, records)
    by_kind = {}
    for rec in records.values():
        key = "blocked" if rec.get("quote_sha256") == "BLOCKED" else rec.get("kind")
        by_kind[key] = by_kind.get(key, 0) + 1
    untested = sorted(i for i, r in records.items() if r.get("testable") and i not in used)
    print(f"{len(records)} records: " + ", ".join(f"{v} {k}" for k, v in sorted(by_kind.items())))
    if untested:
        print("testable but not referenced by any test yet: " + ", ".join(untested))
    for e in errors:
        print(f"ERROR {e}")
    print("registry OK" if not errors else f"{len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
