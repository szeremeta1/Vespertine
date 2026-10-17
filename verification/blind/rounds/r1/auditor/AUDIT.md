VERDICT: FAIL

The required all-pass meter check failed: 157 passed, 2 failed. All six saboteurs were caught and base passed, but neither fact overrides meter failure. One citation does not support the consumer assertion attributed to it, and several requirements are assigned stronger evidence than their consumer support warrants. No submitted tests or implementations were modified.

## Automated results

`./.venv/bin/python -I citecheck.py . --json audit/citecheck.json` exited **0**: **88 citations, 88 resolve; 74 test functions; 0 problems; 14 unused citations**. This checks quotation resolution/anchors, not semantic support. Parametrization produces **159 executed cases** per implementation. Full pytest output is in `audit/<name>.log`; JUnit results are in `audit/<name>.xml`; commands/results are in `audit/commands.log`.

| Implementation | Passed | Failed | Exit |
|---|---:|---:|---:|
| bare stub (VBLIND_IMPL unset) | 0 | 159 | 1 |
| meter/vblind_ref.py | 157 | 2 | 1 |
| saboteurs/base.py | 159 | 0 | 0 |
| saboteurs/sab_byte_order.py | 136 | 23 | 1 |
| saboteurs/sab_dop_bit_order.py | 153 | 6 | 1 |
| saboteurs/sab_length_off_by_one.py | 155 | 4 | 1 |
| saboteurs/sab_padding.py | 148 | 11 | 1 |
| saboteurs/sab_pc_datatype.py | 158 | 1 | 1 |
| saboteurs/sab_swapped_markers.py | 152 | 7 | 1 |

All 159 stub cases failed with NotImplementedError, as required; no false pass. Base has no failures to adjudicate. No run had collection errors or skipped cases.

## Saboteur kill table

Every listed test actually failed against the variant. Full parameter IDs are retained. No surviving saboteur, so there is no uncaught mutation to attribute to a missing requirement. The marker-phase mutation violates the interface's `first_marker` contract; swapping phase by itself does not violate DoP's permitted alternation.

