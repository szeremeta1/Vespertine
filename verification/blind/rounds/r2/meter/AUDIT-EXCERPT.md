# Auditor findings for the meter (round 1 excerpt)

The round-1 auditor ran a conformance suite you have not seen against your meter: 157 of 159 cases passed. These are the auditor's words on the two failures and on your citation comments, copied verbatim. Nothing else from the suite is given to you.

## Failures adjudicated from corpus

1. `tests/test_iec61937.py::test_dts_odd_length_frame_last_byte_is_msb_aligned`: **meter implementation wrong relative to the available secondary reference**. `meter/vblind_ref.py:370–371` rejects size1025 solely because it is odd. ETSI TS102114 §5.4.2 p.26 defines FSIZE+1 in bytes over96–16384, without an even restriction. FFmpeg spdifenc file p.1 lines666–668 explicitly handles a final lone byte by emitting it shifted8. The payload easily fits the512-frame period. ST337 §7.3.1 p.12 also describes zeroing unused final-frame bits. Neither cited source justifies meter's categorical impossibility claim; its own `_burst` already pads odd bytes. This is not a proven primary IEC violation: consumer normative odd-DTS requirements remain unavailable. Test acceptance/alignment should be labeled secondary, rather than upgraded by the professional structural citation.
2. `tests/test_iec61937.py::test_dts_odd_length_frame_fill_is_zero_and_period_kept`: **same meter defect**, same size1025 rejection before any fill assertion. FFmpeg's odd-byte path plus `ffio_fill(...,0,padding)` and ST337 unused-zero rule support zero fill at their respective tiers. The test name additionally claims period preservation, but its body checks only zero fill after word517, not `len(w)==1024`; it can vacuously pass a short output. That missing assertion does not excuse the actual rejection.

These are two failed cases, not two distinct defects. Do not delete them merely to make meter green; retain the failed automated result until the implementation and secondary-tier attribution are resolved.

## Meter's own citation comments and constants

All named wire constants were inspected: DoP markers/24-bit layout, Pa/Pb, types1/11/12/13/21/31, Pc shifts/masks, header size4 words, length-word width, periods1536/6144, all AC-3 size-table entries, E-AC-3 sizes/block counts/bsid, DTS header positions/ranges/sample formula and parse units. No invented named wire constant was found with no support anywhere in corpus, but the following defects and limits matter:

| Meter location / value | Audit |
|---|---|
| `_DOP_MARKERS`, word widths/shifts | Supported by dop-1.1 p.2 diagram/text and interface representation. |
| `_PA`, `_PB`, `_PREAMBLE_WORDS=4` | Supported by ST337 p.9 and FFmpeg spdif.h p.1. Meter falsely attributes `#define BURST_HEADER_SIZE 0x8` to spdifenc; actual definition is in supplied spdif.h. |
| `_DT_AC3=1`, `_DT_EAC3=21`, `_DT_EXT=31` | Supported by consumer allocation/preview/FFmpeg for1/21; ST337 p.9 supports31 six-word preamble excluded by scope. |
| `_DT_DTS={512:11,1024:12,2048:13}` | Numbers in ST338 consumer column; samples-to-code mapping only in FFmpeg spdif.h. Adjacent meter comment fails to quote that sample link explicitly; tier must stay secondary. |
| `_AC3_PERIOD=1536` | Corpus supports1536 in codec/sibling text; FFmpeg expression uses undefined-in-this-corpus `AC3_FRAME_SIZE` from an absent included header. Consumer agreement is inferred from that symbol and duration, not a literal consumer1536 definition. |
| `_EAC3_PERIOD=6144`, E-AC-3 Pd bytes | Direct24576-byte/byte-count assignments in FFmpeg; honestly secondary, not professional1536/bits. |
| `_AC3_WORDS_*` tables | All values match A52 Table5.18 across corpus pages52 AND53. Comment cites only52; high-rate entries continue on53. The fscod reserved-code comment cites p.20, but corpus anchor is p.38 (printed page20). Correct page convention. |
| E-AC-3 `(1,2,3,6)`, frmsiz+1, bsid11–16 | Supported by TS102366 p.127. ATSC p.161 additionally supports reduced-rate fscod2; ETSI p.127 instead reserves fscod3, a real edition/profile distinction the suite does not exercise. |
| E-AC-3 six-block/substream grouping | ST340 p.10 supports professional carriage; alleged TS102366 J.1.4.1 p.241 quote is actually p.240 and concerns ISOBMFF/CMAF samples, not IEC bursts. Do not use it as consumer transport authority. |
| DTS nblks>=5, fsize>=95 and FSIZE+1 | Actual semantic ranges/formula are on TS102114 p.26, not p.25 as several meter comments claim; p.25 supplies syntax. Values have corpus support despite wrong page references. |
| DTS odd-size rejection | No cited corpus prohibition; conflicts with secondary explicit padding. This is unsupported behavior despite being listed under O9. A choice cannot silently exclude a case handled by the adopted secondary model. |
| Pc layout | Structural positions supported; FFmpeg comment says type bits0–6, so describing it as identical5-bit type plus mode layout needs the scoped mode0 restriction. |
| `_burst` zero fill | Correct value supported by ST337 §6.1 p.6 and FFmpeg fill; meter cites ST337 §7.4, which only requires periodic extended-sync zeros, insufficient alone for every stuffing word. |
| Parser units for unknown types | Treating all unknown types as bits is an open policy, not established by corpus for every consumer type; FFmpeg explicitly says units depend on type. Unknown/pause types are out of scope here. |

Header minimum lengths8 for AC-3,6 for E-AC-3 and10 for DTS are implementation guard policies, not cited normative minima. AC-3's fixed syncinfo+bsid/bsmod header needs6 bytes, though legitimate table-sized syncframes are larger; DTS's secondary path checks9 bytes and its extracted size fields fit earlier. These guard literals do not establish new format requirements. Meter's declared empty-input, strict-length, acquisition-delay and incomplete-group policies remain open choices or validation policy, not standard constants. Meter comments are not included in the tests/citations.py checker; their wrong pages, compressed non-verbatim quotations and wrong source-file attribution are separate from citecheck's zero-problem result.
