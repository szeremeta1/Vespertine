VERDICT: PASS WITH FINDINGS

All required automated gates stand: citecheck exits0 with93/93 resolving keys and no problems; all276 stub cases fail with NotImplementedError; meter and base each pass276/276; every one of six variants has actual assertion failures. No skips, xfails, collection failures or import errors conceal results. Manual semantic review finds no DOES-NOT-SUPPORT key, but the partial support and corpus limits below prevent a claim of complete consumer-standard conformance.

## Results matrix

| Implementation | Passed | Failed | Skipped | Exit | Evidence |
|---|---:|---:|---:|---:|---|
| stub/vblind.py (VBLIND_IMPL unset) | 0 | 276 | 0 | 1 | [stub.xml](stub.xml), [stub.txt](stub.txt) |
| meter/vblind_ref.py | 276 | 0 | 0 | 0 | [meter.xml](meter.xml), [meter.txt](meter.txt) |
| saboteurs/base.py | 276 | 0 | 0 | 0 | [base.xml](base.xml), [base.txt](base.txt) |
| saboteurs/sab_byte_order.py | 139 | 137 | 0 | 1 | [sab_byte_order.xml](sab_byte_order.xml), [sab_byte_order.txt](sab_byte_order.txt) |
| saboteurs/sab_dop_bit_order.py | 270 | 6 | 0 | 1 | [sab_dop_bit_order.xml](sab_dop_bit_order.xml), [sab_dop_bit_order.txt](sab_dop_bit_order.txt) |
| saboteurs/sab_length_off_by_one.py | 272 | 4 | 0 | 1 | [sab_length_off_by_one.xml](sab_length_off_by_one.xml), [sab_length_off_by_one.txt](sab_length_off_by_one.txt) |
| saboteurs/sab_padding.py | 265 | 11 | 0 | 1 | [sab_padding.xml](sab_padding.xml), [sab_padding.txt](sab_padding.txt) |
| saboteurs/sab_pc_datatype.py | 275 | 1 | 0 | 1 | [sab_pc_datatype.xml](sab_pc_datatype.xml), [sab_pc_datatype.txt](sab_pc_datatype.txt) |
| saboteurs/sab_swapped_markers.py | 269 | 7 | 0 | 1 | [sab_swapped_markers.xml](sab_swapped_markers.xml), [sab_swapped_markers.txt](sab_swapped_markers.txt) |

Each run used `./.venv/bin/python -m pytest tests -q -p no:cacheprovider --junitxml audit/<name>.xml`, with VBLIND_IMPL set to the listed implementation, except the stub where it was removed from the environment. Exact expanded commands and exit codes are in [runs.json](runs.json). Complete stdout/stderr is saved per run. The isolated citecheck command was exactly `./.venv/bin/python -I citecheck.py . --json audit/citecheck.json`; result: `citations: 93 (93 resolve); tests: 77; problems: 0; unused citations: 11`, exit0. There are77 test functions and276 parameterized cases; these counts measure different things.

## Saboteur kill table

All listed kills were read from the fresh JUnit failure elements. [kills.json](kills.json) lists every exact failing parameterized node ID, including all114 table cases abbreviated below.

