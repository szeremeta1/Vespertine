<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Nocturne app icon">
</p>

<h1 align="center">Nocturne</h1>

<p align="center">
  <strong>A free, open-source, bit-perfect music player for macOS.</strong><br>
  Native sample rates on your DAC, Spatial Audio on AirPods, and an honest signal path, from 16/44.1 to 24/192, DSD and 7.1.
</p>

<p align="center">
  <a href="https://github.com/szeremeta1/Nocturne/releases/latest"><img src="https://img.shields.io/github/v/release/szeremeta1/Nocturne?label=download&color=c8a765" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-1f1f1f" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%26%20Intel-universal-1f1f1f" alt="Universal">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-1f1f1f" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="https://github.com/szeremeta1/Nocturne/releases/latest"><strong>Download Nocturne</strong></a> · signed, notarized, and it keeps itself up to date
</p>

<br>

<p align="center">
  <img src="docs/screenshots/spatial-audio-airpods-max.png" alt="Nocturne playing Fleetwood Mac's Rumours in 5.1 as head-tracked Spatial Audio on AirPods Max, with a live meter for each of the six channels">
</p>
<p align="center"><sub><em>Rumours</em> in 5.1, rendered as head-tracked Spatial Audio on AirPods Max, with a live meter for every channel.</sub></p>

Nocturne plays FLAC, ALAC, WAV, AIFF, DSD (DSF/DSDIFF), APE, WavPack, TTA, Opus, Vorbis, Musepack, MP3, AAC and more. It switches your DAC (a FiiO K11, an AirPods Max on USB-C, a receiver, anything class-compliant) to each file's native sample rate and bit depth, and it tells you exactly what happens to the signal on the way there.

## Highlights

### Bit-perfect, all the way to 24/192
The device follows every track's native format, and **BIT-PERFECT** appears only when nothing touches the samples. Here a 24-bit / 192 kHz FLAC plays untouched on a FiiO K11.

