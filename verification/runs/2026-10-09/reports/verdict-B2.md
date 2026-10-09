# verdict-B2: final report

## Round 0

## B2 report: implementation

**Delivered:** `/srv/cleanroom/verdict-B2/harness/Sources/CleanRoomB2/B2Verdict.swift`. It defines `public enum B2Verdict { public static let subject: (any BadgeVerdict)? = B2BadgeVerdict() }`. `B2BadgeVerdict` is an internal stateless struct conforming to `BadgeVerdict`. It imports only `Contracts`. `swift build` succeeds in Swift 6 mode, and I changed none of the files I was given. I used `Sources/Scratch/main.swift` to try about 50 cases, which all behaved as intended. That file isn't delivered. The code never traps:
- Rate comparison only uses Double subtraction.
- Bit depths are only compared, never computed on.
- NaN and infinite rates count as unequal.

### Evaluation order
1. If `concealedFrames > 0`, return `DAMAGED FRAMES SILENCED`. This applies to every mode and device (BPV-013).
2. Shared failures return a descriptive reason string:
   - **Device class:** Bluetooth, AirPlay and AirPods Max over Bluetooth fail. Built-in speakers, virtual and aggregate also fail (BPV-010, BPV-011).
   - **Gain:** any digital volume or ReplayGain other than exactly 0 dB fails (BPV-006).
   - **Channels and spatial:** spatial not `off`, `plan.channels != source.channels`, or `deviceChannels < source.channels` fails (BPV-007).
   - **Other apps:** `otherAppsPlaying` fails unless `hogOwnerPID` is non-nil, not −1, and equal to `ownPID` (BPV-008, BPV-009).
3. If `nominalRate`, `physicalBitDepth` or `physicalIsInteger` is nil, return a reason (BPV-003).
4. Then by mode:
   - **PCM**, in order:
     - Lossy or DSD source, `resampling`, or `dsdConvertedToPCM` returns a reason (BPV-001).
     - `nominalRate` must be within 0.5 Hz of `source.sampleRate` (BPV-002).
     - Integer physical format needs at least `source.bitDepth` bits. Float physical format needs at least 32 bits (BPV-004).
     - A source over 24 bits needs `plan.integerMode` (BPV-005).
     - `equalizerActive` returns `EQUALIZER`; otherwise `BIT-PERFECT` (BPV-014, BPV-015).
   - **DoP:** `nominalRate` within 0.5 Hz of `plan.requestedRate` and `physicalBitDepth >= 24` returns `NATIVE DSD · DoP` (BPV-016). Otherwise a reason.
   - **Bitstream:** `nominalRate` within 0.5 Hz of `plan.requestedRate`, physical format integer, `physicalBitDepth >= 16` returns `"BITSTREAM · " + source.codec` (BPV-017). Otherwise a reason.

No reason string equals or starts with any of the named badges.

### Ambiguities or contradictions found
- **BPV-002 / contract:** the 0.5 Hz tolerance is given only in a gap note, and the boundary isn't settled. I treat a difference of exactly 0.5 Hz as equal (`<=`).
- **BPV-004:**
  - Source with `bitDepth == nil` and an integer physical format: the integer comparison doesn't apply, so I let it pass, since BPV-015 says to give the badge when all conditions are met.
  - Float physical format below 32 bits fails regardless of source depth.
- **BPV-005 with BPV-004:** I take "integer mode in effect" to mean `plan.integerMode == true`. I don't also require `physicalIsInteger == true`. A >24-bit source with `integerMode` true and a 32-bit float physical format therefore gets BIT-PERFECT.
- **BPV-003:** "Physical format" is two fields, and I treat a nil in either (`physicalBitDepth` or `physicalIsInteger`) as unreadable. This applies to all three badges, including DoP where integer-ness isn't otherwise needed.
- **BPV-011:** the records don't say whether DoP or bitstream may appear on built-in speakers, virtual or aggregate devices. I excluded them, reading "BPV-006 to BPV-011 hold" in BPV-016 and the "shared conditions" in BPV-017 as including the device-class rule. These devices therefore never get any of the three badges.
- **BPV-013 vs other reasons:** `DAMAGED FRAMES SILENCED` takes priority over every other label, including the Bluetooth reasons and `EQUALIZER`. BPV-013 reads as unconditional.
- **BPV-014:** `EQUALIZER` appears only when everything else would give BIT-PERFECT. With the equalizer on and another failure, a plain reason string is returned. The equalizer has no effect on DoP or bitstream, because BPV-016 and BPV-017 don't list it.
- **BPV-016:**
  - "Planned carrier rate" is read as `plan.requestedRate`.
  - The 24-bit physical format needn't be integer, as the gap note says is open.
  - I added no source-encoding check, and no `resampling` or `dsdConvertedToPCM` check, since "exactly when" lists only the stated conditions.