| Variant | Killing cases | Killing tests |
|---|---:|---|
| sab_byte_order.py | 137 | `tests/test_iec61937.py::test_payload_follows_pd_big_endian` [ac3_48k], [ac3_44k], [ac3_32k], [eac3_6x1], [eac3_1x6], [eac3_2x3], [dts_512], [dts_1024], [dts_2048]<br>`tests/test_iec61937.py::test_ac3_payload_starts_with_the_syncword` [ac3_48k], [ac3_44k], [ac3_32k]<br>`tests/test_iec61937.py::test_ac3_payload_is_one_whole_syncframe_48k`<br>`tests/test_iec61937.py::test_eac3_payload_is_the_frames_in_order`<br>`tests/test_iec61937.py::test_eac3_payload_starts_with_the_syncword`<br>`tests/test_iec61937.py::test_dts_payload_starts_with_the_sync_word` [dts_512], [dts_1024], [dts_2048]<br>`tests/test_iec61937.py::test_dts_odd_length_frame_last_byte_is_msb_aligned`<br>`tests/test_iec61937.py::test_ac3_all_frame_size_rows_preserve_payload_and_bit_length` [all114: fscod0/1/2 × frmsizecod0..37; full node IDs in kills.json]<br>`tests/test_parse.py::test_roundtrip_ac3_payload`<br>`tests/test_parse.py::test_roundtrip_ac3_three_bursts_offsets`<br>`tests/test_parse.py::test_roundtrip_eac3_payload`<br>`tests/test_parse.py::test_roundtrip_dts_payload_and_offsets` |
| sab_dop_bit_order.py | 6 | `tests/test_dop.py::test_pack_oldest_bit_is_bit15`<br>`tests/test_dop.py::test_pack_bit_order_within_first_byte`<br>`tests/test_dop.py::test_pack_second_byte_in_low_half`<br>`tests/test_dop.py::test_pack_sixteen_bits_per_frame_in_time_order`<br>`tests/test_dop.py::test_pack_channel_k_goes_to_pcm_channel_k`<br>`tests/test_dop.py::test_unpack_reads_hand_built_stream` |
| sab_length_off_by_one.py | 4 | `tests/test_iec61937.py::test_eac3_pd_is_payload_length_in_bytes` [eac3_6x1], [eac3_1x6], [eac3_2x3]<br>`tests/test_parse.py::test_roundtrip_eac3_payload` |
| sab_padding.py | 11 | `tests/test_iec61937.py::test_fill_after_payload_is_zero` [ac3_48k], [ac3_44k], [ac3_32k], [eac3_6x1], [eac3_1x6], [eac3_2x3], [dts_512], [dts_1024], [dts_2048]<br>`tests/test_iec61937.py::test_unused_second_subframe_of_last_payload_frame_is_zero`<br>`tests/test_iec61937.py::test_dts_odd_length_frame_fill_is_zero_and_period_kept` |
| sab_pc_datatype.py | 1 | `tests/test_iec61937.py::test_dts_data_type_by_frame_length` [dts_2048-13] |
| sab_swapped_markers.py | 7 | `tests/test_dop.py::test_pack_markers_alternate_from_05`<br>`tests/test_dop.py::test_pack_markers_alternate_from_fa`<br>`tests/test_dop.py::test_pack_default_first_marker`<br>`tests/test_dop.py::test_pack_oldest_bit_is_bit15`<br>`tests/test_dop.py::test_pack_bit_order_within_first_byte`<br>`tests/test_dop.py::test_pack_second_byte_in_low_half`<br>`tests/test_dop.py::test_unpack_reads_hand_built_stream` |

No survivor exists, so no mutation-specific missed requirement needs adjudication. The type mutation is killed specifically on2048-sample DTS by the secondary consumer enum. Swapped markers are an interface first_marker/inverse violation, not a failure of DoP alternation alone; the independent hand-built decode and requested/default phases make the kill legitimate. The bit-order variant preserves its own roundtrip but fails independently specified words. Padding, byte-order and E-AC-3 Pd kills match their declared changed fields. Mutation kills establish detection of these six faults, not exhaustive correctness or independent provenance.

## Citation grades

Manual grades: 81 SUPPORTS; 12 PARTIAL; 0 DOES-NOT-SUPPORT. Every one of the93 keys was reviewed against its cited page and assertion uses, including11 unused documentation keys. The31 complete test-cited pages are captured in [source-review.txt](source-review.txt). SUPPORTS means support for the stated component under its disclosed tier and scope; it does not promote a sibling inference or secondary agreement to consumer normative conformance. PARTIAL means the quote alone lacks a relevant part, is professional-only corroboration, or leaves an explicitly documented inference. Companion citations and the stub contract are distinguished below.

