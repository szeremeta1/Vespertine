# pcm-stream-C: final report

## Report: pcm-stream, role C (mutants)

I wrote 40 mutants across the two files. Each requirement has at least 4. Against my own correct implementation, every mutant fails a check for at least one of its targets, and the correct implementation passes every check. The package builds with `swift build` in Swift 6 language mode with no warnings. A fuzz run of random writes, renders and mutes, in debug mode, hit no traps.

**Files**
- `/srv/cleanroom/pcm-stream-C/harness/Sources/Mutants/FloatMutants.swift`: `FloatMutants.all`, 24 mutants.
- `/srv/cleanroom/pcm-stream-C/harness/Sources/Mutants/IntegerMutants.swift`: `IntegerMutants.all`, 16 mutants.
- Each file stands alone, with private helpers only. Each mutant wraps the correct implementation it is given and tracks how many frames are queued and whether it is muted.
- I changed none of the given files. `Scratch/main.swift` is back to its original one line. My correct implementation, checks and fuzz test are in a new file, `Sources/Scratch/Harness.swift`. It is not called and is not delivered.

**Mutants**
- **FLT-001** (each also targets FLT-002):
  - a: symmetric clip, so −1.0 comes out as −(2^23−1)/2^23.
  - b: noise gate, so |x| < 2^−15 comes out as 0.
  - c: the last channel is scaled to k/(2^23−1).
  - d: odd k with |k| ≥ 2^22 move one step toward zero.
  - e: after 2^20 frames, every sample is multiplied by (1−2^−23).
- **FLT-002** (all leave every k/2^23 exact):
  - a: rounds to the 24-bit grid.
  - b: +1.0 is clipped to (2^23−1)/2^23.
  - c: goes through 32-bit fixed point, so detail below 2^−31 is lost.
  - d: subnormals are flushed to zero.
- **FLT-003**:
  - a: first and last channels swapped.
  - b: holds exactly `capacityFrames`; a write that only partly fits reports one frame too many, and that frame is lost.
  - c: frame #1000 is played twice.
  - d: renders of an odd count ≥ 3 swap their first two frames.
- **FLT-004**:
  - a: k/(2^23−1).
  - b: positive k only use k/(2^23−1).
  - c: −2^23 comes out as −(2^23−1)/2^23.
  - d: in calls longer than 65 536 samples, results are off by one from index 65 536.
  - e: 2^23−1 comes out as 1.0.
- **FLT-005**:
  - a: muted output is the smallest subnormal instead of 0.
  - b: underrun padding has 2^−23 on the last channel.
  - c: mute takes effect one render late.
  - d: muted renders consume frames (also targets FLT-003).
  - e: each frame of underrun silence skips one later frame (also targets FLT-003).
  - f: one extra silent frame after unmuting.
- **INT-001**:
  - a: signalling NaNs are quieted.
  - b: subnormal patterns are flushed to signed zero.
  - c: 0x80000000 comes out as 0.
  - d: every NaN becomes 0x7FC00000.
  - e: the last channel loses its low byte.
  - f: from the second write on, words go through Float.
- **INT-002**:
  - a: channel order reversed.
  - b: holds exactly `capacityFrames`; a write that only partly fits reports one frame too few, so a frame repeats.
  - c: a 4096-frame render skips its last frame.
  - d: the first two frames of the stream are swapped.
  - e: channels are rotated after 65 536 frames.
- **INT-003**:
  - a: muted words are 0x80000000.
  - b: underrun padding has the word 1 on the last channel.
  - c: muted renders consume frames (also targets INT-002).
  - d: unmute takes effect one render late.
  - e: after an underrun, the next written frame is skipped (also targets INT-002).

**Ambiguous or contradictory points**
- **FLT-001 / FLT-002**: every k/2^23 value is also a finite value in −1…+1, so nothing can break FLT-001 without breaking FLT-002. All FLT-001 mutants list both. Only the FLT-002 mutants are FLT-002-only.
- **FLT-002**: "values that need more than 24 significant bits" can't be meant literally, because a Float32 has at most 24. I read it as values that are not multiples of 2^−23.
- **FLT-005 / INT-003**: "consumes nothing when no written samples remain" is trivially true if read literally. I read it as: underrun silence must not use up frames written later.
- **FLT-003 / INT-002 against FLT-005 / INT-003**: a muted render that consumes frames drops them, which also breaks "nothing dropped". I listed both requirements on those mutants.
- **Float silence**: the contract compares values, so −0.0 counts as zero. No mutant relies on telling −0.0 from +0.0. For integers, 0x80000000 is not zero.

**Assumptions**
- A correct stage plays queued frames straight away when it isn't muted. It doesn't hold them back to build up a buffer, and it does accept writes while muted. My mutants' frame-tracking depends on this.
- `channels` is at least 1. A `capacityFrames` below 1 is treated as 1 for the self-imposed capacity in FLT-003-b and INT-002-b. The contract allows that limit, since it only promises *at least* `capacityFrames`. I added it so that the partial-write case can happen whatever capacity the base has.
- `render` calls outside 1…4096 are passed straight to the base, unchanged.
- The contract has no sample rate, so there are no "one rate only" mutants.
- `Float.rounded()` fails to link in this package because the C maths library isn't linked. The mutants round by converting to integers instead.
