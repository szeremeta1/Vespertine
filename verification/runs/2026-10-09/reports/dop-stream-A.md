# dop-stream-A: final report

## Round 0

## Report: dop-stream, role A (tests)

**Delivered:** `/srv/cleanroom/dop-stream-A/harness/Sources/SpecChecks/DoPStreamChecks.swift`. It defines `public enum DoPStreamChecks { public static let all: [SpecCheck<any DoPStageMaker>] }` with 55 checks. Each check names one requirement, has a `// REQ:` line directly above it, and asserts only that ID, always through `checker.expect(cond, "DOPS-00x", msg)`. Checks per requirement: 001 ×11, 002 ×8, 003 ×8, 004 ×9, 005 ×10, 006 ×5, 007 ×4. `swift build` passes from a clean build in Swift 6 mode with no warnings. The file uses only Contracts and SpecKit. No file I was given has changed: I used Scratch for trial runs and then put it back to its original one line.

**How it works:**
- **Music:** every frame a check writes is unique and can never look like DSD silence. The two DSD bytes on channel 0 always differ and encode the frame's identity.
- **Model:** a model of each stage tracks accepted frames, frames played, mute state and the previous output frame across render calls. Each output frame is classified as the frame due, a skipped-ahead or repeated written frame, an altered copy of the frame due, or a frame carrying no music.
- **Scenarios:** many write and render sizes from 1 to 4096; 1–8 channels; capacities from 1 to 8192; fills until the stage refuses; underruns and mutes of every length from 0 to 7 frames (both parities); one-frame renders; writes that exactly keep up; redundant mute calls; seeded random sequences. A fresh stage is used for every scenario. All loops are bounded, there is no clock or system randomness, and nothing is force-unwrapped or indexed unchecked.
- **DOPS-007:** checked by comparing against a second stage set to gain 1.0 with the equalizer off, given the same calls. Silence frames may differ only in their silence byte value.

**Self-test (scratch only, not delivered):**
- Three structurally different correct implementations pass all 55 checks: about 7 s in total in a debug build, at most 0.65 s per check.
- 33 deliberately broken variants were all caught on the requirement they target. Examples: no bridge frame, extra bridges, a bridge at the very start, the wrong silence byte per run, per channel or for the bridge, dropped, repeated or altered frames, swapped channels, mute that consumes or flushes, unmute skipping a frame, short renders, and gain or equalizer changing the output.

**Ambiguous or contradictory points:**
1. **Contract "Music written…" (affects DOPS-001 and DOPS-005):** it's unclear whether the caller's markers alternate across write boundaries or only within one write. I only write one sequence that keeps alternating across all of a stage's writes, so no check ever restarts the markers at a write boundary.
2. **DOPS-005 gap, "the frame output just before it":** read with "it" meaning the silence frame. Then one silence frame is allowed before a music frame only if that music frame's marker equals the marker of the frame before the silence. Read the other way (the frame just before the music), the exception could never apply. Two consequences:
   - On a fresh stage nothing has been output yet, so no bridge is allowed: written music must start at output frame 0.
   - A bridge that ends a render call, followed by a mute before the next call, can't satisfy the rule. It is not judged.
3. **DOPS-001 and DOPS-002 with several channels:** the records don't say whether all channels of one frame must carry the same marker. That isn't asserted; alternation and validity are checked on each channel separately.
4. **DOPS-002 and render's word count:** "exactly frameCount × channels words" is contract text with no record behind it. I assert it under DOPS-002, on the reading that frames the device asked for but didn't get carry no marker.
5. **DOPS-003 "run":** I take it to mean the longest stretch of output frames without new music, spanning render calls, muted silence, dry silence and any bridge frame. Repeats of frames already played count as frames without music.
6. **DOPS-004 scope:** the record doesn't say whether it covers scenarios with a mute in the middle. One check asserts it there: music written before or during a mute must all come out once rendered unmuted. DOPS-004 sets no deadline, so the final drain allows the pending frames plus 4, then up to 3 more render calls. Timing is left to DOPS-005.
7. **DOPS-006 "next music frame out":** a repeat of an old frame counts as the resume point only when new music was waiting.
8. **DOPS-007:** the default gain and equalizer state are unspecified, so the comparison stage is set to 1.0 and off explicitly. Gains above 1 and negative gains are not tested, because a variant that wrongly scales samples could overflow and crash the whole run. Gains used: 0, 0.01, 0.1, 0.25, 0.3, 0.5.
9. **Partial writes:** the contract doesn't say which frames are accepted when fewer than offered are taken.

**Assumptions:**
- When `write` returns n, the first n offered frames were accepted. Return values are clamped to 0…offered. The capacity guarantee is not asserted, since no record states it.
- Bits 7…0 of silence words are not checked, since no record covers them.
- In DOPS-007 scenarios music is written before the first render. From then on DOPS-001…006 fix every output frame except the silence byte value, so two stages driven the same way must match.
- While music waits unmuted, a frame that isn't silence-like but shares DSD bits with the frame due is treated as that frame altered, and counts against DOPS-004 only.
- When the frame before a would-be bridge has an invalid marker, the bridge is not judged; that failure is left to DOPS-002.
- Scenarios write at most 32,768 frames each.

## Round 1

## Review round: DOPS-007 now fails both missed broken implementations

**Decision:** DOPS-007 as written rules them out, so I strengthened the checks.

- **Why the records rule them out:** DOPS-007 says "leaves DoP output unchanged: the same frames come out as with unity gain and no equalizer". DOPS-001 shows that "output" includes silence: "everything the stage outputs (music and silence alike)". The freedom DOPS-003 gives is about which silence byte a stage uses ("a test may not require a particular one"). It doesn't let gain or the equalizer change that byte.
- **Where my tolerance went wrong:** I had let silence frames differ in their silence byte everywhere. That was more than needed: the tolerance is only justified where the unity output itself isn't reproducible.

**What I changed:** only the comparison inside the DOPS-007 checks, in `harness/Sources/SpecChecks/DoPStreamChecks.swift`. Every check, ID and `// REQ:` line is unchanged (still 55 checks).

- Each DOPS-007 scenario now runs on three fresh stages: two set to gain 1.0 with the equalizer off, and one that also gets the gain and equalizer calls.
- Where the two unity stages agree on a frame, the tested stage must send exactly that frame, silence byte included.
- Only where the two unity stages differ on a silence frame is the silence byte left free, as before. That only happens for a stage whose silence byte varies from one instance to another, which DOPS-003 allows.
- The comment at the top of the file is updated to match.

**Results:**
- `swiftbox /srv/cleanroom/dop-stream-A "cd harness && swift build"`: Build complete, no warnings.
- Both missed implementations now fail DOPS-007, on scratch copies I wrote of them: silence runs that start with the equalizer on, or with a gain other than 1.0, use the complement byte.
- My earlier DOPS-007 broken variants still fail DOPS-007 (gain applied to samples, equalizer resetting marker state).
- Four correct scratch stages pass all 55 checks:
  - a fixed silence byte of 0x69;
  - a fixed silence byte of 0x96;
  - a different byte per run;
  - a different byte per instance.
- Scratch is back to its original one line.

**New ambiguity:** DOPS-007 compares against "the same frames … as with unity gain" without saying whether that output is fixed by the calls made. Where a stage's silence byte varies from one instance to another, as DOPS-003 permits, "the same frames" can't be pinned down. There I still allow any silence byte. A stage that does both (varies its byte per instance and also changes it with gain or the equalizer) would therefore pass.