| Key | Cited location / tier | Grade | Reason |
|---|---|---|---|
| DOP_MARKER_ALT | dop-1.1 §2 p.2 / primary | PARTIAL | §2 supplies values and alternation; requested/default first phase and returned phase come from the stub contract, explicitly disclosed in the note. |
| DOP_MARKER_SAME | dop-1.1 §2 p.2 / primary | SUPPORTS | §2 explicitly requires the same marker across every channel in a sample. |
| DOP_MARKER_MSB | dop-1.1 §2 p.2 / primary | SUPPORTS | §2 places the eight marker bits at the top of the 24-bit sample. |
| DOP_BITS_OLDEST | dop-1.1 §2 p.2 / primary | SUPPORTS | §2 assigns sixteen low bits to successive DSD bits, oldest at t0; exact-slot rejection also follows the interface. |
| DOP_DIAGRAM | dop-1.1 §2 p.2 / primary | SUPPORTS | The full p.2 diagram places t0 immediately below dm0 and t15 at the LSB, supporting both byte and bit order. |
| DOP_24BIT | dop-1.1 §2 p.2 / primary | SUPPORTS | The p.2 diagram explicitly labels a 24-bit PCM word. |
| DOP_PER_CHANNEL | dop-1.1 §2 p.2 / primary | SUPPORTS | §2 preserves assigned DSD channel identity; the interface supplies frame/channel indexing. |
| DOP_OTHER_MARKER | dop-1.1 §3 p.2 / primary | SUPPORTS | §3 distinguishes the paired-channel method; §2 and the scope restrict this interface to the base markers. |
| DOP_ALT_MARKERS | dop-1.1 §3 p.2 / primary | SUPPORTS | The §3 row explicitly places 06/F9 in the excluded paired-channel method. |
| DOP_RX_MISSING | dop-1.1 §4 p.3 / primary | SUPPORTS | §4 is a recommended receiver algorithm, not a 32-frame minimum for this API; missing-marker refusal is independently required by §2. |
| ST337_PA | smpte-st337-2015 §7.2.1 p.9 / sibling-standard | SUPPORTS | Table 6 supplies F872 in 16-bit mode; note explains the §8.2–8.3 shared-preamble inference at sibling tier. |
| ST337_PB | smpte-st337-2015 §7.2.1 p.9 / sibling-standard | SUPPORTS | Table 6 supplies 4E1F in 16-bit mode with the same explicit structural inference. |
| ST337_EXT_SYNC | smpte-st337-2015 §7.4 p.13 / sibling-standard | SUPPORTS | §7.4 explicitly prints four zeros then Pa/Pb; tests do not require this before every burst. |
| ST337_FRAME_PRE | smpte-st337-2015 §7.2.2 p.9 / sibling-standard | SUPPORTS | §7.2.2 gives Pa/Pb then Pc/Pd in two frames; offset/raw-Pd semantics also use the interface contract. |
| ST337_CONSUMER_SUBSET (unused) | smpte-st337-2015 §8.2 p.14 / sibling-standard | SUPPORTS | §8.2 expressly supports a general structural relationship, not universal consumer payload/timing equivalence; unused documentation key. |
| ST337_CONSUMER_16 | smpte-st337-2015 §8.3 p.14 / sibling-standard | SUPPORTS | §8.3 expressly limits consumer-compatible bursts to 16-bit frame mode, mode zero. |
| ST337_PRE_FOLLOW | smpte-st337-2015 §7.1 p.8 / sibling-standard | SUPPORTS | §7.1 says preamble followed by payload in a continuous sequence; structural inference is disclosed. |
| ST337_T7_TYPE | smpte-st337-2015 §7.2.4.1 p.10 / sibling-standard | SUPPORTS | Table 7 supplies low-five-bit positions; the note limits consumer carryover to scoped mode zero, not arbitrary seven-bit consumer types. |
| ST337_T7_MODE | smpte-st337-2015 §7.2.4.1 p.10 / sibling-standard | SUPPORTS | Table 7 supplies bits 5–6; consumer-compatible zero mode is separately supported by §8.3. |
| ST337_T7_ERR | smpte-st337-2015 §7.2.4.1 p.10 / sibling-standard | SUPPORTS | Table 7 supplies error flag bit 7; note expressly limits the structural inference. |
| ST337_T7_DTD | smpte-st337-2015 §7.2.4.1 p.10 / sibling-standard | SUPPORTS | Table 7 supplies bits 8–12 only; no professional dependent-field contents are imported. |
| ST337_T7_STREAM | smpte-st337-2015 §7.2.4.1 p.10 / sibling-standard | SUPPORTS | Table 7 supplies bits 13–15; scope fixes emitted stream zero and parser tests only extract fields. |
| ST337_T8_16 | smpte-st337-2015 §7.2.4.3 p.11 / sibling-standard | SUPPORTS | Table 8 explicitly maps zero to 16-bit mode, used with the consumer compatibility clause. |
| ST337_ERR0 | smpte-st337-2015 §7.2.4.4 p.11 / sibling-standard | SUPPORTS | §7.2.4.4 explicitly sets zero when error status is unknown; note explains the sibling inference rather than claiming CRC validity. |
| ST337_STREAM0 | smpte-st337-2015 §7.2.4.6 p.12 / sibling-standard | SUPPORTS | §7.2.4.6 requires a stream zero, consistent with the scope explicitly fixing the single emitted stream to zero. |
| ST337_LEN_BITS | smpte-st337-2015 §7.2.5 p.12 / sibling-standard | PARTIAL | §7.2.5 establishes professional bit units only; consumer AC-3/DTS units depend on secondary FF_LEN_BITS, as disclosed. |
| ST337_LEN_NOPRE | smpte-st337-2015 §7.2.5 p.12 / sibling-standard | SUPPORTS | §7.2.5 excludes Pa–Pd from payload length; the note separates shared structure from per-type consumer units. |
| ST337_FIRST_BIT | smpte-st337-2015 §7.3.1 p.12 / sibling-standard | SUPPORTS | §7.3.1 treats payload as a serial bitstream, first bit at subframe-1 MSB; stated structural inference supports word order, not codec-specific contents. |
| ST337_LAST_UNUSED | smpte-st337-2015 §7.3.1 p.12 / sibling-standard | SUPPORTS | §7.3.1 zeroes unused final-frame bits; note correctly leaves odd-DTS acceptance and encoder Pd at secondary/unverified status. |
| ST337_UNUSED_ZERO | smpte-st337-2015 §6.1 p.6 / sibling-standard | PARTIAL | Right page and section, but quote ends at “set to” and omits the actual zero; complete §6.1 on p.6 and FF_FILL_ZERO support the assertion. |
| ST337_FOUR_ZERO | smpte-st337-2015 §7.4 p.13 / sibling-standard | SUPPORTS | §7.4 describes four zero subframes preceding Pa; parser offset comes from Pa per the interface, not the preceding sync extension. |
| ST337_IDLE | smpte-st337-2015 §Annex-A p.15 / sibling-standard | SUPPORTS | Informative Annex A explicitly describes all-zero idle and no arriving burst; no acquisition policy is imposed. |
| ST338_AC3 | smpte-st338-2016 §4 p.4 / sibling-standard | SUPPORTS | Table 1 row 1 labels AC-3 and the informative IEC column says Same data; this supports allocation, not identical timing. |
| ST338_EAC3_IEC | smpte-st338-2016 §4 p.4 / sibling-standard | PARTIAL | Page Table 1 row 21 supports the qualified consumer allocation, but quote omits row number and sub-data-type qualification; IEC3_T4 independently supports the tested code. |
| ST338_DTS1 | smpte-st338-2016 §4 p.4 / sibling-standard | PARTIAL | Page Table 1 supports IEC code 11, but quoted wrapped fragment omits the row number; sample count comes from FF_DTS1, not SMPTE. |
| ST338_DTS2 | smpte-st338-2016 §4 p.4 / sibling-standard | SUPPORTS | Table 1 IEC column supplies code 12 for type II; note and secondary test correctly source sample count elsewhere. |
| ST338_DTS3 | smpte-st338-2016 §4 p.4 / sibling-standard | SUPPORTS | Table 1 IEC column supplies code 13 for type III; note and secondary test correctly source sample count elsewhere. |
| ST340_AC3_TYPE | smpte-st340-2015 §4.2.1 p.5 / sibling-standard | SUPPORTS | Professional code 1 is corroborated by the IEC allocation column and consumer preview; not used alone as consumer authority. |
| ST340_AC3_PAYLOAD | smpte-st340-2015 §4.3 p.5 / sibling-standard | PARTIAL | §4.3 specifies a complete professional syncframe; consumer unchanged payload relies on FF_PAYLOAD and codec/interface validation, explicitly disclosed. |
| ST340_AC3_PERIOD | smpte-st340-2015 §4.6 p.6 / sibling-standard | PARTIAL | §4.6 supplies professional 1536-frame spacing, not consumer spacing under §8.4; secondary macro/duration inference remains incomplete. |
| ST340_AC3_PAD | smpte-st340-2015 §4.1 p.4 / sibling-standard | PARTIAL | §4.1 supplies professional padding to 1536 samples; note honestly limits this to corroboration of the consumer timing inference. |
| ST340_EAC3_PAYLOAD | smpte-st340-2015 §5.3 p.9 / sibling-standard | PARTIAL | §5.3 specifies professional syncframe payloads; consumer concatenation is supported by secondary FF_EAC3_CONCAT, not this clause alone. |
| ST340_EAC3_6BLK | smpte-st340-2015 §5.3 p.10 / sibling-standard | PARTIAL | §5.3 is professional and includes all-substream/convsync constraints; tested constant-block single-substream groups rely on secondary FFmpeg, as disclosed. |
| ST340_EAC3_TYPE_PRO (unused) | smpte-st340-2015 §5.2.1 p.9 / sibling-standard | SUPPORTS | §5.2.1 says professional code 16; unused documentation key explicitly warns against applying it to consumer E-AC-3. |
| ST340_EAC3_PERIOD_PRO (unused) | smpte-st340-2015 §5.6 p.10 / sibling-standard | SUPPORTS | §5.6 says professional 1536-frame spacing; unused documentation key does not assert this for consumer E-AC-3. |
| IEC3_T3 | iec61937-3-preview §front p.2 / primary-preview | SUPPORTS | Preview contents Table 3 title supplies AC-3 low-five-bit type 1; no hidden table contents are inferred. |
| IEC3_T4 | iec61937-3-preview §front p.2 / primary-preview | SUPPORTS | Preview contents Table 4 title supplies enhanced AC-3 low-five-bit type 21. |
| IEC3_T4_56 | iec61937-3-preview §front p.2 / primary-preview | SUPPORTS | The same Table 4 title explicitly specifies type bits 5–6 equal zero. |
| IEC3_T5 (unused) | iec61937-3-preview §front p.2 / primary-preview | SUPPORTS | Unused title only establishes a size/rate-dependent table exists; note infers no numeric values or timing. |
| A52_SYNC | atsc-a52-2018 §5.4.1.1 p.38 / codec-spec | SUPPORTS | Printed §5.4.1.1 p.38 explicitly supplies AC-3 0B77 and left-bit-first transmission, not E-AC-3 numeric authority. |
| A52_FSCOD | atsc-a52-2018 §5.4.1.3 p.38 / codec-spec | SUPPORTS | Printed §5.4.1.3 Table 5.6 maps all three tested rate codes and the reserved code. |
| A52_SYNCINFO | atsc-a52-2018 §5.3.1 p.31 / codec-spec | SUPPORTS | Printed §5.3.1 Table 5.1 gives all syncinfo field widths used by the builder; BSI follows on p.32. |
| A52_SIZE_48_128 | atsc-a52-2018 §5.4 p.52 / codec-spec | SUPPORTS | Table 5.18 code 010000 is 256 words at 48 kHz, exactly the tested 512-byte fixture; code 17 also appears separately on this page. |
| A52_SIZE_44_0 | atsc-a52-2018 §5.4 p.52 / codec-spec | SUPPORTS | Table 5.18 code zero is 69 words at 44.1 kHz, supporting the half-used final interface frame. |
| A52_SIZE_32_40 (unused) | atsc-a52-2018 §5.4 p.52 / codec-spec | SUPPORTS | Table 5.18 code two is 120 words at 32 kHz; unused numeric fixture documentation. |
| A52_BSMOD (unused) | atsc-a52-2018 §5.3.2 p.32 / codec-spec | SUPPORTS | Printed §5.3.2 BSI starts bsid5, bsmod3, acmod3; unused key correctly explains byte-five layout. |
| E_SYNCINFO | etsi-ts-102366 §Annex-E p.114 / codec-spec | SUPPORTS | Annex E p.114 supplies a sixteen-bit sync field and subsequent BSI layout; E_SYNCWORD supplies the numeric value separately. |
| E_FRMSIZ (unused) | etsi-ts-102366 §Annex-E p.127 / codec-spec | SUPPORTS | Annex E p.127 explicitly defines frmsiz as total sixteen-bit words minus one; unused key supports builder sizing. |
| E_NUMBLKS | etsi-ts-102366 §Annex-E p.127 / codec-spec | SUPPORTS | Annex E p.127 Table E.1.3 explicitly supplies all four tested block-count mappings; no consumer burst period follows from this alone. |
| DTS_SYNC | etsi-ts-102114 §5.4.2 p.25 / codec-spec | SUPPORTS | §5.4.2 p.25 supplies core 7FFE8001 and the field-width layout; header-short refusal also follows the interface. |
| DTS_FSIZE | etsi-ts-102114 §5.4.2 p.26 / codec-spec | SUPPORTS | §5.4.2 p.26 defines total bytes FSIZE+1 without an even-byte restriction; consumer odd carriage is independently secondary. |
| DTS_NBLKS | etsi-ts-102114 §5.4.2 p.26 / codec-spec | SUPPORTS | §5.4.2 p.26 explicitly defines 32*(NBLKS+1) samples; transport code/period still need FFmpeg. |
| FF_SYNC1 (unused) | ffmpeg-spdif-n7.1/spdif §file p.1 / secondary | SUPPORTS | spdif.h defines F872; unused corroboration, honestly secondary. |
| FF_SYNC2 (unused) | ffmpeg-spdif-n7.1/spdif §file p.1 / secondary | SUPPORTS | spdif.h defines 4E1F; unused corroboration, honestly secondary. |
| FF_PC_BITS | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc lines 38–39 give seven type bits, error7 and dependent8–12; note explicitly limits five-bit extraction to scoped bits5–6 zero. |
| FF_PC_STREAM | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line 39 supplies consumer stream bits13–15, independently of professional type-dependent meanings. |
| FF_PD_UNIT | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line 41 says units depend on type; specific branches provide the asserted units, not this comment alone. |
| FF_FILL_ZERO | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line 670 explicitly fills padding with zero; surrounding lines compute its extent. |
| FF_AC3_TYPE | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line 117 explicitly ORs AC-3 with bitstream_mode shifted8, supplying consumer bsmod behavior instead of professional reserved000. |
| FF_AC3_BSMOD | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line 115 extracts byte5 low3, matching the tested bsmod values. |
| FF_AC3_PERIOD | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | PARTIAL | spdifenc line 118 uses AC3_FRAME_SIZE<<2 but the macro definition is absent; equating it with codec duration1536 is a disclosed inference, not a verified expansion. |
| FF_PERIOD_BYTES | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line 64 explicitly defines pkt_offset in bytes; conversion to two sixteen-bit words per interface frame follows the contract. |
| FF_LEN_BITS | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | PARTIAL | spdifenc line 633 supports even AC-3/DTS encoded bit counts; it rounds odd packets to an even size and does not itself prove odd parser extraction of supplied Pd40. |
| FF_EAC3_TYPE (unused) | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line145 sets only the E-AC-3 enum; unused corroboration. |
| FF_EAC3_ENUM (unused) | ffmpeg-spdif-n7.1/spdif §file p.1 / secondary | SUPPORTS | spdif.h explicitly gives E-AC-3=0x15; unused corroboration. |
| FF_EAC3_PERIOD | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line146 gives24576 bytes, hence6144 interface frames; consumer timing is honestly secondary. |
| FF_EAC3_LEN | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc lines138–149 accumulate bytes then put hd_buf_filled in Pd, supporting byte units and concatenated length. |
| FF_EAC3_GROUP | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc repeat array and frame counter give6/3/2/1 frames for the tested constant-numblkscod independent stream; no multi-substream rule is inferred. |
| FF_EAC3_GROUP_IDX | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line131 indexes repeat by byte4 bits5–4 in the tested full-rate branch. |
| FF_DTS1 | ffmpeg-spdif-n7.1/spdif §file p.1 / secondary | SUPPORTS | spdif.h explicitly links512 samples, typeI and code0B; secondary sample-to-code mapping. |
| FF_DTS2 | ffmpeg-spdif-n7.1/spdif §file p.1 / secondary | SUPPORTS | spdif.h explicitly links1024 samples, typeII and code0C; secondary sample-to-code mapping. |
| FF_DTS3 | ffmpeg-spdif-n7.1/spdif §file p.1 / secondary | SUPPORTS | spdif.h explicitly links2048 samples, typeIII and code0D; this is the decisive datatype-mutation oracle. |
| FF_DTS_PERIOD | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc lines266,293,315 make blocks=NBLKS+1 and period=blocks*128 bytes, matching sample count times four. |
| FF_DTS_BADSYNC | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | The bad-sync switch default returns invalid data on the cited source page; the test uses an unsupported all-zero sync. |
| FF_DTS_UNSUPPORTED | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | The switch permits only512/1024/2048 samples and rejects others, matching both tested unsupported durations. |
| FF_TOO_BIG | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | Core-size and padding checks on the same source page reject payloads exceeding a period; the test is not an exact-fit preamble-free case. |
| FF_ODD | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc lines666–668 explicitly emit a lone final byte shifted8; this supports the secondary odd-byte alignment assertion, not Pd rounding. |
| E_SYNCWORD | etsi-ts-102366 §Annex-J p.240 / codec-spec | SUPPORTS | Annex J p.240 explicitly requires0B77 for the constrained elementary streams used as fixtures; note correctly denies general IEC transport authority. |
| FF_EAC3_CONCAT | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc memcpy and subsequent count update concatenate successive packets unchanged before emitting their buffer. |
| FF_PAYLOAD | ffmpeg-spdif-n7.1/spdifenc §file p.1 / secondary | SUPPORTS | spdifenc line631 defaults output to packet bytes; the AC-3 header branch does not replace it, supporting unchanged complete payload. |
| A52_SIZE_TABLE52 | atsc-a52-2018 §5.4 p.52 / codec-spec | SUPPORTS | All31 quoted rows match Table5.18 on p.52, including odd/even44.1kHz sizes; helpers transcribe their columns correctly. |
| A52_SIZE_TABLE53 | atsc-a52-2018 §5.4 p.53 / codec-spec | SUPPORTS | All seven continuation rows match p.53; together with p.52 they cover all38 codes at all three rates. |
| A52_DURATION | atsc-a52-2018 §8.2.1.2 p.110 / codec-spec | SUPPORTS | §8.2.1.2 explicitly gives1536 audio samples per AC-3 syncframe; it supplies codec duration, not an independent consumer-spacing rule. |

