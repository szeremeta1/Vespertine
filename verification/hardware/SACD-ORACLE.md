# SACD oracle: Vespertine against sacd_extract

**Claims:** `CLAIMS.md#sacd-match`, `#sacd-toc`, `#sacd-areas`, `#sacd-readonly`, `#sacd-gapless`, and real-disc
evidence for `#sacd-dst`. **Records:** DST-003 (decoder against libdstdec on the fixtures, in CI) and DST-006 (the
disc format, `blocked-on-source`: the Scarlet Book is licensed to SACD licensees only, so there is no spec to cite
and no purchase route).

The README says Vespertine "matched sacd_extract bit for bit on two real discs". The repository holds no script or
log of that comparison, so the claim can't be re-checked from the repository today. This procedure makes it
re-runnable. Until it has been run and its output recorded, the claim rests on the earlier, unrecorded run.

## The oracle

`sacd_extract` from SACD Ripper reads the disc with its own TOC parser and decodes DST with libdstdec, the
Philips reference module (not FFmpeg's decoder, from which Vespertine's `vespertine_dst.c` is derived). The build
on Alex's machines is "Enhanced sacd_extract" 0.3.9.3 pre-release, Linux x86-64, 2021-12-13, SHA-256
`2f3a280c73d0e8f49c5ad2071d4949e1f621a7987d758dc1123e886746c70bab` (`../SOURCES.md`). It runs on Linux, so step 2
runs on the home server where the images are; step 1 needs macOS.

## Steps (about 30 minutes per disc, most of it waiting)

**0. Fingerprint the image** (`#sacd-readonly`). On the Mac that will read it:

```sh
shasum -a 256 disc.iso > disc.iso.sha256; stat -f '%m %z' disc.iso >> disc.iso.sha256
```

**1. Vespertine's reading** (macOS):

```sh
cd verification/harness
VERIFICATION_SACD_ISO=/path/disc.iso VERIFICATION_SACD_OUT=/tmp/vsacd swift test --filter dumpSACDImage
```

This writes `/tmp/vsacd/toc.json` (areas, channel counts, DST or plain, track start frames and lengths, titles),
one DSDIFF file per track (`2ch-01.dff` …, `mch-01.dff` …) and each area in one piece (`2ch-all.dff`,
`mch-all.dff`). The DSD is what `SACDSource` hands the engine, DST frames decoded by `vespertine_dst.c`. The test
fails if any frame was missing or damaged and played as silence.

**2. sacd_extract's reading** (on the server). Record the build's own usage text first, because the options below
are SACD Ripper's documented ones and an "enhanced" build may name them differently:

```sh
sacd_extract --help > sacd_extract-help.txt 2>&1; sha256sum "$(command -v sacd_extract)"
sacd_extract -P -i disc.iso > sacd_extract-toc.txt               # print the disc and track information
sacd_extract -2 -p -c -i disc.iso                                  # stereo area: DSDIFF, DST converted to DSD
sacd_extract -m -p -c -i disc.iso                                  # multichannel area
```

`-c` matters: without it a DST area comes out as DST-compressed DSDIFF, which `compare_dsd.py` refuses.

**3. Compare.** Copy one side to the other machine, then for each area:

```sh
# every track, in order, against the area in one piece: the DSD of the whole area, and the joins
python3 verification/oracles/sacd/compare_dsd.py /tmp/vsacd/2ch-all.dff <sacd_extract's stereo tracks, in order>
# each track on its own: the track boundaries
for n in 01 02 03; do python3 verification/oracles/sacd/compare_dsd.py /tmp/vsacd/2ch-$n.dff "<sacd_extract's track $n>"; done
```

and compare `toc.json` with `sacd_extract-toc.txt` by eye: the areas, channel counts, DST or plain, track count
and titles, and track lengths.

**4. Fingerprint again** and diff with step 0 (`#sacd-readonly`).

## What counts

| Check | Pass |
|---|---|
| Whole area | `IDENTICAL` for every area (`#sacd-match`, `#sacd-dst` on real DST, `#sacd-gapless`) |
| Each track | `IDENTICAL` for every track. A difference only at a track's first or last frames, with the whole area identical, means the two place track boundaries differently: record it, it isn't a decoding error. |
| TOC | same areas, channels, coding, track count and titles (`#sacd-toc`, `#sacd-areas`) |
| Image | hash, size and modification time unchanged |

The DoP and PCM outputs the README also mentions follow from the DSD: DoP packing is checked bit for bit by the
DoP groups of the harness, and PCM from SACD goes through the same FFmpeg `dsd_msbf` converter as DSDIFF files.

## Record

Commit `toc.json`, `sacd_extract-help.txt`, `sacd_extract-toc.txt` and the compare output under
`verification/runs/sacd-<date>/` (no audio, no image). The disc names already in the docs are The Dark Side of the
Moon (2003; plain stereo, DST 5.1) and Brothers in Arms (20th anniversary; DST stereo, DST 5.1).
