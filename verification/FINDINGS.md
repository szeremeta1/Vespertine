# Findings

What the spec-traced checks found in Vespertine at `98cad1a`. Each finding names the code, the public claim it bears
on, and a failing case anyone can run. Nothing here is fixed in this branch: it changes no code in `Packages/` or
`App/`. A failing case that runs in CI is marked as a known issue (`harness/Tests/AcceptanceTests/KnownFindings.swift`
or `withKnownIssue`), so CI stays green while the finding stands and turns red when it is fixed, as a reminder to
delete the entry and this section. An `H-` entry is an error in this harness that makes Vespertine look wrong
where it isn't.

| ID | What | Kind | Failing case |
|---|---|---|---|
| F-01 | PCM can read BIT-PERFECT when the device's physical format couldn't be read back | code: the badge trusts the plan | macOS acceptance, `BIT-PERFECT verdict` group |
| F-02 | The docs say DTS frames go out inside the IEC 61937 carrier; no DTS carrier exists | docs overclaim | macOS test `F-02: a DTS file has an IEC 61937 carrier` |
| F-03 | "Matched sacd_extract bit for bit on two real discs" can't be re-checked from the repository | missing evidence | none yet: `hardware/SACD-ORACLE.md` |
| F-04 | The rate planner can pick a rate a hertz or two above the source over a true multiple of it | code: contradicts the documented order (an edge case) | macOS acceptance, `Rate planning` group |
| F-05 | DoP always takes the device exclusively and won't play without it; the docs say shared mode can be bit-perfect | docs leave it out | macOS acceptance, `BIT-PERFECT verdict` group |
| H-01 | The shared-mode check expects 32-bit integer mode without exclusive access, which the docs rule out | error in this harness, not in Vespertine | same check as F-05 |

## F-01. PCM can read BIT-PERFECT when the physical format couldn't be read back

**Claim.** `docs/VERIFICATION.md` line 21: "Vespertine switches the device's nominal rate and reads it back from Core
Audio. It doesn't trust its own request." Lines 22-24: "The device's physical format holds the whole sample."
(`CLAIMS.md#bp-readback`, `#bp-word-length`; records BPV-003, BPV-004.)

**Code.** `OutputSession.swift` line 96 reads each output stream's physical format with `try?` and drops the ones
that fail. When none can be read, lines 129-130 fill `AppliedFormat` with the planned bit depth and assume an
integer format:

```swift
physicalBitDepth: Int(physical?.mBitsPerChannel ?? UInt32(plan.physicalBitDepth)),
physicalIsInteger: (physical?.mFormatFlags ?? kAudioFormatFlagIsSignedInteger) & kAudioFormatFlagIsSignedInteger != 0,
```

`SignalPath.isBitPerfect` (PCM case) then compares the source's word length with that planned depth, so a 24-bit
file on a device whose physical format is unknown reads BIT-PERFECT. The physical format is the one thing the badge
can't otherwise confirm: the rate is read twice (the nominal rate, line 94, and each stream's virtual format, lines
99 and 109-111) and the session doesn't open unless they agree, and DoP and bitstream refuse to open without a physical
format of at least 24 or 16 bits (line 118).

**Failing case.** On macOS, `swift test --package-path verification/harness --filter 'BIT-PERFECT'`: the check
"PCM: a rate or physical format that couldn't be read back is not trusted" fails on Vespertine. It runs
`SignalPathVerdict` (`harness/Sources/VespertineAdapters/MacAdapters.swift`), which feeds the real `SignalPath` the
way `OutputSession` fills in `AppliedFormat`. The clean-room implementations B and B2, written from the same
requirement without seeing Vespertine, pass it. It failed as expected in this branch's macOS CI job (a 24-bit plan
with the physical depth, the integer flag or both unread: `got "BIT-PERFECT"`).

**How likely.** Reading `kAudioStreamPropertyPhysicalFormat` fails rarely: a driver that doesn't implement it, or a
device removed while the session opens. Nothing in the repository shows it happening on a real device. A related,
smaller case: on a device with several output streams, a stream whose physical format can't be read is left out of
the minimum at line 101, so the badge is decided by the streams that could be read.

**Fix (not applied).** Treat an unread physical format as unknown rather than as the plan: for example, a
`physicalFormatKnown` flag in `AppliedFormat` that `isBitPerfect` requires, and the status line could say why.

## F-02. DTS in the IEC 61937 carrier

**Claim.** `docs/VERIFICATION.md` line 61 maps the test `BitstreamTests` "The carrier for a file holds its frames
exactly, at the right rate" to "Dolby/DTS frames go out byte for byte inside the IEC 61937 carrier".