## Findings and adjudications

1. **No meter/base failing case.** Both have276 passes and zero failures. There is therefore no failed reference/base assertion to assign to either test or implementation. All automated failures on the stub and variants are retained exactly as observed.

2. **Consumer AC-3 period remains incompletely evidenced.** FF_AC3_PERIOD and meter C42 quote `AC3_FRAME_SIZE << 2`, but the supplied files do not define AC3_FRAME_SIZE. A52_DURATION establishes codec1536 samples, and ST340 §4.6 establishes professional1536 spacing. Those facts make the intended mapping plausible, but do not verify the missing macro expansion or normative consumer spacing. This is a stated inference, already disclosed by both roles, rather than a new proven consumer rule. Timing tests and meter1536 remain useful at the declared inferred/secondary level. Obtain the included FFmpeg definition and normative IEC61937-3 spacing text for direct verification; under R3, do not describe this as established consumer conformance.

3. **Quote completeness needs improvement.** ST337_UNUSED_ZERO omits the terminal zero, ST338_EAC3_IEC omits row21 and the sub-data-type qualification, and ST338_DTS1 omits the row11 number. Their full cited pages support the relevant component, so these are PARTIAL rather than DOES-NOT-SUPPORT. No other role files were edited. Replace these snippets with full relevant row cells/text in a subsequent round.

