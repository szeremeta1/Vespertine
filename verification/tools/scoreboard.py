#!/usr/bin/env python3
#
# Vespertine verification: turns the acceptance run's JSON (VERIFICATION_RESULTS, written by the "Scoreboard" test)
# into the scoreboard tables of REPORT.md.
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   scoreboard.py <results.json> [<results.json> ...]     one file per platform (Linux, macOS)
#
# Per group: checks, requirements covered, whether every clean-room implementation passes every check, how many
# mutants the checks kill, and Vespertine's result on each platform. Per requirement: the same, plus the checks and
# the mutants aimed at it. Then every surviving mutant and every check Vespertine fails, with the first failures. A
# failure already recorded in FINDINGS.md (KnownFindings.swift) is marked "known" with its finding IDs.

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def records() -> dict:
    """id -> {kind, testable}, read line by line so this runs without PyYAML (CI's macOS job prints the scoreboard)."""
    out, current = {}, None
    for path in sorted((ROOT / "requirements").glob("*.yaml")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if m := re.match(r"- id: (\S+)", line):
                current = out.setdefault(m.group(1), {"id": m.group(1)})
            elif current and (m := re.match(r"  (kind|testable): (\S+)", line)):
                current[m.group(1)] = m.group(2) if m.group(1) == "kind" else m.group(2) == "true"
    return out


def known_findings() -> dict:
    """(group, check) -> finding IDs, from KnownFindings.byCheck (one "group/check": "IDs" entry per line)."""
    path = ROOT / "harness/Tests/AcceptanceTests/KnownFindings.swift"
    out = {}
    for m in re.finditer(r'^\s*"([^"/]+)/([^"]+)": "([^"]+)",$', path.read_text(encoding="utf-8"), re.M):
        out[(m.group(1), m.group(2))] = m.group(3)
    return out


def subject_status(results: list, req: str) -> str:
    """'pass', 'FAIL' or 'no assertion' for one requirement over the checks that test it on one subject."""
    if not results:
        return "–"
    status = "pass"
    for r in results:
        if r is None:
            return "not delivered"
        if req in r["failedRequirements"]:
            return "FAIL"
        if not r["passed"] and not r["failedRequirements"]:
            status = "no assertion"
    return status


def vespertine_status(checks: list, req: str, group: str, known: dict) -> str:
    notes = {c["vespertine"].get("notRun") for c in checks if c["vespertine"].get("notRun")}
    if notes:
        return "not run: " + "; ".join(sorted(notes))
    status = subject_status([c["vespertine"].get("result") for c in checks], req)
    if status == "FAIL":
        ids = sorted({known[(group, c["name"])] for c in checks if (group, c["name"]) in known
                      and c["vespertine"].get("result") and req in c["vespertine"]["result"]["failedRequirements"]})
        if ids:
            status += " (known: " + ", ".join(ids) + ")"
    return status


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: scoreboard.py <results.json> [<results.json> ...]")
        return 2
    regs = records()
    known = known_findings()
    boards = [json.loads(Path(p).read_text()) for p in sys.argv[1:]]
    platforms = [b["platform"] for b in boards]
    first = boards[0]
    lines = []

    # Groups
    head = "| Group | Checks | Requirements tested | Clean-room implementations pass | Mutants killed | " + \
        " | ".join(f"Vespertine ({p}): checks passed" for p in platforms) + " |"
    lines += ["### By group", "", head, "|" + "---|" * (5 + len(platforms))]
    for gi, group in enumerate(first["groups"]):
        checks, mutants = group["checks"], group["mutants"]
        reqs = sorted({r for c in checks for r in c["requirements"]})
        labels = sorted({ref["label"] for c in checks for ref in c["references"]})
        ref_cells = []
        for label in labels:
            results = [ref.get("result") for c in checks for ref in c["references"] if ref["label"] == label]
            passed = sum(1 for r in results if r and r["passed"])
            ref_cells.append(f"{label} {passed}/{len(results)}")
        killed = sum(1 for m in mutants if m["killedBy"])
        vcells = []
        for b in boards:
            g = b["groups"][gi]
            ran = [c for c in g["checks"] if not c["vespertine"].get("notRun")]
            passed = sum(1 for c in ran if c["vespertine"].get("result") and c["vespertine"]["result"]["passed"])
            known_failing = sum(1 for c in ran if (g["name"], c["name"]) in known and c["vespertine"].get("result")
                                and not c["vespertine"]["result"]["passed"])
            vcells.append(f"{passed}/{len(ran)}" + (f" ({len(g['checks']) - len(ran)} not run)" if len(ran) < len(g["checks"]) else "")
                          + (f" ({known_failing} known)" if known_failing else ""))
        lines.append(f"| {group['name']} | {len(checks)} | {len(reqs)} | {', '.join(ref_cells) or '–'} | "
                     f"{killed}/{len(mutants)} | " + " | ".join(vcells) + " |")

    # Requirements
    lines += ["", "### By requirement", "",
              "| Requirement | Kind | Checks | Implementations | Mutants killed | " +
              " | ".join(f"Vespertine ({p})" for p in platforms) + " |",
              "|" + "---|" * (5 + len(platforms))]
    for gi, group in enumerate(first["groups"]):
        reqs = sorted({r for c in group["checks"] for r in c["requirements"]})
        for req in reqs:
            checks = [c for c in group["checks"] if req in c["requirements"]]
            labels = sorted({ref["label"] for c in checks for ref in c["references"]})
            impl = ", ".join(f"{l} {subject_status([ref.get('result') for c in checks for ref in c['references'] if ref['label'] == l], req)}"
                             for l in labels)
            aimed = [m for m in group["mutants"] if req in m["targets"]]
            killed = sum(1 for m in aimed if m["killedBy"])
            kind = regs.get(req, {}).get("kind", "?")
            vs = [vespertine_status([c for c in b["groups"][gi]["checks"] if req in c["requirements"]], req,
                                    group["name"], known) for b in boards]
            lines.append(f"| {req} | {kind} | {len(checks)} | {impl} | {killed}/{len(aimed)} | " + " | ".join(vs) + " |")
    untested = sorted(i for i, r in regs.items() if r.get("testable") and r.get("kind") != "oracle"
                      and not any(i in c["requirements"] for g in first["groups"] for c in g["checks"]))
    if untested:
        lines += ["", "Testable records no check covers: " + ", ".join(untested)]

    # Survivors
    lines += ["", "### Surviving mutants", ""]
    survivors = [(g["name"], m) for g in first["groups"] for m in g["mutants"] if not m["killedBy"]]
    if not survivors:
        lines.append("None: every mutant failed a check of a requirement it targets.")
    for name, m in survivors:
        elsewhere = "; ".join(m["failedElsewhere"]) or "nothing"
        lines.append(f"- {name}: `{m['id']}` [{', '.join(m['targets'])}] {m['summary']} (failed only: {elsewhere})")

    # Clean-room failures
    lines += ["", "### Checks a clean-room implementation fails", ""]
    ref_fail = [(g["name"], c, ref) for g in first["groups"] for c in g["checks"] for ref in c["references"]
                if not (ref.get("result") and ref["result"]["passed"])]
    if not ref_fail:
        lines.append("None.")
    for name, c, ref in ref_fail:
        r = ref.get("result")
        detail = "not delivered" if r is None else "; ".join(r["failures"][:3]) or (r.get("thrown") or "")
        lines.append(f"- {name}: “{c['name']}” on {ref['label']}: {detail}")

    # Vespertine failures
    lines += ["", "### Checks Vespertine fails", ""]
    any_fail = False
    for b in boards:
        for g in b["groups"]:
            for c in g["checks"]:
                r = c["vespertine"].get("result")
                if r is not None and not r["passed"]:
                    any_fail = True
                    detail = "; ".join(r["failures"][:3]) or (r.get("thrown") or "made no assertion")
                    finding = known.get((g["name"], c["name"]))
                    note = f" (known: {finding}, FINDINGS.md)" if finding else " (new: not in FINDINGS.md)"
                    lines.append(f"- {b['platform']}, {g['name']}: “{c['name']}” [{', '.join(r['failedRequirements'])}]{note}: {detail}")
    if not any_fail:
        lines.append("None.")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
