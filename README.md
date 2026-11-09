<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/logo.svg">
    <img src="docs/brand/logo-on-light.svg" width="440" alt="Vespertine">
  </picture>
</p>

<p align="center">
  <strong>The free, open-source Mac player for surround and hi-res music collections.</strong>
</p>

Vespertine plays your stereo and surround music from one library: SACD images, DVD-Video discs, DTS CDs, Dolby TrueHD, DTS-HD Master Audio, Atmos and plain FLAC. It plays surround through Apple's Spatial Audio renderer on AirPods, or across several USB DACs at once as one speaker system (Speaker Groups, in beta), measures your room with a USB microphone and corrects each speaker, shows every step between the file and your DAC, and tells you whether your "hi-res" files really are.

<p align="center">
  <a href="https://github.com/szeremeta1/Vespertine/releases/latest"><strong>Download the DMG</strong></a> or <code>brew install --cask szeremeta1/tap/vespertine</code> · macOS 14.4+ · Apple silicon and Intel<br>
  Signed and notarized · no account, no telemetry · <a href="https://vespertineapp.com/">Website</a> · <a href="https://vespertineapp.com/press.html">Press kit</a> · <a href="https://vespertineapp.com/privacy.html">Privacy</a> · <a href="https://github.com/sponsors/szeremeta1">Sponsor</a>
</p>

<p align="center">
  <a href="https://github.com/szeremeta1/Vespertine/releases/latest"><img src="https://img.shields.io/github/v/release/szeremeta1/Vespertine?label=download&color=c8a765" alt="Latest release"></a>
  <a href="https://github.com/szeremeta1/Vespertine/actions/workflows/ci.yml"><img src="https://github.com/szeremeta1/Vespertine/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-1f1f1f" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="https://u24.gov.ua/"><img src="https://img.shields.io/badge/Stand_with-Ukraine-ffd700?labelColor=0057b7" alt="Stand with Ukraine"></a><br>
  <sub><strong>Vespertine stands with Ukraine.</strong> Please donate through <a href="https://u24.gov.ua/">United24</a>, <a href="https://savelife.in.ua/en/donate-en/">Come Back Alive</a> or <a href="https://www.razomforukraine.org/donate/">Razom for Ukraine</a>, or see <a href="https://stand-with-ukraine.pp.ua/">more ways to help</a>.</sub>
</p>

<p align="center">
  <img src="docs/screenshots/tour.gif" width="800" alt="Vespertine's bit-perfect signal path on a Fosi Audio ZD3, room correction measured in a real room, DSD over DoP, stereo and 5.1 versions listed once, 7.1 as head-tracked Spatial Audio on AirPods Max, and the Visualizer's turntable">
</p>

## Highlights

