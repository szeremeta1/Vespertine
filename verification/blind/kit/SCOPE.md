# Scope of this verification round

Owner of the round: the orchestrator, for the product owner. You work ONLY from the files in this room.

## What is being specified

1. **DoP (DSD over PCM)**, the base method: one PCM frame carries one DoP sample per DSD channel; higher DSD
   rates raise the PCM rate (the standard's "solution 1" for 128FS and beyond). The paired-channel alternative
   for links that can't raise the PCM rate is **out of scope** (no function for it in the interface).
2. **IEC 61937 data bursts on a two-channel consumer interface** (IEC 60958 frames, as carried over S/PDIF and
   HDMI): **16-bit samples, both subframes of a frame used for one stream ("frame mode"), one stream
   (bitstream/data-stream number 0)**, for three payload kinds: AC-3, E-AC-3, DTS (core frames, types with
   512/1024/2048-sample frames). Pause bursts, time stamps, multiple streams, 20/24-bit modes, subframe mode,
   the six-word preamble (Pe/Pf), DTS-HD/DTS type IV, TrueHD/MAT, MPEG and AAC are **out of scope**.
3. Channel status bits (IEC 60958-3 / AES3) are **out of scope**: the interface has no channel status.

## The corpus (`corpus/md/*.md`, index in `corpus/index.json`)

Each document is page-anchored (`## [doc-id p.N]`) and section-anchored (`### §X.Y Title [doc-id §X.Y p.N]`).
Page text is kept as pdftotext layout in fenced blocks, so tables keep their columns. Cite as
`doc-id, section, page` plus a verbatim quote (see RULINGS.md, R1).

| doc-id | What it is | Tier |
|---|---|---|
| `dop-1.1` | The DoP open standard v1.1, complete. | **primary** |
| `iec61937-1-preview`, `-2-preview`, `-3-preview`, `-5-preview` | The publisher's free previews of IEC 61937 parts 1, 2, 3, 5: contents, foreword, scope, terms only. | **primary-preview** |
| `smpte-st337-2015`, `smpte-st338-2016`, `smpte-st340-2015` | SMPTE's free professional (AES3) counterpart of IEC 61937: burst format, data types, AC-3/E-AC-3 carriage. | **sibling-standard** |
| `atsc-a52-2018`, `etsi-ts-102366` | AC-3 / E-AC-3 bitstream syntax (frame headers, frame sizes). | **codec-spec** |
| `etsi-ts-102114` | DTS Coherent Acoustics bitstream syntax (core frame header). | **codec-spec** |
| `ffmpeg-spdif-n7.1/spdifenc`, `ffmpeg-spdif-n7.1/spdif` | FFmpeg's open-source IEC 61937 muxer. | **secondary** (an implementation, NOT a specification) |

## What is NOT in the corpus, and why

The normative text of **IEC 61937-1, -2, -3 and -5** is a paid standard and was not bought, so it is not here.
That means the consumer standard's own clauses on the burst preamble, burst-info (data-type codes), stuffing,
repetition periods and the AC-3 / E-AC-3 / DTS mappings are **not available**. What is available instead:
the SMPTE sibling (professional, with its own data-type numbering and fields; ST 337 §8 lists where the
professional and consumer formats can differ), the informative "IEC 61937-2 allocation" column of ST 338
Table 1, the clause and table titles in the IEC previews, and FFmpeg as a secondary reference.

So, for every IEC 61937 behaviour, a requirement can rest on one of:
* a sibling-standard clause that the sibling itself says applies to the consumer format, or that is a property
  of the burst structure common to both (state which, and why, in the citation's `note`);
* an informative consumer allocation printed in a public document (ST 338 Table 1's IEC column);
* FFmpeg only (tier `secondary`): agreement with an independent implementation, not conformance;
* nothing: then it is a **GAP** (see RULINGS.md R3) and must not be asserted.

DoP is fully public, so DoP requirements rest on `dop-1.1` alone; where it is silent, that is a GAP too.
