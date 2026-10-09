# Report: spec-traced verification of Vespertine at `98cad1a`

Run on 2026-10-09. The checks, implementations and mutants were written blind by separate agents; this report
gives their scores, Vespertine's results, how the isolation held up and what the run doesn't show. After the
findings were fixed, the verdict group had a second blind round, and everything was scored again; both sets of
results are here. Findings are in `FINDINGS.md`, the claim-by-claim coverage and the spot checks in
`MAINTAINER-CHECKLIST.md`.

## The answer

At `98cad1a`, Vespertine passed 176 of the 179 accepted checks on macOS and all 108 that can run on Linux. The
three failing checks and two findings from outside the scored checks are in `FINDINGS.md`:

- **F-01**, expected before the run: the badge trusted the plan when the device's physical format couldn't be read
  back.
- **F-04**: the rate planner could pick a rate a hertz or two above the source over a true multiple of it, against
  the order `docs/FEATURES.md` line 33 promises. It needs a device that offers a rate a few hertz above the source
  but not the source itself.
- **F-05**: DoP always takes the device exclusively and won't play without it, the safer behaviour, but the docs
  said shared mode could give it the badge.
- **H-01**: an error in this harness, which expected 32-bit integer mode without exclusive access. F-05 and H-01
  failed the same shared-mode check.
- **F-02**, outside the scored checks: the docs said DTS frames go out inside the IEC 61937 carrier, and no DTS
  carrier exists.
- **F-03**, outside the scored checks: the sacd_extract comparison on two discs can't be re-checked from the
  repository.

F-01 and F-04 are fixed in Vespertine's code, F-02 and F-05 in its docs, and H-01 with a new record (BPV-018) and a
second blind round for the verdict group. With the fixes, Vespertine passes all 181 checks on macOS and all
108 on Linux. F-03 stays open: it needs the discs.

The checks held up: every check passes every clean-room implementation, and 243 of 244 mutants fail a check of a
requirement they target. The one survivor is equivalent: it behaves exactly like the reference it wraps.

## What was checked

65 requirement records in `requirements/`, each tied to a public claim in `CLAIMS.md`:

| Kind | Records | Source |
|---|---|---|
| `spec` | 14 | DoP 1.1, DSDIFF 1.5, Apple's `AudioHardware.h`: public, hashed clause by clause (`SOURCES.md`) |
| `spec`, blocked | 9 | IEC 61937-1, -2, -3, -5 (IEC-001 to 007), ISO/IEC 14496-3 (DST-005), the Scarlet Book (DST-006): not bought |
| `oracle` | 3 | libdstdec for DST (DST-003); FFmpeg's S/PDIF demuxer and a blind carrier scanner for IEC 61937 (IEC-O-001, IEC-O-002) |
| `vespertine-rule` | 39 | Vespertine's own docs at `98cad1a` (BPV-016 and BPV-017 with the F-05 docs change), where no public standard applies (the BIT-PERFECT conditions, integer mode, the rate planner) |

Paywalled text never entered the repository: the IEC records carry only the document, edition and clause, and
Alex chose oracle evidence over buying them (2026-10-09). FFmpeg, libdstdec and the carrier scanner are used only
as oracles, never as the source of a `spec` record. No record cites Apple sample code.

## Method

1. **Records and contracts.** Every record quotes its source (or, for a paywalled one, cites it) and hashes the
   quoted clause; `tools/check_registry.py` recomputes the hashes and fails CI when a cited line moves. The
   contracts in `contracts/` turn each group of records into a Swift interface, written from the records alone.
