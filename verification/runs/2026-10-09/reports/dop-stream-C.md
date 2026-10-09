# dop-stream-C: final report

## Report: dop-stream, role C (mutants)

I delivered 30 mutants in `/srv/cleanroom/dop-stream-C/harness/Sources/Mutants/DoPStreamMutants.swift`, at least two per testable requirement. The package builds cleanly in Swift 6 mode with no warnings, and none of the files I was given are changed: `Scratch/main.swift` is back to its original line. My validation program is kept outside the package at `/srv/cleanroom/dop-stream-C/notes/scratch-validation.swift`.

**How the mutants work.** Each mutant wraps the correct stage it is given.
- The correct stage holds the written music. The mutant mirrors what it accepted and takes from it exactly the music frames it is about to play.
- The mutant itself makes the silence, inserts the bridging frame and handles mute, the way a correct stage does, then changes exactly one behaviour.
- It reads the correct stage's silence byte and first marker from one `render(1)` before anything is written, which consumes nothing.
- Gain and equalizer calls are passed on to the correct stage. Mute is never passed on; the mutant handles it.

**The mutants**

| ID | Targets | What is wrong |
|---|---|---|
| 001-a | 001 | Silence while held (muted or out of music) is always marker 0x05 |
| 001-b | 001 | No bridging frame: music whose marker repeats the previous frame's goes out directly |
| 001-c | 001 | The first held silence frame of each render call restarts the marker at 0x05 |
| 001-d | 001 | Every 32768th held silence frame repeats the previous marker |
| 002-a | 002, 001 | Silence while muted has marker byte 0x00 |
| 002-b | 002, 001 | Silence when out of music has a marker on channel 0 only |
| 002-c | 002, 001 | The bridging frame has marker byte 0x00 |
| 002-d | 002, 001 | Silence uses 0xFB where the marker should be 0xFA |
| 003-a | 003 | Silence has DSD bytes 0x00 |
| 003-b | 003 | The last channel's silence uses the complement byte |
| 003-c | 003 | The silence byte switches every other render call, even inside one run |
| 003-d | 003 | Silence while muted uses a byte with three bits set |
| 003-e | 003 | The bridging frame has DSD bytes 0xFF |
| 004-a | 004 | Music frames come out with channels 0 and 1 swapped |
| 004-b | 004 | The last frame taken by a write that fills the stage is skipped if it comes up during continuous playback |
| 004-c | 004 | Every capacityFrames-th music frame has one DSD bit flipped on its last channel |
| 004-d | 004 | After running out of music, playback resumes by replaying the last two frames played |
| 005-a | 005 | 64 silence frames before music whenever it starts or resumes |
| 005-b | 005 | A marker collision is bridged with three frames instead of one |
| 005-c | 005 | When pending music can't fill a render call, the silence goes first and the music last |
| 005-d | 005 | Two extra silence frames after unmuting |
| 006-a | 006 | Mute is ignored: music keeps playing while muted |
| 006-b | 006 | Mute takes effect one render call late |
| 006-c | 006 | Mute takes effect only at the end of the write it interrupts |
| 006-d | 006, 004, 005 | While muted, pending music is thrown away |
| 007-a | 007, 004 | A gain other than 1.0 scales music DSD bits as a signed sample |
| 007-b | 007, 004 | With the equalizer on, the lowest DSD bit of music words is cleared |
| 007-c | 007 | Silence runs that start with the equalizer on use the complement silence byte |
| 007-d | 007, 004 | A gain of exactly 0.0 zeroes music DSD bits |
| 007-e | 007 | Silence runs that start with a gain other than 1.0 use the complement silence byte |

IDs are shortened here; the full IDs are `C-DOPS-001-a` and so on, and the targets are `DOPS-001` and so on. 002-b, 003-b and 004-a change nothing on mono stages, by design.

**Validation**
- **Checker:** I wrote three legal correct stages (different silence bytes, first markers, spare capacity, and one that changes its silence byte between runs). I drove them with 9 scenarios at 1, 2 and 6 channels, and checked every requirement plus a with/without-gain comparison for DOPS-007.
  - All three correct stages pass.
  - On 2 and 6 channels, every mutant fails exactly its listed targets.
  - On mono, 007-a also shows other failures. A separate check showed its output differs from the unity-gain run only in music DSD bits, so these come from my checker misreading the corrupted frames, not from the mutant.
- **Robustness:** a separate robustness test made about 346,000 render calls over odd channel counts, capacities 0–5000, gains including NaN and infinity, and arbitrary frame contents. Nothing trapped or hung, and every render returned the right number of words.

**Ambiguities and contradictions**
- **DOPS-001 / DOPS-002:** an invalid marker also breaks the 0x05/0xFA alternation, so the DOPS-002 mutants can't avoid violating DOPS-001 and list both. The records don't say whether alternation is checked per channel; 002-b breaks DOPS-001 only if it is. I read a "valid marker" as 0x05 or 0xFA, not as "the marker alternation expects".
- **DOPS-005 gap:**
  - "The frame output just before it" must mean the frame before the silence frame; reading it as the frame before the music frame contradicts DOPS-001.
  - The gap talks about holds, but the contract also forces collisions between two writes with no hold. I assumed one bridging frame is allowed there too.
  - It's unclear whether "no written music remains" means what the stage holds or what the caller wrote but hasn't heard.
- **DOPS-004:** the condition "while the stage keeps being rendered unmuted until it has played them" is unclear when a mute comes in between. I read it strictly, so 006-d also lists DOPS-004 and DOPS-005; under the other reading it violates only DOPS-006.
- **DOPS-006 / DOPS-005:** nothing requires silence while muted ("must still be fed"). So playing music while muted breaks only DOPS-006, which 006-a, b and c rely on.
- **DOPS-007:**
  - Checking "the same frames as with unity gain and no equalizer" needs a comparison run, which only works if the stage behaves the same every time. 007-c and 007-e assume tests compare two identically driven stages.
  - Any change to music under gain or equalizer also breaks DOPS-004, so 007-a, b and d list both.

**Assumptions**
- A write that accepts fewer frames than offered keeps the first ones offered.
- Rendering an empty correct stage consumes nothing.
- A correct stage adds exactly one bridging frame before music whose marker matches the previous frame, and no other silence while music is pending and it isn't muted.
- A silence run can continue across render calls (003-c relies on this).
- Some mutants only show up when tests go far enough: more than 32,768 silence frames (001-d), more than capacityFrames music frames (004-c), gain exactly 0.0 (007-d), at least two channels (002-b, 003-b, 004-a), and muting partway through one write (006-c).
