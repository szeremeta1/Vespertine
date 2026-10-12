# dop-stream-B: final report

I delivered the implementation at `/srv/cleanroom/dop-stream-B/harness/Sources/CleanRoomB/BDoPStream.swift`. It builds cleanly in Swift 6 language mode with `swift build`, with no warnings, and imports only `Contracts`. A randomized model check (300 seeds, about 400 operations each) found no violations of DOPS-001 to DOPS-007. Targeted runs of mute/unmute and of a silence frame inserted at a write boundary behaved as intended. I didn't change any file I was given: I used `Sources/Scratch/main.swift` for testing and then restored its original single line.

**What the stage does**
- **Structure:** `BDoPStream.subject` is a `Sendable` maker struct that returns a final class holding a first-in, first-out queue of written words. The queue grows as needed and drops played words from the front.
- **`write`:** it accepts `min(whole frames offered, capacityFrames − frames queued)` and keeps the accepted frames unchanged. When the stage is full it returns 0. Writes are still accepted while muted.
- **`render`, one output frame at a time:**
  - When unmuted with music queued, the next music frame goes out bit-identical and is consumed. The one exception: if its marker byte (taken from channel 0) equals the marker of the frame output just before, exactly one silence frame goes out first.
  - When muted or the queue is empty, a silence frame goes out and nothing is consumed.
- **Silence frames:** each word is `marker<<24 | 0x69<<16 | 0x69<<8`, with the same value on every channel. The marker is the opposite of the previous output frame's marker; 0x05 when nothing has been output yet.
- **`setGain` and `setEqualizer`:** they have no effect ("DoP is always passthrough").

**Ambiguous or contradictory points**
- **DOPS-005 gap, what "it" refers to:** "the marker of the frame output just before it" can't mean the music frame. The frame just before the music frame is the inserted silence frame itself, and DOPS-001 forbids it from having the same marker. I read "it" as the inserted silence frame: one silence frame is allowed only when the music frame's marker equals the marker of the frame output before that silence.
- **DOPS-005 / DOPS-001, a corner no implementation can avoid:** a marker clash can land on the last slot of a `render` call. The forced silence frame is then output before its music frame. If `setMuted(true)` comes next, that silence is followed by more silence instead of music. Outputting the music there instead would break DOPS-001, so there is no compliant alternative.
- **DOPS-005 exception at write boundaries:** the contract says the first frame of a write need not continue the marker sequence. That applies between two writes still in the queue, not only after a hold. I apply the same single-silence-frame exception there, since the exception's wording isn't limited to holds.
- **`capacityFrames`:** I took it as the exact limit on queued, unplayed frames. The contract only says "at least" this many are accepted into an empty stage.

**Assumptions**
- **Silence byte:** 0x69 (any byte with four bits set qualifies under DOPS-003).
- **Marker before any output:** with nothing output yet, the first music frame goes out with no check, and the first silence frame uses marker 0x05.
- **Ruled-out input never traps:**
  - `channels <= 0` makes `write` return 0 and `render` return `[]`.
  - A negative `capacityFrames` is treated as 0.
  - A trailing partial frame in `write` is ignored.
  - `frameCount < 1` returns `[]`.
  - `frameCount > 4096` is honoured, but capped at about 2^20 words; this only binds for very large requests.
  - Music with invalid or mismatched markers is passed through unchanged, with the marker read from channel 0, and never causes a crash or hang.
- **Low byte of music words:** not masked; bits 7…0 pass through as written.
- **Threading:** the stage has no locking; I assumed calls come in one at a time, since the contract says nothing about concurrency.
