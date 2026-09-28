# Architecture

## From file to DAC

```
file ─▶ SFBAudioEngine decoder ─▶ [DoP / DSD→PCM wrapper] ─▶ [CUE region] ─▶ AVAudioConverter ─▶ ring buffer ─▶ HAL IOProc ─▶ DAC
         (libFLAC, TagLib…)                                                  Float32, SRC only        lock-free     C, no locks,
                                                                             when rates differ        SPSC          no allocation
```

1. **Probe.** `SourceOpener.probe` opens the file and reports its true `SourceFormat`: codec, lossless/lossy/DSD, rate, bit depth and channels.
2. **Plan.** `FormatPlanner.plan` (pure and unit-tested) combines the source with the device's `DeviceCapabilities` (discrete nominal rates, physical formats, DoP opt-in) and the per-device `RatePolicy`. It produces an `OutputPlan`: device rate, physical bit depth, PCM or DoP, and whether SRC or DSD→PCM conversion is needed.
3. **Configure.** `OutputSession` takes hog mode only in exclusive mode (shared is the default, so the device can stay the Mac's sound output), sets the stream's physical format (preferring integer at the planned depth), sets and verifies the nominal rate, ensures a Float32 virtual format, and installs `nrt_device_ioproc`. `DeviceRestore` remembers each device's format before the first change, so it can be put back when Nocturne quits.
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
- The device is held exclusively, or (shared mode) no other process is currently sending audio to it (Core Audio process objects, checked about once a second).
- No Spatial Audio rendering or downmix.
- No software gain is applied (neither ReplayGain nor digital volume).
- For PCM: the source is lossless, it isn't resampled or converted from DSD, the source is at most 24-bit, and the device's physical format can hold it (an integer format at least as deep as the source, or 32-bit float).
- For DoP: the carrier runs at the planned rate with at least 24 bits.

## Library

The library is SQLite via GRDB:

- The `track` table has generated sort and grouping columns, FTS5 search (accent-insensitive) and JSON columns for custom tags.
- Albums are aggregated in SQL rather than stored.
- `LibraryScanner` is incremental (it compares size and modification time), splits single-file CUE albums into region tracks, and flags vanished files as missing instead of deleting them: they disappear from every list, playlists included, and come back with their analyses if the files return. A scan interrupted by a dropped share marks nothing missing.
- Genres are normalized in `Genres` (case, accents, hyphens, slash order, ID3 numbers, localized Apple names) for browsing, filters and search.
- Smart playlist rules compile to SQL; sample rates are entered in kHz, and a rule without a usable value matches nothing.
- `TagWriter` writes tags with TagLib through SFBAudioEngine. Beforehand it takes an APFS clone of the file (free on the same volume) and stores the previous tags in `tagHistory` for revert.

## Multichannel and Spatial Audio

`FormatPlanner` sends every channel to devices that can carry them (following the speaker layout from Audio MIDI Setup, and counting an HDMI receiver's channel capacity even in 2-channel mode), downmixes by channel layout on stereo devices, and on AirPods and Beats renders the channels with Apple's spatial mixer (`AUSpatialMixer`, head tracked or fixed) inside the I/O callback, through a C hook, so head tracking responds instantly.

## Network shares

- `NetworkVolume` mounts with NetFS: soft, read-only by default, hidden from the Finder sidebar, in `/Volumes`. Current macOS refuses mounts inside an app's Application Support folder (protected app data), so mounting there would work once and never again.
- Passwords are internet-password items in the **login** keychain (queried explicitly: an app's plain SecItem calls go to the data-protection keychain, where Finder's share passwords never are).
- `NetworkShareManager` heals connections: it reconnects on launch, wake and network changes, remounts a share that disappeared, force-remounts one that is still listed but no longer answers, and rescans connected shares every 30 minutes (and after the server's analysis run), never while music plays from them. File-system events don't cross the network; these rescans are how additions and deletions on the server appear.
- Playback from a share buffers more before starting, holds in silence and resumes exactly where it stopped if reads stall, and gets priority over caching and analysis.

## File analysis

The analysis core lives in `Packages/NocturneAnalysis` (plain Swift and Foundation): spectra (Accelerate on Apple platforms, a portable FFT elsewhere, tested to agree), the forensic measurements, a chunk-independent sample accumulator and the verdicts. The app decodes with SFBAudioEngine and feeds it. On a server, `nocturne-analyze` decodes with ffmpeg and feeds the same core, writing `<share>/.nocturne/analysis.jsonl`; the app imports matching records (path, size, modification time) and leaves that share's files to the server. See [ANALYSIS.md](ANALYSIS.md).

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
- **AirPods Max over USB-C.** macOS keeps the AirPods on their *Bluetooth* Core Audio device even when audio flows over the cable. Bluetooth stays connected as the control link, and the cable can't be used without it. The HAL exposes no "USB" property for this, so Nocturne treats the path as USB-C lossless when the AirPods' `AirPods Max USB Audio` interface is present in the IORegistry. (Measured on hardware: output latency is 480 frames / 10 ms, as expected of USB.) The device also lists a 24 kHz rate, but that is the mono hands-free format, and the planner ignores rates that can't carry the source's channel count. AirPods Max 2 match as long as their name contains "AirPods Max".
