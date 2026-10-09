# Hardware and loopback procedure

The harness stops at the HAL: it can show that the words Vespertine hands Core Audio are right, not what reaches a
DAC. These steps cover the rest. Each one names the claim it checks and what counts as a pass. Results go in a
device report (`.github/ISSUE_TEMPLATE/dac_report.yml`), with the tool output pasted in.

**Turn speakers and headphones down.** The test signals are at about -20 dBFS (noise for PCM, a 1050 Hz tone for
DSD), but a wrong setting can still play them loudly.

## What you need

- A Mac with Vespertine, and this repository for the tools (`python3` and `swift`, both on a stock Mac with the
  Command Line Tools).
- For P1, D1 and R1 to R3: any USB DAC; for D1 one with a DSD indicator and DoP support.
- For L1 to L3 and D2, one of:
  - an audio interface with a digital output and a digital input (S/PDIF or AES), the output cabled to the input,
    or with an internal digital loopback (RME TotalMix FX "Loopback", for example), recorded by a second app or a
    second Mac;
  - or a DAC with a digital output (some have S/PDIF out) into a recorder.
  A loopback that goes through a sample-rate converter (many S/PDIF inputs have one) can't pass L1; turn the SRC off.
- For B1: an AV receiver on HDMI or optical.

Generate the signals once:

```sh
python3 verification/hardware/signals.py make ~/vespertine-signals
```

This writes `pcm-44100-16.wav`, `pcm-48000-24.wav`, `pcm-96000-24.wav`, `pcm-192000-24.wav` (6 s of seeded
noise each), `gapless-a-48000-24.wav` + `gapless-b-48000-24.wav` (one signal split at a frame count no buffer size
divides), and `dsd64.dff`, `dsd128.dff` (4 s of DSD). Add them to Vespertine's library.

## P1. The signal path reads the device back (`CLAIMS.md#bp-readback`, `#bp-word-length`)

1. `swift verification/hardware/probe.swift` and note the DAC's line.
2. In Vespertine, select the DAC, exclusive mode on, integer mode on, and play `pcm-96000-24.wav`.
3. While it plays, run `probe.swift` again.

**Pass:** the DAC's nominal rate is 96000 Hz, its physical format is integer with at least 24 bits, hog is held by
Vespertine's PID, and the signal path view shows the same rate and depth. If the DAC doesn't offer 96 kHz, use a
rate it does offer and the matching file.

## R1. Each track at its own rate (`CLAIMS.md#rate-native`)

Play `pcm-44100-16.wav`, then `pcm-96000-24.wav`, then `pcm-192000-24.wav` (as far as the DAC goes), running
`probe.swift` during each. **Pass:** the nominal rate follows each file, and the DAC's own display (if it has one)
agrees.

## R2. The device is handed back on quit (`CLAIMS.md#rate-handback`)

1. Quit Vespertine. In Audio MIDI Setup set the DAC to a rate and format Vespertine won't use (44.1 kHz, 16-bit,
   say). Run `probe.swift` and keep the line.
2. Start Vespertine and play `pcm-96000-24.wav` with exclusive and integer mode on. Run `probe.swift`.
3. Quit Vespertine (Cmd-Q, not a force quit). Run `probe.swift`.

**Pass:** after quitting, the DAC's line matches step 1 exactly (rate, physical format) and hog is `none`. If
you've chosen a default rate in Vespertine's settings, it should be that instead. A force quit is not covered by the
claim; note what happens anyway.

## R3. A rate change behind Vespertine's back (`CLAIMS.md#rate-change-behind`)

While `pcm-96000-24.wav` plays without exclusive mode, change the DAC's rate in Audio MIDI Setup. **Pass:** the
signal path stops showing BIT-PERFECT (or Vespertine puts the rate back), within a second or two.

## D1. The DAC's DSD indicator (`CLAIMS.md#dop-indicator`)

Mark the DAC as DoP-capable in Vespertine, play `dsd64.dff`, then `dsd128.dff`. **Pass:** the DAC shows DSD64
and DSD128 (not PCM 176.4 or 352.8 kHz), the tone is clean and quiet, and the signal path reads "NATIVE DSD · DoP".
Pause, seek and resume a few times: the indicator never drops to PCM and there is no click (`#dop-continuity`).

## L1. PCM arrives bit for bit (`CLAIMS.md#bp-definition`, property b)

1. Route Vespertine to the loopback output; exclusive mode on, integer mode on, volume at 0 dB or hardware volume,
   no EQ, no ReplayGain. The signal path must read BIT-PERFECT.
2. Start recording the loopback input as integer PCM WAV, 24- or 32-bit, at the file's rate.
3. Play `pcm-48000-24.wav`, stop the recording a second after it ends.
4. `python3 verification/hardware/signals.py check capture.wav ~/vespertine-signals/pcm-48000-24.wav`

**Pass:** `BIT-EXACT`. Repeat for `pcm-44100-16.wav` and, where the loopback runs that fast, `pcm-96000-24.wav` and
`pcm-192000-24.wav`. Then turn digital volume to -1 dB and repeat once: the check must now FAIL and the badge must
have changed, which shows the check can see a change.

## L2. Integer mode off (`CLAIMS.md#float-24bit`)

Same as L1 with integer mode off (Core Audio's float path) for `pcm-48000-24.wav`. **Pass:** `BIT-EXACT`.
`pcm-44100-16.wav` should pass too.

## L3. Across a track boundary (`CLAIMS.md#gapless`)

Queue `gapless-a-48000-24.wav` then `gapless-b-48000-24.wav`, record both, and run

```sh
python3 verification/hardware/signals.py check capture.wav ~/vespertine-signals/gapless-a-48000-24.wav+$HOME/vespertine-signals/gapless-b-48000-24.wav
```

**Pass:** `BIT-EXACT` across the join: no sample missing, repeated or added.

## D2. DoP arrives bit for bit (`CLAIMS.md#dop-passthrough`, `#dop-bits`)

Needs a loopback that can record 24-bit at 176.4 kHz (352.8 kHz for DSD128). Mark the loopback output as
DoP-capable in Vespertine, record, play `dsd64.dff`, then

```sh
python3 verification/hardware/signals.py checkdop capture.wav ~/vespertine-signals/dsd64.dff
```

**Pass:** `DOP-EXACT`: markers alternate 0x05/0xFA on both channels and every DSD bit of the file is there.

## B1. A receiver decodes the bitstream (`CLAIMS.md#iec-scope`)

Not a bit-exactness check: the carrier itself is checked by `IEC61937-ORACLE.md`. Play
`dolby-digital-tones.ac3` and `dolby-digital-plus-tones.ec3` (in `Packages/VespertineKit/Tests/VespertineAudioTests/Fixtures`)
to an AV receiver with bitstream on. **Pass:** the receiver shows Dolby Digital / Dolby Digital Plus, and the tones
come from the right speakers (L 440 Hz, R 550, C 660, LFE 60, Ls 770, Rs 880; Fixtures/README.md). Dolby Digital
Plus needs HDMI.

## Recording the result

In the device report, list the steps run, paste each tool's last line, and name the interface, cable and recorder.
A FAIL is the useful part: say what the signal path showed at the time.
