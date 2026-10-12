# verdict-A: final report

## Round 0

I've written `/srv/cleanroom/verdict-A/harness/Sources/SpecChecks/VerdictChecks.swift`, which defines `public enum VerdictChecks { public static let all: [SpecCheck<any BadgeVerdict>] }` with 30 checks. Every testable record, BPV-001 to BPV-017, has at least one check. A clean rebuild compiles in Swift 6 mode with no warnings and no new dependencies.

To try the checks, I wrote a scratch implementation of my reading of the records and 64 variants of it:
- The implementation passes all 30 checks, and the whole set runs in about 0.2 s in a debug build.
- All 52 deliberately broken variants are caught except one, "headphones are never BIT-PERFECT", which I left untested on purpose (see BPV-015 below).
- All 11 variants that take choices the records leave open pass every check, so I'm not testing anything a gap leaves open. Examples: the equalizer label winning over other reasons, DoP requiring an integer format, bitstream accepting shared mode, never emitting a bitstream badge.

I've put the scratch file back exactly as I was given it; no other given file was changed.

**How the checks are built**
- Each scenario starts from a path the records fix (a clean PCM path, a clean DoP path, or a bitstream path meeting every BPV-017 condition) and changes one thing.
- The base paths are hand-picked plus deterministic seeded pseudo-random ones (no clock, no system randomness).
- Assertions are written literally as `checker.expect(cond, "BPV-xxx", msg)`, with a `// REQ:` line above each check. I confirmed at runtime that each check's `requirements` list matches the IDs it asserts.
- Exact badges are compared Unicode scalar by Unicode scalar, because Swift's `==` would also accept U+0387 in place of U+00B7.

**Ambiguities and contradictions, by ID**
- **BPV-015:** "A device that can be bit-perfect" is never defined. `builtInHeadphones` and `other` (HDMI) are neither excluded nor confirmed, so they get no positive tests. Positive tests use `usbDAC`, and `airPodsMaxUSBC` via BPV-012.
- **BPV-015 and BPV-008:** Whether BIT-PERFECT needs the device held exclusively when no other app plays isn't stated. BPV-015's list implies it doesn't, so I assert shared mode with no other app gives BIT-PERFECT (and NATIVE DSD · DoP under BPV-016's "exactly when"). These assertions are in their own check.
- **BPV-003:**
  - It covers only the rate and the physical format. A failed hog-owner read (nil) with no other app playing is not tested.
  - I read "physical format" as including `physicalIsInteger`, so a nil integer flag alone rules out the BIT-PERFECT, DoP and bitstream badges.
- **BPV-002:** I read "the requested rate doesn't count", together with BPV-015, as: a request that differs from a matching read-back rate still gives BIT-PERFECT. This is in its own check.
- **BPV-002 (gap):** Rates that should differ are at least 100 Hz apart; rates that should match are exactly equal. The 0.5 Hz tolerance itself is not tested.
- **BPV-004 (gap):** Sources with no bit depth are not tested.
- **BPV-006:**
  - "Exactly 0 dB" is asserted strictly: gains as small as ±0.0001 dB rule the badges out.
  - I treat −0.0 dB as exactly 0. This is in its own check.
- **BPV-009:** A nil hog owner, a hog owner of −1, or another process's ID all count as not exclusive. The odd case of the player's own ID being −1 is not tested.
- **BPV-011 (gap):** On built-in speakers, virtual and aggregate devices, the DoP and bitstream modes are only asserted not to give BIT-PERFECT.
- **BPV-012:** Only stereo 16- and 24-bit files at 48 kHz, with a 24-bit integer 48 kHz read-back, are tested.
- **BPV-013:** It's not said whether another reason wins when one also applies, so only the concealed-frame count is changed. On bitstream paths I only assert that no clean badge appears, not the exact "DAMAGED FRAMES SILENCED", because the records don't fix the bitstream starting badge.
- **BPV-014:** Covers PCM only. The equalizer in DoP or bitstream mode, and the equalizer combined with another failure, are not tested.
- **BPV-016:**
  - Read literally, "exactly when" ignores the equalizer, `integerMode`, the source encoding and device classes other than those in BPV-010/011. Positive tests therefore use only clean `usbDAC` paths.
  - A float physical format of 24 bits or more is untested (its gap). Under 24 bits it's tested in both integer and float.
  - I took "planned carrier rate" to mean `plan.requestedRate`.
