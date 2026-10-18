# Saboteurs

`base.py` implements all seven public functions and the three interface types. Each cited encoding or validation rule lives in a named constant or helper. Public functions compose those rules; `rebind` clones their function namespace so each variant overrides exactly one helper without changing `base` or another variant. Decoder directions of the Pc type and Pd helpers retain the baseline interpretation. No implementation, tests, or sources outside this room were consulted.

Every variant begins with `from base import *` and `import base`. Put `saboteurs` on Python's import search path when loading one by file path. There are no third-party dependencies.

## Exact changes and observable symptoms

| Variant | Single helper change, old → new | Evidence violated | Observable output |
|---|---|---|---|
| `sab_swapped_markers.py` | `dop_marker(first, index, decode=False)`: phase index `index` → `index + 1`; the inverse phase changes in the same helper. | DoP §2 p.2: "0x05 and 0xFA. Each channel within a sample contains the same marker." **Phase selection is specified by the stub's `first_marker` contract, not by DoP.** | `dop_pack` exchanges 05/FA in bits 23–16 on every sample. Its default first marker becomes FA. Payloads, widths, channels and alternation remain identical. `dop_unpack` returns the opposite first-marker value, keeping the variant's own round trip consistent. |
| `sab_pc_datatype.py` | `data_type("dts2048", decode=False)`: `0x0D` → `0x0C`. | `ffmpeg-spdif-n7.1/spdif` §file p.1: "IEC61937_DTS3               = 0x0D,          ///< DTS type III (2048 samples)" (secondary). | Only `dts_burst` for 2048-sample DTS changes, only word 2 (Pc). It announces DTS type II while keeping type III payload, Pd, and repetition length. Other DTS durations and both Dolby formats are identical. Parser interpretation is unchanged. |
| `sab_length_off_by_one.py` | `length_code("eac3", size, decode=False)`: `size` → `size + 1` bytes. | `ffmpeg-spdif-n7.1/spdifenc` §file p.1: "ctx->length_code = ctx->hd_buf_filled;" (secondary). | Only `eac3_burst` changes, only word 3 (Pd), by +1. Preamble fields, payload words, fill, and total length are identical. Parser interpretation is unchanged. |
| `sab_padding.py` | `burst_fill(count)`: `[0] * count` → `[1] * count`. | `ffmpeg-spdif-n7.1/spdifenc` §file p.1: "ffio_fill(s->pb, 0, padding);" (secondary). | All three burst emitters retain their preamble, payload, and word count, but every full stuffing word after the payload becomes 0001. The unused low byte of an odd final payload word remains zero. |
| `sab_byte_order.py` | `payload_words(payload)`: each word `w` → `((w & 255) << 8) | (w >> 8)`. | `ffmpeg-spdif-n7.1/spdifenc` §file p.1: "ff_spdif_bswap_buf16((uint16_t *)ctx->buffer, (const uint16_t *)ctx->out_buf, ctx->out_bytes >> 1);" and "/* a final lone byte has to be MSB aligned */" (secondary). | All three burst emitters exchange the high and low payload byte in every 16-bit sample. Example: normal stream bytes 0B 77 produce 0B77 in base, 770B in the variant. Odd final bytes become LSB aligned. Preamble, Pd, full stuffing words and total length are identical. |
| `sab_dop_bit_order.py` | `dop_data(value, decode=False)`: preserve 16-bit order → reverse all 16 bits; its inverse uses the same reversal. | `dop-1.1` §2 p.2: "The remaining 16 lower bits are then used for the DSD data, first or oldest bit in slot t0." (primary). | Only DoP functions change. `dop_pack` places the newest bit at bit 15 and oldest at bit 0; 1234 becomes 2C48. Markers, channel order and dimensions stay identical. `dop_unpack` reverses the recovered DSD bits; the variant's own round trip remains consistent. |

Full R1 citation records, with exact quotations, tiers, section/page anchors and applicability notes, are in `CITATIONS.json`. The corresponding citation comments are adjacent to the relevant constants/helpers in the implementations.

## Evidence and interpretation

DoP comes from the public primary standard. The recommended receiver's 32-marker acquisition delay in §4 is not imposed on this stateless pack/unpack interface: it describes detecting a switch from PCM, not minimum packet length.

The consumer preamble order follows ST 337 §7.2.2, justified by the shared consumer burst structure described in §8.2–8.3. The numeric sync words and consumer Pc field interpretation are also printed explicitly in FFmpeg. Consumer data types use FFmpeg's consumer enum; no professional data-type numbers are substituted. AC-3's dependent field is `bsmod << 8`, supported by FFmpeg; E-AC-3 and DTS use zero dependent bits. Error and stream-number fields emitted here are zero.

