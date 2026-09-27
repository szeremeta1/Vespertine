# Architecture

## From file to DAC

```
file ─▶ SFBAudioEngine decoder ─▶ [DoP / DSD→PCM wrapper] ─▶ [CUE region] ─▶ AVAudioConverter ─▶ ring buffer ─▶ HAL IOProc ─▶ DAC
         (libFLAC, TagLib…)                                                  Float32, SRC only        lock-free     C, no locks,
                                                                             when rates differ        SPSC          no allocation
```

1. **Probe.** `SourceOpener.probe` opens the file and reports its true `SourceFormat`: codec, lossless/lossy/DSD, rate, bit depth and channels.
2. **Plan.** `FormatPlanner.plan` (pure and unit-tested) combines the source with the device's `DeviceCapabilities` (discrete nominal rates, physical formats, DoP opt-in) and the per-device `RatePolicy`. It produces an `OutputPlan`: device rate, physical bit depth, PCM or DoP, and whether SRC or DSD→PCM conversion is needed.
3. **Configure.** `OutputSession` takes hog mode, sets the stream's physical format (preferring integer at the planned depth), sets and verifies the nominal rate, ensures a Float32 virtual format, and installs `nrt_device_ioproc`.
4. **Decode.** The engine thread pulls decoded audio through `AVAudioConverter`. With equal rates the converter only changes the sample format; integer PCM up to 24 bits maps exactly into Float32, which a unit test verifies sample-for-sample. With different rates it uses `AVSampleRateConverterAlgorithm_Mastering` at maximum quality.
5. **Render.** The IOProc copies from the ring buffer into the device buffer. Gain of exactly 1.0 is a straight copy. Any other gain is applied in double precision with TPDF dither at the DAC's word length. DoP is always passthrough.

## Gapless and format changes

When the current item has been fully decoded, the engine asks `nextItemProvider` for the next one (thread-safe via `QueueMirror`).

- If the new plan is device-compatible (same rate, depth, mode and channels), decoding simply continues into the same ring buffer, and a segment marker records where the new track begins.
- Otherwise the ring buffer drains, the device plays out its own buffer, and the session is reconfigured. That short gap is unavoidable, and every player has it.

Track changes are reported when the new segment becomes *audible*, not when it is decoded.

## Bit-perfect definition (`SignalPath.isBitPerfect`)

A path is marked bit-perfect only when all of these hold:

- The device profile can be bit-perfect (i.e. not Bluetooth or AirPlay).
- The device is held exclusively.
- No software gain is applied (neither ReplayGain nor digital volume).
- For PCM: the source is lossless, it isn't resampled or converted from DSD, the source is at most 24-bit, and the device's physical format can hold it (an integer format at least as deep as the source, or 32-bit float).
- For DoP: the carrier runs at the planned rate with at least 24 bits.

## Library

The library is SQLite via GRDB:

- The `track` table has generated sort and grouping columns, FTS5 search (accent-insensitive) and JSON columns for custom tags.
- Albums are aggregated in SQL rather than stored.
- `LibraryScanner` is incremental (it compares size and modification time), splits single-file CUE albums into region tracks, and flags vanished files as missing instead of deleting them.
- `TagWriter` writes tags with TagLib through SFBAudioEngine. Beforehand it takes an APFS clone of the file (free on the same volume) and stores the previous tags in `tagHistory` for revert.

## Threading

| Thread | Owns |
|---|---|
| Core Audio I/O | C only: ring read, gain, meters, tap |
| `Nocturne Engine` | decoders, converters, device configuration, segments |
| Main actor | UI and stores. The engine is controlled via posted commands and observed via a snapshot polled at ~15 Hz |
| GRDB | database reads and writes, with `ValueObservation` streaming changes to the UI |

## Known limits and roadmap

- **Integer mode.** Nocturne renders Float32 into the HAL, which is exact for sources up to 24 bits. 32-bit integer sources are rounded to Float32. A non-mixable integer virtual format ("integer mode") is on the roadmap for devices that expose one.
- **Resampler.** SRC uses Apple's mastering-quality converter. libsoxr is a candidate alternative.
- **DoP support** can't be detected from the device, so it is opt-in per device.
- **AirPods Max 2 detection.** Detection is by name and transport ("AirPods Max" + USB), so AirPods Max 2 match as long as their name contains "AirPods Max".
