#!/usr/bin/env python3
#
# Vespertine verification: sets up the blind A/B/C runs and collects what the agents deliver.
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   cleanroom.py setup <run-dir> <workspace-root>   write every brief to <run-dir>/briefs/ and a workspace per agent
#                                                   under <workspace-root>/<group>-<role>/ (a SwiftPM package holding
#                                                   only the contract's Swift API, plus the DST fixtures for DST)
#   cleanroom.py collect <run-dir> <workspace-root> copy each agent's deliverable into <run-dir>/outputs/ and into
#                                                   the harness, and record SHA-256s in <run-dir>/MANIFEST.md
#
# An agent sees its brief and its workspace and nothing else: no product name, no product source, no other
# agent's work. A brief carries the contract, the group's requirement records with the product's own
# documentation reduced to "the product's documentation" (no file names, lines or wording beyond each record's
# paraphrase), and the Swift API it compiles against.

import hashlib
import re
import shutil
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
VERIFICATION = HERE.parent
HARNESS = VERIFICATION / "harness"

# group: contract file, record files, Swift contract files, deliverable stem(s), roles
GROUPS = {
    "dop-pack": dict(contract="dop-pack.md", records=["dop-pack.yaml"], swift=["DoPPack.swift"],
                     checks=["DoPPackChecks"], b=["BDoPPack"], mutants=["DoPPackMutants"],
                     protocols=["DoPPacker"], roles=["A", "B", "C"]),
    "dop-stream": dict(contract="dop-stream.md", records=["dop-stream.yaml"], swift=["DoPStream.swift"],
                       checks=["DoPStreamChecks"], b=["BDoPStream"], mutants=["DoPStreamMutants"],
                       protocols=["DoPStageMaker"], roles=["A", "B", "C"]),
    "pcm-stream": dict(contract=["float-stream.md", "integer-stream.md"], records=["float.yaml", "integer.yaml"],
                       swift=["FloatStream.swift", "IntegerStream.swift"],
                       checks=["FloatChecks", "IntegerChecks"], b=["BFloat", "BInteger"],
                       mutants=["FloatMutants", "IntegerMutants"], protocols=["FloatOutput", "IntegerOutput"],
                       roles=["A", "B", "C"]),
    "rate": dict(contract="rate-plan.md", records=["rate.yaml"], swift=["RatePlan.swift"],
                 checks=["RateChecks"], b=["BRate"], mutants=["RateMutants"], protocols=["RatePlanner"],
                 roles=["A", "B", "B2", "C"]),
    "verdict": dict(contract="bit-perfect-verdict.md", records=["verdict.yaml"], swift=["Verdict.swift"],
                    checks=["VerdictChecks"], b=["BVerdict"], mutants=["VerdictMutants"], protocols=["BadgeVerdict"],
                    roles=["A", "B", "B2", "C"]),
    "dst": dict(contract="dst-decode.md", records=["dst.yaml"], swift=["DSTDecode.swift"],
                checks=["DSTChecks"], b=[], mutants=["DSTMutants"], protocols=["DSTDecoderMaker"],
                roles=["A", "C"]),
}

PRODUCT_DOCS = re.compile(r"(docs/)?(ARCHITECTURE|FEATURES|VERIFICATION|README)\.md( lines? [0-9][0-9, -]*)?")


def redact(text: str) -> str:
    text = PRODUCT_DOCS.sub("the product documentation", text)
    return re.sub(r"vespertine", "the product", text, flags=re.IGNORECASE)


def records_for(group: dict) -> str:
    out = []
    for name in group["records"]:
        for rec in yaml.safe_load((VERIFICATION / "requirements" / name).read_text(encoding="utf-8")):
            src = rec["source"]
            if src["availability"] == "repository":
                source = {"doc": "the product's own documentation (a rule the product sets for itself)",
                          "availability": "product rule"}
            else:
                source = {k: src[k] for k in ("doc", "version", "section", "url", "availability") if src.get(k)}
            kind = "product-rule" if rec["kind"] == "vespertine-rule" else rec["kind"]
            r = {"id": rec["id"], "kind": kind, "source": source, "requirement": redact(rec["requirement"])}
            if rec.get("quote"):
                r["quote"] = rec["quote"]
            r["testable"] = rec["testable"]
            if rec.get("status"):
                r["status"] = rec["status"]
            if rec.get("gap"):
                r["gap"] = redact(rec["gap"])
            out.append(r)
    return yaml.safe_dump(out, sort_keys=False, allow_unicode=True, width=110)


def contract_text(group: dict) -> str:
    files = group["contract"] if isinstance(group["contract"], list) else [group["contract"]]
    parts = []
    for f in files:
        text = (VERIFICATION / "contracts" / f).read_text(encoding="utf-8")
        text = text.replace("`verification/fixtures/dst/`", "the fixture set").replace("(see `../requirements/dst.yaml`)", "")
        parts.append(redact(text).strip())
    return "\n\n---\n\n".join(parts)


