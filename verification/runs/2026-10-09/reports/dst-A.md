# dst-A: final report

## What I delivered

I wrote `/srv/cleanroom/dst-A/harness/Sources/SpecChecks/DSTChecks.swift`, which defines `public enum DSTChecks { public static let all: [SpecCheck<any DSTDecoderMaker>] }` with 32 checks. It builds cleanly with `swift build` in Swift 6 language mode, and I changed none of the files I was given. I used `Sources/Scratch` for trials and then put it back to its original one line. Each check has its own `// REQ:` line directly above it, and its `requirements:` list names exactly the IDs it asserts. There are no force unwraps or `fatalError`, every loop is bounded, there is no randomness or clock, and each scenario makes its own decoder.

- **One check per fixture (15 checks; DST-001, 002, 003, 004).** Each uses a fresh decoder for the fixture's channel count. It checks the length (4,704 bytes × channels) and the layout. It checks that the output equals `expected` byte for byte, once as DST-003 and once as DST-004. It also checks each channel separately under DST-004.
- **Sequences (11 checks; all four IDs).**
  - One decoder decodes several frames in a row: repeats, back-to-back frames, stored and DST-coded frames alternating, for 2, 5 and 6 channels.
  - Two 2ch decoders are used in alternation, and so are 2ch, 5ch and 6ch decoders, to catch state shared between decoder objects.
  - Fixtures are decoded after empty, cut, extended and foreign frames. The fixture must still decode to its DSD afterwards.
- **Any decoded frame (6 checks; DST-001 only).** These feed in stored and DST-coded fixtures that are cut short or have bytes appended, the empty frame, and stored frames with another channel count. The result must be nil or exactly 4,704 × channels bytes, where channels is the decoder's channel count.

**Testing:** I tried the checks against two lookup-based decoders in Scratch. They behave correctly: one returns nil for anything that isn't a fixture, the other decodes it to garbage of the right size. Both pass all 32 checks. I also wrote 27 broken variants covering wrong length, missing final samples, length taken from the input, partial output or `[]` on error, planar output, reversed bit order, channel permutations, bit-level interleaving, byte-pair swaps, channel order rotating per call, content errors, nil for 5ch, stored-frame off-by-one, state leaking between calls, nil sticking after a failure, and global state. Every one failed a check on the requirement it targets.

**Timing:** I timed the checks against a made-up workload I wrote to resemble a debug-build DST decoder, not a real one. The slowest check took about 2.1 s and the full set about 29 s per implementation; real decoders could be slower or faster.

## Ambiguous or contradictory points

- **DST-003 / DST-004:** On the fixtures both say the same thing (output equals `expected`), so their assertions are identical. DST-003 says "every DST frame"; it isn't clear whether stored frames count as DST frames. Its gap lists stored frames among the exercised tools, so I applied DST-003 to all 15 fixtures.
- **DST-001:** It doesn't say whether a fixture must decode, so a nil result isn't counted against DST-001; DST-003 and DST-004 catch it. I read "a decoded frame is 4,704 bytes per channel" as applying to any non-nil result, including for bytes that aren't a fixture, using the decoder's channel count. I also read "holds 37,632 samples per channel" to mean that an output matching the fixture except in the last 128 samples per channel fails DST-001.
- **DST-002:** Its gap says the SACD layout comes from the non-public Scarlet Book, but the contract states the layout and the record is testable, so I tested it. Layout can only be seen through known content, so DST-002 fails only when the output is clearly the frame's DSD in another arrangement:
  - its bytes rearranged (planar, other channel order, word swaps);
  - bytes with the bit order reversed;
  - channels interleaved bit by bit;
  - one sample per byte.

  Content errors are left to DST-003 and DST-004. A layout error mixed with wrong content, or a channel shifted by a byte, fails only DST-003 and DST-004.
- **Frame independence:** This is in the contract but has no record of its own. I tested it through DST-001 to DST-004 in the sequence checks.
- **Errors section / DST-005:** Which frames can't be decoded is left open, so I never require nil or non-nil for bytes that aren't a fixture.

## Assumptions

- If a fixture is missing, or its expected size isn't 4,704 × channels, the check throws, which counts as a failure of every ID it names.
- Decoders handle these inputs without trapping: the empty frame, cut frames, frames with bytes appended, and other channel counts' stored frames. I left out bit flips and DST-coded frames from another channel count. They would not catch any extra broken variant, and they make it more likely that a correct but careless decoder traps or hangs.
- Errors in length or layout also change the output bytes, so they fail DST-003 and DST-004 as well. Content errors don't fail DST-001 or DST-002 unless they are confined to the last 128 samples of each channel (then DST-001).
- I only use channel counts 2, 5 and 6.
