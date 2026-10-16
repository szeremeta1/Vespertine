# COMPLIANCE: meter/vblind_ref.py

Citation comments C01–C74 contain R1 JSON entries with document ID, anchored section, corpus page,
verbatim quote, tier and applicability note. Whitespace alone is collapsed. Printed subclauses without
individual corpus anchors are identified in notes under their anchored parent section (for example,
ATSC §5.4 and ETSI Annex-E). Page numbers always follow corpus anchors, not printed folios.

## Implemented requirements and evidence

| Behaviour | Citation comments / corpus locations | Evidence tier and limits |
|---|---|---|
| DoP 24-bit words: eight marker bits, sixteen DSD bits, oldest first; common alternating 0x05/0xFA markers | C01–C03, C72; dop-1.1 §2 p.2 | primary |
| Base method per channel, higher rates through increased PCM rate; paired-channel markers excluded | C04, C73; dop-1.1 §3 p.2 | primary; scope excludes solution 2 |
| DoP empty inputs, odd DSD byte counts, short acquisition runs | C02, C05; dop-1.1 §2 p.2, §4 p.3 | O1–O3 implementation choices; sixteen-bit slot and receiver recommendation are primary |
| Pa=0xF872, Pb=0x4E1F; four preamble words/eight bytes; Pa/Pb then Pc/Pd in successive frames | C06–C11, C14; ST337 §7.2.1–2 p.9, §8.2 p.14; FFmpeg **spdif.h** p.1 | sibling-standard shared-structure inference; secondary corroboration |
| Pc: type bits0–4, mode5–6, error7, dtd8–12, stream13–15; sixteen-bit frame mode0 | C15–C18, C49, C71; ST337 §7.2.4.1 p.10, §7.2.4.3 p.11, §8.3–4 p.14; spdifenc p.1 | sibling-standard structure; FFmpeg describes bits0–6 as type, agreeing here only with scoped mode0 |
| Type31 denotes six-word preamble, excluded by scope | C19; ST337 §7.2.1 p.9 | sibling-standard shared-preamble inference |
| Payload bits occupy MSB-first subframe1 then2; unused final-frame bits zero | C12, C14; ST337 §7.3.1 p.12, §8.2 p.14 | sibling-standard shared-structure inference |
| Sixteen-bit Pd field range; AC-3/DTS bit units | C20–C21, C30, C50–C51; ST337 §7.2.5 p.12; spdifenc p.1 | field width: sibling-standard; consumer units: secondary corroborated by professional bits rule |
| AC-3=1, DTS I/II/III=11/12/13, E-AC-3=21 | C32–C39; ST338 §4 p.4 consumer allocation column; spdif.h p.1 | sibling-standard informative consumer allocation; secondary corroboration |
| DTS 512/1024/2048 samples map to types11/12/13 | C32–C34; spdif.h p.1 lines41–43 | **secondary**; ST338 column alone does not supply sample counts |
| AC-3 dependent bits contain bsmod; professional reserved000 not applied | C16, C46–C47, C70; spdifenc p.1; ST340 §4.2.2 p.5; ST337 §8.4 p.14 | **secondary** consumer behaviour |
| AC-3 one syncframe; 1536-frame period | C40–C42; ST340 §4.3 p.5, §4.6 p.6; spdifenc p.1 | sibling inference; secondary agreement inferred from AC3_FRAME_SIZE and duration, whose literal macro definition is absent |
| AC-3 header/sync, reserved fscod, frame-size tables and bsid<=8 | C52–C57; A52 §5.3 p.31, §5.4 p.38–39 and Table5.18 p.52 **and53**; C46 for bsmod extraction | codec-spec; strict input lengths and header guard are validation policy |
| E-AC-3 header, size=(frmsiz+1)*2, type3 reserved, numblks=(1,2,3,6), bsid11–16 | C58–C62; TS102366 Annex-E p.114,126–127 | codec-spec |
| Reduced-rate fscod2 branch uses six blocks, reserved fscod2 rejected | C63–C64; A52 §2.3 (Annex E) p.161 | codec-spec ATSC profile; ETSI p.127 instead reserves fscod3 |
| E-AC-3 groups six blocks of independent0, retaining following dependent frames | C48, C65, C68; ST340 §5.3 p.10; TS102366 Annex-E p.126; spdifenc p.1 | sibling-standard inference for consumer bursts; FFmpeg agrees for single-substream cases only |
| E-AC-3 first-frame and incomplete-group policy; convsync not checked | C65–C68; ST340 §5.3 p.10; TS102366 Annex-E p.126, Annex-J p.240 | retained O11/G4/G8; Annex J is ISOBMFF/CMAF sample storage, **not IEC transport authority** |
| E-AC-3 dependent bits0, Pd bytes, period6144 frames | C43–C45, C74; spdifenc p.1; ST340 §5.6 p.10 is professional1536 only | **secondary** consumer behaviour |
| DTS sync/header positions | C22; TS102114 §5.4.2 p.25 Table5-1 | codec-spec |
| DTS NBLKS5..127; samples=32*(NBLKS+1); FSIZE95..16383, byte size=FSIZE+1 | C23–C24; TS102114 §5.4.2 p.26 | codec-spec; no even-byte restriction stated |
| DTS accepts odd byte counts; lone byte is MSB-aligned with zero low byte | C25–C26; spdifenc p.1 lines666–668; C24 and C12 corroborate at their own tiers | **secondary** acceptance/alignment, not proven consumer-primary conformance |
| DTS period equals samples; truncate excess to FSIZE+1; refuse payload exceeding period capacity | C28–C31; spdifenc p.1 | **secondary** model plus retained short-frame/preamble-required validation choices |
| Odd-DTS Pd is exact FSIZE+1 bits, preserving existing _burst input policy | C30, C50; spdifenc p.1 lines312,633 | open choice G11: truncated-core path uses exact bits, generic untrimmed default rounds size to even |
| Zero fill through complete period | C13, C27, C31; ST337 §6.1 p.6; spdifenc p.1 lines643,670 | sibling-standard zeros for structural fill; consumer odd-DTS fill/period agreement remains **secondary** |
| Parser uses the same scoped layout and units, rejects unsupported modes/type31/truncation | C11, C17–C21, C51 | sibling structure plus secondary per-type units; unknown/pause/null bits unit is O16 policy |
| Error flag emitted0 when error status unknown | C69; ST337 §7.2.4.4 p.11 | sibling-standard shared-preamble inference; no CRC verification |