def swift_api(group: dict, role: str) -> list[tuple[str, str]]:
    files = [(f"harness/Sources/Contracts/{f}", (HARNESS / "Sources/Contracts" / f).read_text()) for f in group["swift"]]
    if group["swift"] != ["DoPPack.swift"]:
        files.insert(0, ("harness/Sources/Contracts/DoPPack.swift", (HARNESS / "Sources/Contracts/DoPPack.swift").read_text()))
    if role in ("A", "C"):
        files.append(("harness/Sources/SpecKit/SpecKit.swift", (HARNESS / "Sources/SpecKit/SpecKit.swift").read_text()))
        if group is GROUPS["dst"]:
            files.append(("harness/Sources/SpecKit/DSTFixtures.swift", (HARNESS / "Sources/SpecKit/DSTFixtures.swift").read_text()))
    return [(path, redact(redact_header(text))) for path, text in files]


def redact_header(swift: str) -> str:
    return swift.replace("// Vespertine verification: ", "// ")


def module(role: str) -> str:
    return {"A": "SpecChecks", "B": "CleanRoomB", "B2": "CleanRoomB2", "C": "Mutants"}[role]


def deliverables(group: dict, role: str) -> list[str]:
    stems = {"A": group["checks"], "B": group["b"], "B2": [s.replace("B", "B2", 1) for s in group["b"]], "C": group["mutants"]}[role]
    return [f"harness/Sources/{module(role)}/{stem}.swift" for stem in stems]


def package_swift(role: str) -> str:
    deps = '["Contracts", "SpecKit"]' if role in ("A", "C") else '["Contracts"]'
    kit = '        .target(name: "SpecKit", dependencies: ["Contracts"]),\n' if role in ("A", "C") else ""
    scratch_deps = f'["Contracts", {"\"SpecKit\", " if role in ("A", "C") else ""}"{module(role)}"]'
    return f"""// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Workspace",
    targets: [
        .target(name: "Contracts"),
{kit}        .target(name: "{module(role)}", dependencies: {deps}),
        // Anything you like, for trying your work out. Not delivered.
        .executableTarget(name: "Scratch", dependencies: {scratch_deps}),
    ],
    swiftLanguageModes: [.v6]
)
"""


ROLE_TEXT = {
    "A": """## Your role: tests (A)

Write checks that decide whether an implementation of the contract meets the requirement records below.

- Cover every record with `testable: true`: at least one check per requirement ID, and as many as it takes to test the requirement thoroughly (edge cases, every channel, many sizes and sequences). An implementation that breaks a requirement in any way a careful reader of the record could foresee should fail a check.
- Every assertion is `checker.expect(condition, "<ID>", "<message>")`, naming the one requirement it checks. A check's `requirements:` lists exactly the IDs it asserts. Put a comment line `// REQ: <IDs>` directly above each check.
- Assert only what a requirement says. Nothing a record leaves open (read each `gap`), nothing the contract says without a requirement behind it, and no particular choice where the records allow several. Records with `testable: false` are not tested.
- Checks run against several implementations, including deliberately broken ones. They must never trap or hang: check counts before indexing, no force unwraps, no `fatalError`, bounded loops. Each check should finish within a few seconds in a debug build. Use a fresh object per scenario where the contract has state.
- Deterministic: no system randomness or clock. Write your own seeded generator if you want pseudo-random data.
- You have no implementation to run against. You may write one in `Sources/Scratch` to try your checks; it is not delivered and nobody else sees it.
""",
    "B": """## Your role: implementation (B)

Implement the contract so that every requirement record with `testable: true` holds.

- Where the contract and records leave a choice open, pick any behaviour consistent with them; don't add behaviour the contract doesn't ask for.
- Never trap for any input the contract allows; behave sensibly (no crash, no hang) for input it rules out.
- Don't deliver tests. You may try your code in `Sources/Scratch`; it is not delivered.
""",
    "C": """## Your role: mutants (C)

Write deliberately wrong implementations ("mutants") that a good test suite for these requirements must catch.

- For every requirement ID with `testable: true`, write at least two mutants that each violate that requirement as written, while otherwise following the contract and, as far as possible, every other requirement. Range from blatant to subtle: wrong only at an edge, on one channel, after many frames, for one rate, on the second call, and so on. Each must be a real violation a thorough test of the record could detect: never something the record's `gap` leaves open, and never a difference no test could observe through the contract.
- Each mutant is a decorator over a correct implementation that the harness passes in at run time (you don't write that one): `Mutant("C-<REQ>-<letter>", targets: ["<REQ>"], summary: "<one line: what is wrong>") { base in <your wrapper around base> }`. `targets` lists every requirement the mutant violates (usually one).
- Mutants must never trap or hang, for any input the contract allows.
- You may write your own correct implementation in `Sources/Scratch` to try your mutants against; it is not delivered and nobody else sees it.
""",
}