- **BPV-017:** "Only when" states necessary conditions only, so there is no positive bitstream assertion, and the codec name and the exclusive-or-shared question (its gaps) are untested. I took "shared conditions" to be BPV-003 and BPV-006 to BPV-010, plus BPV-013.

**Assumptions**
- `usbDAC` is a device that can be bit-perfect.
- Wherever this list says "rules out the badges", meaning the records that name all three (BPV-003, BPV-006 to BPV-010, BPV-013), the checks assert the badge is none of BIT-PERFECT, "NATIVE DSD · DoP" or anything starting "BITSTREAM · ". The PCM-only records (BPV-001, 002, 004, 005) and BPV-011 assert only "not BIT-PERFECT".
- Lossy and DSD sources are recognised by `encoding`, not by the codec string.
- To test each flag on its own, some inputs are contradictory: resampling on with all rates equal, the DSD-to-PCM flag on a PCM source, lossy encoding with codec "FLAC".
- In clean scenarios, the requested bit depth equals the read-back depth, and the DoP carrier is the DSD rate ÷ 16. `integerMode` is only on with a 32-bit integer device.
- Positive assertions are labelled with the record that grants the allowance (BPV-006, BPV-009, BPV-012). General sufficiency is labelled BPV-015, or BPV-016 for DoP.
- When matching the clean badges in failure cases, strings that are canonically equivalent to them also count as the clean badge.

## Round 1

C-BPV-012-c now fails a check. The records rule it out, so I strengthened the checks in `/srv/cleanroom/verdict-A/harness/Sources/SpecChecks/VerdictChecks.swift`. The package still builds with no errors or warnings.

**Why the records rule it out:**
- BPV-012 says "a 48 kHz file that meets every other condition gets BIT-PERFECT" on AirPods Max over USB-C.
- The only condition about exclusive access is BPV-008, and it applies only "when another app is playing to the device, unless the player holds the device exclusively".
- BPV-015 makes the same point in general: meeting every condition of BPV-001 to BPV-011 gives exactly "BIT-PERFECT".
- So on AirPods Max over USB-C, with no hog owner (−1) and no other app playing, every condition is met, and the badge must be BIT-PERFECT.

My earlier shared-mode check used only `usbDAC` paths, and all my AirPods Max USB-C paths had the device held by the player. That is how this mutant got through.

**What changed:** the check "shared mode with no other app playing: PCM is BIT-PERFECT, DoP is NATIVE DSD · DoP" now also covers all 24 AirPods Max USB-C paths.
- Each path is set to hog owner −1 with no other app playing.
- It uses the same read-back as before: 24-bit integer at 48 kHz, as BPV-012's gap says.
- Each scenario asserts exactly "BIT-PERFECT", labelled BPV-012.
- The check's `requirements` list and its `// REQ:` line are now BPV-012, BPV-015, BPV-016.

**How I verified it:** I ran the 30 checks against a scratch implementation that follows the records, and against a copy of it changed to behave like C-BPV-012-c.
- The scratch implementation passes all 30.
- The mutant copy fails only this check, and only on BPV-012.
- Each check still asserts exactly the IDs it lists.

I put the scratch file back to how it was given. No other given file was changed.

**New ambiguity:** none. A hog owner that couldn't be read (nil) with no other app playing is still untested, on every device, for the reason in my first report: BPV-003 covers only the rate and the physical format.