2. **Blind agents.** For each group, separate agents worked from the records and the contract only:
   **A** wrote the checks, **B** an implementation, **B2** a second implementation on a different model (rate and
   verdict, the groups with the most room for reading), and **C** mutants: deliberately broken implementations,
   each aimed at named requirements. DST has no B (DST-005, the decoding standard, isn't bought), so its checks are
   judged against the fixtures' known answers, which libdstdec confirms. A separate agent wrote the IEC 61937
   carrier scanner from the public ATSC and ETSI frame syntax. 20 agents in all; their briefs are in
   `runs/2026-10-09/briefs/`, their deliverables, unchanged, in `runs/2026-10-09/outputs/` with hashes in
   `MANIFEST.md`.
3. **Acceptance** (`harness/Tests/AcceptanceTests/Acceptance.swift`). A group's checks are accepted when every
   clean-room implementation passes every check, and every mutant fails a check of a requirement it targets. A
   mutant that only fails checks of other requirements counts as a survivor: it shows a requirement its own checks
   don't really test.
4. **Review rounds.** Where a mutant survived, the A agent that wrote the checks got one message naming the
   mutant and what it does, and was asked to strengthen the checks or explain which words of the records leave the
   case open (`runs/2026-10-09/round1/`). When records changed after the findings were fixed, the group's four
   agents got the changed records, and nothing about any result, in a second round (`runs/2026-10-09/round2/`).
5. **Vespertine.** Adapters in `harness/Sources/VespertineAdapters/` put Vespertine's real code behind the same
   contracts, and the accepted checks run against it. Its result is reported as it comes out: a check Vespertine
   fails stays failing, recorded as a known issue tied to `FINDINGS.md`, until Vespertine or its docs change.

## Isolation

Each agent had its own workspace (`/srv/cleanroom/<group>-<role>/`), a SwiftPM package holding only the contract's
Swift API, and a brief with the records, the contract and the rules: read and write only inside the workspace, and
run commands only as `swiftbox <workspace> "<command>"`. `swiftbox` is a chroot into a plain Ubuntu 24.04 image
with Swift 6.2.4, the workspace mounted at `/work` and a private `/tmp`. Records were redacted for the briefs: the
product's name and its doc file names and lines became "the product" and "the product documentation"
(`tools/cleanroom.py`). No agent opened Vespertine's source, another agent's work or this repository.

`runs/2026-10-09/AUDIT.md` checks every tool call every agent made (`tools/audit_runs.py`; the full call logs are
in `runs/2026-10-09/tool-calls/`):

| | Agents |
|---|---|
| No problem | 15 |
| A command run outside `swiftbox` | 4 (dop-pack-A, pcm-stream-A twice, dst-A, carrier-scan) |
| A tool other than Read, Write, Edit or Bash | 1 (dop-stream-A: one Grep, inside its own workspace) |
| A sandboxed command naming `/proc`, `/sys`, a device, a mount or namespace tool, or a host directory | 0 |
| A path read or written outside the workspace | 0 |
| The product named in an agent's words or files | 0 |

The five commands outside `swiftbox`, and what came back, are listed in full in `AUDIT.md`. Three were refused
by the session's permission checks (two `python3` calls on the host, one `mkdir` in the agent's own workspace). The
other two ran and did nothing: a host `python3` given an empty program, and `mkdir -p /dev/null` (which already
exists) in front of an otherwise sandboxed command. None read anything outside the agent's workspace. The audit
covers the four verdict agents' second round too: every call they made in it was clean.

What the isolation doesn't cover:

- **It was enforced by instruction and audited afterwards, not by the operating system.** The agents ran in the
  same container as the session that built this harness, as root. Their Read, Write and Edit tools weren't confined
  to the workspace; the audit shows they stayed in it. `swiftbox` mounts `/proc` and `/dev` and shares the
  container's network, so a process inside it could have reached the host's files through `/proc`; the audit
  searches every sandboxed command for that and found nothing.
- **Each agent's session context named the working directory of the session that started it**
  (`/home/claude/Vespertine`), and so the product's name, and the requester's email address. No agent's words,
  files or tool calls mention the product (the audit checks for it).
- **The records and contracts were written by someone who had read Vespertine's code and docs.** The agents were
  blind; the author of what they read was not. The records' `gap` fields show each place where the author had to
  decide what a doc line means, and the mutant results show the checks test what the records say, not what
  Vespertine does.

## Models

The A, B and C agents and the carrier scanner ran on Claude Opus 5.5 (18 agents). The two B2 implementations ran
on Claude Sonnet 5.5. The prompt asked for a different model or vendor for B2: no other vendor was reachable from
this environment (the proxy refused `api.openai.com` with HTTP 403, and no Codex CLI was installed), so B2 is a
different model from the same vendor. The model of every call is in `AUDIT.md`.

## Scores

The numbers come from `swift test` with `VERIFICATION_RESULTS` set and `tools/scoreboard.py`. The Linux results
are in `runs/2026-10-09/results-linux.json` (the final run, in a release build; before the second round a debug and
a release build gave identical results); the macOS ones are in the CI job's summary.