**Code.** That test's arguments are three Dolby files (`BitstreamTests.swift` lines 73-76). `BitstreamDecoder.open`
reads only Dolby Digital and Dolby Digital Plus, elementary or in MP4 (`Bitstream.swift` line 349).
`IEC61937.dtsBurst` (`Bitstream.swift` line 74) is never called. DTS CDs go to a receiver as stored, which is
already a DTS stream in 16-bit PCM words, not an IEC 61937 burst; any other DTS file is decoded to PCM
(`SourceInspector.canBitstream`, `SourceOpener.swift` lines 311-315).

**Failing case.** On macOS, `harness/Tests/AcceptanceTests/IECCarriers.swift` asks Vespertine for the carrier of
`Fixtures/dts-tones.dts`; it throws (`unsupported`, in this branch's macOS CI job). Recorded as a known issue.

**Fix (not applied).** Change line 61 to "Dolby frames go out byte for byte inside the IEC 61937 carrier; DTS CDs go
out as stored". The README already calls receiver bitstream experimental (line 12) and lists DTS CDs separately.

## F-03. The sacd_extract comparison isn't recorded

**Claim.** `README.md` line 39 and `docs/FEATURES.md` line 7: SACD playback "matched sacd_extract bit for bit on
two real discs" (The Dark Side of the Moon, Brothers in Arms).

**Evidence.** The repository has no script, log or hash list from that comparison, so the claim rests on a run
nobody can repeat from the repository. This is not a contradiction: nothing here shows the claim is wrong. DST
decoding itself is checked in CI against libdstdec on 15 fixture frames (DST-003, `oracles/dst/`), and Vespertine's
decoder passes every DST check (REPORT.md).

**To close it.** Run `hardware/SACD-ORACLE.md` on the two discs and commit its record under
`verification/runs/sacd-<date>/`. It needs the disc images and the `sacd_extract` build on the home server.

## F-04. A rate just above the source can win over a true multiple

**Claim.** `docs/FEATURES.md` line 33: "The planner prefers the same rate family, then a higher rate, then an
integer divisor." (`CLAIMS.md#rate-planner-order`; record RATE-007.)

**Code.** `FormatPlanner.chooseRate` (`FormatPlanner.swift` lines 128-131) first takes the source rate if the
device offers it, to within 0.5 Hz (`DeviceCapabilities.supports`, `Formats.swift` line 94). Otherwise it takes
the first offered rate that `SampleRate.isIntegerMultiple` accepts (`Formats.swift` lines 170-174):

```swift
let r = a / b
return r >= 1 && abs(r.rounded() - r) < 0.0001
```

The tolerance is relative, so any rate up to 0.01% above the source counts as "one times" the source: up to
4.4 Hz at 44.1 kHz, 76.8 Hz at 768 kHz. Rates are sorted, so such a rate comes before every real multiple and wins.

**Failing case.** On macOS, `swift test --package-path verification/harness --filter 'Rate planning'`: the check
"A rate 1 Hz or more from the source rate is not the source rate" fails on Vespertine. With the match-source policy,
a 44.1 kHz source on a device offering 44,101 Hz and 88.2 kHz gets 44,101 Hz; RATE-007 wants 88.2 kHz. The same
happens 2 Hz above, and at 48 kHz: 150 of the check's 300 assertions fail. Rates 1 or 5 Hz below the source
don't trigger it (a ratio under 1 isn't a multiple). B and B2 pass the check.

**How likely.** It needs a device whose rate list holds a rate a few hertz above the source but not the source
itself. Standard rate lists don't, and nothing in the repository shows such a device. If one did, the track would
be resampled by a tiny ratio and not marked BIT-PERFECT (`OutputPlan.resamples`, `Formats.swift` line 128), where
88.2 kHz would have been the documented choice.

**Fix (not applied).** Compare multiples with the same 0.5 Hz equality as `supports`, for example
`abs(a - r.rounded() * b) < 0.5` in `isIntegerMultiple`. That also covers the divisor search on line 131, which
uses the same function.

## F-05. DoP always takes the device exclusively

**Claim.** The bit-perfect conditions in `docs/ARCHITECTURE.md` lines 83-91 include DoP's: "The device is held
exclusively, or (shared mode) no other process is currently sending audio to it", then "For DoP: the carrier runs
at the planned rate with at least 24 bits." `docs/VERIFICATION.md` lines 31-33 say the same of
"Nothing else is mixed in". (`CLAIMS.md#bp-no-mixing`, `#bp-dop-conditions`; records BPV-008, BPV-016.) The docs
say bitstream is exclusive (`docs/ARCHITECTURE.md` line 64) but say no such thing about DoP.

