#!/usr/bin/env python3
#
# Vespertine verification: sets up the blind A/B/C runs and collects what the agents deliver.
# SPDX-License-Identifier: GPL-3.0-or-later
#
#   cleanroom.py setup <run-dir> <workspace-root>   write every brief to <run-dir>/briefs/ and a workspace per agent
#                                                   under <workspace-root>/<group>-<role>/ (a SwiftPM package holding
#                                                   only the contract's Swift API, plus the DST fixtures for DST)
#   cleanroom.py collect <run-dir> <workspace-root> copy each agent's deliverable into <run-dir>/outputs/ and into
#                                                   the harness (the carrier scanner into oracles/carrier-scan/), and record SHA-256s in <run-dir>/MANIFEST.md
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
    setup_carrier_scan(run, root)


# The independent carrier scanner (record IEC-O-002) is written blind the same way: from the public frame syntax of
# AC-3, E-AC-3 and DTS only, without the IEC 61937 burst format (paywalled) or any implementation of it.
CARRIER_SPECS = {"atsc-a52-2018": "ATSC A/52:2018, Digital Audio Compression (AC-3, E-AC-3) Standard",
                 "etsi-ts-102114-1.6.1": "ETSI TS 102 114 V1.6.1, DTS Coherent Acoustics; Core and Extensions"}
CARRIER_SAMPLES = {"sample.ac3": "dolby-digital-tones.ac3", "sample.ec3": "dolby-digital-plus-tones.ec3",
                   "sample.dts": "dts-tones.dts"}
CARRIER_BRIEF = """# Brief: carrier scanner

You are writing a small, independent checking tool. Others work on related things separately; you will not see
their work. Your tool is judged by running it.

## Rules

- Work only in your workspace, `{ws}`. Do not read, list, search or open any path outside it (no `ls /`, no `find`
  outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't try to
  find out what product or code this is for. Don't use the network, web search, GitHub or any tool other than
  these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox {ws} "<command>"`. That runs `<command>` on Linux in a sandbox that sees only your workspace, mounted
  at `/work` (the command starts in `/work`). Python 3.12 is there as `python3`; use the standard library only.
- Your only sources are the two standards in `specs/` (one text file per PDF page, extracted with pdftotext) and
  the sample streams in `samples/`. Don't write the tool from memory of any other implementation; work from the
  standards, and cite the clause or table for every header field and constant in a code comment.
- Deliver `{ws}/carrier_scan.py`. Anything else you write (tests, generators) stays in your workspace and is not
  delivered.
- Finish with a short report as your final message: what you delivered, what you tested it on, everything in the
  standards you found ambiguous, and every assumption you made.

## Background

A player that can't decode Dolby Digital (AC-3), Dolby Digital Plus (E-AC-3) or DTS can still pass the compressed
frames to a receiver hidden inside a 16-bit stereo PCM signal. The frames' bytes ride in consecutive 16-bit PCM
samples, two bytes of the frame per sample, in sample order across both channels; between frames there are other
16-bit words (a few header words and zero padding). You are deliberately not told that container format and the
tool must not depend on it: it finds frames using only the codecs' own frame syntax. Which byte of each pair is the
high byte of the sample is not known, so the tool tries both orders.

The tool exists to show that every original frame arrives intact, in order, and that nothing else in the carrier
looks like a frame.

## The tool

`python3 carrier_scan.py frames <stream>`
: Split an elementary stream (a raw `.ac3`, `.ec3` or `.dts` file: frames back to back, nothing else) into frames.
  Print one JSON object per line: `{{"offset": <byte offset>, "codec": "ac3" | "eac3" | "dts", "length": <bytes>,
  "sha256": "<hex of the frame's bytes>"}}`. Exit 1 if the file isn't entirely valid frames back to back.

`python3 carrier_scan.py scan <carrier.wav>`
: Read a WAV file of 16-bit integer PCM (any channel count, normally 2). Turn its sample data into a byte stream,
  two bytes per sample in sample order, in each of the two byte orders, and scan each for frames. Print a first
  line `{{"byte_order": ...}}` naming the order that found frames, then one line per frame found, as above (offset
  = byte offset in that byte stream). Exit 1 if neither order finds a frame.

`python3 carrier_scan.py compare <carrier.wav> <stream>`
: Exit 0 exactly when the frames found in the carrier are the frames of the stream: the same bytes, in the same
  order, none missing, none extra. Otherwise print what differs (first mismatch, counts) and exit 1.

## Scanning rules

- A candidate frame starts at the codec's sync word, aligned to a 16-bit word of the carrier. Accept it only when
  its header is valid by the standard (reserved or forbidden values rejected), its length can be computed from the
  header, and the whole frame lies inside the data.
- For AC-3 and E-AC-3, also check the frame's CRC words exactly as A/52 defines them; a candidate that fails is
  not a frame. DTS core: check what TS 102 114 lets you check from the header (there is no mandatory frame CRC).
- After accepting a frame, continue after its last byte. Report, after the frames, one summary line
  `{{"rejected_candidates": <n>}}` counting sync words that didn't make a valid frame.
- Out of scope: DTS 14-bit packed streams, DTS extension substreams without a core, TrueHD, AAC. AC-3 and E-AC-3
  independent and dependent substreams are all frames.

## What you have

- `specs/atsc-a52-2018/page-NNN.txt`: {a52}.
- `specs/etsi-ts-102114-1.6.1/page-NNN.txt`: {dts}.
- `samples/sample.ac3`, `samples/sample.ec3`, `samples/sample.dts`: short elementary streams to test `frames` on.
  To test `scan` and `compare`, build your own carriers from them (any padding and filler you like, both byte
  orders, corrupted copies); the real container is not available to you.
"""