| Saboteur | Killing cases | Killing tests |
|---|---:|---|
| sab_byte_order.py | 23 | `tests/test_iec61937.py::test_payload_follows_pd_big_endian[ac3_48k]`<br>`tests/test_iec61937.py::test_payload_follows_pd_big_endian[ac3_44k]`<br>`tests/test_iec61937.py::test_payload_follows_pd_big_endian[ac3_32k]`<br>`tests/test_iec61937.py::test_payload_follows_pd_big_endian[eac3_6x1]`<br>`tests/test_iec61937.py::test_payload_follows_pd_big_endian[eac3_1x6]`<br>`tests/test_iec61937.py::test_payload_follows_pd_big_endian[eac3_2x3]`<br>`tests/test_iec61937.py::test_payload_follows_pd_big_endian[dts_512]`<br>`tests/test_iec61937.py::test_payload_follows_pd_big_endian[dts_1024]`<br>`tests/test_iec61937.py::test_payload_follows_pd_big_endian[dts_2048]`<br>`tests/test_iec61937.py::test_ac3_payload_starts_with_the_syncword[ac3_48k]`<br>`tests/test_iec61937.py::test_ac3_payload_starts_with_the_syncword[ac3_44k]`<br>`tests/test_iec61937.py::test_ac3_payload_starts_with_the_syncword[ac3_32k]`<br>`tests/test_iec61937.py::test_ac3_payload_is_one_whole_syncframe_48k`<br>`tests/test_iec61937.py::test_eac3_payload_is_the_frames_in_order`<br>`tests/test_iec61937.py::test_eac3_payload_starts_with_the_syncword`<br>`tests/test_iec61937.py::test_dts_payload_starts_with_the_sync_word[dts_512]`<br>`tests/test_iec61937.py::test_dts_payload_starts_with_the_sync_word[dts_1024]`<br>`tests/test_iec61937.py::test_dts_payload_starts_with_the_sync_word[dts_2048]`<br>`tests/test_iec61937.py::test_dts_odd_length_frame_last_byte_is_msb_aligned`<br>`tests/test_parse.py::test_roundtrip_ac3_payload`<br>`tests/test_parse.py::test_roundtrip_ac3_three_bursts_offsets`<br>`tests/test_parse.py::test_roundtrip_eac3_payload`<br>`tests/test_parse.py::test_roundtrip_dts_payload_and_offsets` |
| sab_dop_bit_order.py | 6 | `tests/test_dop.py::test_pack_oldest_bit_is_bit15`<br>`tests/test_dop.py::test_pack_bit_order_within_first_byte`<br>`tests/test_dop.py::test_pack_second_byte_in_low_half`<br>`tests/test_dop.py::test_pack_sixteen_bits_per_frame_in_time_order`<br>`tests/test_dop.py::test_pack_channel_k_goes_to_pcm_channel_k`<br>`tests/test_dop.py::test_unpack_reads_hand_built_stream` |
| sab_length_off_by_one.py | 4 | `tests/test_iec61937.py::test_eac3_pd_is_payload_length_in_bytes[eac3_6x1]`<br>`tests/test_iec61937.py::test_eac3_pd_is_payload_length_in_bytes[eac3_1x6]`<br>`tests/test_iec61937.py::test_eac3_pd_is_payload_length_in_bytes[eac3_2x3]`<br>`tests/test_parse.py::test_roundtrip_eac3_payload` |
| sab_padding.py | 11 | `tests/test_iec61937.py::test_fill_after_payload_is_zero[ac3_48k]`<br>`tests/test_iec61937.py::test_fill_after_payload_is_zero[ac3_44k]`<br>`tests/test_iec61937.py::test_fill_after_payload_is_zero[ac3_32k]`<br>`tests/test_iec61937.py::test_fill_after_payload_is_zero[eac3_6x1]`<br>`tests/test_iec61937.py::test_fill_after_payload_is_zero[eac3_1x6]`<br>`tests/test_iec61937.py::test_fill_after_payload_is_zero[eac3_2x3]`<br>`tests/test_iec61937.py::test_fill_after_payload_is_zero[dts_512]`<br>`tests/test_iec61937.py::test_fill_after_payload_is_zero[dts_1024]`<br>`tests/test_iec61937.py::test_fill_after_payload_is_zero[dts_2048]`<br>`tests/test_iec61937.py::test_unused_second_subframe_of_last_payload_frame_is_zero`<br>`tests/test_iec61937.py::test_dts_odd_length_frame_fill_is_zero_and_period_kept` |
| sab_pc_datatype.py | 1 | `tests/test_iec61937.py::test_dts_data_type_by_frame_length[dts_2048-13]` |
| sab_swapped_markers.py | 7 | `tests/test_dop.py::test_pack_markers_alternate_from_05`<br>`tests/test_dop.py::test_pack_markers_alternate_from_fa`<br>`tests/test_dop.py::test_pack_default_first_marker`<br>`tests/test_dop.py::test_pack_oldest_bit_is_bit15`<br>`tests/test_dop.py::test_pack_bit_order_within_first_byte`<br>`tests/test_dop.py::test_pack_second_byte_in_low_half`<br>`tests/test_dop.py::test_unpack_reads_hand_built_stream` |

## Citation grades

Every key was checked against its actual cited page, section context and test usage. Document/section/page anchors and literal quotes all resolve; source-tier labels match SCOPE's document classes. SUPPORTS means the cited page supports its relevant part of the assertion at the stated limited tier, not that one key proves every component of a multi-key assertion. PARTIAL identifies missing inference, attribution or tier limitations. Unused keys are graded for their stated notes. `audit/cited-pages.md` preserves every cited page; `audit/citation-uses.json` maps every key to all using test functions.

