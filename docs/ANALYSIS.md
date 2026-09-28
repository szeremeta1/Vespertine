# File analysis: how Nocturne tells real high resolution from fakes

Nocturne decodes a lossless file at its native rate (up to 10 minutes of it) and looks for four things.
Nothing is modified, and results are saved in the library so a file is only analyzed again when it
changes or when the analyzer improves (`FileAnalysis.currentVersion`).

| Verdict | What it means | How it's found |
|---|---|---|
| **Padded bit depth** | A 16-bit recording stored in a 24-bit file | Every sample's lowest bits are zero. Exact. |
| **Lossy origin** | Made from an MP3, AAC or Opus file | A steep low-pass "wall" that codecs apply, in most frames |
| **Synthetic high frequencies** | Made from a lossy file whose missing highs were *generated* (HE-AAC SBR, xHE-AAC, AI "enhancement"/"remaster" tools) | A step at the old cutoff, then a flat, uniform shelf of content, often ending in a second wall |
| **Upsampled** | A 44.1/48 kHz master sold at 88.2 kHz or higher | A resampler wall between 19.6 and 24.5 kHz with nothing recorded above |

## Measurements (`SpectralForensics`)

About four spectra per second (≈85 ms frames) are reduced to 100 Hz bands. From the frames that carry
music (1–4 kHz above −75 dBFS):

- **Cliffs.** For every band from 9 kHz to Nyquist, the level difference between 200–600 Hz below and
  200–600 Hz above. The steepest one is the *cliff*; every local maximum of at least 8 dB is a *step*.
- **Consistency.** The share of music frames (with real content just below) where the step shows up.
  Codec walls are in nearly every frame; natural roll-offs aren't walls at all.
- **Shelf.** Content above a step that stays at least 12 dB over the floor for 1.5 kHz or more, up to
  the next wall. Its slope (dB/kHz) separates generated shelves (flat) from natural highs (falling).
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
  naturally. Only a steep wall is.

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

## Limits

- High-bitrate lossy files whose cutoff sits where CD mastering filters do (some AAC 256 and LAME V0)
  can pass as genuine. Flagging them would flag genuine CDs too; Nocturne prefers not to accuse a
  genuine file.
- A lossy file whose highs were regenerated so well that no step or shelf remains would not be
  detected. None of the tools tested produce that.
- Verdicts are evidence, not proof. The inspector shows the measurements (cutoff, drop, consistency,
  shelf) and marks them on the spectrum so you can judge for yourself.

## Reproducing

`nocturne-probe forensics <files…>` prints every measurement and the verdict as a tab-separated row.
