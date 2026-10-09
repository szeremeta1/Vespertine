<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/logo.svg">
    <img src="docs/brand/logo-on-light.svg" width="440" alt="Vespertine">
  </picture>
</p>

<p align="center">
  <strong>The free, open-source Mac player for surround and hi-res music collections.</strong>
</p>

I'm Alex, a student who built Vespertine for my own SACD rips and FiiO K11. It puts extracted SACD 5.1 tracks, DTS CDs, DTS-HD MA, TrueHD and Atmos files in one library with your stereo albums, plays them as head-tracked Spatial Audio on AirPods, and checks whether your "hi-res" files really are. The signal path shows every step from file to output, and the bit-perfect conditions and their tests are in the source for anyone to audit. SACD ISO playback is coming in the next release. Channel-for-channel output to an interface and Dolby/DTS bitstream to a receiver are experimental, untested on real receivers/multichannel DACs; reports wanted.

<p align="center">
  <a href="https://github.com/szeremeta1/Vespertine/releases/latest"><strong>Download the DMG</strong></a> or <code>brew install --cask szeremeta1/tap/vespertine</code> · macOS 14.4+<br>
  Signed and notarized · <a href="https://vespertineapp.com/">Website</a> · <a href="https://vespertineapp.com/privacy.html">Privacy: nothing collected</a> · <a href="#how-its-made">How it's made</a>
</p>

<p align="center">
  <a href="https://github.com/szeremeta1/Vespertine/releases/latest"><img src="https://img.shields.io/github/v/release/szeremeta1/Vespertine?label=download&color=c8a765" alt="Latest release"></a>
  <a href="https://github.com/szeremeta1/Vespertine/actions/workflows/ci.yml"><img src="https://github.com/szeremeta1/Vespertine/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-1f1f1f" alt="GPL-3.0"></a>
</p>

<p align="center">
  <img src="docs/screenshots/tour.gif" width="640" alt="Vespertine's surround library, bit-perfect signal path on a FiiO K11, DSD over DoP, 5.1 as Spatial Audio on AirPods Max, and hi-res file analysis">
</p>

## What it does

- **One library for stereo and surround.** Extracted SACD tracks, DTS CDs, DTS-HD MA, TrueHD and multichannel FLAC sit alongside stereo albums. When an album has both a stereo and a surround version, each song is listed once and Vespertine plays the version that suits your output.
- **Head-tracked Spatial Audio on AirPods** for local surround files. Atmos objects are rendered from Dolby Digital Plus; TrueHD Atmos and DTS:X play their channel bed. Surround can also be exported as binaural stereo or multichannel ALAC.
- **A signal path you can check.** Decoding, resampling, channel mixing, gain and output format are shown for every track, read back from Core Audio. BIT-PERFECT appears only when the [conditions in code](Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift) are met, and when something changed the samples it says what. [Tests and hardware checks](docs/VERIFICATION.md) explain what that covers.
- **Fake hi-res detection.** Flags 16-bit audio padded to 24, likely upsampled masters and likely lossy origin, with the measurements behind each verdict and their limits. `vespertine-analyze` runs the same analysis on a Linux server next to your files.
- **Native rate and depth.** Switches your DAC to each file's sample rate, with exclusive (hog) mode and integer mode. PCM playback has been tested up to 384 kHz on a FiiO K11. DSD files decode from DSD64 to DSD512; DoP depends on the DAC and its carrier rate.
- **Lossless on AirPods Max over USB-C**, shown as a 24-bit / 48 kHz device; over Bluetooth it tells you the link is AAC.
- **A library that respects your files.** Albums, artists, songs and genres with combinable filters, smart playlists in units like 24-bit and 88.2 kHz, and a tag editor that backs up every file first. A parametric EQ imports AutoEQ and Equalizer APO presets per output; it is off by default, and when it is on the signal path says EQUALIZER.
- **NAS libraries.** Plays from local drives or SMB, NFS and WebDAV shares, with caching and Keep Offline.
- **SACD images, in the next release.** `.iso` playback (stereo and 5.1, DST-compressed or plain) straight from the image. It matched sacd_extract bit for bit on two real discs.

