<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/logo.svg">
    <img src="docs/brand/logo-on-light.svg" width="440" alt="Vespertine">
  </picture>
</p>

<p align="center">
  <strong>The free, open-source Mac player for surround and hi-res music collections.</strong>
</p>

Vespertine plays your stereo and surround music from one library: SACD images, DVD-Video discs, DTS CDs, Dolby TrueHD, DTS-HD Master Audio, Atmos and plain FLAC. It plays surround as head-tracked Spatial Audio on AirPods, shows every step between the file and your DAC, and tells you whether your "hi-res" files really are.

<p align="center">
  <a href="https://github.com/szeremeta1/Vespertine/releases/latest"><strong>Download the DMG</strong></a> or <code>brew install --cask szeremeta1/tap/vespertine</code> · macOS 14.4+ · Apple silicon and Intel<br>
  Signed and notarized · no account, no telemetry · <a href="https://vespertineapp.com/">Website</a> · <a href="https://github.com/szeremeta1/Vespertine/discussions">Discussions</a> · <a href="https://github.com/sponsors/szeremeta1">Sponsor</a> · <a href="https://vespertineapp.com/privacy.html">Privacy</a>
</p>

<p align="center">
  <a href="https://github.com/szeremeta1/Vespertine/releases/latest"><img src="https://img.shields.io/github/v/release/szeremeta1/Vespertine?label=download&color=c8a765" alt="Latest release"></a>
  <a href="https://github.com/szeremeta1/Vespertine/actions/workflows/ci.yml"><img src="https://github.com/szeremeta1/Vespertine/actions/workflows/ci.yml/badge.svg" alt="CI status"></a> <a href="https://github.com/szeremeta1/Vespertine/actions/workflows/pages.yml"><img src="https://github.com/szeremeta1/Vespertine/actions/workflows/pages.yml/badge.svg" alt="Website deploy status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-1f1f1f" alt="GPL-3.0"></a>
</p>

<p align="center">
  <img src="docs/screenshots/tour.gif" width="800" alt="Vespertine's surround library, bit-perfect signal path on a FiiO K11, DSD over DoP, SACD images, 5.1 as Spatial Audio on AirPods Max, hi-res file analysis and 44 languages">
</p>

<p align="center">
  <a href="https://u24.gov.ua/"><img src="https://img.shields.io/badge/Stand_with-Ukraine-ffd700?labelColor=0057b7" alt="Stand with Ukraine"></a><br>
  <sub><strong>Vespertine stands with Ukraine.</strong> Please donate through <a href="https://u24.gov.ua/">United24</a>, <a href="https://savelife.in.ua/en/donate-en/">Come Back Alive</a> or <a href="https://www.razomforukraine.org/donate/">Razom for Ukraine</a>, or see <a href="https://stand-with-ukraine.pp.ua/">more ways to help</a>.</sub>
</p>

## Highlights

- **Stereo and surround in one library.** SACD 5.1, multichannel FLAC, DTS CDs, TrueHD and DTS-HD MA sit next to your stereo albums. When an album has both versions, each song is listed once and Vespertine plays the one that suits your output.
- **Disc images, played directly.** SACD `.iso` images (stereo and multichannel, DST or plain) and DVD-Video LPCM (`.iso` or a `VIDEO_TS` folder) play straight from the image, with nothing mounted or extracted. It matched sacd_extract bit for bit on two real discs.
- **Spatial Audio for your own files.** Local surround plays as head-tracked Spatial Audio on AirPods, with Atmos objects rendered from Dolby Digital Plus. Surround can also be exported as binaural stereo or multichannel ALAC.
- **A signal path you can check.** Decoding, resampling, mixing, gain and output format are shown for every track, read back from Core Audio. BIT-PERFECT appears only when the [conditions in code](Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift) are met, and when something changed the samples it says what. A built-in [loopback test](docs/LOOPBACK.md) checks the software path sample by sample.
- **Native DSD.** DSF and DSDIFF from DSD64 to DSD512, including DST-compressed files, go out as DoP to DACs that take it, or convert to high-rate PCM.
- **Fake hi-res detection.** Flags 16-bit audio padded to 24, likely upsampled masters and likely lossy sources, with the measurements behind each verdict. `vespertine-analyze` runs the same analysis on a Linux server next to your files.

## Everything else

- **Output:** Switches your DAC to each file's sample rate, with exclusive (hog) mode, integer mode and an option to send 16-bit files as 16-bit. Remembers your DAC and falls back to the best connected output when it's unplugged. Lossless 24-bit / 48 kHz on AirPods Max over USB-C.
- **EQ:** A 20-band parametric EQ that imports AutoEQ and Equalizer APO presets per output. It's off by default, and when it is on the signal path says EQUALIZER.
- **Library:** Albums, artists, songs and genres with combinable filters, smart playlists in units like 24-bit and 88.2 kHz, gapless CUE-sheet albums, and favorites. Imports M3U and Apple Music playlists, play counts and favorites.
- **Metadata:** A tag editor that backs up every file before writing, with MusicBrainz and cover art lookup.
- **Network shares:** SMB, NFS and WebDAV, with caching and Keep Offline. Library scans step aside for the song you're playing.
- **Everyday:** Mini player, menu-bar extra, media keys, ReplayGain, a short setup assistant, automatic updates, and an interface in 44 languages besides English, including right-to-left layouts.