4. **R2 separation is materially respected.** AC-3 bsmod tests use FFmpeg consumer behavior, not professional reserved000. Consumer E-AC-3 is21 and6144 frames with byte-count Pd; professional16/1536/bits are expressly documentary/corroborative. SMPTE payload/group/period citations remain PARTIAL as consumer evidence even when attached to correct assertions. The tests mark dependent consumer unit/timing/grouping assertions secondary. Preview table titles are used only for printed type-code facts. Shared preamble/field-position/serial-bit structure is identified as a sibling inference under §8.2–8.3, not primary consumer authority. FFmpeg seven-bit type information is not silently claimed to define an unrestricted five-bit consumer type.

5. **Odd DTS success does not settle Pd.** The two1025-byte encoder cases now pass both baselines and explicitly check final-byte MSB alignment, remaining zero fill, and period length. Neither asserts the encoder Pd. FFmpeg generic untrimmed odd packet Pd rounds up to an even byte count; its core-truncation branch instead uses exact core bytes. The odd parser case supplies40 bits by hand and checks structural extraction; it does not resolve which encoder length is normative. FF_LEN_BITS alone is PARTIAL for that odd parser assertion; sibling bit-unit structure and the declared parser contract complete the limited inference.

6. **Provenance is unverified.** Two supplied implementations agree on all tested cases and have different code organization. That does not prove their independent authorship or independent derivation from standards. No outside provenance or hidden suite was inspected.