[All features and screenshots](docs/FEATURES.md) · [How it's made](#how-its-made)

## How it's made

Claude Code and Codex wrote most of the code. I decided how the app should behave, wrote acceptance tests, and measured playback on my FiiO K11, AirPods Max over USB-C and Bluetooth, and MacBook Pro speakers. The [commit history](https://github.com/szeremeta1/Vespertine/commits/main/) and [verification guide](docs/VERIFICATION.md) are public.

## Compared with other Mac players

Bit-perfect playback is available in several Mac players. Vespertine focuses on a surround collection, a signal path you can inspect, and GPL source you can audit. Here's what is documented; `?` means unverified, not unsupported.

| | Vespertine | Apple Music (Mac) | Audirvana Studio / Origin | Roon | VeraVox | Colibri | Cog | foobar2000 for Mac |
|---|---|---|---|---|---|---|---|---|
| Source code | GPL-3.0 | Closed | Closed | Closed | Closed | ? | GPL | Closed |
| FLAC / DSD files | Yes / Yes | No / No | Yes / Yes | Yes / Yes | Yes / Yes | Yes / Yes | Yes / Yes | Yes / ? |
| Automatic DAC rate switching | Yes | No | Yes | Yes | Yes | Yes | Yes | ? |
| Exclusive (hog) mode | Yes | No | Yes | Yes | Yes | Yes | Yes | Yes |
| 16/24-bit PCM without sample changes | Conditions + tests | macOS 27: third-party tests¹ | Vendor claim | Vendor claim | In-app loopback test | Vendor claim | In-app indicator | ? |
| Local surround files | Yes² | ? | Yes | Yes | Yes | ? | Yes | ? |
| Apple Spatial Audio for local surround | Yes | ? | ? | ? | ? | ? | Yes | ? |
| Hi-res file analysis | Yes | ? | AudioScan | ? | Yes | ? | ? | ? |
| SACD ISO | Coming in the next release | No | Yes | No (DSF/DFF only) | Yes | No | ? | ? |
| Convolution / audio effect plugins | No / No | ? / ? | Yes (Origin: paid option) / Audio Units | Yes / ? | No / No | ? / ? | ? / ? | ? / Audio Units |
| Streaming services | No | Apple Music | Studio: yes; Origin: no | Yes | No (local + UPnP) | No (radio only) | ? | ? |

¹ Apple Music on macOS 27 was bit-exact at 16/24-bit in [third-party loopback tests reported on ASR](https://www.audiosciencereview.com/forum/index.php?threads/music-app-on-macos-27-and-ios-27-finally-plays-bit-perfect.73373/). This is not a Vespertine measurement or a claim about every Mac configuration. Volume was at 100%; there is still no automatic rate switching, hog mode, FLAC or DSD on Mac. The original test report could not be independently rechecked for this update.

² Multichannel DAC output and receiver bitstream are experimental, untested on real receivers/multichannel DACs; reports wanted. Automated routing and carrier tests do not establish hardware compatibility.

[Comparison sources and scope](docs/COMPARISON.md). Corrections welcome: [open an issue](https://github.com/szeremeta1/Vespertine/issues).

## Known limitations

I've tested playback on a FiiO K11 at rates up to 384 kHz, AirPods Max over USB-C and Bluetooth, and MacBook Pro speakers. [Device reports](https://github.com/szeremeta1/Vespertine/issues/new?template=dac_report.yml) help extend that coverage.

- Channel-for-channel output and receiver bitstream are experimental, untested on real receivers/multichannel DACs; reports wanted. Routing has automated tests and a six-channel aggregate-device check; bitstream carriers were checked with FFmpeg's S/PDIF reader.
- Intel Macs are untested. The Intel build has run under Rosetta. DoP has only been confirmed on the FiiO K11; carrier rates above 384 kHz have not been tested on hardware.
- SACD images have been tested on two real discs (The Dark Side of the Moon, Brothers in Arms: plain and DST stereo, DST 5.1). Discs with a 5.0 area, only a multichannel area, or DSD128 and above are covered only by synthesized images.
- No convolution, audio effect plugins, streaming services or UPnP/DLNA renderers.
- No DSD inside WavPack or DRM-protected Apple Music downloads. TrueHD Atmos and DTS:X objects are not rendered. TrueHD and DTS-HD MA receiver passthrough is unsupported on macOS.

## Build

```bash
brew install xcodegen
```

```bash
scripts/generate-project.sh && open Vespertine.xcodeproj
```

Or build from the command line:

```bash
scripts/generate-project.sh && xcodebuild -project Vespertine.xcodeproj -scheme Vespertine -configuration Release \
  -derivedDataPath build/DD -onlyUsePackageVersionsFromResolvedFile build
```

Run the engine and library tests, and the analysis core's (it also builds on Linux):

```bash
cd Packages/VespertineKit && swift test
```

```bash
cd Packages/VespertineAnalysis && swift test
```

`scripts/audit.sh` runs everything above plus the app tests, sanitizer builds of the real-time C code and a release build.

The FFmpeg decoders for DTS, TrueHD and DSD ship prebuilt in `Packages/VespertineKit/Vendor/FFmpegDCA.xcframework`. To rebuild them from FFmpeg's release tarball (checksum-verified, only those decoders enabled):

```bash
scripts/build-dts-decoder.sh
```

## Try it without your own music

`vespertine-demo` synthesizes an original demo library of 13 fictional albums in every supported container, including DSD64, a CUE-split album and a 24-bit album with one track that is really 16-bit:

```bash
cd Packages/VespertineKit && swift run -c release vespertine-demo ~/Desktop/VespertineDemo
```

To launch against an isolated test library, so your real one is untouched:

```bash
build/DD/Build/Products/Release/Vespertine.app/Contents/MacOS/Vespertine -VespertineDataDirectory /tmp/vespertine-test -VespertineAddSource ~/Desktop/VespertineDemo
```

For Dolby, DTS and TrueHD samples, [FFmpeg's FATE suite](https://fate-suite.ffmpeg.org/) has short clips of each (`ac3/`, `eac3/`, `dts/`, `dca/`, `truehd/`), and `Packages/VespertineKit/Tests/VespertineAudioTests/Fixtures` has tone files made with FFmpeg's encoders.

### Hardware verification

[docs/VERIFICATION.md](docs/VERIFICATION.md) explains how to check bit-perfect playback on your own hardware. `vespertine-probe` drives the real engine against a device and reads back what Core Audio actually did (nominal rate, physical format, hog owner):

```bash
cd Packages/VespertineKit && swift build -c release --product vespertine-probe
```

```bash
.build/release/vespertine-probe list
```

```bash
.build/release/vespertine-probe play "FiiO K11" 3 ~/Music/a.flac ~/Music/b.flac
```

`vespertine-library` runs the same library code from the command line:
- `find` lists folders with music;
- `hires` lists every hi-res file;
- `search <term>` searches tags;
- `import --library <dir> --into <dir> <files…>` imports;
- `enrich --library <dir> [--apply high|all]` enriches;
- `import-server-analysis --library <dir>` imports a share's server analysis results.

`gapless <device> <files…>` plays a queue and reports hand-offs and underruns. `analyze <files…>` runs the analysis (`analyze-json` prints it as JSON, for comparing with `vespertine-analyze file`); `forensics <files…>` prints its raw measurements as a table; `restore-test <device>` checks the quit options that hand a device back.

`scripts/qa-run.sh` and `App/Sources/App/DeveloperHooks.swift` hold the launch arguments used for visual QA. They can open albums, artists and genres, start playback or a shuffle, set any page's filters, select inspector tabs and render windows to PNG, which works even while the screen is locked.

## Releasing

Start with [the release-notes template](docs/releases/TEMPLATE.md). The [release cadence](CONTRIBUTING.md#release-cadence) is at most one beta a week, with the 1.0 freeze from November 3.

```bash
scripts/release.sh --notarize --install
```

```bash
scripts/publish.sh docs/releases/<version>.md
```

The first command builds a universal app and signs it (and every embedded framework and Sparkle helper) with the Developer ID of team `7WMQ9ZV6V8`, and stops if anything ends up signed by another team. It then notarizes and staples both the app and a designed installer DMG, using the notarytool profile `vespertine-notary-7WMQ9ZV6V8` (created once with `xcrun notarytool store-credentials vespertine-notary-7WMQ9ZV6V8 --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer>`). If Apple takes longer than two hours, rerun it with `--resume` instead of `--notarize`. The top of `scripts/release.sh` lists the environment variables that pick another identity, team or profile.

The second command publishes the GitHub release: it signs each Sparkle appcast entry, and the feed itself, with the EdDSA key in the login keychain (account `nocturne`, kept from before the rename so the key never changes) and uploads `appcast.xml` next to the DMG. Never edit the uploaded `appcast.xml` by hand: the app requires a signed feed, so an edit stops every installed copy from updating. Installed copies read the feed from `releases/latest/download/appcast.xml`, so the release GitHub marks *Latest* must always carry `appcast.xml`: any other release (a build of the analyzer, say) goes up with `gh release create --latest=false`, or every installed copy's update check fails until the next app release.

**Back up the Sparkle signing key.** Without it, no future update can be published to existing installs:

```bash
build/DDR/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account nocturne -x vespertine-sparkle-key.txt
```

Store that file somewhere safe (it is a secret), then delete it.

## Layout

| Path | What |
|---|---|
| `Packages/VespertineKit/Sources/CVespertineRT` | Real-time C: lock-free ring buffer, HAL IOProc, dithered gain, integer mode, meters, spectrum tap (DoP included) |
| `Packages/VespertineKit/Sources/CVespertineDTS` | C shims over FFmpeg: DTS CDs, DTS-HD, TrueHD, Matroska and DSD |
| `Packages/VespertineKit/Sources/CVespertineGuard` | Objective-C++ guard that turns exceptions from codec libraries into errors |
| `Packages/VespertineKit/Sources/VespertineAudio` | Device discovery, shared/exclusive output, format switching, `FormatPlanner`, `PlaybackEngine`, Spatial Audio, Dolby Atmos, experimental bitstream (untested on real receivers/multichannel DACs; reports wanted), decoders |
| `Packages/VespertineKit/Sources/VespertineLibrary` | GRDB/SQLite library, scanner, CUE, tag reader and writer, format badges, genres, smart playlists, network shares, server-analysis import, MusicBrainz/ListenBrainz |
| `Packages/VespertineKit/Vendor` | FFmpeg's DTS, TrueHD and DSD decoders, prebuilt (see `scripts/build-dts-decoder.sh`) |
| `Packages/VespertineAnalysis` | The analysis core (spectra, forensics, verdicts) in plain Swift, plus `vespertine-analyze` for Linux servers |
| `App/` | SwiftUI app (Obsidian & Brass design) |
| `docs/` | Architecture notes, design mockups, screenshots, release notes |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how audio gets from file to DAC.

## Contributing

Bug reports, device reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and please follow the [code of conduct](CODE_OF_CONDUCT.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Third-party components, with versions, sources and the FFmpeg build options, are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md): SFBAudioEngine (MIT), GRDB (MIT), Sparkle (MIT), TagLib (LGPL/MPL), libFLAC (BSD), WavPack (BSD), Monkey's Audio (BSD), libopus/libvorbis/libogg (BSD), the Musepack decoder (BSD), mpg123 (LGPL), libsndfile (LGPL), LAME (LGPL), DUMB (zlib-like), TTA (LGPL), and FFmpeg's DTS, TrueHD/MLP and DSD decoders with its DTS, TrueHD, Matroska, DSF and DSDIFF demuxers (LGPL-2.1+, built from source by `scripts/build-dts-decoder.sh`).

## Trademarks

Dolby, Dolby Atmos, Dolby Digital, Dolby Digital Plus and Dolby TrueHD are trademarks of Dolby Laboratories. DTS, DTS-HD Master Audio and DTS:X are trademarks of DTS, Inc. Apple, AirPods, AirPods Max and Spatial Audio are trademarks of Apple Inc. Vespertine names these formats and products only to describe what it plays and where. It is not certified, licensed or endorsed by Dolby, DTS or Apple, and it doesn't use their logos.

Vespertine was called Nocturne until version 0.6.0.
