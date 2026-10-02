# Architecture

## From file to DAC

```
file ─▶ SFBAudioEngine / FFmpeg ─▶ [DoP / DSD→PCM wrapper] ─▶ [CUE region] ─▶ AVAudioConverter ─▶ ring buffer ─▶ HAL IOProc ─▶ DAC
         (libFLAC, TagLib…)                                                  Float32, SRC only        lock-free     C, no locks,
                                                                             when rates differ        SPSC          no allocation
```

1. **Probe.** `SourceOpener.probe` opens the file and reports its true `SourceFormat`: codec, lossless/lossy/DSD, rate, bit depth and channels.
2. **Plan.** `FormatPlanner.plan` (pure and unit-tested) combines the source with the device's `DeviceCapabilities` (discrete nominal rates, physical formats, DoP opt-in) and the per-device `RatePolicy`. It produces an `OutputPlan`: device rate, physical bit depth, PCM or DoP, and whether SRC or DSD→PCM conversion is needed.
3. **Configure.** `OutputSession` takes hog mode only in exclusive mode (shared is the default, so the device can stay the Mac's sound output), sets the stream's physical format (preferring integer at the planned depth), sets and verifies the nominal rate, ensures a Float32 virtual format, and installs `nrt_device_ioproc`. `DeviceRestore` remembers each device's format before the first change, so it can be put back when Vespertine quits.
4. **Decode.** The engine thread pulls decoded audio through `AVAudioConverter`. With equal rates the converter only changes the sample format; integer PCM up to 24 bits maps exactly into Float32, which a unit test verifies sample-for-sample. With different rates it uses `AVSampleRateConverterAlgorithm_Mastering` at maximum quality.
5. **Render.** The IOProc copies from the ring buffer into the device buffer. Gain of exactly 1.0 is a straight copy. Any other gain is applied in double precision with TPDF dither at the DAC's word length. DoP is always passthrough.

Every decoder is wrapped in `GuardedDecoder`, which calls it through `CVespertineGuard` (Objective-C++). A C++ or Objective-C exception thrown inside a codec library, such as Monkey's Audio seeking in a truncated file, becomes an ordinary "won't play" error instead of ending the process.

## DSD

DSF and DSDIFF open through FFmpeg at any rate from DSD64 to DSD512 (SFBAudioEngine's readers stop at DSD128, and its DSD→PCM at DSD64). For DoP, `RawDoPDecoder` reads the raw DSD bytes (`nff_read_dsd`; DSF is planar and LSB-first, DSDIFF interleaved and MSB-first) and packs 16 bits per channel into each 24-bit frame with alternating 0x05/0xFA markers, so the DAC runs at a sixteenth of the DSD rate (176.4 kHz for DSD64). DoP is planned only when the DAC is marked DoP-capable and supports that carrier rate; otherwise FFmpeg converts DSD to PCM at an eighth of the DSD rate and the planner resamples as needed.

DoP frames are passthrough, so meters and the spectrum can't read them as PCM. With `nrt_context_set_dop`, the render context reads the DSD bits in each frame instead: a triangular window over the current and previous frame's 16 bits (a sinc² decimation by 16) gives a level for the meters and the spectrum tap, and the inspector's spectrum stops at 20 kHz for DoP. The frames themselves are never modified; a test checks they come out bit-identical.

## Format badges

`FormatMark` (VespertineLibrary) names a track's or album's format for badges: Dolby Atmos (with what carries it), Dolby TrueHD, Dolby Digital Plus, Dolby Digital, DTS-HD Master Audio, DTS:X, DTS, DSD64–DSD512, Hi-Res Lossless or Lossless. The badge is plain text in the app's own style. Dolby's and DTS's logos are trademarks licensed only with certified products, and Vespertine's TrueHD and DTS decoders (FFmpeg) are not licensed, so the logos aren't used.

## Gapless and format changes

When the current item has been fully decoded, the engine asks `nextItemProvider` for the next one (thread-safe via `QueueMirror`).

- If the new plan is device-compatible (same rate, depth, mode and channels), decoding simply continues into the same ring buffer, and a segment marker records where the new track begins.
- Otherwise the ring buffer drains, the device plays out its own buffer, and the session is reconfigured. That short gap is unavoidable, and every player has it.

Track changes are reported when the new segment becomes *audible*, not when it is decoded.

A queue change (shuffle, repeat, edits) never touches the audible track. If the next track has already been decoded into the ring, `nrt_ring_rewind` takes that look-ahead back, but only when it is still well ahead of the reader (the larger of 250 ms and four I/O buffers). The engine then asks `nextItemProvider` again. When the look-ahead is too close to be taken back safely, it plays, and the new order applies from the track after it.

## DTS CDs

A DTS CD (or DTS-WAV) stores a DTS bitstream as 16-bit stereo PCM, usually in 14-bit words. Played as PCM, it is full-scale noise. When `SourceOpener.probe` opens a 16-bit stereo 44.1/48 kHz lossless file, it looks for a DTS sync word in the first 8,192 frames (`ndts_find_sync`). If it finds one, it wraps the file's decoder in `DTSDecoder`. That decoder feeds the words, as stored, to FFmpeg's `dca` parser and decoder (the `CVespertineDTS` shim over `Vendor/FFmpegDCA.xcframework`, built by `scripts/build-dts-decoder.sh` with only the DTS, TrueHD/MLP, Dolby Digital (Plus) and DSD decoders). Output is Float32 in the stream's own channel order, with a layout from its channel mask.

Positions stay in the carrier's frames: a DTS CD holds one 512-sample frame per 512 carrier frames. So CUE indexes, seeks and durations are unchanged. Carrier frames before the first sync word are silence. A seek re-syncs a little before the target and drops the surplus decoded frames. The source is reported as lossy "DTS" with its real channel count, so the planner routes it as surround or Spatial Audio. A test checks the decode of a real DTS CD against FFmpeg's, bit for bit.

## Dolby, TrueHD and DTS-HD

- **Dolby Digital / Dolby Digital Plus** decode through macOS's licensed decoders (`.ac3`/`.ec3` are routed to the Core Audio decoder, which the MP3 decoder would otherwise claim by extension). A Dolby Digital Plus file carries Atmos objects (JOC) when Core Audio lists `ec+3` formats for it (5.1.2 up to 9.1.6). The codec is then "Dolby Atmos".
- **Dolby Atmos.** macOS doesn't expose object rendering through its public decode APIs: AudioConverter, ExtAudioFile and AVAssetReader all give the 5.1 bed with silent heights, which was checked on Apple's Atmos sample stream. So by default `SystemRendererSession` hands the untouched Dolby Digital Plus frames (AVAssetReader, compressed) to `AVSampleBufferAudioRenderer` on the chosen device, with a render synchronizer for position, pause and seek. macOS renders the objects for the output, as Apple Music does. With `atmosBySystem` off, the bed plays through Vespertine's own engine.
- **DTS / DTS-HD MA / Dolby TrueHD** in `.dts`, `.dtshd`, `.thd`, `.mlp` and `.mka` decode through FFmpeg (`CVespertineFF`, `FFmpegDecoder`). Lossless ones are reported as PCM with their bit depth. A test checks TrueHD decodes identically to the 24-bit source it was encoded from.

## Bitstream (IEC 61937)

On outputs marked as having a receiver (`bitstreamDeviceUIDs`), Dolby and DTS-CD sources plan as mode `.bitstream`: exclusive, exact rate, integer ≥ 16-bit, no gain. `BitstreamDecoder` wraps Dolby Digital frames in 1536-frame bursts at the stream's rate (Pd in bits). It groups Dolby Digital Plus frames into six-block bursts of 6144 frames at four times the rate (Pd in bytes, so HDMI only). DTS CDs go out as stored. The carriers are checked with FFmpeg's S/PDIF demuxer, which decodes them identically to the original files. A gapless transition into an Atmos track that macOS renders drains the ring first, then hands over.

## Integer mode

With `integerMode` and exclusive access, plain PCM that needs no processing plans with `integerSamples`: no resampling, Spatial Audio, downmix, digital volume or ReplayGain, on a device with a non-mixable Int32 physical format. `OutputSession` switches the physical format to non-mixable Int32; setting only the virtual format is accepted but ignored by USB Audio Class DACs such as the FiiO K11. The converter then decodes straight to Int32. The ring carries those words in its float slots, and the IOProc copies them as integers, including ones that would be NaN as floats, while meters read them as integers. So 32-bit sources are bit-perfect. The device is put back on mixable Float32 when the session ends.

## Output device

With a specific output chosen (`EngineSettings.deviceUID`), the engine never substitutes another device. If that device isn't listed, or won't start, when playback begins, the item is parked and the engine waits for it (`waitingForDevice` in the snapshot) for up to 60 s. It re-checks on every Core Audio device-list change and twice a second, and starts playback as soon as the device is back. If the device disappears mid-song, it waits the same way. This covers AirPods Max, whose Core Audio device is removed while they're off your head and re-published a few seconds after they're back on, often after their "play" command has already arrived. Pause cancels the wait. With *System Output* chosen, the engine follows the Mac's default output as before.

### Switching and skipping

- **Instant silence.** Skip, seek, pause, stop and a change of output set `nrt_context_set_muted` from the caller's thread: the IOProc plays silence and takes nothing from the ring. The old song stops at once even while the engine thread is busy (a network read can take seconds, and the ring holds 20–30 s). The engine clears the mute when it starts or resumes playing; because nothing was consumed, a pause or output change resumes exactly where it went quiet.
- **Output changes keep the file open.** `restartFromCurrentPosition` hands the song's open decoder to the restart (`carried`), which seeks it back to the playback position when the new output needs the same kind of decoding (PCM stays PCM). Only the output session and converter are rebuilt, so a switch takes a few hundred milliseconds even on a busy share, instead of reopening and re-analysing the file.
- **Commands go first.** The start-up prefill stops as soon as another command is waiting, several output changes in one batch restart playback once, and a retry for an output that isn't ready reuses the file already probed.
- **Probing is small.** FFmpeg-opened files (DTS, TrueHD, Matroska, DSD) are analysed from their first 256 KB / 0.1 s; their headers and first frames describe them fully.

## Bit-perfect definition (`SignalPath.isBitPerfect`)

A path is marked bit-perfect only when all of these hold:

- The device profile can be bit-perfect (i.e. not Bluetooth or AirPlay).
- The device is held exclusively, or (shared mode) no other process is currently sending audio to it (Core Audio process objects, checked about once a second).
- No Spatial Audio rendering or downmix.
- No software gain is applied (neither ReplayGain nor digital volume).
- For PCM: the source is lossless, it isn't resampled or converted from DSD, the source is at most 24-bit (32-bit with integer mode, which skips the Float32 step), and the device's physical format can hold it (an integer format at least as deep as the source, or 32-bit float).
- For DoP: the carrier runs at the planned rate with at least 24 bits.

## Library

The library is SQLite via GRDB:

- The `track` table has generated sort and grouping columns, FTS5 search (accent-insensitive) and JSON columns for custom tags.
- Albums are aggregated in SQL rather than stored.
- `LibraryScanner` is incremental (it compares size and modification time), splits single-file CUE albums into region tracks, and flags vanished files as missing instead of deleting them: they disappear from every list, playlists included, and come back with their analyses if the files return. A scan interrupted by a dropped share marks nothing missing.
- Moved and renamed files (a library manager such as Lidarr reorganizing a share) are recognized at the end of each scan. `reconcileMovedTracks` pairs each missing track with a new one of the same size, duration and title (the same file, moved). For a file whose tags were rewritten on the way, it instead uses the same title, artist, track, disc, format and duration. A pair must be unambiguous on both sides. The new entry takes over the old one's playlist entries, play count, rating, date added, tag history and, for an unchanged file, its analysis. The stale entry is dropped, and the play queue is repointed at the new files. When a song fails to play because its file is gone, its source is rescanned at once (at most every two minutes), even during playback.
- Genres are normalized in `Genres` (case, accents, hyphens, slash order, ID3 numbers, localized Apple names) for browsing, filters and search.
- Every page has its own filter (`LibraryFilter`): format, sample rate, bit depth, channels, analysis verdict, genre, decade, artist and source, plus the 24-bit, 88.2 kHz-and-up, multichannel and favorites conditions. Choices within one facet widen the match and facets narrow it. The album query also aggregates every format, rate, depth, layout, verdict and source among an album's tracks (`FilterFacts`), so album pages filter without reading tracks. An album matches a facet when any of its tracks does. Playing or shuffling a filtered album page plays those albums' songs that pass the per-song facets (format, layout, verdict, source, favorites); when a song has several versions, only the passing versions are candidates. A page opened from a filtered one (an artist from Artists, a genre from Genres) starts with its filter.
- Smart playlist rules compile to SQL; sample rates are entered in kHz, and a rule without a usable value matches nothing.
- `TagWriter` writes tags with TagLib through SFBAudioEngine. Beforehand it takes an APFS clone of the file (free on the same volume) and stores the previous tags in `tagHistory` for revert.

## Multichannel and Spatial Audio

`FormatPlanner` sends every channel to devices that can carry them (following the speaker layout from Audio MIDI Setup, and counting an HDMI receiver's channel capacity even in 2-channel mode), downmixes by channel layout on stereo devices, and on AirPods and Beats renders the channels with Apple's spatial mixer (`AUSpatialMixer`, head tracked or fixed) inside the I/O callback, through a C hook, so head tracking responds instantly.

## Network shares

- `NetworkVolume` mounts with NetFS: soft, read-only by default, hidden from the Finder sidebar, in `/Volumes`. Current macOS refuses mounts inside an app's Application Support folder (protected app data), so mounting there would work once and never again.
- Passwords are internet-password items in the **login** keychain (queried explicitly: an app's plain SecItem calls go to the data-protection keychain, where Finder's share passwords never are).
- `NetworkShareManager` heals connections: it reconnects on launch, wake and network changes, remounts a share that disappeared, force-remounts one that is still listed but no longer answers, and rescans connected shares every 30 minutes (and after the server's analysis run), never while music plays from them. File-system events don't cross the network; these rescans are how additions and deletions on the server appear.
- Playback from a share buffers more before starting, holds in silence and resumes exactly where it stopped if reads stall (after 5 s are buffered again), and gets priority over caching and analysis.
- The output ring holds about 20–30 s of audio: `OutputSession.ringFrames` is a power of two within a 96 MB budget, never under 5 s. A share whose server is busy (on a loaded HDD pool, a single read can wait several seconds) never drains it. The cache copies the playing track first, 2 s after it starts. Once the copy is complete, `PlaybackEngine.reopen` opens it at exactly the decoder's frame and swaps it in under the converter, so the rest of the track is read locally. A unit test checks the result is byte-identical to continuous decoding for FLAC and WAV. This happens only where a seek can't change the output (lossless PCM and DoP). Lossy decoders and DSD→PCM carry state across a seek, so those tracks finish from the share. `EngineSnapshot.readingFromShare` shows which source is in use.
- The share health check doesn't count a slow answer as a dead mount while the cache is still receiving data (a remount would cut off what's playing).

## File analysis

The analysis core lives in `Packages/VespertineAnalysis` (plain Swift and Foundation): spectra (Accelerate on Apple platforms, a portable FFT elsewhere, tested to agree), the forensic measurements, a chunk-independent sample accumulator and the verdicts. The app decodes with SFBAudioEngine and feeds it. On a server, `vespertine-analyze` decodes with ffmpeg and feeds the same core, writing `<share>/.vespertine/analysis.jsonl`; the app imports matching records (path, size, modification time) and leaves that share's files to the server. See [ANALYSIS.md](ANALYSIS.md).

## Threading

| Thread | Owns |
|---|---|
| Core Audio I/O | C only: ring read, gain, meters, tap |
| `Vespertine Engine` | decoders, converters, device configuration, segments |
| Main actor | UI and stores. The engine is controlled via posted commands and observed via a snapshot polled at ~15 Hz |
| GRDB | database reads and writes, with `ValueObservation` streaming changes to the UI |

## Known limits and roadmap

- **Integer mode** needs exclusive access and a DAC with a non-mixable Int32 format. Elsewhere Vespertine renders Float32, which is exact up to 24 bits.
- **Object audio.** Atmos in Dolby Digital Plus is rendered by macOS. Atmos in TrueHD and DTS:X play their lossless channel bed; their objects need a receiver, and macOS gives apps no way to send TrueHD or DTS-HD MA over HDMI (no high-bit-rate passthrough).
- **DSD in WavPack** isn't supported.
- **Resampler.** SRC uses Apple's mastering-quality converter. libsoxr is a candidate alternative.
- **DoP support** can't be detected from the device, so it is opt-in per device.
- **AirPods Max over USB-C.** macOS keeps the AirPods on their *Bluetooth* Core Audio device even when audio flows over the cable. Bluetooth stays connected as the control link, and the cable can't be used without it. The HAL exposes no "USB" property for this, so Vespertine treats the path as USB-C lossless when the AirPods' `AirPods Max USB Audio` interface is present in the IORegistry. (Measured on hardware: output latency is 480 frames / 10 ms, as expected of USB.) The device also lists a 24 kHz rate, but that is the mono hands-free format, and the planner ignores rates that can't carry the source's channel count. AirPods Max 2 match as long as their name contains "AirPods Max".
