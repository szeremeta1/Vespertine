# dop-pack-B: final report

I wrote the DoP packer in `/srv/cleanroom/dop-pack-B/harness/Sources/CleanRoomB/BDoPPack.swift`. It builds in Swift 6 language mode with `swift build`, and the hand checks I ran in Scratch all came out right. I changed none of the files I was given: I used `Sources/Scratch/main.swift` for the checks and then put it back exactly as it was.

**What it does:** `BDoPPack.subject` is a `Packer` that conforms to `DoPPacker` and depends only on `Contracts`.
- For each channel `c` and sample period `j`, the output is `(marker_j << 16) | (dsd[c][2j] << 8) | dsd[c][2j+1]`. Bits 31…24 are always zero.
- `marker_j` is `firstMarker` when `j` is even and the other marker (0x05 or 0xFA) when `j` is odd. All channels share the same marker in a period (DOP-001, 002, 003).
- Bytes are copied as they are, with no bit reversal. An input byte's most significant bit is its oldest sample, and slot t0 (the oldest) is bit 15. So the older byte fills bits 15…8 and the newer byte fills bits 7…0, in time order (DOP-004, 006). Each channel gets one output sample per two of its own input bytes, and every bit appears exactly once (DOP-005, 007).
- It throws `InvalidInput` when:
  - there are no channels;
  - the first channel's length is odd;
  - any channel's length differs from the first;
  - `firstMarker` is neither 0x05 nor 0xFA (this is checked even when the channels are empty).
- Empty channels return a matching number of empty arrays. The code has no paths that can trap: indexing stays in bounds once the input is validated, and the shifts can't overflow.

**Checks I ran:**
- Two channels `[12 34 56 78]` and `[AB CD EF 01]` with first marker 0x05 gave `051234 FA5678 | 05ABCD FAEF01`.
- Starting with 0xFA gave `FA1234 055678 FA9ABC`.
- `[[],[]]` gave `[[],[]]`.
- All six invalid-input cases threw `InvalidInput`.

**Ambiguities and contradictions:**
- **DOP-004:** the record's own gap note says only the figure shows that t0 is bit 15. I followed the requirement as written (t0 is the MSB). This matches the contract, and it means bytes are copied unchanged.
- **DOP-002:** the standard doesn't say which marker comes first. The contract settles this with `firstMarker`, so nothing was left open.
- **Errors:** the contract doesn't say which error applies first when several apply, but every case throws the same `InvalidInput`, so the order makes no visible difference.
- I found no contradictions between the contract, the records and the Swift API.

**Assumptions:**
- "Sample period `j`" means output index `j`. Whether it gets `firstMarker` or the other marker depends only on whether `j` is even or odd, and each call starts over at `firstMarker` (no state is kept between calls).
- The invalid-marker check also applies to empty channels, since the contract states it with no exception.
- I added nothing beyond the contract: no clamping, no partial output, no state.