| Key | Page / section / declared tier | Grade | Reason |
|---|---|---|---|
| DOP_MARKER_ALT | dop-1.1 p.2 §2; primary | PARTIAL | Correct values/alternation; does not prescribe default 05 or requested starting phase, which come from stub contract. |
| DOP_MARKER_SAME | dop-1.1 p.2 §2; primary | SUPPORTS | Explicit same marker on all channels; unequal lengths cannot form complete synchronous frames. |
| DOP_MARKER_MSB | dop-1.1 p.2 §2; primary | SUPPORTS | Explicit eight MSbits marker; diagram supplies 24-bit width. |
| DOP_BITS_OLDEST | dop-1.1 p.2 §2; primary | SUPPORTS | Sixteen low bits, oldest at t0; exact interface representation implies refusing incomplete 16-bit groups. |
| DOP_DIAGRAM | dop-1.1 p.2 §2; primary | SUPPORTS | Diagram orders t0 through t15 from bit15 to bit0, supporting all byte/bit expectations. |
| DOP_24BIT | dop-1.1 p.2 §2; primary | SUPPORTS | Diagram explicitly specifies 24-bit PCM word. |
| DOP_PER_CHANNEL | dop-1.1 p.2 §2; primary | SUPPORTS | Explicit channel assignment supports channel order and frame dimensions. |
| DOP_OTHER_MARKER | dop-1.1 p.2 §3; primary | SUPPORTS | Alternative paired-channel method distinguished by another marker; base values supplied by §2. |
| DOP_ALT_MARKERS | dop-1.1 p.2 §3; primary | SUPPORTS | Diagram explicitly places 06/F9 in the excluded alternative method. |
| DOP_RX_MISSING | dop-1.1 p.3 §4; primary | SUPPORTS | Missing marker in any channel ends DSD recognition; used only for malformed streams, not acquisition delay. |
| ST337_PA | smpte-st337-2015 p.9 §7.2.1; sibling-standard | SUPPORTS | Table 6 gives F872; note states shared-structure carryover via §8.2–8.3 at sibling tier. |
| ST337_PB | smpte-st337-2015 p.9 §7.2.1; sibling-standard | SUPPORTS | Table 6 gives 4E1F; note explicitly inherits shared-structure justification. |
| ST337_EXT_SYNC | smpte-st337-2015 p.13 §7.4; sibling-standard | SUPPORTS | Explicit 16-bit extended sync values; used for Pa/Pb and offsets, not demanding every burst have four leading zeros. |
| ST337_FRAME_PRE | smpte-st337-2015 p.9 §7.2.2; sibling-standard | SUPPORTS | Explicit Pa/Pb then Pc/Pd frame order; offset/raw-Pd expectations also derive from interface. |
| ST337_CONSUMER_SUBSET | smpte-st337-2015 p.14 §8.2; sibling-standard | SUPPORTS | Unused in tests; honestly quotes general subset argument, subject to §8.4 exceptions. |
| ST337_CONSUMER_16 | smpte-st337-2015 p.14 §8.3; sibling-standard | SUPPORTS | Explicit consumer-compatible 16-bit frame mode with mode=0. |
| ST337_PRE_FOLLOW | smpte-st337-2015 p.8 §7.1; sibling-standard | SUPPORTS | Preamble followed by payload; common structural inference is stated. |
| ST337_T7_TYPE | smpte-st337-2015 p.10 §7.2.4.1; sibling-standard | SUPPORTS | Table gives bits0–4; consumer-compatible mode restriction is independently cited; type numbers require separate evidence. |
| ST337_T7_MODE | smpte-st337-2015 p.10 §7.2.4.1; sibling-standard | SUPPORTS | Table gives bits5–6; consumer mode=0 separately explicit in §8.3. |
| ST337_T7_ERR | smpte-st337-2015 p.10 §7.2.4.1; sibling-standard | SUPPORTS | Table locates error flag at bit7, consistent with cited secondary consumer comment. |
| ST337_T7_DTD | smpte-st337-2015 p.10 §7.2.4.1; sibling-standard | PARTIAL | Correct field position, not consumer value semantics; note omits R2 applicability explanation (FF_PC_BITS independently supports position). |
| ST337_T7_STREAM | smpte-st337-2015 p.10 §7.2.4.1; sibling-standard | PARTIAL | Correct field position; note omits explicit carryover rationale, though FF_PC_STREAM confirms consumer layout. |
| ST337_T8_16 | smpte-st337-2015 p.11 §7.2.4.3; sibling-standard | SUPPORTS | Mode0 is explicitly 16-bit; applicability additionally established by consumer §8.3. |
| ST337_ERR0 | smpte-st337-2015 p.11 §7.2.4.4; sibling-standard | PARTIAL | Full sentence gives error=0 for unknown errors; note omits explicit consumer carryover rationale, though consumer encoding agrees. |
| ST337_STREAM0 | smpte-st337-2015 p.12 §7.2.4.6; sibling-standard | SUPPORTS | At least one stream0 plus SCOPE explicitly fixes the only stream to 0. |
| ST337_LEN_BITS | smpte-st337-2015 p.12 §7.2.5; sibling-standard | PARTIAL | Professional bits unit; consumer even-size AC-3/DTS agrees with FFmpeg, but odd-DTS exact Pd inference is unverified and §8.4 exceptions matter. |
| ST337_LEN_NOPRE | smpte-st337-2015 p.12 §7.2.5; sibling-standard | SUPPORTS | Explicit payload-only count, a shared burst-structure property; no claim that E-AC-3 uses bits. |
| ST337_FIRST_BIT | smpte-st337-2015 p.12 §7.3.1; sibling-standard | SUPPORTS | Page describes serial bits across subframes, first at MSB; shared structure rationale stated in note. |
| ST337_LAST_UNUSED | smpte-st337-2015 p.12 §7.3.1; sibling-standard | SUPPORTS | Explicit unused final-frame bits zero; supports low-byte and unused-subframe fill under structural inference. |
| ST337_UNUSED_ZERO | smpte-st337-2015 p.6 §6.1; sibling-standard | SUPPORTS | Page completes truncated quote with zero; interburst unused locations zero, independently confirmed by consumer FFmpeg. |
| ST337_FOUR_ZERO | smpte-st337-2015 p.13 §7.4; sibling-standard | SUPPORTS | Zeros preceding Pa are outside the burst; test uses eight leading zero words and does not assert a universal four-zero rule. |
| ST337_IDLE | smpte-st337-2015 p.15 §Annex-A; sibling-standard | SUPPORTS | All-zero stream is idle, no burst; informative annex at honest sibling tier. |
| ST338_AC3 | smpte-st338-2016 p.4 §4; sibling-standard | SUPPORTS | Informative IEC column confirms consumer code1; Same data does not automatically establish all consumer timing/field rules. |
| ST338_EAC3_IEC | smpte-st338-2016 p.4 §4; sibling-standard | SUPPORTS | Full row21 gives consumer E-AC-3 allocation with sub-data-type caveat; preview independently confirms scoped code21. |
| ST338_DTS1 | smpte-st338-2016 p.4 §4; sibling-standard | PARTIAL | Row11 IEC column says DTS I; does not itself link 512 samples, which correctly rests on FF_DTS1. |
| ST338_DTS2 | smpte-st338-2016 p.4 §4; sibling-standard | PARTIAL | Row12 IEC column says DTS II; 1024-sample link is secondary FFmpeg. |
| ST338_DTS3 | smpte-st338-2016 p.4 §4; sibling-standard | PARTIAL | Row13 IEC column says DTS III; 2048-sample link is secondary FFmpeg. |
| ST340_AC3_TYPE | smpte-st340-2015 p.5 §4.2.1; sibling-standard | SUPPORTS | Professional code1 is explicitly also code1 in ST338 consumer allocation, as note states. |
| ST340_AC3_DTD_RESERVED | smpte-st340-2015 p.5 §4.2.2; sibling-standard | DOES-NOT-SUPPORT | Professional reserved bits and rep-rate flag do not establish consumer bsmod0 dependent field; §8.4 explicitly warns of differences. FF_AC3_TYPE is the actual secondary support. |
| ST340_AC3_PAYLOAD | smpte-st340-2015 p.5 §4.3; sibling-standard | PARTIAL | Explicit professional one-syncframe payload; Same data is a reasonable declared inference, not consumer normative confirmation. |
| ST340_AC3_PERIOD | smpte-st340-2015 p.6 §4.6; sibling-standard | PARTIAL | 1536 is professional repetition period; Same data allocation does not guarantee spacing under §8.4. Consumer value independently secondary FFmpeg plus codec duration. |
| ST340_AC3_PAD | smpte-st340-2015 p.4 §4.1; sibling-standard | PARTIAL | Professional padding to1536; note does not explain consumer applicability; consumer period support is secondary. |
| ST340_EAC3_PAYLOAD | smpte-st340-2015 p.9 §5.3; sibling-standard | PARTIAL | Professional syncframe grouping only; note admits consumer carryover rests on FFmpeg, so consumer rule is secondary. |
| ST340_EAC3_6BLK | smpte-st340-2015 p.10 §5.3; sibling-standard | PARTIAL | Professional six-block rule and convsync restriction; consumer single-substream grouping agrees with FFmpeg, not independently established by professional clause. |
| ST340_EAC3_TYPE_PRO | smpte-st340-2015 p.9 §5.2.1; sibling-standard | SUPPORTS | Unused background explicitly professional16, never used as consumer expected code. |
| ST340_EAC3_PERIOD_PRO | smpte-st340-2015 p.10 §5.6; sibling-standard | SUPPORTS | Unused background explicitly professional1536, never used as consumer period. |
| IEC3_T3 | iec61937-3-preview p.2 §front; primary-preview | SUPPORTS | Contents and surrounding AC-3 section/table identify type bits0–4=1; preview tier honestly limited to title. |
| IEC3_T4 | iec61937-3-preview p.2 §front; primary-preview | SUPPORTS | E-AC-3 table title identifies bits0–4=21, without inventing absent table contents. |
| IEC3_T4_56 | iec61937-3-preview p.2 §front; primary-preview | SUPPORTS | Same title explicitly restricts bits5–6=0. |
| IEC3_T5 | iec61937-3-preview p.2 §front; primary-preview | PARTIAL | Unused title establishes size/rate dependence only; does not prove a specific repetition period or difference from1536. |
| A52_SYNC | atsc-a52-2018 p.38 §5.4.1.1; codec-spec | PARTIAL | Quoted AC-3 clause establishes 0B77; E-AC-3 use needs Annex E syncword semantics (available elsewhere in corpus), not this clause alone. |
| A52_FSCOD | atsc-a52-2018 p.38 §5.4.1.3; codec-spec | SUPPORTS | Page38 table gives 48/44.1/32 mapping; layout is on separately cited page31; unused in test assertions. |
| A52_SYNCINFO | atsc-a52-2018 p.31 §5.3.1; codec-spec | SUPPORTS | Full page31 table supplies 16/16/2/6 layout; short title quote alone is weak but cited page supports builder. |
| A52_SIZE_48_128 | atsc-a52-2018 p.52 §5.4; codec-spec | SUPPORTS | Table columns and row16 give256 words=512 bytes at48k. |
| A52_SIZE_44_0 | atsc-a52-2018 p.52 §5.4; codec-spec | SUPPORTS | Row0 at44.1k gives69 words=138 bytes, odd word count. |
| A52_SIZE_32_40 | atsc-a52-2018 p.52 §5.4; codec-spec | SUPPORTS | Row2 at32k gives120 words; unused assertion citation also supports fixture size. |
| A52_BSMOD | atsc-a52-2018 p.32 §5.3.2; codec-spec | SUPPORTS | Page32 bsi starts bsid5 then bsmod3; with syncinfo this is byte5 low3; unused assertion key. |
| E_SYNCINFO | etsi-ts-102366 p.114 §Annex-E; codec-spec | PARTIAL | Page114 supports header layout and 16-bit syncword but not numeric 0B77; add E-AC-3 syncword semantic clause. |
| E_FRMSIZ | etsi-ts-102366 p.127 §Annex-E; codec-spec | SUPPORTS | Explicit size-minus-one in16-bit words; unused key supports fixture construction. |
| E_NUMBLKS | etsi-ts-102366 p.127 §Annex-E; codec-spec | SUPPORTS | Full table supplies all four 1/2/3/6 mappings; codec block count is not a consumer grouping mandate. |
| DTS_SYNC | etsi-ts-102114 p.25 §5.4.2; codec-spec | SUPPORTS | Table5-1 supplies32-bit sync and complete builder field widths. |
| DTS_FSIZE | etsi-ts-102114 p.26 §5.4.2; codec-spec | SUPPORTS | FSIZE+1 total bytes, range96–16384, no even-byte restriction; carriage acceptance separately secondary. |
| DTS_NBLKS | etsi-ts-102114 p.26 §5.4.2; codec-spec | SUPPORTS | Explicit32*(NBLKS+1), supports sample calculations, not IEC repetition period by itself. |
| FF_SYNC1 | ffmpeg-spdif-n7.1/spdif p.1 §file; secondary | SUPPORTS | Unused direct secondary Pa constant. |
| FF_SYNC2 | ffmpeg-spdif-n7.1/spdif p.1 §file; secondary | SUPPORTS | Unused direct secondary Pb constant. |
| FF_PC_BITS | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | PARTIAL | Consumer comment gives type bits0–6, not a universal5-bit type; supports error/dtd positions; scoped bits5–6=0 separately justified. |
| FF_PC_STREAM | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Consumer comment explicitly gives bitstream bits13–15. |
| FF_PD_UNIT | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Explicit unit varies by type; E-AC-3 assignment separately establishes bytes. |
| FF_FILL_ZERO | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Consumer comment explicitly says spaces filled with zero, corroborated by ffio_fill. |
| FF_AC3_TYPE | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Code copies bsmod into bits8–10 and leaves higher dependent bits clear; secondary even when bsmod=0. |
| FF_AC3_BSMOD | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Explicit byte5 low3 extraction. |
| FF_AC3_PERIOD | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | PARTIAL | Expression references AC3_FRAME_SIZE; its1536 definition is not in supplied FFmpeg files. Codec/sibling corpus corroborates1536; expression alone lacks numeric definition. |
| FF_PERIOD_BYTES | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Explicit pkt_offset units bytes; conversion to2-byte words/4-byte frames follows interface. |
| FF_LEN_BITS | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Explicit even-byte alignment then*8; tested encoder lengths are even. Does not support exact unrounded odd-DTS Pd. |
| FF_EAC3_TYPE | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Unused direct enum assignment leaves dependent/error/stream bits0. |
| FF_EAC3_ENUM | ffmpeg-spdif-n7.1/spdif p.1 §file; secondary | SUPPORTS | Unused direct enum21=E-AC-3. |
| FF_EAC3_PERIOD | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Explicit24576-byte period, secondary; conversion12288 words is exact. |
| FF_EAC3_LEN | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | hd_buf_filled accumulates packet bytes and is assigned to Pd; secondary byte-count rule. |
| FF_EAC3_GROUP | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Unused repeat array supports same-numblkscod single-substream grouping only. |
| FF_EAC3_GROUP_IDX | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Unused code extracts byte4 bits5–4 to index repeats, guarded by fscod. |
| FF_DTS1 | ffmpeg-spdif-n7.1/spdif p.1 §file; secondary | SUPPORTS | Explicit consumer enum11 and512 samples; secondary mapping honestly labeled. |
| FF_DTS2 | ffmpeg-spdif-n7.1/spdif p.1 §file; secondary | SUPPORTS | Explicit consumer enum12 and1024 samples; secondary mapping honestly labeled. |
| FF_DTS3 | ffmpeg-spdif-n7.1/spdif p.1 §file; secondary | SUPPORTS | Explicit consumer enum13 and2048 samples; secondary mapping honestly labeled. |
| FF_DTS_PERIOD | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | blocks++ then<<7 bytes gives32 samples/block times4 bytes/frame. |
| FF_DTS_BADSYNC | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Code default sync case returns invalid data; scoped input is16-bit BE. |
| FF_DTS_UNSUPPORTED | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Switch accepts512/1024/2048 and rejects other sample counts. |
| FF_TOO_BIG | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Full page DTS oversized path and packet padding<0 error support refusal; exact-fit no-preamble exception is not exercised. |
| FF_ODD | ffmpeg-spdif-n7.1/spdifenc p.1 §file; secondary | SUPPORTS | Explicit live odd-byte path emits final byte<<8; supports acceptance/alignment at secondary tier, not normative consumer conformance. |