## Open choices

The complete retained policies are O1–O16 in the module docstring. They include empty inputs, receiver
acquisition delay, odd DSD bytes, strict AC-3/E-AC-3 lengths, incomplete E-AC-3 groups, short DTS rejection,
preamble-less DTS refusal, unknown-type parser units and nonzero stuffing acceptance. The AC-3 eight-byte,
E-AC-3 six-byte and DTS ten-byte header guards are implementation policies, not normative header minima.
These behaviours remain unchanged. Odd DTS bytes are now carried, following the adopted secondary path.

## Gaps

- G1–G3: normative IEC61937-1/-2/-3/-5 clauses are unavailable. Consumer mappings, dependent fields,
  per-type units and periods cannot be called primary consumer conformance. E-AC-3 bytes/6144 remain secondary.
- G4–G5: convsync is not checked; reduced-rate and32/44.1kHz consumer E-AC-3 repetition details are unsettled.
- G6: error status is unknown and emitted0; compressed audio CRCs are not verified.
- G7: consumer normative odd-DTS carriage/alignment is unavailable; ETSI byte sizes do not prohibit it,
  FFmpeg carries it, and professional unused-bit zeros do not upgrade the secondary consumer evidence.
- G8: multi-substream consumer E-AC-3 grouping is unconfirmed. ST340 grouping is a sibling inference;
  TS102366 Annex J p.240 constrains ISOBMFF/CMAF samples. Normative consumer grouping text is needed.