- **Speaker Groups (Beta): several DACs, one speaker system.** Play one stream across two or more DACs as a single quad or surround setup, with a channel map, a drawing of your room, and per-speaker level, delay and polarity. 5.1 and Dolby Atmos beds are placed on the speakers you actually have, and the signal path says exactly what that did to the samples. Off by default, and a beta: [read what is and isn't verified](#speaker-groups-beta).
- **Room correction, measured in your room.** Measure with a UMIK-1 or another calibrated USB microphone at one to five spots around your seat, and Vespertine fits filters to each speaker and lines up their delay and level. Stereo and 5.1 (5.1 is tested with simulated rooms and imported profiles, not yet in a real 5.1 room). It also imports REW and Equalizer APO filters and impulse responses. Off by default and bit-perfect while off. [More below](#room-correction).
- **Stereo and surround in one library.** SACD 5.1, multichannel FLAC, DTS CDs, TrueHD and DTS-HD MA sit next to your stereo albums. When an album has both versions, each song is listed once and Vespertine plays the one that suits your output.
- **Disc images, played directly.** SACD `.iso` images (stereo and multichannel, DST or plain) and DVD-Video LPCM (`.iso` or a `VIDEO_TS` folder) play straight from the image, with nothing mounted or extracted.
- **Spatial Audio for your own files.** Local surround plays through Apple's Spatial Audio renderer on AirPods (head-tracked where macOS provides it), with Atmos objects rendered from Dolby Digital Plus. Surround can also be exported as binaural stereo or multichannel ALAC.
- **A signal path you can check.** Decoding, resampling, mixing, gain and output format are shown for every track, read back from Core Audio. BIT-PERFECT appears only when the [conditions in code](Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift) are met, and when something changed the samples it says what. A built-in [loopback test](docs/LOOPBACK.md) checks the software path sample by sample.
- **Native DSD.** DSF and DSDIFF from DSD64 to DSD512, including DST-compressed files, go out as DoP to DACs that take it (up to DSD256 on the DACs tried), or convert to high-rate PCM.
- **Fake hi-res detection.** Flags 16-bit audio padded to 24, likely upsampled masters and likely lossy sources, with the measurements behind each verdict. `vespertine-analyze` runs the same analysis on a Linux server next to your files.
- **Speaks your language.** English and 44 more, from Ukrainian and Japanese to Amharic and Tamil, with right-to-left layouts for Arabic, Hebrew, Persian and Urdu and separate Simplified, Traditional and Hong Kong Chinese. A check on every change confirms each string exists in every language with matching placeholders and plural forms, and every screen was reviewed in every language for clipped or overlapping text. Corrections from native speakers are welcome.

<p align="center">
  <img src="docs/screenshots/languages-wall.png" width="800" alt="Vespertine written in each of its 45 interface languages, from ヴェスパタイン and Веспертайн to فسبرتاين and वेस्परटाइन, at mixed sizes and typefaces">
</p>

## Speaker Groups (Beta)

> **This is a beta.** It is off by default, behind one switch in Settings › Playback › Speaker Groups (beta), and with the switch off nothing about playback changes. The routing, the editor and the room-correction pieces are covered by automated tests and by opt-in tests against virtual devices. On real DACs only one session has run (a Fosi Audio ZD3 leading a FiiO K11, with a UMIK-1), using a probe tool rather than the app. **Nothing in the app has been listened to on a real group yet**, so reports are very welcome.

Two or more USB DACs, played as one multichannel system: a Fosi ZD3 and a FiiO K11 as the front and back pairs of a quad, for example. Vespertine builds a private Core Audio aggregate of your DACs that exists only inside Vespertine (other apps can't see it or play into it) and removes it when playback stops. One DAC, the clock leader, sets the time; every other DAC is resampled by a few millionths to follow it, so the speakers stay together without the image drifting.

<p align="center">
  <img src="docs/screenshots/speaker-groups-setup.png" width="800" alt="Vespertine's Speaker Group editor for a quad named Quad (virtual devices): a top-down drawing of the room with four speakers (front left and right, back left and right) around the listening seat, and a table with each speaker's distance, angle, wait, level, level trim and delay trim">
</p>

<sub>The screenshots here were taken on a Mac with two virtual audio devices (Vespertine Loopback and BlackHole 2ch) standing in for two stereo DACs. They show the screens, not a measurement of real DACs.</sub>

- **Channel map.** Every channel of every DAC is assigned to a speaker (front left, centre, back right…). An **Identify** button plays three quiet bursts of pink noise (-30 dBFS) on that one channel of that one DAC, so you can check the wiring, and each channel has an **Inverted** box. Presets lay out a Quad, an ITU 5.1 room or two pairs facing each other. Up to 16 output channels in total.
- **Your room, drawn.** Drag the speakers and your seat on a top-down drawing; each speaker's distance, angle, delay and level are worked out from it, so every speaker reaches the seat together. "Use the Drawing" turns that into a room-correction profile (delays and levels, no microphone needed), or measure the group with a microphone and the wizard also times each follower DAC against the leader.
- **Per-speaker trims.** Level (-40 to +12 dB), extra delay (0 to 40 ms) and a polarity flip for each speaker. A headroom guard lowers the shared preamp by the largest boost any channel can reach, so a trim doesn't clip a loud song.
- **Surround placed by where your speakers stand.** A song's channels go to the speakers by position: a channel with a speaker of its own plays there untouched; one between two speakers is panned between them with equal power (halfway is -3 dB each, as in ITU-R BS.775); one outside every pair goes to the nearest speaker at -3 dB. Stereo, 5.1 and 7.1 files, and the 5.1/7.1 channel bed of a Dolby Digital Plus Atmos file, are all routed this way. The **LFE is dropped by default** where there is no subwoofer; you can instead send it to every speaker at a level, or to one speaker. Stereo on a quad plays the front pair only by default, or mirrors to the back at a level, or gives each pair its own stereo, or uses every speaker.
- **A signal path that stays honest.** The group is labelled BIT-PERFECT only when every channel the song uses lands on a DAC that is not resampled (the leader, or DACs sharing a hardware clock) and nothing changes the samples: no mixing, trim, filter or digital volume. Otherwise the signal path says what changed. A drift-corrected follower is always slightly altered; on virtual devices it measured 103 to 131 dB signal to noise, far below the noise of a real DAC and amplifier, but it is not bit-perfect.
- **If a DAC goes away,** the group either fades and pauses and names the DAC, or carries on with the DACs that are left (after a short mute) and folds the music onto them. It never carries on silently on a new clock in the middle of a song.

**The signal path with a group playing.** A 5.1 test file folded into the quad by speaker position: the leader's pair is bit-perfect and says it is the clock leader; the other pair is marked resampled, and the group as a whole is not labelled BIT-PERFECT.

<p align="center">
  <img src="docs/screenshots/speaker-groups-signal-path.png" width="800" alt="Vespertine playing a 5.1 test signal through the Quad (virtual devices) group: the signal path lists the FLAC source, the decoder, the native 48 kHz rate, a 5.1 to Quad downmix, unity volume, the group at 32-bit float, Vespertine Loopback as bit-perfect for the front left and right and the clock leader, and BlackHole 2ch as resampled for the back left and right, followed by the channel meters">
</p>

**The channel map.** Every channel of every output against the speaker on it, with an Identify button and an Inverted box on each.

<p align="center">
  <img src="docs/screenshots/speaker-groups-channel-map.png" width="800" alt="The Speaker Group editor's channel map: Vespertine Loopback channels 1 and 2 are front left and front right, BlackHole 2ch channels 1 and 2 are back left and back right, each with an Inverted box and an Identify button; below are the DACs' own volume sliders and the stereo, subwoofer and lost-output choices">
</p>

**Limits, plainly:**

- Beta, with one probe session on real DACs and none of the app. Not yet checked on hardware: a bit-exact leader, follower quality, a quad channel for channel, the Identify tone, a real unplug, one hour of playback. [The script for the next hardware session](verification/hardware/SPEAKER-GROUPS.md) is in the repo.
- Only the clock leader's channels can be bit-perfect. Start offsets between DACs were repeatable to about 21 µs in typical runs, but 3 of 49 drift-corrected runs came in about 3.5 ms late, unexplained, and a follower crept steadily behind the leader (+13.5 ppm, 0.81 ms a minute, in one pair). The wizard can measure that rate and trim for it, but the trim has not been confirmed on hardware over its full 10 minutes.
- PCM only: DSD is converted to PCM, Dolby and DTS bitstreams are decoded rather than passed through, and integer mode, "Match 16-bit sources" and head-tracked Spatial Audio don't apply to a group. On a group, Atmos plays its channel bed, not macOS's object rendering.
- It is for speakers around one listening seat, not whole-home audio: Bluetooth and AirPlay outputs can't join (they add 100 ms or more of changing delay), and a macOS built-in output can join but is never bit-perfect.
- The group has no volume of its own, and the volume keys don't control it: set each DAC's volume once, by hand.
- The screens for creating and editing groups are in English for now; the switch is in all 45 languages. The stereo-to-quad rows come from the routing rules, not a standard, and still need listening approval.

[Speaker Groups in detail](docs/SPEAKER-GROUPS.md)

## Room correction

Measure your room with a UMIK-1 (or another calibrated USB microphone) from one to five listening spots. Vespertine plays sweeps through one speaker at a time and designs filters for each speaker from the measurement. They are cut-dominant: they take down the room's peaks and boost broad dips only gently. The same measurement sets each speaker's delay and level, so they all reach your seat together and at the same loudness.

- **Targets:** Warm (the default), Gentle tilt or Flat, for the bass only or the full range. Change the target and redesign the filters without measuring again.
- **Import and export:** REW and Equalizer APO filters (each speaker's delay, level and filters) in, Equalizer APO text out. Impulse responses (WAV, AIFF, CAF or FLAC) play by convolution.
- **Stereo and 5.1** (5.1 is tested with simulated rooms and imported profiles, not yet in a real 5.1 room).
- **See the change:** the Room Portrait shows the speakers, your seat and each microphone spot as it's measured, and the Curve Reveal turns the measured response into the predicted one. A before/after switch compares them. "After" is predicted, not measured.
- **Off by default.** Playback is bit-perfect while it's off. While it's on, the signal path says ROOM CORRECTION.

**Measured in a real room:** a stereo pair on a Fosi Audio ZD3, measured with a UMIK-1 (its serial number is blacked out), with the Warm target. The thin lines are the measurement, the bold lines the predicted result, and the window scrolls on to each speaker's delay, level and filters.

<p align="center">
  <img src="docs/screenshots/room-correction-fosi-zd3.png" width="560" alt="Vespertine's Room Correction window for a Fosi Audio ZD3, with room correction on and Keep native DSD ticked. The stereo profile measured with a UMIK-1 microphone, its serial number blacked out, shows the measured and predicted response of the left and right speakers against the Warm target, with a room peak near 125 Hz flattened in the predicted result, and the window scrolling on to each speaker's delay, level and filters">
</p>

**Imported from REW (sample):** a 5.1 profile imported as Equalizer APO text, showing what the correction does to each of the six speakers.

<p align="center">
  <img src="docs/screenshots/room-correction-rew-5-1.png" width="560" alt="Vespertine's Room Correction window with a sample 5.1 profile imported from REW: the on switch for the output, Measure Again, Import and Export, a graph of what the correction does to each of the six speakers, and each speaker's delay, level and filters">
</p>

[How room correction works](docs/ROOM-CORRECTION.md)

## Everything else

- **Output:** Switches your DAC to each file's sample rate, with exclusive (hog) mode, integer mode and an option to send 16-bit files as 16-bit. Remembers your DAC and falls back to the best connected output when it's unplugged. Lossless 24-bit / 48 kHz on AirPods Max over USB-C.
- **EQ:** A 20-band parametric EQ that imports AutoEQ and Equalizer APO presets per output. It's off by default, and when it is on the signal path says EQUALIZER.
- **Library:** Albums, artists, songs and genres with combinable filters, smart playlists in units like 24-bit and 88.2 kHz, gapless CUE-sheet albums, and favorites. Imports M3U and Apple Music playlists, play counts and favorites.
- **Metadata:** A tag editor that backs up every file before writing, with MusicBrainz and cover art lookup.
- **Network shares:** SMB, NFS and WebDAV, with caching and Keep Offline. Library scans step aside for the song you're playing.
- **Everyday:** Mini player, menu-bar extra, media keys, an optional Discord status with cover and format, ReplayGain, a short setup assistant and automatic updates.

**Formats:** FLAC, ALAC, WAV, AIFF, DSF, DSDIFF, SACD ISO, DVD-Video LPCM, Dolby Digital, Dolby Digital Plus with Atmos, Dolby TrueHD, MLP, DTS, DTS-HD MA, DTS CDs, APE, WavPack (including DSD), TTA, TAK, Opus, Vorbis, Musepack, MP3 and AAC, the audio of Matroska and WebM files, plus CUE sheets (beside the file, or inside a FLAC).

[All features, formats and screenshots](docs/FEATURES.md)

## Compared with other Mac players

Bit-perfect playback is available in several Mac players. Vespertine focuses on a surround collection, a signal path you can inspect, and GPL source you can audit. Here's what each player's own documentation or source code says. "Not documented" means the vendor doesn't say either way; it is not a claim that the player lacks the feature.

| | Vespertine | Apple Music (Mac) | Audirvana Studio / Origin | Roon | VeraVox | Colibri | Cog | foobar2000 for Mac |
|---|---|---|---|---|---|---|---|---|
| Source code | GPL-3.0 | Closed | Closed | Closed | Closed | Closed | GPL-2.0 | Closed |
| FLAC / DSD files | Yes / Yes | No / No | Yes / Yes | Yes / Yes | Yes / Yes | Yes / Yes | Yes / Yes | Yes / No⁴ |
| Automatic DAC rate switching | Yes | No | Yes | Yes | Yes | Yes | Yes | Not documented |
| Exclusive (hog) mode | Yes | No | Yes | Yes | Yes | Yes | Yes | Yes |
| 16/24-bit PCM without sample changes | Conditions + tests | macOS 27: third-party tests¹ | Vendor claim | Vendor claim | In-app loopback test | Vendor claim | In-app indicator | Not documented |
| Local surround files | Yes² | Not documented | Yes | Yes | Yes | Not documented | Yes | Not documented |
| Apple Spatial Audio for local surround | Yes | Catalog Atmos only³ | Not documented | Not documented | Not documented | Not documented | Yes | Not documented |
| Hi-res file analysis | Yes | No | AudioScan | Dynamic range, loudness | Yes | Not documented | No (live spectrum only) | No (live spectrum only) |
| SACD ISO | Yes | No | Yes | No (DSF/DFF only) | Yes | No | No | No⁴ |
| Room correction | Measured in the app (USB mic), or REW / APO and impulse-response import | No | Via convolution (Origin: paid option) or Audio Units | Via convolution | No (by design) | Not documented | No | Not documented |
| Convolution / audio effect plugins | Yes (room correction) / No | No / No | Yes (Origin: paid option) / Audio Units | Yes / No | No / No | Not documented / Not documented | No / No | Not documented / Audio Units |
| Streaming services | No | Apple Music | Studio: yes; Origin: no | Yes | No (local + UPnP) | No (internet radio) | No (internet radio) | No (internet radio) |

¹ Apple Music on macOS 27 was bit-exact at 16/24-bit in [third-party loopback tests reported on ASR](https://www.audiosciencereview.com/forum/index.php?threads/music-app-on-macos-27-and-ios-27-finally-plays-bit-perfect.73373/). This is not a Vespertine measurement or a claim about every Mac configuration. Volume was at 100%; there is still no automatic rate switching, hog mode, FLAC or DSD on Mac. The original test report could not be independently rechecked for this update.

² Multichannel DAC output and receiver bitstream are experimental, untested on real receivers and multichannel USB DACs (one Sony TV over HDMI has been tested: see docs/DEVICES.md); reports wanted. Automated routing and carrier tests do not establish hardware compatibility.

³ Apple documents Spatial Audio with head tracking for Dolby Atmos tracks in the Apple Music catalog. It does not document spatial rendering of your own multichannel files.

⁴ Tested on foobar2000 2.26 (macOS 27.0.1), with no components: DSF, DFF and SACD ISO files fail with "Unsupported file format". DSF and DFF play only as 352.8 kHz PCM after installing FFmpeg separately and adding them to its FFmpeg Decoder Wrapper; SACD ISO still fails.

[Comparison sources and scope](docs/COMPARISON.md). Corrections welcome: [open an issue](https://github.com/szeremeta1/Vespertine/issues).

## Known limitations

PCM playback has been tested up to 768 kHz and DSD256 on a Fosi Audio ZD3, and up to 384 kHz and DSD128 on a FiiO K11 (developer reports). Playback has also been tested on AirPods Max over USB-C and Bluetooth, MacBook Pro speakers, and a Sony TV over HDMI in 5.1 ([details](docs/DEVICES.md)). [Device reports](https://github.com/szeremeta1/Vespertine/issues/new?template=dac_report.yml) help extend that.

- Channel-for-channel output has been reported on one real device, a Sony TV over HDMI (5.1 and a 7.1 to 5.1 downmix, developer report without a capture; see [Tested devices](docs/DEVICES.md)). Multichannel USB DACs and Dolby/DTS bitstream to receivers are untested on real hardware; reports wanted.
- Intel Macs are untested (the Intel build has run under Rosetta). DoP is reported to work up to DSD256 on the Fosi Audio ZD3 and up to DSD128 on the FiiO K11 (developer reports, no capture); DSD512 over DoP is untested on hardware.
- No audio effect plugins, streaming services or UPnP/DLNA. Convolution is only part of room correction.
- No DVD-Audio or DRM-protected Apple Music downloads. Dolby AC-4 and MPEG-H 3D Audio (Sony 360 Reality Audio) files are listed and named but not decoded, MQA plays as the plain FLAC it contains, and Auro-3D as ordinary surround PCM (no decoder for any of them; see [docs/FEATURES.md](docs/FEATURES.md)). TrueHD Atmos and DTS:X objects are not rendered, and TrueHD and DTS-HD MA receiver passthrough is unsupported on macOS.

## Building

You need Xcode and XcodeGen (`brew install xcodegen`):

```bash
scripts/generate-project.sh && open Vespertine.xcodeproj
```

Run the tests with `swift test` in `Packages/VespertineKit` and `Packages/VespertineAnalysis` (the analysis core also builds on Linux), or `scripts/audit.sh` for everything. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers command-line builds, a synthesized demo library, and the tools for checking playback on your own hardware.

## Contributing

Bug reports, device reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Third-party components and their licenses are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Trademarks

Dolby, Dolby Atmos, Dolby Digital, Dolby Digital Plus and Dolby TrueHD are trademarks of Dolby Laboratories. DTS, DTS-HD Master Audio and DTS:X are trademarks of DTS, Inc. Apple, AirPods, AirPods Max and Spatial Audio are trademarks of Apple Inc. Vespertine names these formats and products only to describe what it plays and where. It is not certified, licensed or endorsed by Dolby, DTS or Apple, and it doesn't use their logos.

Vespertine was called Nocturne until version 0.6.0.