## Failures adjudicated from corpus

1. `tests/test_iec61937.py::test_dts_odd_length_frame_last_byte_is_msb_aligned`: **meter implementation wrong relative to the available secondary reference**. `meter/vblind_ref.py:370–371` rejects size1025 solely because it is odd. ETSI TS102114 §5.4.2 p.26 defines FSIZE+1 in bytes over96–16384, without an even restriction. FFmpeg spdifenc file p.1 lines666–668 explicitly handles a final lone byte by emitting it shifted8. The payload easily fits the512-frame period. ST337 §7.3.1 p.12 also describes zeroing unused final-frame bits. Neither cited source justifies meter's categorical impossibility claim; its own `_burst` already pads odd bytes. This is not a proven primary IEC violation: consumer normative odd-DTS requirements remain unavailable. Test acceptance/alignment should be labeled secondary, rather than upgraded by the professional structural citation.
2. `tests/test_iec61937.py::test_dts_odd_length_frame_fill_is_zero_and_period_kept`: **same meter defect**, same size1025 rejection before any fill assertion. FFmpeg's odd-byte path plus `ffio_fill(...,0,padding)` and ST337 unused-zero rule support zero fill at their respective tiers. The test name additionally claims period preservation, but its body checks only zero fill after word517, not `len(w)==1024`; it can vacuously pass a short output. That missing assertion does not excuse the actual rejection.

