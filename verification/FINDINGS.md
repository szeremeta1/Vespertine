# Findings

What the spec-traced checks found in Vespertine at `98cad1a`. Each finding names the code, the public claim it bears
on, and a failing case anyone can run. Nothing here is fixed in this branch: it changes no code in `Packages/` or
`App/`. A failing case that runs in CI is marked as a known issue (`harness/Tests/AcceptanceTests/KnownFindings.swift`
or `withKnownIssue`), so CI stays green while the finding stands and turns red when it is fixed, as a reminder to
delete the entry and this section.

| ID | What | Kind | Failing case |
|---|---|---|---|
| F-01 | PCM can read BIT-PERFECT when the device's physical format couldn't be read back | code: the badge trusts the plan | macOS acceptance, `BIT-PERFECT verdict` group |
| F-02 | The docs say DTS frames go out inside the IEC 61937 carrier; no DTS carrier exists | docs overclaim | macOS test `F-02: a DTS file has an IEC 61937 carrier` |
| F-03 | "Matched sacd_extract bit for bit on two real discs" can't be re-checked from the repository | missing evidence | none yet: `hardware/SACD-ORACLE.md` |

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
requirement without seeing Vespertine, pass it.

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
`Fixtures/dts-tones.dts`; it throws. Recorded as a known issue.

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
  changed. [3, 7] is what correct counts give when b has the lower id, but the test can't tell that apart from
  swapped counts. Reading each id's count on its own would make it deterministic and catch a swap. Not changed
  here.
