# verdict-C: final report

I've written 79 mutants covering all 17 testable requirements. `swift build` passes with no errors or warnings. In my own scratch tests every mutant was caught by a check of a requirement it targets.

**Deliverable:** `/srv/cleanroom/verdict-C/harness/Sources/Mutants/VerdictMutants.swift` defines `public enum VerdictMutants { public static let all: [Mutant<any BadgeVerdict>] }`. It imports only Contracts and SpecKit, has no stored state, and changes none of the given files. I edited `Sources/Scratch/main.swift` while testing and then put back its original one line.

**How the mutants work.** Each one wraps the correct verdict the harness supplies, in one of two ways:
- **Overlook a failure:** when the targeted failing condition is present, the mutant asks the correct verdict about the input with that condition repaired. If that answer is BIT-PERFECT, NATIVE DSD · DoP or a BITSTREAM · badge, it returns it; otherwise it returns the correct answer.
- **Replace a correct badge:** when the correct verdict gives a particular badge in a particular situation, the mutant returns a different string.

**How I checked them.** In Sources/Scratch I wrote my own correct implementation and 143 checks, each changing one field from a valid starting input. The implementation passed all 143. I also fed every mutant 400k randomised inputs, including Int.min/max, NaN, ±inf and nil PIDs:
- Nothing trapped or hung.
- Every difference from my implementation was the targeted condition getting the wrong badge, in the targeted mode.

**Mutants per requirement** (primary ID; 2 is the minimum): 001: 5, 002: 4, 003: 5, 004: 5, 005: 3, 006: 7, 007: 6, 008: 4, 009: 4, 010: 5, 011: 3, 012: 3, 013: 6, 014: 4, 015: 5, 016: 6, 017: 4.

They run from blatant to subtle, for example:
- **Edges:** a 24-bit float format accepted (004-c), bytes compared instead of bits so 24-bit passes on 20-bit (004-e), gains under ±0.5 dB treated as 0 dB (006-c), a single concealed frame ignored (013-b), 32-bit integer format rejected for DoP (016-d).
- **One rate:** sources above 192 kHz skip the rate check (002-c), DoP badge only at the 176.4 kHz carrier rate (016-f).
- **One channel layout:** device channels only checked for files with more than two channels (007-d).
- **Many frames:** the concealed-frame count is kept in 16 bits, so large counts wrap and are ignored (013-e).
- **Exact strings:** "BIT PERFECT", "EQUALIZER " with a trailing space, a U+2022 bullet in the DoP badge.

Shared conditions broken only in DoP or bitstream mode also list BPV-016 or BPV-017 as targets. Mutants that wrongly reject a valid path list BPV-015.

**Ambiguous or contradictory points**
- **BPV-014 vs BPV-015:** the equalizer isn't among the BPV-001–011 conditions. So BPV-015 literally requires BIT-PERFECT with the equalizer on, while BPV-014 requires "EQUALIZER". I treated BPV-014 as the more specific rule.
- **BPV-016 vs BPV-003:** BPV-016's "exactly when" leaves out BPV-003. With only `physicalIsInteger` nil, BPV-016 demands the DoP badge and BPV-003 forbids it. No mutant touches that case.
- **BPV-016 vs BPV-011:** BPV-011 only rules out BIT-PERFECT, so it trivially "holds" in DoP mode. Read literally, BPV-016 then requires the DoP badge on built-in speakers, virtual and aggregate devices, which BPV-011's gap leaves open. BPV-016 also says nothing about the equalizer. I avoided all of these.
- **BPV-016 wording:** I took "planned carrier rate" to be `plan.requestedRate`. Whether a 24-bit float format counts is left open by the gap, so DoP mutants only use integer formats.
- **BPV-017:** "the shared conditions" is never defined. I took it as BPV-003, BPV-006–010 and BPV-013, leaving out BPV-011. BPV-017 is only a necessary condition ("only when"), so nothing requires a BITSTREAM badge and no mutant removes one. Exclusive vs shared access is open, so bitstream mutants keep the test's hog-mode owner; 008-d only changes it when another app is playing.
- **BPV-007 in bitstream:** the record requires sent channels to equal the file's. I followed the record (007-f), even though real 5.1 passthrough usually sends two channels.
- **BPV-009:** no input field records a request for exclusive access, so the "request that didn't take effect" clause can only be seen through `hogOwnerPID`. BPV-009 itself can only be observed through BPV-008, so 008 and 009 checks will catch each other's mutants. 009-c (own PID not recognised) targets BPV-009 and BPV-015 but not BPV-008, because BPV-008 is only a necessary condition.
- **BPV-003:** I read "physical format" as both `physicalBitDepth` and `physicalIsInteger`, so an unread integer flag on its own is unconfirmed (003-c).
- **BPV-002:** mutants only differ for rates more than 0.5 Hz apart.
- **BPV-004:** sources with no bit depth are left open, so the BPV-004 mutants only act when the source has a bit depth.
- **BPV-013:** which label wins when damage combines with another failure is left open, so the damage mutants only act where the correct verdict gives the damage label, or by removing the concealment.
- **BPV-012 / BPV-015:** "a device that can be bit-perfect" includes AirPods Max on USB-C, so the BPV-012 mutants also list BPV-015. Other mutants that reject a valid BIT-PERFECT skip that device so they don't break BPV-012.

**Assumptions**
- The correct verdict gives BIT-PERFECT, NATIVE DSD · DoP or a BITSTREAM · badge whenever every condition holds, including bitstream on `.other` and `.usbDAC`. The "overlook" mutants rely on this.
- When a mutant pretends a lossy or DSD source is lossless PCM and the source has no bit depth, it uses 16 bits.
- A −0.0 dB gain counts as 0 dB.
- Concealed-frame mutants only act on counts above 0.
- I wrote no "wrong on the second call" mutants. They need shared state that is safe across threads, which requires the Synchronization or Foundation module, outside the package.
- I avoided `Double.rounded()`, because without Foundation it fails to link (undefined `round`) in an executable that uses the module.