These are two failed cases, not two distinct defects. Do not delete them merely to make meter green; retain the failed automated result until the implementation and secondary-tier attribution are resolved.

## Findings

- **Blocking automated failure:** meter157/159. Base159/159 and six killed variants establish useful independent agreement, not all-reference conformance.
- **R2 consumer/professional attribution:** `ST340_AC3_DTD_RESERVED` cites professional reserved dependent bits and a professional repetition flag to support consumer dependent-field zero for bsmod0. ST337 §8.4 p.14 expressly says this field can differ. FFmpeg independently supports the expected consumer value, but it remains secondary; attaching this sibling key cannot promote it. Grade DOES-NOT-SUPPORT is for the attributed consumer rule, even though the professional quote itself is real.
- **R2 timing and grouping:** ST338's informative "Same data" allocation does not automatically establish identical AC-3 burst spacing, fields or all payload coding. ST340 professional AC-3 period/padding and E-AC-3 payload/grouping should remain professional corroboration; consumer periods and the simple grouping demonstrated here rest on FFmpeg. Neither professional E-AC-3 code16 nor period1536 is incorrectly expected by the suite, which correctly expects consumer21/6144.
- **Per-assertion tiers:** a codec header citation or preview type-code title cannot promote a compound claim about consumer payload units, grouping or timing. Examples: `test_parse_payload_in_bytes_for_eac3_type` remains secondary for bytes despite IEC3_T4; `test_roundtrip_eac3_payload` needs secondary carriage support despite a preview code citation; odd-DTS acceptance remains secondary. The checker lists citation tiers but does not prove each expected value at the best listed tier.
- **R2 notes incomplete:** several ST337 field notes state positions without the required carryover explanation. Shared burst structure plus §8.2–8.3 is defensible for positions; dependent-field content is a separate issue. Add the argument directly to the relevant notes and keep consumer semantics limited to actual consumer evidence.
- **Interface attribution:** requested DoP phase/default05 is explicit in stub, not mandated by dop-1.1. DOP_MARKER_ALT is only partial for those assertions. The swapped-marker saboteur is legitimately killed for interface behavior, not an independently specified default DoP phase.
- **Fixture/citation precision:** E_SYNCINFO establishes E-AC-3 syncword width, not its numeric value; A52_SYNC is an AC-3 clause. E-AC-3 numeric syncword support exists elsewhere in the corpus, e.g. TS102366 J.1.5.1 p.240, but is not the cited numeric clause. Table-title-only quotes such as A52_SYNCINFO and E_NUMBLKS resolve, but quoting all actual relied-on row cells would make evidence clearer.

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

