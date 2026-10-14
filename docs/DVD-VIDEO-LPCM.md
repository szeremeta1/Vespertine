# DVD-Video LPCM

Vespertine plays the LPCM music on a DVD-Video disc straight from the disc image (`.iso`) or from a `VIDEO_TS` folder. Nothing is mounted, extracted or written. A disc becomes one album per title and one track per chapter. Each track is an exact sample range of its VOB's audio. Tracks go through the same import, index, decode and seek paths as CUE and SACD tracks.

**DVD-Audio is not supported.** That covers `AUDIO_TS`, MLP (Meridian Lossless Packing) and DVD-Audio PCM (`.AOB`). A disc that has only DVD-Audio content reports “This is a DVD-Audio disc” and adds no tracks. A hybrid disc plays only its DVD-Video LPCM.

## Supported formats

DVD-Video limits an LPCM stream to 6.144 Mbit/s. Every combination inside that limit is supported:

| Sample size | 48 kHz | 96 kHz |
|---|---|---|
| 16-bit | 1–8 channels | 1–4 channels |
| 20-bit | 1–6 channels | 1–3 channels |
| 24-bit | 1–5 channels | 1–2 channels |

Every sample is decoded exactly. The decoder outputs Float32, which holds 24-bit integers exactly, so the signal path can report the playback as bit-perfect.

Some streams are refused with an error rather than played:

- An LPCM header above the 6.144 Mbit/s limit, such as 24-bit 96 kHz with 3 channels.
- The 44.1 kHz and 32 kHz rate codes, and quantization code 3. DVD-Video allows none of these.
- An LPCM format that changes within a VOB.
- CSS-scrambled sectors. Encrypted discs must be decrypted rips.

A title set whose audio is AC-3, DTS or MPEG adds no tracks. Its error names the coding.

### Byte layout

16-bit samples are big-endian, frame by frame. 20-bit and 24-bit samples are stored in pairs of sample frames. Each pair holds, in order:

1. The upper 16 bits of every sample: frame 0's channels, then frame 1's.
2. The low bits in the same order. For 24-bit, that is one byte per sample. For 20-bit, it is one nibble per sample, two to a byte, earlier sample in the high nibble.

The 7-byte LPCM header (substream, frame count, first-access-unit pointer, frame number, format, dynamic range) is dropped. Frames and sample pairs may be split across packets. They are joined byte-exactly.

## Navigation and timing

- **Titles and cells.** The reader parses `VIDEO_TS.IFO`, then each `VTS_nn_0.IFO`. It reads audio attributes, program chains, programs, cell playback and position tables, the cell address table (VTS_C_ADT) and the VOBU address map. Title VOBs `VTS_nn_1.VOB` to `_9.VOB` form one sector address space.
- **Images.** `VIDEO_TS` is found through the image's UDF file system (ECMA-167 / UDF 1.02, as players use it). If that fails, ISO 9660 is used. Short and long allocation descriptors, extended file entries and multi-extent files are supported.
- **Exact timing.** Each cell's start comes from the presentation time of its first VOBU, from the NAV pack's PCI, on the 90 kHz clock. It is converted to the nearest sample of its VOB's LPCM run. Ties go to the later sample.
- **Ignored times.** The IFO's playback times are rounded to video frames and are never used for timing. On the Bob Dylan disc, summing them drifts by 7.6 s.
- **Time stamp checks.** Every packet's PTS is checked against the samples counted before it. A gap, an overlap or an off-lattice time stamp is an error.
- **Whole VOBs.** A VOB's first cell starts at its first sample. Its last cell runs to the last complete sample. The tail is kept even where the audio outlasts the video.
- **Seeking.** Seeks are sample-accurate. A binary search over sectors finds the packet by PTS, then the reader skips to the exact frame. Tracks that share a VOB join gaplessly.
- **Defective navigation.** The cell address table is checked:
  - Its entries must be in order and inside the VOBs.
  - Every program chain's cells must match it.
  - Every cell's first sector must be a NAV pack with its VOB and cell ID.

  If any check fails, cells are rebuilt from the NAV packs. The reader walks each VOBU's end address, or scans when that address is missing, and groups VOBUs by the DSI's VOB and cell IDs. Chapters that name programs or program chains that don't exist fall back to the title's own programs. IFOs that place cells past the end of the VOBs indicate a truncated copy. That is an error, not something to work around.

## What becomes a track