![Coldplay's X&Y at 24-bit / 192 kHz playing bit-perfect on a FiiO K11](docs/screenshots/bit-perfect-fiio-24-192.png)

### Lossless on AirPods Max over USB-C
AirPods Max on USB-C are recognized as a lossless 24-bit / 48 kHz device. 48 kHz music plays bit-perfect, and the Digital Crown and volume keys control them directly.

![Ariana Grande's eternal sunshine at 24-bit / 48 kHz playing bit-perfect on AirPods Max over USB-C](docs/screenshots/bit-perfect-airpods-max-usb-c.png)

### Catches fake hi-res
Upsampled, padded, lossy-origin and "AI-enhanced" files are detected, with the evidence shown. Here a 24/48 file turns out to be a lossy source cut at 16.3 kHz, with a synthetic shelf generated above it.

![The Analysis tab flagging a track as having synthetic high frequencies, with its long-term spectrum](docs/screenshots/fake-hi-res-detection.png)

### Browse like Apple Music
Albums, artists, songs and **genres**, with Genre, Decade and format filters. Messy tags are handled: "Hip-Hop" and "hip hop" are one genre, multi-genre tags count under each, and localized genre names are merged.

![The Genres page: a tile per genre with a mosaic of its covers](docs/screenshots/genres.png)

### Search finds everything
Artists, albums (by title, artist, genre or year) and songs, in one place. Every word you type has to match, ignoring case and accents.

![Searching "fleetwood": the artist, 18 albums and 265 songs](docs/screenshots/search.png)

### Smart playlists that speak your language
Rules use the units shown everywhere else (48 kHz, 24-bit), so "every 24-bit / 48 kHz track" is one rule away. Here that playlist plays bit-perfect on AirPods Max.

![A smart playlist of every 24-bit / 48 kHz track, playing bit-perfect on AirPods Max](docs/screenshots/smart-playlist.png)

### A mini player that still tells the truth

<p align="center"><img src="docs/screenshots/mini-player.png" width="520" alt="Nocturne's mini player"></p>

## What it does

- **Automatic device format.** Each track's rate is matched on the device (16/44.1, 24/96, 24/192, 352.8…). If the device can't run at that rate, Nocturne converts with Apple's mastering-quality resampler. It prefers a rate in the same family (44.1 → 88.2), then the nearest higher rate, then an integer divisor (384 → 192). Per-device overrides: *match source*, *device maximum* or a fixed rate.
- **Shared or exclusive.** By default Nocturne shares the device and makes it the Mac's sound output while it plays, so volume keys, Control Center and the AirPods Max Digital Crown control what you hear. Playback is still bit-perfect unless another app plays through the same device at the same time, and Nocturne says so when that happens. **Exclusive (hog) mode** is one switch away if you'd rather silence other apps on the device (macOS then sends volume keys elsewhere); the device is released after a configurable pause.
- **Stays on the output you chose.** Nocturne never switches your music to another device on its own. If the chosen output is missing when playback starts (AirPods Max still reconnecting after you put them back on, a DAC being replugged), it waits for it for up to a minute and plays the moment it's back. If it drops out mid-song, playback continues where it left off once it returns.
- **Hands your DAC back.** When Nocturne quits, each device it switched goes back to the sample rate and bit depth it had before (so other apps, and tools like LosslessSwitcher, carry on where they left off), or to 44.1 kHz · 16-bit or 48 kHz · 24-bit if you prefer.
- **AirPods Max / AirPods Max 2 over USB-C.** These are recognized as lossless 24-bit / 48 kHz devices. 48 kHz material plays bit-perfect and everything else is converted to 48 kHz. Over Bluetooth, Nocturne tells you the link is AAC.
- **Dolby Atmos.** Dolby Digital Plus with Atmos (the format Apple Music and streaming services use) is rendered by macOS's own Atmos renderer on the output you chose: head-tracked Spatial Audio on AirPods, height channels on a multichannel output. Or, if you prefer, its 5.1/7.1 bed plays through Nocturne's own path.
- **Dolby Digital, Dolby Digital Plus, Dolby TrueHD, DTS-HD Master Audio.** `.ac3`, `.ec3`, Dolby audio in M4A/MP4, `.dts`, `.dtshd`, `.thd` and Matroska audio (`.mka`) all play, each channel in its place. TrueHD and DTS-HD MA are lossless and can be bit-perfect. With DTS:X and TrueHD Atmos, Nocturne plays the channel bed; the objects need a receiver.
- **Bitstream to an AV receiver.** Per output, Dolby Digital, Dolby Digital Plus (Atmos included, over HDMI) and DTS CDs can be sent untouched, in IEC 61937 bursts, for a receiver or soundbar to decode.
- **Integer mode.** With exclusive access, on DACs that offer it (the FiiO K11 does), music that needs no processing reaches the DAC as 32-bit integers with no floating-point step, so 32-bit recordings are bit-perfect too.
- **DTS CDs.** DTS 5.1 discs and DTS-WAV files (a DTS bitstream disguised as 16-bit stereo PCM, which other players blast out as full-scale noise) are recognized and decoded to 5.1, including albums split by a CUE sheet, so they play in surround or as Spatial Audio on AirPods.
- **DSD.** DSD goes to the DAC as DoP on DACs you mark as DoP-capable (off by default, because DoP sent to a non-DoP DAC is noise). Otherwise it's converted to high-rate PCM.
- **A truthful signal path.** *BIT-PERFECT* (brass) appears only when the rate is native, nothing touches the samples, no other app is mixing into the device and the word length fits. Every other state is shown in copper with the reason.
- **Gapless playback** across tracks that share a device format, including CUE-sheet albums split from a single file.
- **Volume.** Nocturne uses the DAC's hardware volume when it has one. Optionally, a 64-bit dithered digital volume can be enabled; it's clearly marked as not bit-perfect.
- **Find Music on This Mac.** Spotlight searches every drive. Each file's true format is checked, and hi-res, lossless or all music can be picked by folder or by file. Recordings, prompts, clips and duplicate copies are left out.
- **Library.** Folders are referenced in place and watched for changes, or you can *Import & Organize* to copy music into `~/Music/Nocturne`. On the same drive the copies are APFS clones and take no extra space. It keeps albums, artists, songs and genres, with Genre, Decade and format filters (albums are dated by their original release, not the reissue you have); search across artists, albums (title, artist, genre, year) and songs (accent-insensitive); playlists; and smart playlists whose rules use the same units as the rest of the app. Files on unplugged drives stay in the library and show as offline; files you delete disappear from every list on the next scan (and come back if you restore them). Files that are moved or renamed, for example by Lidarr reorganizing a share, are recognized as the same songs, so playlists, play counts and analysis stay with them.
- **Rich metadata editing** for single tracks or batches, written into the files via TagLib (Vorbis comments, ID3v2, MP4, APE). It covers artwork, sort fields, lyrics and custom tags. Each file is cloned to a backup (instant on APFS) and the previous tags are kept for one-step revert.
- **Enrich Metadata.** Missing titles, artists, albums, years, track numbers and cover art are filled in from structured file names and **MusicBrainz / Cover Art Archive**. Each proposal shows its source and confidence before anything is written.
- **MusicBrainz and Cover Art Archive** lookup and correction, and **ListenBrainz** scrobbling (optional; the token is kept in the Keychain).
- **Multichannel and Spatial Audio.** 5.0, 5.1, 7.1 and other multichannel files play everywhere: rendered with Apple's Spatial Audio (head tracked or fixed, with your personalized profile) on AirPods and Beats, sent channel-for-channel to multichannel interfaces and AV receivers (following your speaker setup, even when HDMI is left in 2-channel mode), or downmixed by layout on stereo DACs. The signal path always says which, with a live meter for every channel. **Export for Spatial Audio** turns them into binaural stereo that sounds spatial on any headphones, or multichannel ALAC for Apple devices.
- **Network shares.** Connect to SMB, NFS or WebDAV shares on your network or over Tailscale/VPN (⌘K). Read-only by default and mounted where macOS keeps network volumes (hidden from the Finder sidebar). They heal themselves: Nocturne reconnects after sleep, network changes and server restarts, and remounts a share that has stopped answering. Shares are rescanned every half hour (never while you're playing from them), so music added to or deleted from the server shows up by itself. Indexing is quick over slow links, and playback is built for slow or busy servers. It keeps up to half a minute of audio in hand, copies the playing track to the Mac straight away, and moves playback to that copy mid-song, sample for sample, the moment it's complete, so the rest of the song no longer depends on the network. What you play is cached, with **Keep Offline** for whole albums. Passwords live in the login keychain alongside Finder's.
- **Fake hi-res detection.** Finds a file's true bit depth (16-bit padded into 24-bit), upsampled "hi-res", lossy-origin files, and "enhanced" files whose high frequencies were synthesized (SBR or AI upscaling). Every verdict shows its evidence; results are saved, can run automatically on import, and filter the Songs view. A *Suspect Hi-Res* smart playlist collects them. For music on a NAS or server, `nocturne-analyze` runs the same analysis next to the files and Nocturne imports the results, so nothing is read over the network. [How it works](docs/ANALYSIS.md).
- **Live spectrum** of exactly what the DAC receives, plus a mini player, a menu-bar extra and full Now Playing / media-key integration.

## Build

```bash
brew install xcodegen
```

```bash
xcodegen generate && open Nocturne.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project Nocturne.xcodeproj -scheme Nocturne -configuration Release -derivedDataPath build/DD build
```

Run the engine and library tests, and the analysis core's (it also builds on Linux):

```bash
cd Packages/NocturneKit && swift test
```

```bash
cd Packages/NocturneAnalysis && swift test
```

`scripts/audit.sh` runs everything above plus the app tests, sanitizer builds of the real-time C code and a release build.

## Try it without your own music

`nocturne-demo` synthesizes an original demo library of 13 fictional albums in every supported container, including DSD64, a CUE-split album, a deliberately fake 24-bit track and an upsampled "hi-res" album:

```bash
cd Packages/NocturneKit && swift run -c release nocturne-demo ~/Desktop/NocturneDemo
```

To launch against an isolated test library, so your real one is untouched:

```bash
build/DD/Build/Products/Release/Nocturne.app/Contents/MacOS/Nocturne -NocturneDataDirectory /tmp/nocturne-test -NocturneAddSource ~/Desktop/NocturneDemo
```

### Hardware verification

`nocturne-probe` drives the real engine against a device and reads back what Core Audio actually did (nominal rate, physical format, hog owner):

```bash
cd Packages/NocturneKit && swift build -c release --product nocturne-probe
```

```bash
.build/release/nocturne-probe list
```

```bash
.build/release/nocturne-probe play "FiiO K11" 3 ~/Music/a.flac ~/Music/b.flac
```

`nocturne-library` runs the same library code from the command line:
- `find` lists folders with music;
- `hires` lists every hi-res file;
- `search <term>` searches tags;
- `import --library <dir> --into <dir> <files…>` imports;
- `enrich --library <dir> [--apply high|all]` enriches;
- `import-server-analysis --library <dir>` imports a share's server analysis results.

`gapless <device> <files…>` plays a queue and reports hand-offs and underruns. `analyze <files…>` runs the analysis (`analyze-json` prints it as JSON, for comparing with `nocturne-analyze file`); `forensics <files…>` prints its raw measurements as a table; `restore-test <device>` checks the quit options that hand a device back.

`scripts/qa-run.sh` and `App/Sources/App/DeveloperHooks.swift` hold the launch arguments used for visual QA. They can open albums, start playback, select inspector tabs and render windows to PNG, which works even while the screen is locked.

## Releasing

```bash
scripts/release.sh --notarize --install
```

```bash
scripts/publish.sh docs/releases/<version>.md
```

The first command builds a universal app and signs it (and every embedded framework and Sparkle helper) with the Developer ID. It then notarizes and staples both the app and a designed installer DMG. If Apple takes longer than two hours, rerun it with `--resume` instead of `--notarize`.

The second command publishes the GitHub release: it signs the Sparkle appcast entry with the `nocturne` EdDSA key from the login keychain and uploads `appcast.xml` next to the DMG. Installed copies read the feed from `releases/latest/download/appcast.xml`.

**Back up the Sparkle signing key.** Without it, no future update can be published to existing installs:

```bash
build/DDR/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account nocturne -x nocturne-sparkle-key.txt
```

Store that file somewhere safe (it is a secret), then delete it.

## Layout

| Path | What |
|---|---|
| `Packages/NocturneKit/Sources/CNocturneRT` | Real-time C: lock-free ring buffer, HAL IOProc, dithered gain, meters, spectrum tap |
| `Packages/NocturneKit/Sources/NocturneAudio` | Device discovery, shared/exclusive output, format switching, `FormatPlanner`, `PlaybackEngine`, Spatial Audio, decoding for analysis |
| `Packages/NocturneKit/Sources/NocturneLibrary` | GRDB/SQLite library, scanner, CUE, tag writer, genres, smart playlists, network shares, server-analysis import, MusicBrainz/ListenBrainz |
| `Packages/NocturneAnalysis` | The analysis core (spectra, forensics, verdicts) in plain Swift, plus `nocturne-analyze` for Linux servers |
| `App/` | SwiftUI app (Obsidian & Brass design) |
| `docs/` | Architecture notes, design mockups, screenshots |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how audio gets from file to DAC.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Third-party components: SFBAudioEngine (MIT), GRDB (MIT), TagLib (LGPL/MPL), libFLAC (BSD), WavPack (BSD), Monkey's Audio (BSD), libopus/libvorbis/libogg (BSD), mpg123 (LGPL), libsndfile (LGPL), LAME (LGPL), DUMB (zlib-like), TTA (LGPL), FFmpeg's DTS and TrueHD decoders and DTS/TrueHD/Matroska demuxers (LGPL-2.1+, built from source by `scripts/build-dts-decoder.sh`).
