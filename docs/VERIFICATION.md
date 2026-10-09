# Checking that Vespertine is bit-perfect on your hardware

“Bit-perfect” is a claim you can check, not something to take on trust. This page covers:

- what Vespertine means by it,
- what the app reads back from macOS to decide it,
- the automated tests behind it,
- and three ways to confirm it on your own DAC, the last of which needs no software from us at all.

## Tested hardware and experimental paths

Playback has been checked on a FiiO K11 at rates up to 384 kHz, including DoP and integer mode; AirPods Max over USB-C and Bluetooth; and MacBook Pro speakers. The Intel build has run under Rosetta, not on an Intel Mac. DoP carrier rates above 384 kHz have not been tested on hardware. DSD64–512 file decoding is not proof of native DSD output at every rate.

Receiver bitstream and channel-for-channel multichannel DAC output are experimental, untested on real receivers/multichannel DACs; reports wanted. Routing is covered by automated tests and a six-channel aggregate-device check; IEC 61937 carriers are checked with FFmpeg's S/PDIF reader. Those checks do not establish receiver or interface compatibility.

## What the claim covers

Vespertine shows **BIT-PERFECT** only when every sample of the file reaches the device's input unaltered. That requires all of the following, checked on each track (`SignalPath.isBitPerfect` in `Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift`):

- **The source is PCM** and plays at its own sample rate. Nothing is resampled and no DSD is converted to PCM.
- **The device runs at that rate.** Vespertine switches the device's nominal rate and reads it back from Core Audio. It doesn't trust its own request.
- **The device's physical format holds the whole sample.**
  - An integer DAC needs at least the file's bit depth.
  - A float device needs a full 32-bit float.
  - In the normal float pipeline, up to 24 bits pass through exactly. 32-bit integer files need **integer mode**, which sends 32-bit integers to DACs that offer an integer format.
- **No gain is applied anywhere in software.**
  - Volume is either the DAC's own hardware control or fixed.
  - Digital volume must be off or at exactly 0 dB.
  - ReplayGain must be off or at 0 dB.
- **No spatial or channel processing is applied.** The device has at least as many channels as the file.
- **Nothing else is mixed in.**
  - Either Vespertine has the device to itself (exclusive "hog" mode),
  - or no other app is playing to it at the same moment.
- **The device class can be bit-perfect at all.**
  - Bluetooth devices never can, because macOS re-encodes the audio for the radio link. AirPlay can't either. For these, Vespertine says what it does instead: resampled, spatialised, and so on.
  - The one exception is AirPods Max with the USB-C cable connected. macOS keeps listing them as a Bluetooth device, but the audio runs over the cable as lossless 24-bit / 48 kHz. Vespertine detects the cable through the IORegistry (`DeviceProfile.swift`) and treats 48 kHz files as bit-perfect on that device. This is the one claim on this page that a loopback test can't confirm, because AirPods have no digital output: it rests on Apple's description of the USB-C path, and on what the app reads back.

If any condition fails, the badge says what changed instead of BIT-PERFECT. DSD over DoP and the experimental Dolby/DTS bitstream path have their own badges and their own conditions (`NATIVE DSD · DoP`, `BITSTREAM · …`).

## 1. What the app reads back

Open the inspector's **Now Playing** panel. Its **Signal Path** section lists each step from file to device. The device values are read from Core Audio after playback starts:

- **Nominal rate.** The device's current sample rate (`kAudioDevicePropertyNominalSampleRate`).
- **Physical format.** What the device's output stream is really running: integer or float, bit depth, channel count and rate (`kAudioStreamPropertyPhysicalFormat`).
- **Exclusive or shared.** Exclusive means Vespertine holds the device in hog mode (`kAudioDevicePropertyHogMode`). The probe prints the owning process ID, which should be Vespertine's own.
- **Volume stage.** Hardware, fixed, or digital. Digital shows its dB.

The same readback is printed by the command-line probe (see below). You can also compare it with **Audio MIDI Setup** while a track plays: the device's format there should match the file's rate.

## 2. The automated tests

Run `swift test` in `Packages/VespertineKit`. The tests that bear on bit-perfection play generated signals through the real engine code and compare the output sample for sample. They don't compare levels or spectra.

| Test | What it proves |
|---|---|
| `RingBufferTests` “Unity gain is bit-transparent for every 24-bit value pattern” | the float path carries every possible 24-bit sample unchanged at unity gain |
| `RingBufferTests` “Integer mode copies every 32-bit word untouched…” | integer mode passes each 32-bit word through, including patterns that would be NaN as floats |
| `IntegerModeTests` “A 32-bit integer source reaches the output word for word”, “A 24-bit source arrives as its samples in the top 24 bits, nothing added” | the integer path end to end, from decoder to output buffer |
| `DSDTests` “DoP from the raw stream carries the DSD bits exactly, with alternating markers” | DSF and DSDIFF DSD bits survive DoP packing exactly, and the markers a DAC looks for alternate correctly |
| `BitstreamTests` “The carrier for a file holds its frames exactly, at the right rate” | Dolby/DTS frames go out byte for byte inside the IEC 61937 carrier |
| `StreamingTests` “Moving to the local copy mid-track continues sample for sample” | switching from the network share to the cached copy mid-track doesn't drop or repeat a sample |
| `RingBufferTests` “Muted, the output is silent at once…” and “Rebuffering holds in silence without consuming…” | mute and rebuffering never alter or skip music; they only insert silence where playback is actually held |