### First scoring, before the first review round

| Group | Checks | Clean-room implementations pass | Mutants killed |
|---|---|---|---|
| DoP packing | 16 | B 16/16 | 24/24 |
| DoP output stream | 55 | B 55/55 | 28/30 |
| Rate planning | 22 | B 22/22, B2 22/22 | 38/38 |
| BIT-PERFECT verdict | 30 | B 30/30, B2 30/30 | 78/79 |
| DST decoding | 32 | reference answers 32/32 | 26/27 |
| Float and integer output | – | not yet delivered | – |

Survivors: `C-DOPS-007-c`, `C-DOPS-007-e`, `C-BPV-012-c` and the equivalent `C-DST-001-g`.

### At `98cad1a`, after the first review round

| Group | Checks | Requirements | Clean-room implementations pass | Mutants killed | Vespertine, Linux | Vespertine, macOS |
|---|---|---|---|---|---|---|
| DoP packing | 16 | 7 | B 16/16 | 24/24 | not run (Swift, macOS only) | 16/16 |
| DoP output stream | 55 | 7 | B 55/55 | 30/30 | 55/55 | 55/55 |
| Float output | 14 | 5 | B 14/14 | 24/24 | 11/11 (FLT-004's 3 need macOS) | 14/14 |
| Integer output | 10 | 3 | B 10/10 | 16/16 | 10/10 | 10/10 |
| Rate planning | 22 | 10 | B 22/22, B2 22/22 | 38/38 | not run (macOS only) | 21/22 (F-04) |
| BIT-PERFECT verdict | 30 | 17 | B 30/30, B2 30/30 | 79/79 | not run (macOS only) | 28/30 (F-01; F-05 and H-01) |
| DST decoding | 32 | 4 | reference answers 32/32 | 26/27 (one equivalent) | 32/32 | 32/32 |
| **All** | **179** | **53** | **every check, every implementation** | **237/238** | **108/108 run** | **176/179: 3 known, 0 new** |

On Linux the harness builds Vespertine's real-time C engine (`vespertine_rt.c`, which does the DoP stream, float and
integer output) and its DST decoder from `Packages/` and runs the checks on them; Vespertine's Swift code needs
macOS. The 53 requirements are every testable record except the two IEC oracle records, which the
`verification-iec-oracle` job runs on the carriers Vespertine writes (`hardware/IEC61937-ORACLE.md`).

On macOS the adapters also run Vespertine's Swift code: the DoP packer, the rate planner, `SignalPath` behind
the verdict, and 24-bit decoding for FLT-004. The macOS numbers are from the `verification-macos` CI job
(`macos-26`); its summary prints the same tables. The three failing checks are known issues tied to their
findings, so the job passes while they stand and fails when one of them stops failing. In the IEC step, the F-02
test asks for a DTS carrier and gets `unsupported`, as recorded.

### After the fixes and the second review round

The verdict group has two more checks and six more mutants (see "The second review round"); nothing else in the
harness changed.