**Formats:** FLAC, ALAC, WAV, AIFF, DSF, DSDIFF, SACD ISO, DVD-Video LPCM, Dolby Digital, Dolby Digital Plus with Atmos, Dolby TrueHD, MLP, DTS, DTS-HD MA, DTS CDs, APE, WavPack, TTA, Opus, Vorbis, Musepack, MP3 and AAC, plus CUE sheets.

[All features, formats and screenshots](docs/FEATURES.md)

## Compared with other Mac players

Bit-perfect playback is available in several Mac players. Vespertine focuses on a surround collection, a signal path you can inspect, and GPL source you can audit. Here's what each player's own documentation or source code says. **?** means the vendor doesn't say either way ("not documented"); it is not a claim that the player lacks the feature.

| | Vespertine | Apple Music (Mac) | Audirvana Studio / Origin | Roon | VeraVox | Colibri | Cog | foobar2000 for Mac |
|---|---|---|---|---|---|---|---|---|
| Source code | GPL-3.0 | Closed | Closed | Closed | Closed | Closed | GPL-2.0 | Closed |
| FLAC / DSD files | Yes / Yes | No / No | Yes / Yes | Yes / Yes | Yes / Yes | Yes / Yes | Yes / Yes | Yes / No⁴ |
| Automatic DAC rate switching | Yes | No | Yes | Yes | Yes | Yes | Yes | ? |
| Exclusive (hog) mode | Yes | No | Yes | Yes | Yes | Yes | Yes | Yes |
| 16/24-bit PCM without sample changes | Conditions + tests | macOS 27: third-party tests¹ | Vendor claim | Vendor claim | In-app loopback test | Vendor claim | In-app indicator | ? |
| Local surround files | Yes² | ? | Yes | Yes | Yes | ? | Yes | ? |
| Apple Spatial Audio for local surround | Yes | Catalog Atmos only³ | ? | ? | ? | ? | Yes | ? |
| Hi-res file analysis | Yes | No | AudioScan | Dynamic range, loudness | Yes | ? | No (live spectrum only) | No (live spectrum only) |
| SACD ISO | Yes | No | Yes | No (DSF/DFF only) | Yes | No | No | No⁴ |
| Convolution / audio effect plugins | No / No | No / No | Yes (Origin: paid option) / Audio Units | Yes / No | No / No | ? / ? | No / No | ? / Audio Units |
| Streaming services | No | Apple Music | Studio: yes; Origin: no | Yes | No (local + UPnP) | No (internet radio) | No (internet radio) | No (internet radio) |

¹ Apple Music on macOS 27 was bit-exact at 16/24-bit in [third-party loopback tests reported on ASR](https://www.audiosciencereview.com/forum/index.php?threads/music-app-on-macos-27-and-ios-27-finally-plays-bit-perfect.73373/). This is not a Vespertine measurement or a claim about every Mac configuration. Volume was at 100%; there is still no automatic rate switching, hog mode, FLAC or DSD on Mac. The original test report could not be independently rechecked for this update.

² Multichannel DAC output and receiver bitstream are experimental, untested on real receivers/multichannel DACs; reports wanted. Automated routing and carrier tests do not establish hardware compatibility.

³ Apple documents Spatial Audio with head tracking for Dolby Atmos tracks in the Apple Music catalog. It does not document spatial rendering of your own multichannel files.

⁴ Tested on foobar2000 2.26 (macOS 27.0.1), with no components: DSF, DFF and SACD ISO files fail with "Unsupported file format". DSF and DFF play only as 352.8 kHz PCM after installing FFmpeg separately and adding them to its FFmpeg Decoder Wrapper; SACD ISO still fails.

[Comparison sources and scope](docs/COMPARISON.md). Corrections welcome: [open an issue](https://github.com/szeremeta1/Vespertine/issues).

## Known limitations

Playback has been tested on a FiiO K11 at rates up to 384 kHz, AirPods Max over USB-C and Bluetooth, and MacBook Pro speakers. [Device reports](https://github.com/szeremeta1/Vespertine/issues/new?template=dac_report.yml) help extend that.

- Channel-for-channel output to multichannel DACs and Dolby/DTS bitstream to receivers are experimental and untested on real hardware; reports wanted.
- Intel Macs are untested (the Intel build has run under Rosetta). DoP is confirmed only on the FiiO K11, and carrier rates above 384 kHz are untested on hardware.
- No convolution, audio effect plugins, streaming services or UPnP/DLNA.
- No DVD-Audio, DSD inside WavPack or DRM-protected Apple Music downloads. TrueHD Atmos and DTS:X objects are not rendered, and TrueHD and DTS-HD MA receiver passthrough is unsupported on macOS.

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
