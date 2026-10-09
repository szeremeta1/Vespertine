# dop-pack-C: final report

I wrote 24 mutants, at least three for each of the seven testable requirements, in `/srv/cleanroom/dop-pack-C/harness/Sources/Mutants/DoPPackMutants.swift` (`DoPPackMutants.all`). `swift build` passes in Swift 6 mode (debug and release) with no warnings.

The file uses only Contracts and SpecKit. No file I was given is changed: I used Sources/Scratch for testing and then put it back to its original one line.

**How each mutant works:** it first calls the correct packer, so invalid input still throws `InvalidInput` and empty channels still return empty arrays. It then rewrites the correct output. All indexing is bounds-checked, so no mutant can trap or hang.

**Testing:** in Scratch I tried every mutant against my own correct packer, using one simple check per requirement. Inputs had 1, 2, 3 and 6 channels and from 0 up to 9000 bytes per channel, with both markers. Results:
- My correct packer passed every check.
- Every mutant failed the checks for every requirement it targets.
- Every mutant still threw on all five invalid-input cases and returned empty arrays for empty channels.

**Mutants (targets):**
- **DOP-001 (24-bit layout):**
  - a: the marker is also copied into bits 31..24.
  - b: the sample is sign-extended, so 0xFA samples get 0xFF in bits 31..24.
  - c: odd periods get 0xFF in bits 31..24, as if the other marker came from a 32-bit NOT.
- **DOP-002 (alternation):**
  - a: firstMarker on every sample.
  - b: the marker restarts every 1023 periods, so it repeats at the boundary (needs 1024+ periods).
  - c: periods 0 and 1 both carry firstMarker.
  - d: the other marker is the negation of firstMarker (0x05 to 0xFB, 0xFA to 0x06). Targets DOP-002 and DOP-001.
- **DOP-003 (same marker on all channels):**
  - a: odd channels use the opposite marker throughout.
  - b: one marker toggle is shared across channels, so channels disagree only when the period count is odd.
  - c: channels 2 and up use the opposite marker (only shows with 3+ channels).
- **DOP-004 (time order, oldest in bit 15), each also targeting DOP-007:**
  - a: the two bytes of each sample are swapped.
  - b: periods come out in reverse order.
  - c: bits 8 and 7 (slots t7 and t8) are exchanged.
  - d: the period index wraps at 256, so later samples repeat earlier data.
- **DOP-005 (own channel's data only), each also targeting DOP-004 and DOP-007:**
  - a: each channel carries the next channel's data.
  - b: the last sample of channels 1 and up carries channel 0's last data.
  - c: bit 0 of each sample comes from the next channel.
- **DOP-006 (each byte read MSB first), each also targeting DOP-004 and DOP-007:**
  - a: every byte bit-reversed.
  - b: only the second byte of each sample bit-reversed.
  - c: the two nibbles of each byte swapped.
- **DOP-007 (every bit exactly once):**
  - a: the last sample of each channel is dropped.
  - b: an extra trailing sample repeats the last 16 bits, with the marker still alternating.
  - c: output stops after 4096 periods (needs 4097+ periods).
  - d: all 16 data bits are inverted. Targets DOP-007 and DOP-004.

**Ambiguities and overlaps:**
- **DOP-001 and the contract's "bits 31..24 are zero":** any change to bits 23..16 also changes the marker value and so breaks DOP-002. The only DOP-001-only violation left is nonzero bits 31..24. I took "Each DoP sample is a 24-bit value" in DOP-001 to cover that.
- **DOP-001 / DOP-002:** "the marker byte" is never defined in DOP-001. I read it as 0x05 or 0xFA, from DOP-002, so a wrong marker value counts against both.
- **DOP-002 gap and firstMarker:** a packer that ignores firstMarker but still alternates breaks only the contract, not DOP-002 as written. The gap leaves the first marker open, so I wrote no mutant for it, and none for marker phase carried over between calls (the contract's "State: none").
- **DOP-003 vs firstMarker:** the contract says "the first output sample" (singular). If each channel's element 0 must carry firstMarker, the DOP-003 mutants also break that. Channel 0 is always correct in them.
- **DOP-004 gap:** whether t0 is bit 15 is shown only in the standard's figure. I wrote no mutant that only moves t0 to bit 0, i.e. reverses all 16 bits. Every DOP-004 mutant is wrong under either reading.
- **DOP-004, DOP-005, DOP-006 and DOP-007 overlap:** DOP-007's "moved" covers every misplaced bit. DOP-004's "that channel's next 16 DSD samples" covers wrong-channel and wrong-bit-order data too. So targets list several IDs where that applies.
- **Extra sample (C-DOP-007-b):** I targeted DOP-007 only, though one could argue a sample past the end also breaks DOP-004. I pad with the channel's own repeated data so it doesn't also break DOP-005.
- **Possible extra kills from other checks:**
  - Some tests may kill a mutant under a requirement it doesn't target. For example, a DOP-006 single-bit test also catches a byte swap (C-DOP-004-a), a t7/t8 swap (C-DOP-004-c), a dropped sample (C-DOP-007-a) or inverted bits (C-DOP-007-d), and a DOP-005 test may catch the inversion.
  - A DOP-002 test that reads the marker as `v >> 16` would also kill the DOP-001 mutants.
  - I don't count any of these as violations of those requirements.

**Assumptions:**
- The packer passed in at run time is correct and returns `dsd[c].count / 2` samples per channel. Mutants only rewrite its output.
- A thorough test uses at least 2 channels, at least 3 channels, an odd period count, and more than 256, 1023 and 4096 periods. A few mutants (C-DOP-002-b, C-DOP-003-b, C-DOP-003-c, C-DOP-004-d, C-DOP-007-c) only show up under those conditions.
- Importing toolchain modules such as Synchronization or Foundation would go beyond "modules already in the workspace package". So no mutant keeps state between calls, and there are no "second call" mutants.
