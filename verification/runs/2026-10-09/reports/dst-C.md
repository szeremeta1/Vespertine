# dst-C: final report

## Report: dst, role C (mutants)

I wrote 27 mutants in `/srv/cleanroom/dst-C/harness/Sources/Mutants/DSTMutants.swift`. The package builds in Swift 6 mode with `swift build` and shows no warnings. The file uses only the Contracts and SpecKit modules. Every file I was given is unchanged. I used the Scratch target for testing and then put `Sources/Scratch/main.swift` back to its original one-line content.

**How the mutants work.** Each mutant wraps the correct decoder passed in at run time and changes its result in one deliberate way. A mutant can only see what the contract exposes: the channel count, the frame bytes, the correct result, and how many times the same decoder has been called. Every helper checks its bounds, so no mutant traps or hangs on any input.

**What I checked.** I couldn't run them against a real decoder. In Scratch I used a stand-in for the correct decoder: it returns the expected output for each fixture, decodes a stored-looking frame of the right size to its payload, and returns nil for anything else. Against it I ran four kinds of check:
- a new decoder for each fixture;
- one decoder for all fixtures of a channel count, over three rounds (forward, reversed, forward);
- an empty frame, a truncated frame and a frame with one bit flipped, each required to give nil or 4704 × channels bytes;
- equality with the expected output in all of these.

Every mutant was caught by at least one of these. The ones that only go wrong from a later call onwards (001-d, 002-h, 003-f, 004-b, 004-d) need a decoder that is used for several frames. 001-c and 001-g need the "nil or right length" check on frames that aren't fixtures.

**The mutants, by requirement:**
- **DST-001 (frame length):**
  - a: every channel loses its final byte.
  - b: 6-channel only, one extra byte per channel.
  - c: returns an empty array instead of nil (targets only DST-001).
  - d: one byte short from the second call on.
  - e: output cut to the stereo size (9 408 bytes) for 5 and 6 channels.
  - f: 5-channel output padded to the 6-channel size.
  - g: correct on fixture frames, but any other frame it decodes comes out short (targets only DST-001).
- **DST-002 (layout):**
  - a: channels 1 and 2 swapped.
  - b: bits reversed in every byte.
  - c: channels output one after another instead of interleaved.
  - d: 6-channel only, channels 3 and 4 swapped.
  - e: last channel's bits reversed.
  - f: interleaved two bytes at a time.
  - g: last byte of each channel bit-reversed (an edge case; 9 of 15 fixtures show it).
  - h: channel order rotated from the third call on.
- **DST-003 / DST-004 (exact output):**
  - 003-a: every byte inverted.
  - 003-b: the frame's very last sample flipped.
  - 003-c: each channel delayed by one sample.
  - 003-d: one bit flipped mid-frame, only on compressed frames.
  - 003-e: 5-channel frames return nil.
  - 003-f: first sample flipped from the second call on.
  - 003-g: channel 6 replaced by silence (0x69 bytes).
  - 004-a: one bit flipped, only on stored frames.
  - 004-b: decoding the same frame again returns a cached copy with one bit wrong.
  - 004-c: frames over 12 000 bytes return nil.
  - 004-d: one bit flipped from the sixth call on.
  - 004-e: last 8 bytes of channel 2 replaced by silence.

**Ambiguities and contradictions:**
- **DST-003 and DST-004 can't be told apart.** Each fixture's expected DSD is both the encoder's input (DST-004) and the reference decoder's output (DST-003), as DST-004's gap says. No mutant can break one without breaking the other on the fixtures, so every content mutant lists both as targets.
- **What "every DST frame" means in DST-003 is unclear.** It could mean only the 12 DST-coded frames, or all 15. The Test data section calls all fifteen "DST frames", so I read it as all 15. Under that reading the stored-only mutant (C-DST-004-a) also targets DST-003; under the narrower reading it would break DST-004 only.
- **DST-001 and DST-002 always drag in DST-003 and DST-004 on fixtures.** Changing a fixture's length or layout also changes the bytes DST-003/DST-004 compare. Those mutants therefore list all three. The only way to break DST-001 alone is on frames that aren't fixtures (001-c and 001-g).
- **DST-002's gap.** The gap says the SACD layout comes from the non-public Scarlet Book. I treated layout as testable anyway, because the contract's Output section states the layout outright and the fixtures follow it.
- **Undecodable frames.** The contract says nil means "can't be decoded", but leaves which frames those are to DST-005, which is not testable. So C-DST-001-c is only detectable through a "nil or 4704 × channels bytes" check on an input the correct decoder rejects.

**Assumptions:**
- The correct decoder returns nil for at least one input a thorough test would try, such as an empty or truncated frame. C-DST-001-c depends on this.
- The correct decoder returns a result for at least one changed frame that isn't a fixture, such as one with a bit flipped. C-DST-001-g depends on this. It also reads `DSTFixtures.all` to recognise fixture frames.
- A thorough test uses one decoder for several frames, including the same frame twice. The contract requires the result not to depend on earlier frames.
- Mutants that look at frame size treat "frame shorter than its decoded output" as a compressed frame. That holds for all 15 fixtures; nothing else about the frame format is assumed.