## Meter citation and constant audit

All74 structured C01–C74 comments were opened and checked for verbatim quote, page, section and tier. The final check using the supplied citecheck checker reports zero errors in [meter-citations.json](meter-citations.json). The three additional meter-only pages (A52 p.39/p.161 and TS102366 p.126) were manually read and are saved in [meter-extra-pages.txt](meter-extra-pages.txt). An initial ad hoc equality comparison reported26 tier mismatches because the index spells FFmpeg’s tier secondary-implementation while R1 requires secondary. Those diagnostic results are preserved in [meter-citations-initial.json](meter-citations-initial.json). This was a checker comparison bug, corrected using the supplied checker’s explicit alias rule; no citation or tier was rewritten to hide a genuine failure.

| Constants/behavior | Meter support | Judgment |
|---|---|---|
| DoP05/FA,24-bit layout,16 DSD bits, channel identity, bit order | C01–C05,C72,C73; DoP pp.2–3 | Supported primary values; first-marker default is the contract, and short-run acquisition is explicitly an open choice. |
| F872/4E1F, four-word/eight-byte preamble | C06–C11,C14 | Supported by spdif.h plus shared-preamble sibling inference. C08 is correctly attributed to spdif.h. |
| Type1/21 and DTS512/1024/2048→11/12/13 | C32–C39 | IEC informative allocation and secondary enum support; sample-to-type link remains secondary. |
| Pc field shifts, mode0, stream0, error0; type31 extension | C15–C19,C49,C69–C71 | Shared structure/scope and secondary corroboration; professional reserved-dependent values are explicitly not applied. |
| AC-3 period1536 | C40,C42 | Partial only: literal professional/codec duration exists, consumer macro expansion does not. This is the principal unresolved numeric provenance link. |
| E-AC-3 period6144, Pd bytes, dependent0 | C43–C45,C74 | Secondary values directly present/derived from24576 bytes; professional period correctly excluded. |
| Payload high-byte ordering, odd-byte high alignment, zero final bits/fill | C12–C14,C25–C27,C31 | Supported shared structure/secondary behavior; no normative consumer odd-DTS acceptance claim follows. |
| Pd16-bit range and even AC-3/DTS bit counts | C20,C21,C50,C51 | Width supported structurally; type-specific units secondary. Unknown-type bits policy is unsupported by corpus but openly O16/out of scope. |
| AC-3 header positions, sync0B77, size tables, fscod3 invalid, bsid<=8 | C46,C52–C57 | C55/C56 cover both table pages and every literal size; no invented size constant found. C57 is a baseline-decoder restriction with an Annex E exception, acknowledged in its note. |
| E-AC-3 header, size words, numblks1/2/3/6, stream-type3 reserved, bsid11..16 | C58–C62,C68 | Codec support present. Numeric0B77 in _eac3_info lacks its own adjacent E-AC-3 numeric citation; it is available in corpus Annex J p.240 (tester E_SYNCWORD), so this is traceability weakness, not a value absent from corpus. |
| Reduced-rate six blocks/fscod2=3 reserved | C63,C64; A52 p.161 | Supported ATSC profile; ETSI p.127 instead reserves fscod3. Profile difference is expressly G9, not universal codec agreement. |
| Six-block grouping, independent0 burst start, following dependents | C48,C65–C68 | Partial consumer applicability; C67 is CMAF storage context only. Runtime counts only independent0, so it does not validate six blocks of every other substream as C65 professional wording requires. G8 discloses the consumer gap. |
| DTS sync/layout, NBLKS range5..127,32*(NBLKS+1), FSIZE95..16383,+1 bytes | C22–C24 | Explicit codec support, correct pages25/26. |
| DTS period=samples, trim excess, fit period*4-8, exact size*8 odd Pd | C28–C31,C50 | Secondary period/truncation/capacity derivations; odd untrimmed Pd is disclosed G11/O9 policy and differs from FFmpeg default. |
| Header guards8/6/10, empty handling, strict size checks, unknown parser units | O1–O3,O10–O16 | These are policies, not corpus-proven constants; comments now say so. No evidence upgrades are justified by the fact tests pass. |