- **BPV-017:**
  - "Planned rate" is `plan.requestedRate`.
  - I didn't require exclusive hog mode. Shared mode with no other app playing is accepted, per BPV-008.
  - The codec name after the dot is `source.codec`, unchanged and not uppercased.
  - With an empty codec the badge is `"BITSTREAM · "`.
  - BPV-007 still applies, so a bitstream plan whose channel count differs from the file's gets a reason, not a BITSTREAM badge.
- **BPV-009:** a `nil` `hogOwnerPID` (read failed) counts as not held. A `hogOwnerPID` of −1 never counts as held, even if `ownPID` were also −1.
- **BPV-012:** AirPods Max over USB-C needs no special case. It behaves like any other device that can be bit-perfect, and its readback is judged by the same rate and format rules.

### Assumptions
- `requestedRate` is ignored for PCM, per BPV-002. `requestedBitDepth` is never used, per BPV-003.
- A gain of NaN counts as "other than exactly 0 dB". −0.0 counts as 0.
- A negative `concealedFrames` (ruled out by the contract) counts as none.
- A source codec that doesn't match the mode (for example FLAC sent as `bitstream`) isn't checked, because the records don't ask for it.

## Round 2

## B2 report, round 2

**Delivered:** `/srv/cleanroom/verdict-B2/harness/Sources/CleanRoomB2/B2Verdict.swift` is updated for the new records. `swift build` passes in Swift 6 mode. About 55 scratch cases (not delivered) pass. I touched no given files.

### What changed
I moved the hog-mode check into one helper, `playerHoldsDevice(readback)`. It is true only when `hogOwnerPID` is non-nil, not −1, and equal to `ownPID` (BPV-009). BPV-008's "unless the player holds the device" now uses the same helper, with the same behaviour as before. The edits:
- **BPV-016 (DoP):** `NATIVE DSD · DoP` now also requires the player to hold the device. If it doesn't, the result is a plain reason string, "Player does not hold the device for DoP". Shared mode with no other app playing is no longer enough. The other conditions are unchanged:
  - the rate read back within 0.5 Hz of `plan.requestedRate`;
  - physical depth at least 24, integer-ness not required;
  - BPV-003, BPV-006 to BPV-011 and BPV-013.
- **BPV-017 (bitstream):** `"BITSTREAM · " + source.codec` now also requires the player to hold the device. If it doesn't, the result is a plain reason string, "Player does not hold the device for bitstream". The other conditions are unchanged.
- **BPV-018 and the `integerMode` row (PCM, BPV-005):** a source deeper than 24 bits is bit-perfect only when `plan.integerMode` is true and the player holds the device. A case with `integerMode` true and the device not held is ruled out. I treat integer mode as not in effect there, so a >24-bit source gets a reason string, never BIT-PERFECT. This matches BPV-018's note that such a source is never bit-perfect unless the player holds the device. It doesn't trap. BPV-018 is `testable: false`, so nothing else enforces it.
- **Order of checks:** unchanged. The held check sits after the shared failures and the BPV-003 readback check, inside the DoP and bitstream branches.

### New ambiguities and assumptions
- **BPV-016/017 with `otherAppsPlaying`:** holding the device with `otherAppsPlaying` true still passes BPV-008 and gives the badge.
- **BPV-016/017 reason when not held:** the badge is not specified beyond not being the named badge. I return a descriptive reason string, not `DAMAGED FRAMES SILENCED`, except that damaged frames still take priority over every other label (BPV-013).
- **`integerMode` true with the device not held:** the contract rules it out, so treating it as not in effect is my choice. A nil `hogOwnerPID` counts as not held for the same purpose.
- **BPV-005 / BPV-018:** integer mode still doesn't require `physicalIsInteger == true`, as in round 1.
- All other round 1 ambiguities and assumptions stand as reported before.
