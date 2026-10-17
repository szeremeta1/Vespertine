# 1.0 shot list

Every image and video of the app interface, the track each one is shot on, what it needs, and what has to be true on
screen before it ships. Shot on Vespertine 0.11.1 (Release of main at 8135150 plus this branch's QA hooks, run as its own copy with bundle ID `org.szeremeta.Vespertine.shoot`) against a copy of the maker's library (`-VespertineDataDirectory`), with the window at 1440×900 pt (`-VespertineWindowSize`) on a Retina display, captured window-only and scaled to 2400×1500, and background analysis off (`-autoAnalyze NO`). The Mac's default and alert outputs sit on the silent Vespertine Loopback during the shoot, so an exclusive hold on the K11 or the AirPods never moves macOS's output to the built-in speakers. Everything else (press key art, site
JPEGs, the tour, the social previews) is derived from these by the scripts named at the end.

| Scene (`docs/screenshots/`) | Track | Needs | True on screen |
|---|---|---|---|
| `multichannel-albums` | Albums, Multichannel chip | library | the grid shows Bob Dylan's *Blood on the Tracks* DSD64 5.1, Elton John's *Goodbye Yellow Brick Road* and Oasis's *Morning Glory* SACD among the multichannel albums |
| `bit-perfect-fiio-24-96` | *Les jeux d'eau à la Villa d'Este*, Lazar Berman (FLAC 24/96) | FiiO K11, exclusive mode | BIT-PERFECT, EXCLUSIVE, 32 / 96; 96 kHz native, unity volume, hog mode; TRUE 24 from analysis |
| `dsd-native-dop` | *Love for the Sake of Love*, Claudja Barry (DSD128) | FiiO K11, DoP enabled for it | NATIVE DSD · DoP, 32 / 352.8; DSD128 · 5.6 MHz source; DSD over PCM marked native DSD; no conversion step |
| `stereo-and-surround-versions` | *Don't Look Back in Anger*, Oasis, *Morning Glory* SACD: DSD64 stereo and 5.1 | AirPods Max | each song listed once, DSD64 · 5.1 + STEREO; the 5.1 version plays as head-tracked Spatial Audio; DSD → PCM 352.8 → 48 kHz shown as converted |
| `spatial-audio-airpods-max` | *Candle in the Wind*, Elton John (24/88.2 5.1) | AirPods Max, head tracking on | Spatial Audio active, 6 channels in, head tracking shown; no BIT-PERFECT badge (it's rendered, not bit-perfect) |
| `fake-hi-res-detection` | *Velvet Hour*, The Lantern Lounge Orchestra (the deliberate fake: MP3 192 kb/s → 24/192) | none | LOSSY ORIGIN?; claimed 24/192; steep cutoff ~16 kHz (measured on dormhub with `vespertine-probe` on a fresh fake from `score.py`, 76% of frames, 30 dB drop) |
| `search` | search "Let It Be"; *Let It Be*, The Beatles (DTS CD, 44.1 kHz 5.1) selected | library | DTS · 44.1 kHz · 5.1 next to the stereo FLAC mix and Dolly Parton's 24/96; tags read-only on the share |
| `genres` | Genres page | library | counts match the library |
| `smart-playlist` | smart playlist *AirPods Max Bit-Perfect*, filtered to Oasis; *Don't Look Back in Anger* (24/48) playing | AirPods Max | BIT-PERFECT, 48 kHz native, unity volume, exclusive |
| `mini-player` | *Don't Look Back in Anger*, Oasis (24/48) on AirPods Max | AirPods Max | BIT-PERFECT only if the device runs at 48 kHz with unity volume |
| `sacd-iso` | *Brothers In Arms*, Dire Straits, from the 2005 20th Anniversary SACD image (`SACD-R.iso`), stereo area | FiiO K11, DoP enabled for it | NATIVE DSD · DoP, 32 / 176.4; source SACD · DSD64 · 2.8 MHz; decoder "SACD image · DST (lossless) decoded to DSD"; unity volume, hog mode |
| `languages` (`languages.png`) | Albums › *Années de pèlerinage* (Lazar Berman), track 2 of each disc selected, Details inspector, in Japanese, German, Ukrainian, Arabic, Brazilian Portuguese and Simplified Chinese (`-AppleLanguages`; Arabic also with `-AppleTextDirection YES`, as on a Mac set to Arabic) | FiiO K11 selected, nothing playing | no truncated or overlapping strings; Arabic mirrored right to left; composited by `scripts/make-languages-grid.sh` |
| `output-settings` | Settings › Playback | FiiO K11 selected, nothing playing | the remembered output, the fallback to the best connected output, Match 16-bit sources on |
| `equalizer` | Window › Equalizer with the AutoEQ *Sennheiser HD 600* preset (oratory1990) on the FiiO K11, over the main window playing *Les jeux d'eau* (24/96); the two window captures are laid out as they sat on screen (`scripts/compose-windows.swift`) | FiiO K11 | the preset on for the K11; EQUALIZER badge and the Equalizer step in the signal path; no BIT-PERFECT badge |
| `loopback-test` | Controls › Loopback Test…, quick test run (`-VespertineOpenSheet loopback-run`) | the "Vespertine Loopback" output installed (`scripts/install-loopback-device.sh`) | BIT-EXACT for 24/44.1, 24/96, 16-bit padded and the gapless pair |
| `setup-welcome`, `setup-output` | first-run setup, welcome and output steps (`-VespertineSetup show -VespertineSetupStep welcome\|output`) on an empty library | none (silent) | the steps as a new user sees them |

## Video

- **Trailer** (`site/public/assets/trailer`): re-record the window clips (`scripts/brand/stage/raw`, ScreenCaptureKit, window
  only) on the same tracks as the stills, re-measure the overlay positions in `Scenes.swift` for each new recording,
  then `render.sh`, the Final Cut Pro edit and `deliver.sh`. Needs the FiiO K11 and AirPods Max for the bit-perfect,
  DSD and Spatial scenes.
- **Tour GIF** (`docs/screenshots/tour.gif`): `scripts/make-tour-gif.sh` from the stills.

## Derived

- Press key art (`docs/press/*`): `scripts/brand/build.sh`.
- Social previews (`site/public/assets/og*.png`): `scripts/make-social-preview.sh`. The website's per-page cards (`site/public/og/*.jpg`): `npm run og` in `site/`.
- Site JPEGs (`site/src/assets/shots/*.jpg`, `site/src/assets/press/*.jpg`): `scripts/make-site-images.sh`.
- Social previews render natively on a headless Mac with `VESPERTINE_SOCIAL_RENDERER=native`.

## Checks before a shot ships

1. The build is 1.0.0 (Release), from the commit being released.
2. The signal path in the inspector agrees with Audio MIDI Setup (device rate and format) at the moment of capture.
3. Every badge on screen is one the app earned on that file; no edited pixels inside the window.
4. No real release is shown as fake hi-res.