ROLE_TEXT["B2"] = ROLE_TEXT["B"].replace("(B)", "(B2)")


def brief(name: str, group: dict, role: str, workspace: Path) -> str:
    stems = {"A": group["checks"], "B": group["b"], "B2": [s.replace("B", "B2", 1) for s in group["b"]], "C": group["mutants"]}[role]
    shapes = []
    for stem, proto in zip(stems, group["protocols"]):
        if role == "A":
            shapes.append(f"`public enum {stem} {{ public static let all: [SpecCheck<any {proto}>] = [ … ] }}`")
        elif role == "C":
            shapes.append(f"`public enum {stem} {{ public static let all: [Mutant<any {proto}>] = [ … ] }}`")
        else:
            shapes.append(f"`public enum {stem} {{ public static let subject: (any {proto})? = <your implementation> }}`")
    files = "\n".join(f"- `{workspace}/{d}` defining {s}" for d, s in zip(deliverables(group, role), shapes))
    api = "\n\n".join(f"### `{path}`\n\n```swift\n{text.rstrip()}\n```" for path, text in swift_api(group, role))
    fixtures = ""
    if name == "dst":
        fixtures = "\nThe DST fixture set is in `fixtures/dst/` of your workspace (`DSTFixtures.all` loads it): " + ", ".join(
            f"`{p.stem}`" for p in sorted((VERIFICATION / "fixtures/dst").glob("*.dst"))) + \
            ". Each `<name>.dst` is a frame and `<name>.dsd` the DSD it encodes; `fixtures.json` lists channels and coding.\n"
    return f"""# Brief: {name}, role {role}

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `{workspace}`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox {workspace} "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox {workspace} "cd harness && swift build"`, and run your scratch program with
  `swiftbox {workspace} "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
{files}
  It must compile in Swift 6 language mode with `swiftbox {workspace} "cd harness && swift build"`, depend on
  nothing but the modules already in the workspace package, and not change any file you were given.
- Finish with a short report as your final message: what you delivered, every requirement or contract point you
  found ambiguous or contradictory (by ID), and every assumption you made.

{ROLE_TEXT[role]}
## The contract

{contract_text(group)}

## The requirement records

```yaml
{records_for(group).rstrip()}
```
{fixtures}
## The Swift API (already in your workspace)

{api}
"""


def setup(run: Path, root: Path) -> None:
    (run / "briefs").mkdir(parents=True, exist_ok=True)
    for name, group in GROUPS.items():
        for role in group["roles"]:
            ws = root / f"{name}-{role}"
            if ws.exists():
                shutil.rmtree(ws)
            (ws / "harness/Sources/Scratch").mkdir(parents=True)
            (ws / f"harness/Sources/{module(role)}").mkdir(parents=True)
            (ws / "harness/Package.swift").write_text(package_swift(role))
            (ws / "harness/Sources/Scratch/main.swift").write_text("// Scratch: try things out here. Not delivered.\n")
            for path, text in swift_api(group, role):
                (ws / path).parent.mkdir(parents=True, exist_ok=True)
                (ws / path).write_text(text)
            if name == "dst":
                shutil.copytree(VERIFICATION / "fixtures/dst", ws / "fixtures/dst", ignore=shutil.ignore_patterns("README.md"))
            text = brief(name, group, role, ws)
            (run / "briefs" / f"{name}-{role}.md").write_text(text)
            (ws / "BRIEF.md").write_text(text)
            print(f"{name}-{role}: {ws}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(run: Path, root: Path) -> None:
    out = run / "outputs"
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, group in GROUPS.items():
        for role in group["roles"]:
            ws = root / f"{name}-{role}"
            for rel in deliverables(group, role):
                src = ws / rel
                if not src.exists():
                    rows.append(f"| {name} | {role} | `{rel}` | missing | |")
                    continue
                dest = out / f"{name}-{role}" / Path(rel).name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dest)
                shutil.copyfile(src, HARNESS / rel.removeprefix("harness/"))
                rows.append(f"| {name} | {role} | `{rel}` | `{sha256(src)}` | {len(src.read_text().splitlines())} |")
    brief_rows = [f"| `briefs/{p.name}` | `{sha256(p)}` |" for p in sorted((run / "briefs").glob("*.md"))]
    (run / "MANIFEST.md").write_text(
        "# Run manifest\n\nEvery deliverable exactly as the agent wrote it (also in `outputs/`), copied unchanged into "
        "the harness.\n\n| Group | Role | File | SHA-256 | Lines |\n|---|---|---|---|---|\n" + "\n".join(rows) +
        "\n\n## Briefs\n\n| Brief | SHA-256 |\n|---|---|\n" + "\n".join(brief_rows) + "\n")
    print("\n".join(rows))


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("setup", "collect"):
        print("usage: cleanroom.py setup|collect <run-dir> <workspace-root>")
        sys.exit(2)
    (setup if sys.argv[1] == "setup" else collect)(Path(sys.argv[2]), Path(sys.argv[3]))
