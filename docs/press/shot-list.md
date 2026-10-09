# 1.0 shot list

Every image and video of the app interface, the track each one is shot on, what it needs, and what has to be true on
screen before it ships. Shot on Vespertine 1.0.0 against the maker's library. Everything else (press key art, site
JPEGs, the tour, the social previews) is derived from these by the scripts named at the end.

| Scene (`docs/screenshots/`) | Track | Needs | True on screen |
|---|---|---|---|
| `multichannel-albums` | Albums, Multichannel chip | library | the grid shows *Let It Be* (The Beatles, DTS CD 44.1 kHz 5.1), Bob Dylan DSD64 5.1, Elton John 24/88.2 5.1 and Oasis DSD64 5.1 |
| `bit-perfect-fiio-24-192` (renamed `bit-perfect-fiio-24-96`) | *Les jeux d'eau à la Villa d'Este*, Lazar Berman (FLAC 24/96) | FiiO K11, exclusive mode | BIT-PERFECT badge; source 24/96, device 96 kHz native, unity volume, hog mode; TRUE 24 badge from analysis |
| `dsd-native-dop` | *Love for the Sake of Love*, Claudja Barry (DSD128) | FiiO K11, DoP enabled for it | DSD128 source; DoP at 352.8 kHz on the device; no PCM conversion step; BIT-PERFECT shown only if the path says so |
| `stereo-and-surround-versions` | *Don't Look Back in Anger*, Oasis: stereo 24/96 and DSD64 5.1 | library | the song listed once with both versions; the version played matches the output (stereo on a stereo device) |
| `spatial-audio-airpods-max` | *Candle in the Wind*, Elton John (24/88.2 5.1) | AirPods Max, head tracking on | Spatial Audio active, 6 channels in, head tracking shown; no BIT-PERFECT badge (it's rendered, not bit-perfect) |
| `fake-hi-res-detection` | *Velvet Hour*, The Lantern Lounge Orchestra (the deliberate fake: MP3 192 kb/s → 24/192) | none | LOSSY ORIGIN?; claimed 24/192; steep cutoff ~16 kHz (measured on dormhub with `vespertine-probe` on a fresh fake from `score.py`, 76% of frames, 30 dB drop) |
| `search` | search "Oasis" (or "Let it be"); the list includes *Lost*, Cali Life Style (MP3 128 kb/s) | library | MP3 · 128 kb/s, Lossy, and no hi-res badge on it |
| `genres`, `smart-playlist` | library pages; smart playlist *AirPods Max Bit-Perfect* | library | counts match the library; rules shown are the playlist's |
| `mini-player` | *Don't Look Back in Anger*, Oasis (24/48) on AirPods Max | AirPods Max | BIT-PERFECT only if the device runs at 48 kHz with unity volume |

## Video

- **Trailer** (`site/assets/trailer`): re-record the window clips (`scripts/brand/stage/raw`, ScreenCaptureKit, window
  only) on the same tracks as the stills, re-measure the overlay positions in `Scenes.swift` for each new recording,
  then `render.sh`, the Final Cut Pro edit and `deliver.sh`. Needs the FiiO K11 and AirPods Max for the bit-perfect,
  DSD and Spatial scenes.
- **Tour GIFs** (`docs/screenshots/tour*.gif`): `scripts/make-tour.swift` from the stills.

## Derived

- Press key art (`docs/press/*`): `scripts/brand/build.sh`.
- Social previews (`site/assets/og*.png`): `scripts/make-social-preview.sh`.
- Site JPEGs (`site/assets/*.jpg`, `site/assets/press/shot-*.jpg`): crops of the stills.

## Checks before a shot ships

1. The build is 1.0.0 (Release), from the commit being released.
2. The signal path in the inspector agrees with Audio MIDI Setup (device rate and format) at the moment of capture.
3. Every badge on screen is one the app earned on that file; no edited pixels inside the window.
4. No real release is shown as fake hi-res.