| Group | Checks | Requirements | Clean-room implementations pass | Mutants killed | Vespertine, Linux | Vespertine, macOS |
|---|---|---|---|---|---|---|
| DoP packing | 16 | 7 | B 16/16 | 24/24 | not run (Swift, macOS only) | 16/16 |
| DoP output stream | 55 | 7 | B 55/55 | 30/30 | 55/55 | 55/55 |
| Float output | 14 | 5 | B 14/14 | 24/24 | 11/11 (FLT-004's 3 need macOS) | 14/14 |
| Integer output | 10 | 3 | B 10/10 | 16/16 | 10/10 | 10/10 |
| Rate planning | 22 | 10 | B 22/22, B2 22/22 | 38/38 | not run (macOS only) | 22/22 |
| BIT-PERFECT verdict | 32 | 17 | B 32/32, B2 32/32 | 85/85 | not run (macOS only) | 32/32 |
| DST decoding | 32 | 4 | reference answers 32/32 | 26/27 (one equivalent) | 32/32 | 32/32 |
| **All** | **181** | **53** | **every check, every implementation** | **243/244** | **108/108 run** | **181/181** |

The 53 requirements are the same: BPV-018, the new record, is `testable: false`.

### By requirement

Acceptance per requirement: every check of it passes every clean-room implementation, and every mutant aimed at it
fails one of its checks. All 53 meet both, except DST-001's equivalent mutant. The table is the final state. At
`98cad1a`, four requirements failed on macOS: RATE-007 (F-04), BPV-003 (F-01), and BPV-015 and BPV-016 through the
same shared-mode check, BPV-015 on its 32-bit PCM paths (H-01) and BPV-016 on its DoP paths (F-05).

| Requirement | Kind | Checks | Implementations | Mutants killed | Vespertine (Linux) | Vespertine (macOS) |
|---|---|---|---|---|---|---|
| DOP-001 | spec | 2 | B pass | 4/4 | not run (macOS only) | pass |
| DOP-002 | spec | 3 | B pass | 4/4 | not run (macOS only) | pass |
| DOP-003 | spec | 1 | B pass | 3/3 | not run (macOS only) | pass |
| DOP-004 | spec | 1 | B pass | 11/11 | not run (macOS only) | pass |
| DOP-005 | spec | 2 | B pass | 3/3 | not run (macOS only) | pass |
| DOP-006 | spec | 1 | B pass | 3/3 | not run (macOS only) | pass |
| DOP-007 | vespertine-rule | 6 | B pass | 14/14 | not run (macOS only) | pass |
| DOPS-001 | spec | 11 | B pass | 8/8 | pass | pass |
| DOPS-002 | spec | 8 | B pass | 4/4 | pass | pass |
| DOPS-003 | spec | 8 | B pass | 5/5 | pass | pass |
| DOPS-004 | vespertine-rule | 9 | B pass | 8/8 | pass | pass |
| DOPS-005 | vespertine-rule | 10 | B pass | 5/5 | pass | pass |
| DOPS-006 | vespertine-rule | 5 | B pass | 4/4 | pass | pass |
| DOPS-007 | vespertine-rule | 4 | B pass | 5/5 | pass | pass |
| FLT-001 | vespertine-rule | 3 | B pass | 5/5 | pass | pass |
| FLT-002 | vespertine-rule | 2 | B pass | 9/9 | pass | pass |
| FLT-003 | vespertine-rule | 3 | B pass | 6/6 | pass | pass |
| FLT-004 | vespertine-rule | 3 | B pass | 5/5 | not run (macOS only) | pass |
| FLT-005 | vespertine-rule | 3 | B pass | 6/6 | pass | pass |
| INT-001 | vespertine-rule | 4 | B pass | 6/6 | pass | pass |
| INT-002 | vespertine-rule | 3 | B pass | 7/7 | pass | pass |
| INT-003 | vespertine-rule | 3 | B pass | 5/5 | pass | pass |
| RATE-001 | spec | 1 | B pass, B2 pass | 3/3 | not run (macOS only) | pass |
| RATE-002 | spec | 1 | B pass, B2 pass | 3/3 | not run (macOS only) | pass |
| RATE-003 | vespertine-rule | 2 | B pass, B2 pass | 10/10 | not run (macOS only) | pass |
| RATE-004 | vespertine-rule | 4 | B pass, B2 pass | 5/5 | not run (macOS only) | pass |
| RATE-005 | vespertine-rule | 3 | B pass, B2 pass | 8/8 | not run (macOS only) | pass |
| RATE-006 | vespertine-rule | 2 | B pass, B2 pass | 4/4 | not run (macOS only) | pass |
| RATE-007 | vespertine-rule | 3 | B pass, B2 pass | 3/3 | not run (macOS only) | pass |
| RATE-008 | vespertine-rule | 1 | B pass, B2 pass | 3/3 | not run (macOS only) | pass |
| RATE-009 | vespertine-rule | 2 | B pass, B2 pass | 3/3 | not run (macOS only) | pass |
| RATE-010 | vespertine-rule | 3 | B pass, B2 pass | 5/5 | not run (macOS only) | pass |
| BPV-001 | vespertine-rule | 2 | B pass, B2 pass | 5/5 | not run (macOS only) | pass |
| BPV-002 | vespertine-rule | 1 | B pass, B2 pass | 6/6 | not run (macOS only) | pass |
| BPV-003 | vespertine-rule | 3 | B pass, B2 pass | 5/5 | not run (macOS only) | pass |
| BPV-004 | vespertine-rule | 2 | B pass, B2 pass | 5/5 | not run (macOS only) | pass |
| BPV-005 | vespertine-rule | 1 | B pass, B2 pass | 3/3 | not run (macOS only) | pass |
| BPV-006 | vespertine-rule | 3 | B pass, B2 pass | 7/7 | not run (macOS only) | pass |
| BPV-007 | vespertine-rule | 3 | B pass, B2 pass | 6/6 | not run (macOS only) | pass |
| BPV-008 | vespertine-rule | 1 | B pass, B2 pass | 7/7 | not run (macOS only) | pass |
| BPV-009 | spec | 1 | B pass, B2 pass | 8/8 | not run (macOS only) | pass |
| BPV-010 | vespertine-rule | 1 | B pass, B2 pass | 5/5 | not run (macOS only) | pass |
| BPV-011 | vespertine-rule | 1 | B pass, B2 pass | 3/3 | not run (macOS only) | pass |
| BPV-012 | vespertine-rule | 2 | B pass, B2 pass | 3/3 | not run (macOS only) | pass |
| BPV-013 | vespertine-rule | 1 | B pass, B2 pass | 6/6 | not run (macOS only) | pass |
| BPV-014 | vespertine-rule | 1 | B pass, B2 pass | 4/4 | not run (macOS only) | pass |
| BPV-015 | vespertine-rule | 4 | B pass, B2 pass | 11/11 | not run (macOS only) | pass |
| BPV-016 | vespertine-rule | 4 | B pass, B2 pass | 15/15 | not run (macOS only) | pass |
| BPV-017 | vespertine-rule | 3 | B pass, B2 pass | 13/13 | not run (macOS only) | pass |
| DST-001 | spec | 32 | reference decoder pass | 6/7 | pass | pass |
| DST-002 | spec | 26 | reference decoder pass | 8/8 | pass | pass |
| DST-003 | oracle | 26 | reference decoder pass | 25/25 | pass | pass |
| DST-004 | vespertine-rule | 26 | reference decoder pass | 25/25 | pass | pass |

## The first review round

Three mutants survived the first scoring, in two groups, and DST had the equivalent mutant below. Each A agent
got one message, resumed in its own workspace with the same rules; the messages are in `runs/2026-10-09/round1/`
with the diff of what each changed.

- **dop-stream-A**, for `C-DOPS-007-c` and `C-DOPS-007-e`: with the equalizer on or a gain other than 1, they
  start silence runs with the complement silence byte, which DOPS-003 allows. The checks compared the tested stage
  with one stage at unity gain and let the silence byte differ freely, so the mutants passed. The agent now runs
  two unity stages and leaves the silence byte free only where those two disagree (a stage whose silence byte
  varies from instance to instance); everywhere else the tested stage must match exactly. Both mutants now fail
  DOPS-007's checks.
- **verdict-A**, for `C-BPV-012-c`: it gives BIT-PERFECT on AirPods Max over USB-C only while the player holds the
  device in hog mode. The agent decided BPV-012 with BPV-015 rules it out, and added AirPods Max over USB-C in
  shared mode, with no other app playing, to the shared-mode check (now tagged BPV-012 too).

pcm-stream-A was still writing the integer checks at the first scoring, so its 16 integer mutants had nothing to
fail yet. Its checks were scored once it delivered them, and killed every mutant; it got no review message.

After the round, every mutant except the equivalent one fails a check of a requirement it targets, and B and B2
still pass every check. Both agents said the records ruled their mutants out. dop-stream-A named one gap that
remains: where a stage's silence byte varies from instance to instance (which DOPS-003 allows), "the same frames as
at unity gain" can't be pinned down, so a stage that varies its byte per instance and also changes it with gain or
the equalizer would still pass. verdict-A named none new; its first report had already said a hog owner that
couldn't be read is untested, because BPV-003 covers only the rate and the physical format.

## The second review round

The fixes for F-05 and H-01 changed three records the verdict group was written from. With the docs now saying DoP
and bitstream always take the device exclusively, BPV-016 and BPV-017 require the player to hold the device (BPV-017
had left that open as a gap). BPV-018, new, says integer mode is in effect only while the player holds the device;
it is `testable: false`, and the contract's `integerMode` row now says inputs that break it don't occur. Each of the
four verdict agents was resumed in its own workspace, under the same rules, with one message carrying those records
and that row, redacted like the briefs, and nothing about how any implementation had scored. The messages and the
diff of what each agent changed are in `runs/2026-10-09/round2/`.

- **verdict-A** split the shared-mode check. Shared-mode PCM with no other app playing must still be BIT-PERFECT,
  now only for sources of at most 24 bits, with integer mode off. Two new checks say a DoP or bitstream path never
  gets its badge when the player doesn't hold the device: no owner, another process, or an owner that couldn't be
  read, with or without another app playing. BPV-005 gained shared-mode cases for deeper sources, which must not be
  BIT-PERFECT. Whenever a check releases the device, integer mode goes off with it, so no check builds an input that
  BPV-018 rules out (the agent counted all 47,137 inputs its checks build).
- **verdict-B and verdict-B2** require the device held for DoP and bitstream, and count integer mode as in effect
  only while it is. They name the reason differently (B: "DEVICE NOT HELD"; B2, a sentence), which the records leave
  open.
- **verdict-C** wrote six mutants that let DoP or bitstream through without the device held: in shared mode, with
  another process as the owner, or with an owner that couldn't be read. It changed four others that the new records
  had made correct, or that were wrong only on inputs that can no longer occur (C-BPV-005-a and -b, C-BPV-008-b and
  -c).

B and B2 pass every check, and all 85 verdict mutants fail a check of a requirement they target. The agents named
what the records still leave open: what an unheld DoP or bitstream path shows, beyond not its own badge (so no
record stops it reading BIT-PERFECT; `CLAIMS.md#bp-says-what` implies it can't, but BPV-015 covers PCM only); when a
BITSTREAM badge must appear (BPV-017 says only when it may); and a hog owner that couldn't be read counting as not
held, which they all took from BPV-009.

## The equivalent mutant

`C-DST-001-g` returns one channel-byte group too few, but only for frames that aren't among the fixtures. Mutants
wrap a reference implementation, and DST's only reference is the fixtures' known answers (there is no clean-room DST
decoder, because DST-005's standard isn't bought). That reference decodes nothing but the fixtures, so this mutant
never changes an output and no check can tell it from the reference. It is listed in `EquivalentMutants`
(`harness/Tests/AcceptanceTests/KnownFindings.swift`): its survival is expected, and the run fails if a check ever
kills it. It does mark a real limit: DST-001's frame-size rule is judged only on the 15 fixture frames.

## Disagreements between implementations

None: B and B2 passed every check in every round, so the stop-and-ask rule for A and B disagreeing never applied.
They do read some records differently where the records leave a choice open, and the checks deliberately don't
assert those cases:

- **RATE-010**, a fixed rate the device doesn't offer: B falls back to the match-source choice, B2 returns the
  requested rate as it is (the contract allows either).
- **RATE-004 and RATE-005**, a DoP device with only 16-bit formats: neither rate implementation checks bit depth
  before choosing DoP, and both reports name the gap. The checks use 24-bit devices, as RATE-005's gap says.
- **Rate equality**: both rate implementations count rates less than 0.5 Hz apart as equal, both verdict
  implementations rates up to and including 0.5 Hz apart. No check uses a difference of exactly 0.5 Hz.
- **BPV-016**: neither verdict implementation requires DoP's physical format to be integer (see the observation in
  `FINDINGS.md`).

## What changed after results were seen

Everything the agents wrote is in `outputs/` exactly as delivered. After scoring started, these changes were made
outside the agents, each before the result it could affect was known:

- **The verdict adapter** (`MacAdapters.swift`, `SignalPathVerdict`) was corrected before any macOS run: it had
  left out that `OutputSession` refuses to open unless each stream's virtual format carries the requested rate
  (lines 99, 109-111). Without that, F-01 also covered a failed rate readback, which Vespertine does catch. F-01 was
  narrowed to the physical format.
- **The review round** changed two check files (diffs in `round1/`).
- **`EquivalentMutants`** gained `C-DST-001-g`, with the reasoning above.
- **`KnownFindings`** gained F-01's check before the macOS run, and `IECCarriers.swift` F-02's, so CI stays green
  while a finding stands and fails when one stops reproducing.
- **Two more `KnownFindings` entries** came after the first full macOS run: the rate check for F-04, and the
  shared-mode check for F-05 and H-01. H-01 is an error in this harness, but the check stays as verdict-A wrote it:
  fixing it by hand after seeing Vespertine's result would break the blind rule. `FINDINGS.md` gives the fix, a new
  record and one more blind round. While it stands, the known issue covers the whole check, including its 16- and
  24-bit cases that Vespertine passes today.
- **The verdict adapter wasn't changed after any macOS result.** It turned on integer mode only while the device is
  held, and refused DoP without the device held, from the first commit that had it, because `OutputSession` does
  (lines 98 and 118-123). Those two lines are what the shared-mode check runs into.
- **The fixes** came after every result above: F-01 and F-04 in Vespertine's code, F-02 and F-05 in its docs. The
  records citing the changed doc lines were re-read and re-hashed (BPV-016, and the `CLAIMS.md` quotes), BPV-016 and
  BPV-017 now require the device held, and BPV-018 is new. The verdict group's checks, implementations and mutants
  changed only through the second blind round.
- **The verdict adapter** passes `AppliedFormat`'s new `physicalFormatKnown` the way `OutputSession` now sets it
  (false when the physical format wasn't read back), and its line references follow `OutputSession.swift`.
- **`KnownFindings`** is empty again, and the F-02 test went with the claim it checked.
- **The macOS job** moved from a debug build to a release build after the debug run hit its time limit.
- **The scoreboard** labels a failure that is already a finding as known, with its IDs, and any other as new.

## Vespertine's own CI on this branch

Every job that tested Vespertine before this branch (the analysis core on Linux; the engine, library and
real-time C on macOS; the app on macOS) passes on this branch. The first pull request changed nothing in
`Packages/` or `App/`. The fixes change three files there (`Formats.swift` for F-04, `OutputSession.swift` and
`SignalPath.swift` for F-01), each fix with a new test in Vespertine's own suite, and every job passes with them
(run 38005282468). Two things happened along the way:

- One run failed one of Vespertine's own tests, in the engine job's release run: "Reads Apple Music's library…"
  depends on the order a task group finishes in. It passed on the next run. `FINDINGS.md` has the details under
  Observations.
- The new macOS verification job first ran in a debug build and hit its 40-minute limit. It now builds once in
  release (`swift test -c release`, which keeps `@testable` imports) and runs each group as its own step with its own
  time limit: about 6 minutes in all. On Linux, debug and release gave identical results.

## What this run doesn't show

- **Anything on a real device.** The verdict, rate and float checks run Vespertine's code with Core Audio's answers
  supplied by the adapters, not read from hardware. What leaves the Mac is covered only by the manual procedures in
  `hardware/LOOPBACK.md`, which haven't been run.
- **The IEC 61937 burst layout.** IEC-001 to 007 are blocked on the paywalled parts; the carriers are checked only
  against FFmpeg's demuxer and the blind scanner (`hardware/IEC61937-ORACLE.md`), which confirms the frames inside
  come out exactly, not that every field of the burst preamble is what the standard says.
- **DST decoding from the standard.** DST-005 and DST-006 are blocked. DST is checked against libdstdec on 15
  fixture frames, and against the fixtures' known answers.
- **The SACD comparison on real discs** (F-03). `hardware/SACD-ORACLE.md` is ready; it needs the disc images and
  `sacd_extract` on the home server.
- **Claims with no record.** `MAINTAINER-CHECKLIST.md` lists them.
- **That the docs are right.** A `vespertine-rule` check enforces what the docs say. If a doc line is wrong, so is
  the check.

## Reproducing it

From the repository root:

```sh
python3 verification/tools/fetch_oracles.py && python3 verification/tools/check_registry.py
cd verification/harness
VERIFICATION_RESULTS=$PWD/results.json swift test; python3 ../tools/scoreboard.py results.json
```

On Linux this needs Swift 6.2 and Python 3 with PyYAML; on macOS, Xcode's toolchain, and it runs every check
against Vespertine. The clean-room run itself can be repeated with `tools/cleanroom.py setup`, a fresh agent per
brief, `tools/cleanroom.py collect` and `tools/audit_runs.py`; a new run goes in a new `runs/<date>/` and doesn't
replace this one.
