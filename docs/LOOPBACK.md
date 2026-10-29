# Loopback test (software check)

The loopback test plays a test signal through Vespertine and records it back through a virtual loopback device. It then compares every sample with what was played. It is in **Settings › Playback › Loopback Test…** and **Controls › Loopback Test…**, and on the command line as `vespertine-probe loopback`.

Results are always labelled **Loopback (software check)**. The BIT-PERFECT badge never depends on them.

## What it proves

A bit-exact result shows that for that format, on that Mac, with that macOS and Vespertine version, these steps delivered every sample unchanged to a virtual device:
- the real decoder, reading a WAV file;
- Vespertine's playback engine, including gapless joins and switching from 16-bit to 24-bit;
- the Core Audio output.

It catches the faults a software player can introduce:
- dropped or inserted frames
- gain changes
- dither
- truncation to fewer bits
- channel swaps and inverted polarity
- a resampler left on

## What it doesn't prove

- **Nothing about your DAC, cable or any hardware.** The samples go to a virtual device in the Mac. What a real DAC receives over USB, and what it does with the samples, is outside this test.
- **Nothing about other formats or settings.** Each case forces EQ, digital volume, ReplayGain, Spatial Audio, bitstream and downmix off and matches the output rate to the source. The report lists the settings used. Results are kept per device, format, settings, macOS version and Vespertine version. The signal path only shows a result from the same macOS and Vespertine version.
- **Nothing about the virtual device's limits.** BlackHole carries 32-bit float, so 16-bit matching reports "no 16-bit mode" and the 32-bit integer case is skipped.

## Setting it up

The test plays full-scale noise. To keep that away from speakers and headphones, it refuses every output that isn't a virtual device.

The dedicated device is a separate 2-channel copy of [BlackHole](https://github.com/ExistentialAudio/BlackHole) named **Vespertine Loopback**, so a BlackHole you already use isn't touched. To install it from Vespertine's source:

```sh
scripts/install-loopback-device.sh          # builds and installs it (asks for your password)
scripts/install-loopback-device.sh --remove # uninstalls it
```

Any other virtual device works too, as long as nothing else plays to it or records from it during the test. macOS asks once for permission to record, because the test reads the loopback device's input. The loopback test never records a microphone; only Room Correction's measurement does, while you run one.

## Running it

- **Quick** (about 10 seconds): 24-bit at 44.1 and 96 kHz, 16-bit at 44.1 kHz and a gapless pair.
- **Full** (one to two minutes): every common rate from 44.1 to 384 kHz that the device offers. Each rate gets 24-bit, 16-bit padded, 16-bit matched and 32-bit integer mode. A gapless pair and a 16-bit to 24-bit switch are added at the first rate.

Playback pauses while the test runs. The test uses its own engine and puts the device's sample rate back afterwards. **Copy Report** puts a Markdown report on the clipboard. It lists every case, the settings used and, for anything that failed, each channel.

From the command line, unattended:

```sh
vespertine-probe loopback --full --json loopback.json --markdown loopback.md
```

The options are `--quick` (the default), `--device <name>`, `--input <name>` and `--rates 44100,96000`. The exit code is:
- 0: every case was bit-exact
- 1: a case failed
- 2: a test setup problem, or every case was skipped

## How it works

For each channel, the signal has these parts, in order:
1. silence
2. a start sync: a maximum-length sequence at half of full scale, with a different polynomial for each channel
3. an edge block: full scale, the smallest steps and sign patterns
4. about two seconds of seeded random samples at the file's full bit depth
5. the start sync reversed, as an end sync
6. silence again

The gapless case splits the signal into two files in the middle of the random part.

The analyzer:
- Finds each channel with FFT cross-correlation. The peak must be above 0.9 and the next-highest peak below 0.2.
- Measures how far the end sync moved.
- Compares every sample, then names the difference: gain, dither, k-bit truncation, dropouts or lost frames, or clocks that aren't locked.

Some results say nothing about Vespertine, so they are reported as a **test setup problem**:
- no signal reached the input;
- the signal couldn't be found in the recording;
- the recorder skipped (a discontinuity in its timestamps);
- the clocks weren't locked.

The analyzer is pure Swift. Its tests inject each of these faults. See `LoopbackSignal.swift`, `LoopbackAnalysis.swift` and `Loopback.swift`.

## Later options

These would cover what this test can't. Neither is planned yet.

- **Hardware digital loop.** An interface's S/PDIF or AES output cabled to a digital input would check the whole path to a real device's output, at up to 24 bits. Today you can do this by hand: see the [verification guide](VERIFICATION.md#4-checking-it-outside-vespertine).
- **Analog measurement.** Recording a DAC's analog output with a measurement interface shows noise, distortion and frequency response. That is a DAC's sound quality, not whether the samples arrived bit for bit.
