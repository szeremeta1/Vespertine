# pcm-stream-B: final report

## Report: pcm-stream, role B (implementation)

Both deliverables are written and build cleanly in Swift 6 language mode with `swiftbox /srv/cleanroom/pcm-stream-B "cd harness && swift build"`, with no errors or warnings. They depend only on `Contracts`, and none of the files I was given has changed.

### Delivered
- `/srv/cleanroom/pcm-stream-B/harness/Sources/CleanRoomB/BFloat.swift`: `public enum BFloat { public static let subject: (any FloatOutput)? = BFloatOutput() }`
  - `int24ToFloat` returns `Float(k) / 8_388_608` for each sample, in order. This is exact for every 24-bit k: any |k| ≤ 2^24 converts to Float32 without rounding, and dividing by a power of two gives no subnormal results.
  - `makeStage` returns a FIFO of interleaved frames that copies samples through unchanged.
- `/srv/cleanroom/pcm-stream-B/harness/Sources/CleanRoomB/BInteger.swift`: `public enum BInteger { public static let subject: (any IntegerOutput)? = BIntegerOutput() }`
  - It uses the same FIFO design over `UInt32`, and words are never interpreted.
- Each file stands alone; neither depends on the other.

### Checking
I ran a throwaway test in `Sources/Scratch`. All checks passed:
- **Conversion:** all 2^24 inputs convert exactly. All results are distinct, and k comes back when the result is multiplied by 2^23.
- **Float stage:** all 2^24 converted values passed through it bit for bit with 1, 2, 3 and 8 channels, using random write and render sizes.
- **Exact copy:** random finite floats in [−1, 1] came out unchanged, including subnormals, −0.0 and ±1.
- **Integer stage:** NaN, infinity, −0 and subnormal patterns plus 200k random words came out unchanged, with random write and render sizes and mute toggling.
- **Stage rules:** capacity, full, partial-frame input, mute and resume, and underrun behaved as described below.
- **Speed (debug build):** converting all 2^24 samples takes about 0.8 s. Rendering 2^24 samples in 4096-frame chunks takes about 0.56 s.

I edited `Sources/Scratch/main.swift` for the test and then restored it byte for byte. The sandbox also created a build cache at `/work/.home/.cache`.

### Ambiguous or underspecified points (by ID)
- **FLT-005 / INT-003 and `render`:** neither says what happens when fewer frames are queued than `frameCount`. I chose to play the queued frames and then pad the rest of the buffer with silence. The other reading, all silence until enough frames are queued, also seems consistent with the records.
- **`write` ("takes whole frames only", both contracts):** it's unclear whether input is guaranteed to be whole frames or the stage must cut a trailing partial frame. I accept `floor(count / channels)` frames, limited by free room, and ignore any trailing partial frame.
- **`capacityFrames` (both contracts):** there's no stated upper bound, and the range for `capacityFrames` and `channels` is unspecified. I accept exactly `capacityFrames` frames and no more. When room is short, `write` accepts as many whole frames as fit. Storage grows lazily, so a very large capacity such as `Int.max` doesn't trap.
- **Huge channel counts:** a huge channel count could make a valid `render` impossible to allocate. I only guard `frameCount × channels` against overflow.
- **FLT-002 gap:** NaN, infinities and values beyond ±1 aren't sent by the contract. The stage copies them through unchanged anyway; there is no clamping or sanitising.
- **FLT-004 gap:** I used the contract's 2^23 scale.
- **Mute (both contracts):** the contract doesn't say whether writes are accepted while muted. I accept them normally.

### Assumptions
- **"The device must still be fed" while muted:** `render` still returns exactly `frameCount × channels` values, all silence, and consumes nothing.
- **Silence values:** silence is +0.0 for floats and word 0 for integers.
- **`frameCount` outside 1…4096 (ruled out):** `render` returns `[]` and consumes nothing.
- **`channels ≤ 0`:** `write` returns 0 and `render` returns `[]`.
- **`capacityFrames ≤ 0`:** this gives a stage that accepts nothing.
- **Out-of-range `int24ToFloat` inputs (not tested):** these return `Float(k) / 2^23`, rounded. There is no masking or sign-extension, and it doesn't trap.
- **Threading:** I assumed the stages are used from one thread. The stage protocols aren't `Sendable`, so they have no locking; I avoided Foundation and Synchronization so the code depends only on modules in the package.
