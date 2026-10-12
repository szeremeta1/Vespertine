# IEC 61937 carrier oracle

**Records:** IEC-O-001, IEC-O-002 (oracle). IEC-001 to IEC-007 (the burst format itself) are `blocked-on-source`:
IEC 61937-1, -2, -3 and -5 are paywalled and were not bought (decision 2026-10-09: oracle only; CHF 440 for the four
parts, see `../SOURCES.md`).

**Claim:** `CLAIMS.md#iec-carrier-exact`. What this establishes is that the frames come out of Vespertine's carrier
intact and in order, read back by two independent readers. It does not establish that the burst preamble, data
types, Pd units or padding conform to IEC 61937, and it says nothing about any receiver (`CLAIMS.md#iec-scope`).

## What runs, and where

| Step | Where | What |
|---|---|---|
| 1 | CI, macOS (`verification-macos`) | `AcceptanceTests/IECCarriers.swift` writes the carrier Vespertine sends for each Dolby test file: the output of `BitstreamDecoder`, the object the engine plays in bitstream mode, unchanged, as 16-bit stereo WAV at the carrier rate. |
| 2 | CI, Linux (`verification-iec-oracle`) | `oracles/iec61937/check_carriers.py` reads each carrier back with FFmpeg 6.1.1's S/PDIF demuxer (`-f spdif`), writes the frames out raw and compares them with the original `.ac3` / `.ec3` byte for byte (IEC-O-001). |
| 3 | same job | the same script runs `oracles/carrier-scan/carrier_scan.py compare`: a scanner written blind from ATSC A/52:2018 (syncinfo, frame size table, Annex E `frmsiz`, CRCs) that never saw IEC 61937 or FFmpeg, and finds the codec frames in the carrier by their own sync words and CRCs (IEC-O-002). |

The carriers pass between the two jobs through the Actions cache (`enableCrossOsArchive`), keyed by run, since the
repository pins no artifact action.

| Carrier | Holds | Rate |
|---|---|---|
| `dolby-digital-tones.ac3.iec.wav` | `dolby-digital-tones.ac3` (AC-3, 5.1, 384 kb/s) | 48 kHz |
| `dolby-digital-plus-tones.ec3.iec.wav` | `dolby-digital-plus-tones.ec3` (E-AC-3, 5.1) | 192 kHz |
| `dolby-digital-plus-tones.m4a.iec.wav` | the same E-AC-3 frames, read from MP4 | 192 kHz |

DTS isn't covered: Vespertine sends DTS CDs to a receiver as stored (16-bit words straight from the file, no
IEC 61937 burst; `CLAIMS.md#iec-dtscd`), decodes other DTS files to PCM, and nothing calls `IEC61937.dtsBurst`
(see `../FINDINGS.md`).

## Why these two oracles

- **FFmpeg's demuxer** (`libavformat/spdifdec.c`, `spdif.c`, `spdif.h` at tag `n6.1.1`, pinned by the IEC-O-001
  hash; `tools/fetch_oracles.py` fetches exactly those files). It was written from the IEC text by people outside
  this project and is what most software uses to read IEC 61937. The job refuses any FFmpeg that isn't 6.1.1, the
  version whose source the record pins (Ubuntu 24.04's package).
- **The blind scanner** shares nothing with FFmpeg or with Vespertine: it knows only the codecs' frame syntax from
  the public ATSC standard, and it would find a frame that is truncated, split, byte-swapped wrongly or followed by
  junk that parses as a frame. Its brief is `runs/2026-10-09/briefs/carrier-scan.md`, its report
  `runs/2026-10-09/reports/carrier-scan.md`.

Agreement of both says the frames ride the carrier whole. A disagreement between them, or with the original
stream, is a finding.

## Running it by hand (macOS, about 5 minutes)

```sh
cd verification/harness
VERIFICATION_IEC_OUT=/tmp/carriers swift test --filter writeIECCarriers
# FFmpeg 6.1.1 is needed for the pinned oracle; Homebrew's is newer. On Linux (or a Linux VM):
python3 verification/oracles/iec61937/check_carriers.py /tmp/carriers
```

With a newer FFmpeg the script stops at the version check. To look anyway, run the two checks it runs:

```sh
ffmpeg -v error -f spdif -i /tmp/carriers/dolby-digital-tones.ac3.iec.wav -c copy -f ac3 - | cmp - Packages/VespertineKit/Tests/VespertineAudioTests/Fixtures/dolby-digital-tones.ac3
python3 verification/oracles/carrier-scan/carrier_scan.py compare /tmp/carriers/dolby-digital-tones.ac3.iec.wav Packages/VespertineKit/Tests/VespertineAudioTests/Fixtures/dolby-digital-tones.ac3
```

## What would close the gap

Buying IEC 61937-1 (CHF 160), -2 (CHF 90) and -3 (CHF 90) would let IEC-001 to IEC-006 become spec records with
clause hashes, and the burst layout could then get clean-room checks like the DoP group's. -5 (CHF 100) only
matters once DTS is sent in bursts. A receiver test (a real AV receiver showing "Dolby Digital" or "Dolby Digital
Plus" and decoding the tones to the right channels) is still needed for compatibility; see `LOOPBACK.md`, step B1.