Consumer burst periods use FFmpeg: AC-3's frame duration is 1536 samples (also in ST 340 §4.1), E-AC-3's output is 24576 bytes / 4 bytes per interface frame = 6144 frames, and DTS's `blocks << 7` bytes gives 512/1024/2048 frames. Professional E-AC-3's 1536-frame period is deliberately not imported. Payload words are big endian sample values: FFmpeg's byte swap before little endian PCM serialization preserves the stream's first byte as the sample MSB. Serialization itself is outside the interface.

AC-3 sizes use the complete ETSI Table 4.13. E-AC-3 frame sizes and block counts use Annex E; its grouping accumulates six blocks per independent/dependent substream, with independent zero delimiting groups and following dependent frames retained. Six-block grouping has sibling support, not a verified consumer normative clause. E-AC-3 converted AC-3 frames are recognized as the independent zero six-block substream, per Annex E p.126. Framing checks inspect headers and sizes, not compressed audio coefficients or CRC validity.

## Gaps

- The consumer normative clauses are absent. Consumer Pc mapping, exact payload representation, fill, repetition periods and E-AC-3 Pd units supported only by FFmpeg establish secondary agreement, not verified IEC conformance. Obtaining IEC 61937 parts 1, 2, 3 and 5 would resolve this.
- DoP specifies alternation but permits either starting phase. Exchanging 05 and FA preserves DoP standard conformance. `sab_swapped_markers` therefore tests the explicit `first_marker` interface contract; it cannot legitimately prove a standard-mandated default phase.
- Consumer E-AC-3 grouping for multiple substreams and converter synchronization is unverified. The baseline uses the sibling's six-block model plus codec substream ordering. It does not inspect the variable-position Converter Synchronization Flag or claim consumer alignment to that flag. A complete consumer requirement needs IEC 61937-3.
- For odd-byte DTS payloads, ST 337's exact bit count gives `len(payload) * 8`; the FFmpeg default instead rounds Pd to whole 16-bit words. The baseline uses exact bit count and zero-pads the unused low byte, under the explicitly labeled sibling inference. Its applicability to consumer odd-byte DTS is **unverified**; none of the six mutations changes this choice.
- No playable compressed-media fixtures are provided. Checks use structurally valid headers and sizes, with deterministic payload bytes. Full compressed-audio decodability and CRC validity are **unverified**. No independently authored conformance suite is available in this room, so whether it detects these variants remains **unverified**.

## Open choices

- Empty/zero-channel DoP and zero-length DoP channels raise `DoPError`; no sample exists to recover channel count or starting phase. Equal, nonempty channel lengths must contain whole 16-bit groups. Either defined marker can start a stream. No implicit DSD padding is introduced.
- `eac3_group([])` returns `[]`; incomplete groups and empty bursts raise `BurstError`. Annex E calls sample-rate code 3 reserved, so it is rejected; the secondary FFmpeg branch for that code does not supply normative support for accepting it.
- Exact syncframe length is required. Trailing extraneous bytes, DTS payloads too large for their preamble, unsupported DTS durations and non-big-endian core input are rejected. No raw DTS-disc preamble omission is implemented because this interface returns a complete data burst.
- `parse_bursts` scans past nonsync words, starts bursts only at an even word offset, skips payload words atomically and accepts an omitted trailing fill region. A Pa candidate with malformed Pb, truncated header, unsupported type or inconsistent length raises `BurstError`. It permits reported Pc flags/stream fields and does not certify stuffing, compressed contents or between-burst spacing. Non-byte-aligned lengths and nonzero unused low bytes are rejected. Empty input returns `[]`.

## Checks

Run from the room:

```sh
./.venv/bin/python saboteurs/check_citations.py
./.venv/bin/python saboteurs/check_saboteurs.py
```

The first script checks every quoted string against its single source page and verifies section/page membership in the corpus index. The second imports all variants simultaneously and checks every public function, both DoP starting phases, multiple channel counts, all three DTS durations, odd/even DTS sizes, all AC-3 size/rate combinations, E-AC-3 1/2/3/6-block groups, multiple independent/dependent substreams, malformed inputs and concatenated burst offsets. Exact delta masks verify that mutations affect only the stated fields. Baseline output is rechecked after variant calls to detect namespace contamination. `CHECK_RESULTS.json` records the current result.
