# File analysis: how Vespertine tells real high resolution from fakes

Vespertine decodes a lossless file at its native rate (up to 10 minutes of it) and looks for four things.
Nothing is modified, and results are saved in the library so a file is only analyzed again when it
changes or when the analyzer improves (`FileAnalysis.currentVersion`).

Only zero padding is exact. The other three are read from the spectrum, and each has innocent
explanations, so the app shows them as questions ("LOSSY ORIGIN?"), never above "likely", and every
summary says what else could produce the same evidence.

| Verdict | What it suggests | What's measured | What else looks the same |
|---|---|---|---|
| **Padded bit depth** | A 16-bit recording stored in a 24-bit file | Every sample's lowest bits are zero. Exact. | Nothing (a 20-bit master in a 24-bit file is reported as 20 bits, which it is) |
| **Lossy origin?** | Made from an MP3, AAC or Opus file | A steep low-pass "wall", in most frames | Steep mastering or anti-alias filters, FM broadcast sources (15 kHz), band-limited historical masters |
| **Synthetic high frequencies?** | Made from a lossy file whose missing highs were *generated* (HE-AAC SBR, xHE-AAC, AI "enhancement"/"remaster" tools) | A step at the old cutoff, then a flat shelf of content whose level rises and falls with the music, often ending in a second wall | An exciter or noise reduction used on a band-limited recording |
| **Upsampled?** | A 44.1/48 kHz master (or a lossy file) sold at 88.2 kHz or higher | A steep wall between 19.6 and 24.5 kHz, the steepest in the file; or, above 22.05 or 24 kHz, a mirror image of the music just below it, moment by moment (what a converter's filter leaves) | For the wall: a steep low-pass applied in mastering, or a DSD-to-PCM conversion filtered that low. For the mirror: a mix with parts recorded or processed at 44.1/48 kHz |

**Genuine** means none of these was found, not that the file is proven genuine: some high-bitrate lossy
files pass (see [Limits](#limits)). Float and 32-bit files aren't tested for padding, and say so. A file
too short to measure (under about 1.5 s), or with nothing in its spectrum that stands out from the noise
floor (very quiet, or channels that cancel when mixed to mono), is reported as **inconclusive**.

## Measurements (`SpectralForensics`)

About four spectra per second (≈85 ms frames) are reduced to 100 Hz bands. From the frames that carry
music (1–4 kHz above −75 dBFS):

- **Cliffs.** For every band from 9 kHz to Nyquist, the level difference between 200–600 Hz below and
  200–600 Hz above. The steepest one is the *cliff*; every local maximum of at least 8 dB is a *step*.
- **Consistency.** The share of music frames (with real content just below) where the step shows up.
  Codec walls are in nearly every frame; natural roll-offs aren't walls at all.
- **Shelf.** Content above a step that stays at least 12 dB over the floor for 1.5 kHz or more, up to
  the next wall. Its slope (dB/kHz) separates generated shelves (flat) from natural highs (falling).
- **Tracking.** How closely the shelf's level follows the music just below the step, frame to frame
  (correlation, −1…1). Generated highs are made from the music below and follow it; tape hiss or vinyl
  surface noise added after a band-limited source stays put (measured: 0.96–0.99 for generated shelves,
  −0.07–0.29 for steady hiss and surface noise). A shelf counts as synthetic only at 0.5 or more; below
  that, the step is reported as a cutoff with steady noise above it.
- **Mirror** (88.2 kHz and up). Upsampling puts a reflection of the music below the source's Nyquist
  (22.05 or 24 kHz) above it. A long, clean filter removes it and leaves the wall above; the shorter ones
  converters use by default (ffmpeg's among them) leave it, a few dB down just above the old Nyquist and
  20–40 dB down 2–3 kHz further, and their wall lands at ~25–33 kHz, above the upsampling zone (with a
  low-quality converter there's no wall at all). So for each old Nyquist, in five 800 Hz
  stretches from 0.15 to 4.15 kHz on either side, every frame's fine structure (each bin's level minus the
  average of the bins around it) is compared with the previous frame's, and the change below is
  correlated with the change above, reflected (−1…1). Where both sides stand out from the floor, the
  mean over the frames is the *mirror correlation*. Changes, not levels: a sustained tone whose partials
  happen to sit on their own reflection doesn't change, and a genuine partial that glides moves the same
  way on both sides, while an image moves the opposite way, exactly.
- **Floor.** The quietest 1 kHz stretch, so "content" means something relative to this file.

## Calibration

Thresholds were set on labelled audio, not guessed:

- **Genuine:** CD and hi-res masters (analog-era and modern, classical to pop), plus 16/44.1 CD rips.
- **Fakes made from those same excerpts:** MP3 128/320/V0 (LAME), AAC 128/256 (Apple), Opus 96/160,
  HE-AAC 40/64 kbps (SBR, i.e. real bandwidth extension), 44.1 kHz → hi-res upsampling, 16-bit padding;
  every fake converted back to 24-bit FLAC at the original rate, which is how fake "hi-res" is made.

What the data showed:

- Genuine masters never had a wall of 15 dB or more below 19.6 kHz.
- Genuine CD masters have their anti-alias wall at 20.4–21.3 kHz, and steep ones (up to ~39 dB) sit at
  21.1 kHz and above. 20 kHz-class codec walls sit at 19.9–20.6 kHz (MP3 320 ≈ 20.0, Opus 20.3, HE-AAC
  20.4–20.6). So in CD-rate files only walls below 20.7 kHz count, and only when steep (22 dB or more)
  and consistent (85% of frames or more).
- In hi-res files, the same zone means "made from a 44.1/48 kHz file" and is reported as upsampled.
- "Little content above 24 kHz" is *not* evidence of upsampling on its own: analog tape masters roll off
  naturally. Only a steep wall is, or (from version 4) a mirror image.
- Below 44.1 kHz a file's own anti-alias filter falls in the codec zone (a 32 kHz master cuts off near
  15 kHz), so the top tenth of its band is never counted as a codec wall.

Results (verdict counted correct when a fake is flagged with any non-genuine verdict):

| Pipeline | Flagged |
|---|---|
| Genuine masters | 0 of 11 flagged (all genuine) |
| MP3 128 / MP3 320 | 13/13 · 13/13 |
| MP3 V0 | 9/13 |
| AAC 128 / AAC 256 | 13/13 · 6/13 |
| Opus 96 / 160 | 13/13 · 13/13 |
| HE-AAC (SBR) 40 / 64 | 13/13 · 13/13 |
| Upsampled from 44.1 kHz | 8/8 |
| 16-bit padded | 13/13 |

On 79 real files from a large personal library, 4 were flagged; spectrograms confirmed all 4 (an MP3
transcode, an MP3 later upsampled to 192 kHz, a 48 kHz session and a CD master both sold as 24/96).
Two fan releases labelled "Enhanced 24-bit" were correctly identified as synthetic high frequencies.

These results were measured with analysis version 2. At 44.1 kHz and above, version 3 turns no flag
into "genuine": a shelf that doesn't follow the music, or (at 44.1 kHz) a weak step vouched for only by
a wall in the CD filter zone, is now reported as a lossy-origin cutoff instead of synthetic high
frequencies. Tracking wasn't re-measured on the files above; on generated SBR-style shelves it's
0.96–0.99. Below 44.1 kHz, a cutoff in the top tenth of the band now counts as the file's own filter:
genuine 32 kHz and 22.05 kHz masters are no longer flagged, and a lossy file at those rates whose
cutoff sits that high isn't either.

Version 4 adds the mirror. Version 3 passed a full-band 48 kHz master upsampled with ffmpeg's default
resampler (`ffmpeg -i master.flac -ar 96000 fake.flac`) as genuine at every hi-res rate: the images
pushed the wall to ~28 kHz (32 kHz with a shorter filter, 24.8 kHz with `filter_size=128`; with a
low-quality converter there was no wall at all). Measured on synthetic masters (music-like, with noise
up to the top of the band) upsampled with ffmpeg (default, shorter and longer filters, soxr) and by
linear interpolation, at 16 and 24 bits, from 44.1 and 48 kHz to 88.2–192 kHz:

| Material | Mirror correlation |
|---|---|
| ffmpeg's default and shorter filters | 0.87–1.00 |
| The same from a master with its own anti-alias filter (its wall is in the zone too) | 0.63 (16-bit) – 0.96 |
| Longer ffmpeg filters (`filter_size` 64–256) | 0.65–0.88 |
| Linear interpolation | 1.00 |
| soxr (no image left; caught by its wall at 23.6–24.0 kHz) | not measurable |
| Made at 88.2–192 kHz, content to 40+ kHz | −0.03–0.02 |
| DSD-style conversions low-passed at 24.5, 30 and 40 kHz | −0.01–0.02 |
| Sustained tones whose partials sit on their own reflection | 0.21 at most |

A mirror counts at 0.5 or more, in at least 8 frames. A DSD conversion low-passed at 30 kHz stays
genuine: its wall is above any 44.1/48 kHz source's, and what's above 24 kHz doesn't mirror. These are
synthetic masters, not the labelled corpus above; no genuine hi-res file has been measured above 0.21.

Version 4 also stops calling an MP3's top band synthetic. At 128 kb/s LAME passes a band of real,
quieter content between its step (~16.6 kHz) and its low-pass (~18.2 kHz), and since it is the music,
it follows the music. A shelf narrower than 3 kHz that ends below 19.6 kHz is now read as an encoder's
low-pass transition, a lossy origin; the generated shelves in the calibration set are 4.5–4.7 kHz wide
and end at 20.3–21.0 kHz.

Stored results are judged anew from their measurements, except hi-res files that would come out
genuine without the mirror, which never measured it: those are analyzed once more (on a server too).

## Limits

- High-bitrate lossy files whose cutoff sits where CD mastering filters do (some AAC 256 and LAME V0)
  can pass as genuine. Flagging them would flag genuine CDs too; Vespertine prefers not to accuse a
  genuine file.
- The reverse also happens: a steep cutoff is a steep cutoff, whatever made it. Genuine lossless files
  are flagged when a steep low-pass sits in their signal path: a CD whose anti-alias or sample-rate
  converter filter is fully closed by about 21 kHz (only "possible" there, since codecs and CD filters
  overlap at 19.6–20.7 kHz), an FM broadcast recording (15 kHz), a historical remaster low-passed to
  remove hiss, or a hi-res transfer low-passed at 20–22 kHz in mastering or DSD conversion. Steady hiss
  or surface noise above such a cutoff (tape transfers, needle drops) is recognized and named, but a
  noise level that moves with the music (Dolby or dbx noise reduction on playback) can still look
  synthetic. Treat a flag as a reason to look at the spectrum and the source, not as proof.
- A lossy file whose highs were regenerated so well that no step or shelf remains would not be
  detected. None of the tools tested produce that.
- The mirror needs something to reflect: a master with little just below its Nyquist leaves an image
  too faint to measure (its own filter's wall, in the upsampling zone, is caught instead), and so can a
  16-bit file whose image sinks into its noise. A hi-res file upsampled again (88.2/96 to 176.4/192 kHz)
  isn't looked for.
- A genuine hi-res mix with parts recorded or processed at 44.1/48 kHz (samples, or a plugin that runs at
  the lower rate) carries their images and can be flagged as upsampled; the summary says so.
- The results table scores the same corpus the thresholds were set on, so it shows that the detector
  separates that data, not a measured error rate on unseen files. The 79 real files above are the only
  out-of-sample check, and that is a small one.
- Verdicts are evidence, not proof. The inspector shows the measurements (cutoff, drop, consistency,
  shelf and how it tracks the music) and marks them on the spectrum so you can judge for yourself; the
  mirror correlation is quoted in the summary.

## Reproducing

`vespertine-probe forensics <files…>` prints every measurement and the verdict as a tab-separated row,
and `vespertine-probe analyze <files…>` prints the verdict with its explanation.

To see a verdict on files you can regenerate, make a fake with macOS's own tools. This encodes a track as
HE-AAC (which adds synthetic highs above its cutoff) and converts it back to a 24-bit FLAC, which is how
fake "hi-res" is made:

```sh
afconvert -f m4af -d aach -b 64000 original.flac he.m4a
ffmpeg -i he.m4a -ar 48000 -c:a flac -sample_fmt s32 fake.flac
vespertine-probe analyze original.flac fake.flac
```

On a track from the `vespertine-demo` library this reports the original as genuine and the copy as
a lossy origin (a brick-wall cutoff at about 20.5 kHz). Use real, full-bandwidth music for other tests:
the demo's synthetic tracks have almost nothing above 3 kHz, so an ordinary AAC re-encode of one has no
cutoff to find and passes as genuine.

The most common home-made fake is one ffmpeg command. From a 48 kHz master with content up to 24 kHz
(a digital production, or a recording whose converter filter closes late):

```sh
ffmpeg -i master48.flac -ar 96000 -c:a flac -sample_fmt s32 fake96.flac
vespertine-probe analyze master48.flac fake96.flac
```

The copy is reported as upsampled: above 24 kHz its spectrum mirrors the music just below.
`vespertine-probe forensics` shows the mirror's old Nyquist, correlation and frames in its last three columns.

## Analyzing on the server (`vespertine-analyze`)

Analysis reads every file in full. For music on a network share, especially a remote one, it's far faster
to analyze next to the files and let Vespertine import the results. `vespertine-analyze` runs the same analysis
code as the app (`Packages/VespertineAnalysis`, plain Swift + Foundation), decoding with ffmpeg. Results
match the app's: same verdicts, bit depths and cutoffs (the portable FFT is tested against Accelerate's).

Build a static Linux binary (from any machine with a Swift 6.4 toolchain and the matching
[static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)):

```bash
swift build --package-path Packages/VespertineAnalysis -c release --swift-sdk x86_64-swift-linux-musl --product vespertine-analyze
```

On the server, install `ffmpeg`, copy the binary to `/usr/local/bin`, and point it at the folder the share
exports:

```bash
vespertine-analyze index "/srv/music"
```

It writes `/srv/music/.vespertine/analysis.jsonl` (one JSON record per file; appended as it goes, so an
interrupted run loses nothing) and `status.json` (progress). Later runs analyze only new or changed files,
and after an update, files whose stored result Vespertine can't judge anew from its measurements.
The music itself is only ever read. Run it nightly at low priority as an ordinary user that can read the
music and write `.vespertine` (never as root), for example with systemd:

```ini
# /etc/systemd/system/vespertine-analyze.service
[Service]
Type=oneshot
User=media
ExecStart=/usr/local/bin/vespertine-analyze index "/srv/music" --jobs 2
Nice=19
CPUWeight=10
IOWeight=10
IOSchedulingClass=idle

# /etc/systemd/system/vespertine-analyze.timer
[Timer]
OnCalendar=*-*-* 01:00
Persistent=true
[Install]
WantedBy=timers.target
```

Vespertine looks for `.vespertine/analysis.jsonl` at the root of each connected share, imports matching results
(same path, size and modification time) every few minutes, reading only what was appended since last time,
and stops reading that share's files for background analysis. Settings → Library shows the server's progress.
