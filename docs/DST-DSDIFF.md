# DST-compressed DSDIFF

SACD images and DST-compressed DSDIFF are separate input paths. The SACD reader already recognizes plain 2,048-byte sectors and raw 2,064-byte sectors. Before this fix, `.dff` files went through the bundled FFmpeg reader, whose enabled decoders did not include DST. Such a file could have library metadata while playback failed with “Decoder not found”.

`DSTDSDIFFInfo` reads the DSDIFF properties, frame count and optional seek index. `DSTDSDIFFSource` decodes its DST frames using the same production DST implementation as SACD images. It provides raw DSD to DoP or to the shared, primed DSD-to-PCM converter. Existing CUE-region handling applies after that. Nothing is extracted into or written over the source file.

The parser follows [Philips DSDIFF 1.5](https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf), §§3.2 and 3.4–3.5. An absent or structurally invalid optional index is rebuilt from frame headers. Indexed frames are checked against their actual headers. Truncated containers, invalid frames and mismatching optional CRCs fail decoding. Reads are buffered for sequential/network access; indexed seeks do not decode the preceding album.

Library migration `v17-dst-dsdiff` invalidates previously misclassified `.dff` rows, including CUE tracks, for the next scan. Otherwise unchanged file timestamps would preserve their old metadata. Track IDs, play counts and library state survive the reread.

The source audit also exposed an EAC CUE parser bug: `FILE` may follow `TRACK` or its `INDEX 00`, before `INDEX 01`. The parser now retains pending metadata and associates the track with the file containing `INDEX 01`. A regression covers both command orders and a cross-file pregap. The library scanner still only creates virtual tracks for single-file CUE sheets; multi-file sheets are copied by the organizer and their audio files are scanned normally. This change does not claim new multi-file virtual-track support.

## Verification

- `DSTDSDIFFTests`: indexed/unindexed stereo, five-channel and six-channel files; compressed and stored frames; every DSD byte and the complete PCM/DoP outputs against an uncompressed equivalent; seeking; optional CRCs; malformed indexes, truncation and damaged frames.
- `SACDLibraryTests`: raw/plain SACD import preserves the image byte for byte; compressed DSDIFF CUE tracks scan correctly; an old library upgrades and rereads unchanged files without losing play counts or track IDs.
- `SACDCorpusTests`: opt-in actual-image and DSDIFF checks through the app's own source opener and PCM/DoP paths. These open no output device.
- [Corpus runner](../verification/oracles/sacd/corpus/README.md): complete production-core reads and per-track hashes on a server, with matching native macOS integration checks. [Recorded results](../verification/runs/sacd-2026-10-14/) contain no audio or private source paths.

A complete SACD-area read retains pauses between tracks. Independent extractors can end each track at its declared duration instead. Any differing lengths must be checked at the original track boundary; a matching music prefix and separately retained pause are not a decoding mismatch. Never silently label a different-length comparison “identical”.

The real-file audit also found malformed headers in older DSF conversions made by an external converter. Those files are independent reference artifacts, not inputs to the new decoder. Their sample counts and data sizes must be validated against the original DSDIFF and [Sony's DSF specification](https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf). Padding must not be counted as music. Library-only header repairs retain the audio bytes and have per-file backups; torrent sources remain unchanged.

These are decoding, seeking, library and build checks. They do not establish physical DAC/receiver compatibility or constitute a published release.