## Gaps and coverage limits

- Full normative IEC61937-1/-2/-3/-5 consumer clauses are absent. Primary consumer conformance for payload mapping, dependent-field content, stuffing, repetition rates and per-type length units remains **unverified**. Obtain those clauses to settle this; previews cannot supply their absent tables.
- Odd DTS: emitted final-byte padding is supported secondary; exact consumer Pd rounding is **unverified**. Base uses exact size*8; FFmpeg initializes `FFALIGN(size,2)*8` unless a truncation path overrides it. Neither odd encoder test checks Pd, nor does the odd parser fixture prove which encoder unit rule consumers require. Do not mistake both implementations passing that parser test for normative evidence.
- Multiple independent/dependent E-AC-3 substreams, convsync alignment, incomplete-group eac3_group behavior and sample-rate transitions are untested. Codec ordering and professional constraints are available, simple FFmpeg grouping only covers a limited model; full consumer validation needs IEC61937-3. Meter admits not validating convsync.
- Reduced-rate E-AC-3 edition/profile conflict (ATSC fscod2 vs ETSI reserved3), non48k consumer periods, exact-fit no-preamble DTS, malformed/trailing input policy and empty DoP behavior remain outside these assertions or open choices. No creative policy was invented to settle them.
- Every AC-3 table row is not exercised: only three size/rate fixtures plus bsmod variations. All relevant table values are in corpus and could support more coverage. Parser mode refusal, truncated preambles, non-byte-aligned lengths, word-range validation, false sync inside payload, nonzero unused low-byte rejection and even-start constraints are also incompletely covered; positions/length limits have corpus/interface support, while recovery policy needs an explicit open choice.
- No playable compressed-audio/CRC fixtures or actual transport/receiver runs are present. End-to-end decoding, hardware acceptance, channel status and acquisition latency are **unverified** or explicitly out of scope. Six chosen mutations do not establish exhaustive fault coverage.
- Independence/provenance of builder roles is **unverified** beyond supplied files and declarations; this audit did not read outside the room or use network/git.

## Open choices

DoP starting phase is caller-controlled; default05 is the interface default. Empty input, trailing incomplete E-AC-3 groups, parser recovery and extra compressed-frame bytes differ between implementations and are not normalized by this audit. Existing documented choices remain documented choices. No tests, meter, base or saboteurs were edited to resolve disagreements.

## Summary

Citation resolution passes, base passes159/159, the stub fails159/159, and all six mutations are caught. The round fails its meter all-pass gate (two secondary odd-DTS cases), with one unsupported consumer citation and additional tier/page/coverage findings. These results stand exactly as recorded.
