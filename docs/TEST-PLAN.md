# Test plan: macOS 27 and Intel Macs

A manual checklist for a release candidate on two configurations the automated tests don't cover:

- **macOS 27 on Apple silicon**, the current macOS. CI builds and tests on macOS 26 runners.
- **An Intel Mac.** CI checks that the universal build contains an x86_64 slice. The Intel build has run under Rosetta, but it has never run on an Intel Mac (README, Known limitations).

Copy this file into an issue or a note for each run and tick what passes. A failure gets its own issue (the [crash](https://github.com/szeremeta1/Vespertine/issues/new?template=crash.yml), [bug](https://github.com/szeremeta1/Vespertine/issues/new?template=bug_report.yml) or [device](https://github.com/szeremeta1/Vespertine/issues/new?template=dac_report.yml) template), linked from the run. Anything skipped is written down as skipped, not as passed.

## Run details

- [ ] Vespertine version and build (About Vespertine):
- [ ] macOS version and build (About This Mac):
- [ ] Mac model and chip:
- [ ] On Intel: Activity Monitor › CPU shows Vespertine's **Kind** as **Intel**, not **Apple** (an Apple silicon Mac running it under Rosetta also shows Intel, so check the chip too)
- [ ] Output devices on hand (DAC, AirPods, receiver, built-in speakers):
- [ ] Test music: your own files, or the synthesized demo library (`vespertine-demo`, [DEVELOPMENT.md](DEVELOPMENT.md)) plus the FFmpeg FATE samples for Dolby, DTS and TrueHD

## Install and first launch

- [ ] The DMG from the release opens and the app copies to Applications
- [ ] The first launch passes Gatekeeper with no warning beyond the usual "downloaded from the Internet" prompt
- [ ] `brew install --cask szeremeta1/tap/vespertine` installs the same version (or `brew upgrade --cask vespertine`)
- [ ] The setup assistant runs through: pick an output, add a music folder
- [ ] The Local Network prompt shows Vespertine's explanation when a network share is added
- [ ] Light Mode and Dark Mode: the main window, menu bar window, popovers, alerts and menus all draw dark and are readable

## Library

- [ ] Adding a folder scans it; albums, artists, songs and genres fill in
- [ ] Albums with stereo and multichannel versions show each song once
- [ ] Edition labels such as "(DCC Mastering)" or "(Japan SHM-CD)" join their album's editions card
- [ ] Filters and a smart playlist (for example 24-bit and 88.2 kHz or higher) give the expected tracks
- [ ] A CUE-sheet album lists its tracks and plays gaplessly
- [ ] The tag editor writes a change and keeps its backup copy
- [ ] Quit and reopen: the library, playlists, favorites and play history are all still there

## Playback and signal path

For each output device on hand:

- [ ] FLAC at 44.1, 96 and 192 kHz: the device switches to each file's rate and the signal path shows BIT-PERFECT
- [ ] Exclusive (hog) mode on and off: the signal path reports it, and other apps can't play while it's on
- [ ] Integer mode (if the device offers it)
- [ ] 16-bit files sent as 16-bit (Settings option)
- [ ] ALAC, WAV, AIFF, APE, WavPack and the lossy formats play
- [ ] DSF and DSDIFF (including DST-compressed): DoP on a DoP-capable DAC, PCM conversion otherwise; the signal path says which
- [ ] An SACD `.iso` (stereo and multichannel areas)
- [ ] A DVD-Video `.iso` or `VIDEO_TS` folder
- [ ] Dolby Digital, Dolby Digital Plus, TrueHD, DTS, DTS-HD MA and a DTS CD decode and play
- [ ] Gapless: a live or classical album plays through without clicks or gaps
- [ ] Unplug the DAC while playing: playback moves to the best connected output; plugging it back in returns to it
- [ ] Volume: hardware volume where the device has it; for a fixed-volume output, **Volume control in Vespertine** works, and below 100% the signal path no longer says BIT-PERFECT
- [ ] EQ: importing an AutoEQ preset works, and with EQ on the signal path says EQUALIZER
- [ ] Mini player, menu-bar extra and media keys control playback
- [ ] Up Next panel: Play Next, Add to Queue, drag to reorder, remove; History lists songs played for 10 seconds or more
- [ ] Spatial Audio on AirPods: 5.1 plays spatialized, and head tracking follows the AirPods or is reported as unavailable. Unverified: whether macOS offers head-tracked Spatial Audio on an Intel Mac, so record what the signal path says

## Loopback test (software check)

Needs a virtual loopback device ([LOOPBACK.md](LOOPBACK.md); `scripts/install-loopback-device.sh`).

- [ ] Settings › Playback › Loopback Test… runs every case and reports bit-exact for the formats the virtual device carries
- [ ] Or on the command line: `vespertine-probe loopback`, built as in [DEVELOPMENT.md](DEVELOPMENT.md)

## Analysis

- [ ] Analyzing a few albums gives verdicts with their measurements (the demo library includes one 24-bit track that is really 16-bit)
- [ ] Analyzing the whole library finishes, and the app stays responsive while it runs
- [ ] With a song playing from a network share, analysis keeps going

## Network shares

- [ ] An SMB share (and NFS or WebDAV if available) connects, scans and plays
- [ ] Keep Offline downloads an album, which then plays with the share disconnected

## Updates

- [ ] Vespertine › Check for Updates… reports the current version as up to date (or offers the newer release)
- [ ] Updating from the previous release through Sparkle installs and relaunches
- [ ] Beta channel ([BETA-CHANNEL.md](BETA-CHANNEL.md)), once a beta has been published: with `VespertineBetaUpdates` on the beta is offered, and with it off it isn't

## Languages

- [ ] Switch to one right-to-left language (Arabic or Hebrew) and one other: the layout mirrors and nothing is cut off in the main window, Settings and the setup assistant

## Performance (mainly for Intel)

- [ ] CPU in Activity Monitor while playing: FLAC 24/192, DSD256 or DSD512 converted to PCM, and 5.1 with Spatial Audio. Write the numbers down; there's no target yet
- [ ] No dropouts during a library scan or analysis while music plays
- [ ] Memory after an hour of playback is about what it was after the first few minutes

## After the run

- [ ] File issues for failures and link them here
- [ ] If an Intel Mac passed, update the README's Known limitations, `docs/FEATURES.md` and `docs/VERIFICATION.md` (all three say the Intel build has only run under Rosetta)
- [ ] Device results go in a [device report](https://github.com/szeremeta1/Vespertine/issues/new?template=dac_report.yml)