- **Menus.** Menus are never read: `VIDEO_TS.VOB` and `VTS_nn_0.VOB`, the VMGM and VTSM.
- **Previews.** A cell from a different VOB at the end of a program, under 120 s, is excluded as a navigation preview. Without this rule, a whole-title extraction reports the program's “last chapter” as running into the preview.
- **Unplayed cells.** Cells that no title plays are kept as an extra album when they are 120 s or longer. Shorter ones are excluded.
- **Duplicates.** A chapter whose cells another chapter already lists, or a “play all” program made of other chapters, is listed once.
- **Limits.** Only the first LPCM stream of a title set is played, and only the first angle of a multi-angle block.
- **Multichannel.** DVD-Video LPCM carries no speaker assignment. Channels are taken as stored, with the usual layout for the count.

## In the library

- **Locations.** An image is listed by its `.iso`. A `VIDEO_TS` folder is listed by its `VIDEO_TS.IFO`. Each track's location is `<path>#dvd-<title set>-<stream>-<first sector>-<last sector>-<n>`, which names the VOB run to reopen. The region is the track's sample range in that run.
- **Names.** DVD-Video has no text for artists or songs. Tracks are named “Track N”. The album is named after the image or the folder that holds `VIDEO_TS`, with “· Title N” added when a disc has several titles. Several titles usually means several albums, sometimes by different artists, so none is attributed to another. Edits stay in the library, as for CUE tracks.
- **Import and caching.** A `VIDEO_TS` folder is played in place: add it with Add Folder. Copy-and-organize import and Find Music skip it. Its tracks aren't cached from network shares, because the cache would copy only `VIDEO_TS.IFO`.
- **Rescans.** A folder disc is reread when its `VIDEO_TS.IFO` changes, not when only its VOBs do.
- **Upgrades.** No migration is needed. DVD images had no tracks before, and `.ifo` wasn't scanned, so an upgraded library picks discs up on its next scan.

## Verification

- **Unit tests.** `DVDVideoTests` and `DVDLibraryTests` use synthetic discs built in code (`DVDFixture`). They cover:
  - De-interleaving at every allowed width, rate and channel count, with the byte layout pinned by hand.
  - Packets splitting frames and access units.
  - Cell boundaries between samples, with audio multiplexed ahead of video.
  - NAV-pack cell recovery, broken chapter references, previews, play-all titles and unplayed cells.
  - Exact seeks at the beginning, middle and end.
  - Lost time stamps, non-pack sectors, CSS-scrambled packets, format changes, truncated VOBs and truncated images. All of these fail with an error.
  - ISO 9660, UDF (including extended file entries) and bridge images, plus AC-3-only and DVD-Audio discs.
  - Library scans and rescans.
- **Real discs.** `DVDVideoCorpusTests` is opt-in through `VESPERTINE_DVD_FIXTURES`. It decodes every track of real discs through `SourceOpener` and the region decoder. It hashes the complete PCM and compares it with independent references. It also checks seeks at the beginning, middle and end. Results are in [verification/dvd-video-lpcm-2026-10-14.json](verification/dvd-video-lpcm-2026-10-14.json).
  - **Disc image (a Bob Dylan compilation), 24/96 stereo.** 26 tracks (the disc's own readme lists 25), one VOB in 26 cells. Tracks 1–25 are identical, sample for sample, to an independent extraction from the import audit, made with FFmpeg and split at the chapters' 90 kHz times.
  - **Last Dylan track.** Track 26 is 88 samples (0.9 ms) longer than that extraction, and its first 16 008 392 samples match it. The disc's LPCM continues 88 samples past where the extraction stopped, with consistent time stamps. FFmpeg's plain MPEG-PS demuxer decodes those samples too, and the whole VOB run matches it bit for bit. Why the extraction stopped there isn't established. It isn't at the last VOBU's end time.
  - **VIDEO_TS folder (Supertramp's *Breakfast in America* and Roger Hodgson's *In the Eye of the Storm*), 24/96 stereo.** 19 VOBs. The result is 10 + 7 tracks in two titles, so two albums, plus 2 excluded previews of 67.9 s and 51.9 s. Every VOB's audio matches FFmpeg's decode of the same sectors. Previews included, all 19 VOBs in disc order match the import audit's whole-VOB-set decode.
- **Not tested on real discs.** No real disc has been tested at 16 or 20 bits, at 48 kHz, with more than 2 channels, with CSS, with multiple angles, or with several LPCM streams. Those paths are covered only by synthetic discs. For 20-bit and 24-bit with 3 or more channels, implementations disagree on the grouping:
  - Vespertine uses the sample-pair layout above. It matches FFmpeg for mono and stereo, and VLC for stereo.
  - FFmpeg and VLC group four samples at a time for 3 and more channels (VLC for mono too).
  - The layout is unconfirmed until a real multichannel 20-bit or 24-bit DVD-Video disc is checked.

These are decoding, seeking, library and build checks. They don't establish physical DAC compatibility, and they are not a published release.