No literal core marker/type/size/period value was found to be wholly invented with no occurrence or derivation anywhere in the corpus. That narrower conclusion does not verify the unresolved consumer AC-3 period linkage, arbitrary validation thresholds, unknown-type units, consumer multi-substream grouping, or odd encoder Pd. These remain unsupported as universal consumer requirements.

## Gaps and open choices the round could not test

- **Absent normative consumer text:** IEC61937-1/-2/-3/-5 full clauses are missing. Consumer payload coding, dependent bits, length units, stuffing and repetition details remain inferred or secondary. The preview titles and professional Same data column do not replace those clauses.
- **Untested but corpus-supported checks:** reserved AC-3 fscod/frmsizecod, additional bsmod cases, DTS range limits/short-payload/trailing-byte cases, variable E-AC-3 frame sizes and mixed block-code sequences are not comprehensively exercised. Codec header facts can support more fixtures; exact refusal/recovery policies still require the interface or explicit choices. All114 AC-3 size cases now cover the full table, so missing size-row coverage is no longer a finding.
- **E-AC-3 substreams and synchronization:** no dependent/additional independent substream or convsync test. Codec ordering is available in TS102366 p.126 and professional grouping/convsync in ST340 p.10, but consumer applicability is unverified. Incomplete eac3_group output, empty bursts, rate changes and ATSC/ETSI reduced-rate profile choices are not settled by this suite.
- **Parser boundaries and policy:** mode refusal, unsupported/out-of-scope types, odd-index sync, isolated bad-Pb candidates, negative/oversize/bool input words, non-byte-aligned Pd, nonzero unused low bytes and nonzero stuffing remain untested. The stub requires refusal of inconsistent preamble/length but does not specify every recovery decision. Tests now cover recognized truncated preambles and embedded sync-like payload data; these do not establish complete parser validation.
- **Empty inputs and representation limits:** empty channel lists, zero-length channels and dop_unpack([]) remain open choices; meter returns[] for zero-length packed channels whereas base raises, a disclosed policy difference invisible to this suite. No finite samples test all DoP channel counts/lengths or arbitrary data.
- **Odd DTS encoder Pd and consumer AC-3 macro linkage:** obtain missing definitions/consumer clauses before asserting either exact-vs-rounded odd lengths or a directly verified consumer1536 period. The successful odd-byte encoder tests cover alignment/fill/length only.
- **Actual media and transport:** fixtures synthesize headers and payload bytes; CRCs, full compressed-audio validity, playable decoding, receiver behavior, carrier timing and hardware acceptance are unverified. Channel status, other word widths, pause/timestamp/multistream transport, paired-channel DoP, DTS-HD and other codecs are outside the round scope.

## Command results and artifacts

[COMMANDS.md](COMMANDS.md) records every shell invocation and its result, including inspection commands and the initial diagnostic tier-comparison issue. [runs.json](runs.json), nine JUnit XML files and nine full pytest logs preserve fresh execution results; no historical report result was substituted for a current run. All audit-created files are inside this room. Existing tests, implementations, corpus and harness were not edited.

## Summary

276/276 cases pass both supplied working implementations; all276 fail the bare stub; all six variants are caught. All93 test citations resolve and all74 meter comments resolve. The round stands with partial citation support, disclosed source/provenance gaps and additional untested behavior; it does not establish full normative consumer IEC61937 conformance.