**Code.** `PlaybackEngine.swift` lines 762-763 always ask for the device exclusively when the plan is DoP or
bitstream, whatever the exclusive setting ("DSD over DoP only survives untouched with sole access, so it always
takes the device"). If the device isn't held after that, `OutputSession.swift` lines 118-123 refuse to open
("DoP requires exclusive, bit-transparent output"), and the engine reports the track as failed and moves to the next
one (`PlaybackEngine.swift` lines 671-676). So the shared-mode route to NATIVE DSD · DoP that the docs describe never
happens: DoP is exclusive or doesn't play.

**Failing case.** On macOS, the check "shared mode with no other app playing: PCM is BIT-PERFECT, DoP is NATIVE
DSD · DoP" gets "OUTPUT NOT OPENED" (the verdict adapter's answer when `OutputSession` would refuse) for every one
of its 58 DoP paths. B and B2 pass the check. The same check also fails for H-01 below; both are recorded under it
as one known issue.

**Why it matters.** The behaviour is the safer one: any other sound mixed into a DoP stream breaks its markers, and
the DAC would play noise. But the docs promise more than the app does in two ways a user can notice: with shared
mode chosen (the default), playing DSD over DoP still takes the device away from other apps, and if another app
already holds it, a DSD track fails instead of playing.

**Fix (not applied).** Say it in the docs: in `docs/FEATURES.md` near line 35, and next to line 91 of
`docs/ARCHITECTURE.md`, that DoP, like bitstream, always takes the device exclusively and doesn't play when it
can't. Then BPV-016 and the shared-mode check change with them (see H-01).

## H-01. The shared-mode check expects integer mode without exclusive access

**What happened.** The same shared-mode check also fails on 34 of its 178 PCM paths, all of them 32-bit sources
planned with integer mode, with no process holding the device. Vespertine says CONVERTED; the check wants
BIT-PERFECT. The 16- and 24-bit paths, and AirPods Max over USB-C, pass.

**Vespertine is right.** Integer mode needs exclusive access (`docs/FEATURES.md` line 37, `docs/ARCHITECTURE.md`
lines 68 and 136), and a 32-bit source is bit-perfect only with integer mode (`docs/ARCHITECTURE.md` line 90).
`OutputSession.swift` line 98 turns integer mode on only while the device is held, so in shared mode a 32-bit
source goes through Float32, and CONVERTED is what really happens.

**Where the error is.** The verdict contract describes `integerMode` as "the player is sending 32-bit integers
straight to the device" (`contracts/bit-perfect-verdict.md` line 36), independent of the hog owner, and BPV-015
doesn't say integer mode needs the device held. No record covers `CLAIMS.md#int-conditions` (it is in
`MAINTAINER-CHECKLIST.md`'s list of claims with no record). So verdict-A, writing blind, reasonably built shared-mode
paths with integer mode in effect, a state Vespertine can't reach. The adapter (`MacAdapters.swift` line 229)
models line 98 faithfully, so it turns those inputs into the float path.

**Fix (not applied here).** Add a record for `#int-conditions` (integer mode is in effect only with the device held),
say so in the contract's `integerMode` row, and give verdict-A that record and F-05's resolution in one more blind
round, then score again. Changing the check by hand now, after seeing Vespertine's result, would break the rule that
checks are written blind. Until then the known issue covers the whole check, so a regression in its other cases
(16- and 24-bit PCM in shared mode, which Vespertine passes today) wouldn't show.

## Observations (not failures)

- **DoP doesn't require an integer physical format.** `SignalPath.isBitPerfect` (DoP case) checks the depth and the
  rate, not `physicalIsInteger`; `OutputSession` line 118 likewise. A device with a 32-bit float physical format
  would pass and would almost certainly not carry DoP intact. The docs don't say either way (BPV-016's gap), so this
  is not counted as a failure.
- **One of Vespertine's own tests depends on scan order.** "Reads Apple Music's library, and brings in its
  playlists, loved songs and play counts once" (`PlaylistInterchangeTests.swift` line 129) reads the two play counts
  `ORDER BY id` and expects song a's first. `LibraryScanner.scan` reads files in a task group and stores tracks in
  the order the reads finish (`LibraryScanner.swift` lines 176-210), so a can get the higher id. It failed that way
  in this branch's CI, in the release run of the engine job (`counts → [3, 7]`), with nothing in `Packages/`
  changed, and passed on the next run. [3, 7] is what correct counts give when b has the lower id, but the test can't tell that apart from
  swapped counts. Reading each id's count on its own would make it deterministic and catch a swap. Not changed
  here.
