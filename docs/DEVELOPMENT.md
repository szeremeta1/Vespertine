# Developing Vespertine

How to build Vespertine, run its tests, try it without your own music, and check playback on your own hardware. Commands run from the repository root unless they `cd` first. [CONTRIBUTING.md](../CONTRIBUTING.md) covers reports and pull requests.

## Building

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

The golden PCM tests (`GoldenPCMTests.swift`) render a fixed set of files (gapless pairs, 44.1/48/96 kHz, mono to 5.1, 16/24/32-bit and float, DoP, Dolby and DTS bitstream, a CUE sheet, a silent tail) through the engine's decode, convert, ring and render steps with no device, and compare SHA-256 hashes of the exact output with `Tests/VespertineAudioTests/Fixtures/golden-pcm.json`. A change that is meant to alter the output is re-recorded with `VESPERTINE_GOLDEN_RECORD=1 swift test --filter GoldenPCM`, and the pull request says why.

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

## Hardware verification

[VERIFICATION.md](VERIFICATION.md) explains how to check bit-perfect playback on your own hardware. `vespertine-probe` drives the real engine against a device and reads back what Core Audio actually did (nominal rate, physical format, hog owner):

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

## Website

The website (vespertineapp.com) is an Astro site in `site/`: `cd site && npm ci && npm run dev`. Its version, download link and "What's new" come from the GitHub releases at build time, and publishing a release rebuilds it, so a release needs no website edit. Feature, format and FAQ wording lives in `site/src/data/content.ts`; keep it in step with this folder's docs. [site/README.md](../site/README.md) has the rest.
