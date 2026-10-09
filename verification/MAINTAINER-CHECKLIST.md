# Maintainer checklist

What this harness proves about Vespertine, what it doesn't, what it would cost to close the gaps, and how to check
in under half an hour that the harness itself is honest. The numbers are in `REPORT.md`, the problems in
`FINDINGS.md`.

## Kinds of evidence

| Evidence | What it shows | Where it runs |
|---|---|---|
| **Spec check** (record kind `spec`) | Vespertine does what a published document says (DoP 1.1, DSF 1.01, DSDIFF 1.5, Apple's Core Audio headers). Each assertion carries `// REQ:` with the record, and the record carries the clause's hash. | CI: `verification-linux`, `verification-macos` |
| **Rule check** (`vespertine-rule`) | Vespertine does what its own docs say (the BIT-PERFECT conditions, for example). Only as strong as the docs: if a doc line is wrong, the check enforces the wrong thing. | CI: same jobs |
| **Oracle** (`oracle`) | Vespertine agrees with an independent implementation: libdstdec for DST, FFmpeg's S/PDIF demuxer and a blind carrier scanner for IEC 61937. A second opinion, not proof. | CI: `verification-registry` (DST), `verification-iec-oracle` |
| **Hardware procedure** | What leaves the Mac: loopback captures, a DAC's DSD indicator, a receiver. Manual, with a tool that decides pass or fail. | `hardware/LOOPBACK.md`, `hardware/SACD-ORACLE.md`, by hand |
| **Blocked** (`status: blocked-on-source`) | Nothing yet: the standard hasn't been bought. Listed so the gap is visible. | – |

A check is accepted only if two clean-room implementations written from the record alone (B, and B2 on a second
model where there is one) pass it, and every mutant aimed at its requirement fails it. The CI mutant step fails if
any mutant survives. Vespertine's result is reported, never tuned: a check Vespertine fails stays failing, recorded
in `FINDINGS.md` as a known issue, until Vespertine or its docs change.

## What is proven, by which evidence

| Claim (`CLAIMS.md`) | Records | Evidence | Gaps |
|---|---|---|---|
| DoP markers alternate 0x05/0xFA (`#dop-marker`) | DOP-001 to 003, DOPS-001 | spec checks | – |
| DSD bits survive packing (`#dop-bits`) | DOP-004 to 007 | spec checks, rule check | over the wire: LOOPBACK D2 |
| DoP carrier rate is DSD ÷ 16 (`#dop-carrier-rate`) | RATE-001 to 003 | spec checks, rule check | – |
| DoP frames never modified (`#dop-passthrough`) | DOPS-004 | rule check | over the wire: LOOPBACK D2 |
| DoP only when marked and offered (`#dop-plan`) | RATE-004, RATE-005 | rule checks | – |
| A held DoP stream keeps its markers (`#dop-continuity`) | DOPS-002, DOPS-003 | spec checks | DAC indicator: LOOPBACK D1 |
| Mute and underruns don't skip music (`#mute-no-skip`) | DOPS-005, DOPS-006, FLT-005, INT-003 | rule checks | – |
| EQ doesn't touch DoP (`#eq-not-dop`) | DOPS-007 | rule check | – |
| 24-bit through the float path unchanged (`#float-24bit`) | FLT-001, FLT-002, FLT-004 | rule checks | over the wire: LOOPBACK L2 |
| Samples keep channel and order (`#bp-definition`) | FLT-003 | rule check | over the wire: LOOPBACK L1 |
| Integer mode passes every 32-bit word (`#int-32bit-words`) | INT-001, INT-002 | rule checks | – |
| BIT-PERFECT conditions (`#bp-*`, `#eq-label`) | BPV-001 to 017 | rule checks (BPV-009: spec, Core Audio headers) | macOS only; readback on a real device: LOOPBACK P1 |
| Track's own rate, planner fallback order (`#rate-native`, `#rate-planner-order`) | RATE-006 to 010 | rule checks | macOS only; on a DAC: LOOPBACK R1 |
| DST decodes to the original DSD (`#sacd-dst`) | DST-001 to 004 | spec checks (frame size), oracle (libdstdec), rule check | DST-005 blocked (ISO/IEC 14496-3) |
| SACD frames are 1/75 s, 4704 bytes per channel (`#sacd-frames`) | DST-001, DST-002 | spec checks (DSDIFF 1.5, DSF 1.01) | – |
| Dolby frames go out byte for byte in the carrier (`#iec-carrier-exact`) | IEC-O-001, IEC-O-002 | oracles (FFmpeg demux, blind scanner) | burst layout itself blocked: IEC-001 to 007 |
| Matched sacd_extract on two discs (`#sacd-match`) | – | none in the repository | F-03; `hardware/SACD-ORACLE.md` |
| Integer mode only with the device held (`#int-conditions`) | BPV-018 | rule record, not testable from the verdict alone: the contract rules out inputs that break it | on a device: integer mode off in shared mode |
| Device handed back on quit, rate change noticed (`#rate-handback`, `#rate-change-behind`) | – | hardware procedure only | LOOPBACK R2, R3 |
| Gapless (`#gapless`) | – | hardware procedure only | LOOPBACK L3 |
| A receiver decodes the bitstream (`#iec-scope`) | – | hardware procedure only | LOOPBACK B1 |

Not covered at all (no record, no procedure): `#eq-flat-is-none`, `#float-rounds-wider`, `#int-24-top-bits`,
`#dop-file-bit-order`, `#iec-dtscd`, the DTS-CD claims, `#sacd-toc` and `#sacd-areas` beyond the
SACD procedure's by-eye TOC comparison, `#sacd-readonly` beyond its fingerprints, `#stream-swap`, `#dec-lossless`
and the file-analysis claims. Vespertine's own test suite covers several of these; this harness doesn't vouch for
them. A missing record can cost something: until BPV-018 covered `#int-conditions`, the shared-mode check expected
integer mode without exclusive access (H-01).

## Blocked, and what it costs to unblock

From `SOURCES.md` (list prices on 2026-10-09). Alex chose oracle evidence instead on 2026-10-09.

| Buy | Price | Unblocks |
|---|---|---|
| IEC 61937-1:2021 | CHF 160 | IEC-001, IEC-002, IEC-003 (burst preamble, payload length, stuffing and byte order) |
| IEC 61937-2:2021 + AMD1:2026 | CHF 90 | IEC-004 (data-type codes) |
| IEC 61937-3:2017 + AMD1:2020 | CHF 90 | IEC-005, IEC-006 (AC-3 and E-AC-3 bursts) |
| IEC 61937-5:2006 + AMD1:2019 | CHF 100 | IEC-007 (DTS bursts; moot while no DTS carrier exists, see F-02) |
| ISO/IEC 14496-3:2019 | CHF 227 | DST-005 (DST decoding from the standard rather than the reference decoder) |

CHF 440 for the four IEC parts (CHF 640 as consolidated editions), CHF 667 with ISO/IEC 14496-3. DST-006 (the SACD
disc format) has no purchase route: the Scarlet Book is licensed to SACD licensees only. After buying one, add it
with `tools/spec_cache.py add <doc> <file.pdf>`, then write the checks; the clause text stays in the git-ignored
`spec-cache/`.

## Vespertine's own rules still standing in for a standard

39 records are `vespertine-rule`: no public standard covers them, so the source is Vespertine's own documentation at
`98cad1a` (BPV-016 and BPV-017 with the F-05 docs change). If a doc line changes, `check_registry.py` fails until
the record is re-read and its hash updated, so the docs and the checks can't drift apart silently. Read each
record's `gap` before trusting it: it says what the doc leaves open and how the record decided.

- `docs/VERIFICATION.md`: DOP-007, DOPS-005, FLT-001, FLT-003, FLT-005, INT-001 to 003, BPV-001 to 008, BPV-010,
  BPV-012, BPV-015
- `docs/ARCHITECTURE.md`: DOPS-004, DOPS-006, FLT-002, FLT-004, RATE-003, RATE-004, BPV-013, BPV-016, BPV-017
- `docs/FEATURES.md`: DOPS-007, DST-004, RATE-005 to 010, BPV-011, BPV-014, BPV-018

The ones a reader is most likely to dispute: BPV-003 (reads "doesn't trust its own request" as covering a failed
readback; F-01 rests on it), BPV-006 (applies the gain conditions to DoP and bitstream too), RATE-007 to 009 (read
"same rate family" as integer multiples and divisors), and BPV-016 (doesn't require the DoP carrier's physical
format to be integer).

## Five spot checks (under 30 minutes in all)

Run from the repository root, on a Mac with the Command Line Tools or on Linux with Swift 6 and Python 3 with PyYAML.

1. **The registry is consistent** (1 minute). `python3 verification/tools/fetch_oracles.py && python3
   verification/tools/check_registry.py` prints OK. Then change one word of `docs/VERIFICATION.md` line 21 and run
   it again: it must fail on BPV-002 and BPV-003. `git checkout docs/VERIFICATION.md`.

2. **A hash matches its source** (5 minutes). `python3 verification/tools/spec_cache.py fetch`, then
   `python3 verification/tools/spec_cache.py clause dop-1.1 2 "The 8 most significant bits are used for the DSD marker" "0x05 and 0xFA."`
   prints the clause and a hash equal to DOP-002's `quote_sha256` in `requirements/dop-pack.yaml`. Read the
   printed clause against page 2 of the PDF in `spec-cache/pdf/`.

3. **The checks catch a real bug in Vespertine's code** (10 minutes). In
   `Packages/VespertineKit/Sources/CVespertineRT/vespertine_rt.c` change `#define NRT_DOP_MARKER_B 0xFAu` to `0xFBu`,
   then `swift test --package-path verification/harness --filter 'DoPStreamAcceptance/vespertine'`. About 19 DoP
   stream checks must fail, naming DOPS-002 (tried on 2026-10-09: 19 issues). `git checkout Packages/`.

4. **The clean room was clean** (5 minutes). Open `runs/2026-10-09/briefs/` and pick one brief, say
   `verdict-B.md`: it gives the records, the contract and nothing about Vespertine. Then open
   `runs/2026-10-09/tool-calls/verdict-B.tsv`: every call is a read or write inside its own workspace or a
   `swiftbox` command. `runs/2026-10-09/AUDIT.md` lists the exceptions.

5. **A mutant dies for the right reason** (5 minutes). Pick a mutant in `harness/Sources/Mutants/` and read its
   summary and targets. Run `VERIFICATION_RESULTS=$PWD/results.json swift test --package-path verification/harness`,
   then `python3 verification/tools/scoreboard.py results.json` and look the mutant up in `results.json`: `killedBy`
   lists the checks it failed on a requirement it targets (only those count as a kill), and `failedElsewhere` the
   checks it failed on other requirements. Read one of those checks and convince yourself it would catch that bug.

## When something changes

- **A Vespertine doc line changes**: `check_registry.py` names the record. Re-read the line, update the record's
  requirement if the meaning changed, recompute the hash (the checker prints it), and re-run the checks.
- **Vespertine's code changes and a check fails**: either a regression (fix the code) or a deliberate change of
  behaviour (change the doc first, then the record, then the check, and say so in the PR).
- **A finding is fixed**: the known issue turns into a failure. Delete its entry in `KnownFindings.swift` (or its
  `withKnownIssue`) and move the finding to the "Fixed" section of `FINDINGS.md`.
- **A record's meaning changes after results were seen** (a doc fix, a missing record): give the group's agents the
  changed records in one more blind round, as `runs/2026-10-09/round2/` did for F-05 and H-01, then collect, audit
  and score again. Never edit a check by hand to match Vespertine.
- **A mutant survives in CI**: a check got weaker. Find the commit that changed the check; never delete the mutant.
- **A standard is bought**: see "Blocked" above. The record's `status: blocked-on-source` goes, its hash is filled
  in from the cache, and its checks go through the same clean-room round (`tools/cleanroom.py`).