Tests that use real hardware are opt-in, because they open your audio devices (`HardwareAuditTests`):

```sh
VESPERTINE_HARDWARE_TESTS=1 swift test --filter HardwareAuditTests
VESPERTINE_HARDWARE_TESTS=1 VESPERTINE_INTEGER_DEVICE="<part of your DAC's name>" swift test --filter HardwareAuditTests
```

The integer-device test plays a 32-bit source to your DAC. It passes only if the device's physical format reads back as 32-bit integer and the signal path reports BIT-PERFECT. The rate-change test plays a 96 kHz file in shared mode, switches the device to 48 kHz behind the engine's back (as Audio MIDI Setup does), and passes only if the song keeps its speed and the signal path names the rate the device really runs at; it uses the DAC named in `VESPERTINE_INTEGER_DEVICE`, or the built-in output. The hardware tests play silence or near-silence, so they're safe to run with speakers connected; quit Vespertine first, since a device it holds exclusively can't be opened or switched by the tests.

## 3. The probe

`vespertine-probe` builds with the package (`swift run vespertine-probe …` in `Packages/VespertineKit`).

```sh
vespertine-probe list
vespertine-probe play "<device name or UID>" 20 <file> [file…]
vespertine-probe watch 30
vespertine-probe doptest "<DoP DAC name>"
```

- **`list`** shows every output device with:
  - transport (USB, built-in, Bluetooth…),
  - whether its class can be bit-perfect,
  - the sample rates and physical formats it offers.
- **`play`** plays the files on the device for the given number of seconds. It then prints the signal path Vespertine computed, next to an independent Core Audio readback of nominal rate, physical format and hog owner, so you can check that the two agree.
- **`watch`** prints every device's volume and the system output whenever they change. Use it to catch another app or macOS changing the device mid-play.
- **`doptest`** plays DSD over DoP on the device (it turns DoP on for it, and writes two DSD64 test files of soft pings if you give it none). It pauses, seeks and skips on a schedule, prints what to listen for at each step, and checks that the device keeps running through them. The DAC should stay in DSD the whole time: no click, no missing ping. Only the resume after the last, long pause (the device is let go after `VESPERTINE_RELEASE_AFTER` seconds, 15 by default) and the stop may click.

## 4. Checking it outside Vespertine

These methods don't depend on anything Vespertine reports.

**DTS-CD or DoP indicator test (no extra hardware beyond what you own).**

The receiver path below is experimental, untested on real receivers/multichannel DACs; reports wanted. This is a proposed check for your setup, not a result already measured by the developer.

- A DTS-encoded audio CD rip (a `.wav` that is really a DTS stream) only turns into surround on an AV receiver if the stream arrives unprocessed. Any gain change, dither, resampling or mixing scrambles it, and the receiver plays white noise or refuses the stream.
- To test: play such a file from Vespertine as **PCM** (bitstream off) over optical or HDMI to a receiver. If the receiver shows DTS, nothing on that path processed the samples. (It's a test for processing, not proof against every possible bit error: the null test below is the rigorous one.)
- The same principle works with DSD: a DAC lights its DSD indicator for DoP only when the DoP marker bytes arrive untouched. Any gain or resampling destroys them, so a lit indicator rules out processing (the DAC checks the markers, not every DSD bit).

**Digital loopback null test (the rigorous one).**

1. Connect a digital output (S/PDIF optical or coaxial, or an audio interface's digital out) to a digital input. That can be a second interface or the same interface's own input.
2. Play a test file from Vespertine to the output while recording the input at the same sample rate and bit depth, for example in Audacity or with `sox`.
3. Trim the recording to the start of the file and subtract it from the original: invert one and mix, or use `sox -m -v -1`.

A bit-perfect path nulls to digital silence, every sample exactly zero. Any residual means something in the chain changed the audio. Remember the S/PDIF link itself carries at most 24 bits.

**Hash comparison (same setup).**

1. Record the loopback to a WAV at the file's format.
2. Cut both to the same sample range.
3. Compare checksums of the raw sample data (for example with `ffmpeg -i x.wav -f s24le - | shasum`). Equal hashes mean identical samples.

## What bit-perfect doesn't cover

- **It is a statement about the samples, not the sound.** It says nothing about the DAC's analogue output quality.
- **macOS limits.**
  - Bluetooth links, AirPlay and spatial audio are never bit-perfect, and Vespertine says so. (AirPods Max on the USB-C cable are not on the Bluetooth link; see above.)
  - In shared mode, another app playing to the same device gets mixed in. Vespertine looks for this about once a second, through Core Audio's list of processes that are playing to the device (`DeviceControl.otherProcessesPlaying`), and drops the badge when it finds one. A sound shorter than that can slip past, and so can anything Core Audio doesn't list. Exclusive mode prevents mixing altogether.
- **What happens inside the device.** macOS tells an app the format it sends to a device, not what the device does with it. A DAC's own hardware volume is not counted as changing the samples (that is the point of using it), and any DSP in the DAC, the headphones or the speakers is invisible to Vespertine.
- **The float path.** Files wider than 24 bits are rounded unless integer mode is on and the DAC offers a 32-bit integer format.

If your measurement disagrees with what Vespertine shows, please open an issue with:

- the `vespertine-probe play` output,
- your device,
- the file's format.