def setup_carrier_scan(run: Path, root: Path) -> None:
    ws = root / "carrier-scan"
    if ws.exists():
        shutil.rmtree(ws)
    for doc in CARRIER_SPECS:
        shutil.copytree(VERIFICATION / "spec-cache/txt" / doc, ws / "specs" / doc)
    (ws / "samples").mkdir(parents=True)
    fixtures = VERIFICATION.parent / "Packages/VespertineKit/Tests/VespertineAudioTests/Fixtures"
    for name, src in CARRIER_SAMPLES.items():
        shutil.copyfile(fixtures / src, ws / "samples" / name)
    text = CARRIER_BRIEF.format(ws=ws, a52=CARRIER_SPECS["atsc-a52-2018"], dts=CARRIER_SPECS["etsi-ts-102114-1.6.1"])
    (run / "briefs" / "carrier-scan.md").write_text(text)
    (ws / "BRIEF.md").write_text(text)
    print(f"carrier-scan: {ws}")


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
    # A delivered file replaces its stand-in in the module's Placeholders.swift (an empty registry, or nil).
    for mod in ("SpecChecks", "CleanRoomB", "CleanRoomB2", "Mutants"):
        holder = HARNESS / "Sources" / mod / "Placeholders.swift"
        if not holder.exists():
            continue
        delivered = {f.stem for f in holder.parent.glob("*.swift") if f.name != "Placeholders.swift"}
        kept = [l for l in holder.read_text().splitlines()
                if not (m := re.match(r"public enum (\w+) ", l)) or m.group(1) not in delivered]
        if any(l.startswith("public enum ") for l in kept):
            holder.write_text("\n".join(kept) + "\n")
        else:
            holder.unlink()
    src = root / "carrier-scan/carrier_scan.py"
    if src.exists():
        for dest in (out / "carrier-scan/carrier_scan.py", VERIFICATION / "oracles/carrier-scan/carrier_scan.py"):
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
        rows.append(f"| carrier-scan | | `carrier_scan.py` | `{sha256(src)}` | {len(src.read_text().splitlines())} |")
    else:
        rows.append("| carrier-scan | | `carrier_scan.py` | missing | |")
    brief_rows = [f"| `briefs/{p.name}` | `{sha256(p)}` |" for p in sorted((run / "briefs").glob("*.md"))]
    (run / "MANIFEST.md").write_text(
        "# Run manifest\n\nEvery deliverable exactly as the agent wrote it (also in `outputs/`), copied unchanged into "
        "the harness. Each is the agent's last delivery: where an agent had a review round, `round1/` (and `round2/` "
        "for the verdict group, after the F-05 and H-01 record changes) holds the message it was sent and the diff "
        "from its previous delivery.\n\n"
        "| Group | Role | File | SHA-256 | Lines |\n|---|---|---|---|---|\n" + "\n".join(rows) +
        "\n\n## Briefs\n\n| Brief | SHA-256 |\n|---|---|\n" + "\n".join(brief_rows) + "\n")
    print("\n".join(rows))


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("setup", "collect"):
        print("usage: cleanroom.py setup|collect <run-dir> <workspace-root>")
        sys.exit(2)
    (setup if sys.argv[1] == "setup" else collect)(Path(sys.argv[2]), Path(sys.argv[3]))
