# verdict-B: final report

I've delivered `/srv/cleanroom/verdict-B/harness/Sources/CleanRoomB/BVerdict.swift`. It compiles cleanly in Swift 6 mode with no warnings. I tested it against every testable record in a scratch program and all checks passed. The scratch program is gone: `Sources/Scratch/main.swift` is back to its original one-line content, and I didn't change any other file I was given. `swiftbox` also left a sandbox cache under `/work/.home`.

**What it does.** `BVerdict.subject` is a stateless `BadgeVerdict` struct. It checks in this order, and the first condition that fails picks the badge:
1. Any concealed frames (count > 0) give exactly `"DAMAGED FRAMES SILENCED"` (BPV-013).
2. Bluetooth, AirPods Max over Bluetooth and AirPlay are refused for every badge (BPV-010). Built-in speakers, virtual and aggregate devices are refused too (BPV-011).
3. A missing nominal rate, physical bit depth or physical integer flag gives "FORMAT NOT CONFIRMED" (BPV-003).
4. Checks every mode shares (BPV-006 to BPV-009):
   - Spatial audio on, channels sent different from the file's, or the device carrying fewer channels than the file.
   - Digital volume or ReplayGain at anything but exactly 0 dB.
   - Another app playing when the hog owner isn't the player's own PID. A nil or −1 owner counts as not exclusive.
5. Mode-specific checks:
   - **PCM:** DSD converted to PCM, a lossy or DSD source, resampling, a read-back rate more than 0.5 Hz from the file's rate, an integer physical format shallower than the source or a float one under 32 bits, or a source deeper than 24 bits without integer mode. If all of those pass, an active equalizer gives "EQUALIZER"; otherwise the badge is "BIT-PERFECT".
   - **DoP:** read-back rate within 0.5 Hz of `requestedRate` and at least 24 physical bits give "NATIVE DSD · DoP".
   - **Bitstream:** read-back rate within 0.5 Hz of `requestedRate` and an integer format of at least 16 bits give "BITSTREAM · " followed by `source.codec`.

Every other outcome is a short reason, such as "RATE MISMATCH" or "SHARED DEVICE". No reason equals, contains or starts with a named badge string. Nothing can trap: there is no integer arithmetic, and a NaN rate or gain simply fails its check.

**Ambiguous or contradictory points**
- **BPV-011 vs BPV-016:** BPV-011's gap says the docs don't say whether DoP or bitstream can appear on speakers, virtual or aggregate devices. BPV-016, though, lists BPV-011 among the DoP conditions. "BPV-011 holds" could also be read as trivially true for a DoP badge, which would then require DoP on those devices.
- **BPV-016 ("exactly when") vs BPV-003:** if the bit depth is read back (≥ 24) but the integer flag is nil, BPV-016 would require the DoP badge while BPV-003 forbids it.
- **BPV-016:** it doesn't say whether the 24-bit format must be integer. Read literally, the source encoding, `dsdConvertedToPCM` and the equalizer don't affect the DoP badge either.
- **BPV-017:** the "shared conditions" aren't listed. It's also open whether the device must be held exclusively, and what follows the dot.
- **BPV-004:** a PCM source with no bit depth (a float file) isn't covered.
- **BPV-013 and BPV-014:** neither says which label wins when another condition also fails.
- **BPV-002:** the 0.5 Hz tolerance comes from the contract's gap note, not from the docs.
- **BPV-009:** it doesn't cover the case where `ownPID` is −1.

**Assumptions I made**
- **Devices:** the BPV-011 exclusion applies to the DoP and bitstream badges as well.
- **DoP and bitstream:** both compare the read-back rate with `plan.requestedRate`, which I took as the planned carrier rate.
- **DoP literal reading:** I followed BPV-016 to the letter. No integer requirement, no check of source encoding or `dsdConvertedToPCM`, and the equalizer is ignored.
- **Bitstream:** the shared conditions are 003, 006 to 011 and 013. Shared mode with no other app playing is accepted, and resampling, encoding and equalizer aren't checked. The codec string is appended unchanged.
- **Failed readback (BPV-003):** a nil integer flag counts as an unconfirmed format and wins over BPV-016.
- **No-depth source (BPV-004):** a PCM source with nil bit depth has no integer-depth constraint; it only needs a float format to be at least 32 bits.
- **Integer mode (BPV-005):** I don't check that the physical format is integer, so a 32-bit float physical format with integer mode on can still be "BIT-PERFECT".
- **Label precedence:** concealed frames take priority over every other reason. The equalizer only decides the badge when everything else passes, so it never hides another failure.
- **Ruled-out inputs:** a negative concealed-frame count counts as none. −0.0 dB counts as 0 dB. A hog owner of −1 is never exclusive, even if `ownPID` is −1.