- G9: ATSC fscod2 and ETSI reserved-fscod3 edition/profile differences remain; existing ATSC handling is retained.
- G10: AC3_FRAME_SIZE is defined in an absent FFmpeg included header. Consumer1536 agreement is inferred
  using codec/sibling duration and the symbol expression, not a literal supplied consumer definition.
- G11: FFmpeg truncated-core DTS Pd uses exact bytes*8, whereas the generic untrimmed default rounds odd
  packet size to even first. Exact FSIZE+1 bits is retained and documented; normative consumer Pd text is needed.

## Round 2 changes

1. Removed the categorical odd-DTS rejection. TS102114 §5.4.2 p.26 defines FSIZE+1 byte sizes without
   an even restriction (C24); spdifenc p.1 lines666–668 explicitly emits a lone byte shifted8 (C25–C26).
   Existing _burst packing now supplies zero low bits, zero remaining fill and the full period (C12–C13,
   C27, C31). Consumer acceptance/alignment/fill-period expectations are labeled secondary.
2. Corrected DTS semantic references to p.26; syntax remains p.25. Replaced compressed header/range
   quotations with exact text (C22–C24). Made the sample-to-code link explicit using spdif.h row comments
   with512/1024/2048 (C32–C34), keeping that mapping secondary.
3. Corrected BURST_HEADER_SIZE attribution to **spdif.h**, p.1 (C08), and checked Pa/Pb against the same
   supplied file and ST337 p.9 (C06–C11). Removed the incorrect spdifenc definition claim.
4. Corrected AC-3 reserved fscod to corpus p.38 (printed p.20), and cited both Table5.18 pages52 and53
   with exact table rows (C52–C56). Recorded the missing AC3_FRAME_SIZE definition rather than claiming
   a literal FFmpeg1536 constant (C40, C42; G10).
5. Corrected E-AC-3 Annex J to p.240 and explicitly limited it to ISOBMFF/CMAF sample storage (C67).
   Retained grouping as a sibling inference from ST340 §5.3 p.10, with consumer applicability unconfirmed
   (C48, C65–C68; G8). Documented ATSC/ETSI reduced-rate differences (C63–C64; G9).
6. Corrected zero-fill support to ST337 §6.1 p.6 and the actual FFmpeg fill call; §7.4 alone was insufficient
   to support every stuffing word (C13, C27, C31).
7. Corrected the Pc comparison: FFmpeg describes type bits0–6; the five-bit-type/mode interpretation agrees
   only under scoped mode0 (C15–C18, C49, C71). Labeled unknown-type bits units and header minimum guards
   as policies (C51; O15–O16), without changing their behaviour.
8. Replaced every old citation comment with structured R1 entries, rechecked all quotes verbatim against
   their individual anchored pages, and identified printed subclauses in notes instead of inventing anchors.
   Updated OPEN CHOICES/GAPS and disclosed the existing odd-DTS Pd ambiguity (C30, C50; G11).
9. Extended selfcheck.py with15 odd-DTS cases across all three scoped periods, including1025 bytes,
   both odd-length residues modulo4 and near-capacity payloads. Checks cover explicit total period length,
   final0xAB00 word, zero fill, exact-byte round-trip, consecutive burst offsets, excess-byte truncation,
   short-frame refusal and oversize odd-frame refusal. Added verification of all74 citation records and
   exported signatures/defaults/dataclass fields against stub/vblind.py. Constants follow the citations above.

## Verification and preserved round-1 result

The auditor reported **157/159 passed**, with two odd-DTS failures from the same rejection defect.
That historical result is retained. The hidden suite is not in this room, so a new hidden-suite result is
**unverified**; this report does not replace it with a claimed159/159.

Command: `./.venv/bin/python meter/selfcheck.py`

Result: `ok: existing checks; 15 odd-DTS cases; 74 page-verified citations; stub interface`

All existing self-checks were retained. The only runtime implementation change is removal of the
odd-size DTS rejection; all other behaviour and the public interface remain unchanged.
