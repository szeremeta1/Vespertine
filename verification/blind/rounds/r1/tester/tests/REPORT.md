# Conformance suite for `stub/vblind.py`: report

Run: `VBLIND_IMPL=<impl.py> ./.venv/bin/python -m pytest tests -q` (159 test cases, 74 test functions).
Against the bare stub: 159 failed, 0 passed. `citecheck.py`: 88 citations resolve, 0 problems.
Self-check: `tools/refimpl.py` (a throwaway implementation written from the same reading as the tests, not a
deliverable) passes all 159, so the input builders and expectations are at least consistent with one reading.
Secondary-marked tests can be deselected with `-m "not secondary"`.

Tiers: P = primary (dop-1.1), PP = primary-preview (IEC 61937 previews), SIB = sibling-standard (SMPTE 337/338/340),
CODEC = codec-spec (A/52, TS 102 366, TS 102 114), SEC = secondary (FFmpeg). The marker `secondary` is set when the
decisive fact rests on FFmpeg only (see notes).

## Requirement -> tests -> citation keys -> tier

### DoP (`test_dop.py`)

| Requirement | Test(s) | Keys | Tier |
|---|---|---|---|
| Markers 0x05/0xFA alternate every frame, from first_marker | `test_pack_markers_alternate_from_05`, `..._from_fa`, `test_pack_default_first_marker` | DOP_MARKER_ALT | P |
| Same marker on every channel of a frame | `test_pack_same_marker_on_every_channel` | DOP_MARKER_SAME | P |
| Marker = 8 MSBs of a 24-bit word | `test_pack_marker_is_the_8_msbs_of_a_24_bit_word` | DOP_MARKER_MSB, DOP_24BIT | P |
| 16 DSD bits in the low 16 bits, oldest bit first (t0 = bit 15, then in time order, byte 0 before byte 1) | `test_pack_oldest_bit_is_bit15`, `..._bit_order_within_first_byte`, `..._second_byte_in_low_half`, `..._sixteen_bits_per_frame_in_time_order` | DOP_BITS_OLDEST, DOP_DIAGRAM | P |
| One DSD channel per PCM channel; 2 bytes per frame | `test_pack_channel_k_goes_to_pcm_channel_k`, `test_pack_frame_count_and_width` | DOP_PER_CHANNEL, DOP_BITS_OLDEST | P |
| pack refuses markers of the base method's complement / other method | `test_pack_rejects_marker_not_of_base_method` (0x06, 0xF9, 0x00, 0xFF, 0x04) | DOP_MARKER_ALT, DOP_OTHER_MARKER, DOP_ALT_MARKERS | P |
| pack refuses data it cannot represent (odd byte count, unequal channels) | `test_pack_rejects_odd_byte_count`, `test_pack_rejects_unequal_channel_lengths` | DOP_BITS_OLDEST, DOP_MARKER_SAME, DOP_PER_CHANNEL | P |
| unpack inverts pack, returns first marker | `test_unpack_inverts_pack` (both markers), `test_unpack_reads_hand_built_stream` | DOP_MARKER_ALT, DOP_BITS_OLDEST, DOP_DIAGRAM | P |
| unpack refuses: non-alternating markers, marker differing between channels, a channel without marker, the other method's markers, plain PCM, words wider than 24 bits | `test_unpack_rejects_*` (6 tests) | DOP_MARKER_ALT, DOP_MARKER_SAME, DOP_RX_MISSING, DOP_OTHER_MARKER, DOP_ALT_MARKERS, DOP_24BIT, DOP_MARKER_MSB | P |
| DSD rate -> PCM rate | not testable: the interface exposes no rate (skipped as instructed) | n/a | n/a |

### IEC 61937 bursts (`test_iec61937.py`), every kind (AC-3 48/44.1/32 kHz, E-AC-3 6x1, 1x6, 3x2 blocks, DTS 512/1024/2048)

| Requirement | Test(s) | Keys | Tier |
|---|---|---|---|
| Pa=0xF872, Pb=0x4E1F in frame 1 (Ch1, Ch2) at word 0,1 | `test_pa_pb_are_the_sync_words_in_frame_one` | ST337_PA, ST337_PB, ST337_EXT_SYNC, ST337_FRAME_PRE | SIB |
| Pc/Pd in frame 2, payload from word 4, big-endian bytes in 16-bit words, first byte in the high byte | `test_payload_follows_pd_big_endian` | ST337_FRAME_PRE, ST337_PRE_FOLLOW, ST337_FIRST_BIT | SIB |
| Pc bits 5-6 (data_mode) = 0 | `test_pc_data_mode_bits_are_zero` | ST337_T7_MODE, ST337_T8_16, ST337_CONSUMER_16 | SIB |
| Pc error flag (bit 7) = 0 | `test_pc_error_flag_clear` | ST337_T7_ERR, ST337_ERR0 | SIB |
| Pc stream number (bits 13-15) = 0 | `test_pc_stream_number_is_zero` | ST337_T7_STREAM, ST337_STREAM0 | SIB |
| Fill after payload is zero | `test_fill_after_payload_is_zero` | ST337_UNUSED_ZERO, FF_FILL_ZERO | SIB |
| Unused half of the last payload frame is zero (odd word count: 69-word AC-3 frame) | `test_unused_second_subframe_of_last_payload_frame_is_zero` | ST337_LAST_UNUSED, A52_SIZE_44_0 | SIB |
| AC-3 data_type = 1 | `test_ac3_data_type_is_1` | IEC3_T3, ST340_AC3_TYPE, ST338_AC3, ST337_T7_TYPE | PP |
| AC-3 Pd = payload bits | `test_ac3_pd_is_payload_length_in_bits` | ST337_LEN_BITS, ST337_LEN_NOPRE, ST338_AC3, FF_LEN_BITS | SIB |
| AC-3 burst = 1536 frames = 3072 words (all three sample rates) | `test_ac3_burst_is_1536_frames_long` | ST340_AC3_PERIOD, ST340_AC3_PAD, FF_AC3_PERIOD | SIB |
| AC-3 payload = one whole syncframe, begins 0x0B77 | `test_ac3_payload_starts_with_the_syncword`, `test_ac3_payload_is_one_whole_syncframe_48k` | A52_SYNC, ST340_AC3_PAYLOAD, A52_SIZE_48_128, ST337_FIRST_BIT | SIB |
| AC-3 data_type_dependent = 0 for bsmod 0 | `test_ac3_data_type_dependent_zero_for_bsmod_0` | ST340_AC3_DTD_RESERVED, FF_AC3_TYPE | SIB |
| AC-3 bsmod copied to Pc bits 8-10 | `test_ac3_bsmod_in_data_type_dependent_bits_0_2` (secondary) | FF_AC3_TYPE, FF_AC3_BSMOD, FF_PC_BITS | SEC |
| AC-3 refusals: wrong syncword, truncated syncframe | `test_ac3_rejects_wrong_syncword`, `test_ac3_rejects_truncated_syncframe` | A52_SYNC, ST340_AC3_PAYLOAD, A52_SIZE_48_128, A52_SYNCINFO | SIB/CODEC |
| E-AC-3 data_type = 21, Pc bits 5-6 = 0 (not the professional 16) | `test_eac3_data_type_is_21_with_bits_5_6_zero` | IEC3_T4, IEC3_T4_56, ST338_EAC3_IEC | PP |
| E-AC-3 Pd = payload BYTES | `test_eac3_pd_is_payload_length_in_bytes` (secondary) | FF_EAC3_LEN, FF_PD_UNIT | SEC |
| E-AC-3 burst = 6144 frames = 12288 words | `test_eac3_burst_is_6144_frames_long` (secondary) | FF_EAC3_PERIOD, FF_PERIOD_BYTES | SEC |
| E-AC-3 payload = grouped syncframes in order, begins 0x0B77 | `test_eac3_payload_is_the_frames_in_order`, `test_eac3_payload_starts_with_the_syncword` | ST340_EAC3_PAYLOAD, A52_SYNC, E_SYNCINFO, ST337_FIRST_BIT | SIB |
| E-AC-3 burst refuses partial / more-than-six-block groups, wrong sync | `test_eac3_rejects_partial_group`, `..._more_than_six_blocks`, `..._wrong_syncword` | ST340_EAC3_6BLK, E_NUMBLKS, A52_SYNC, E_SYNCINFO | SIB/CODEC |
| E-AC-3 grouping: 6/3/2/1 frames for numblkscod 0/1/2/3; indices cover each frame once, in order; groups acceptable to `eac3_burst` | `test_eac3_group_is_six_blocks_per_burst` (x4), `test_eac3_group_covers_every_frame_once_in_order`, `test_eac3_group_of_six_block_frames_feeds_eac3_burst` | ST340_EAC3_6BLK, E_NUMBLKS, ST340_EAC3_PAYLOAD, IEC3_T4 | SIB/CODEC |
| DTS data_type 11/12/13 for 512/1024/2048-sample frames | `test_dts_data_type_by_frame_length` (secondary) | FF_DTS1/2/3, ST338_DTS1/2/3, DTS_NBLKS | SEC (see note 1) |
| DTS Pd = payload bits | `test_dts_pd_is_payload_length_in_bits` | ST337_LEN_BITS, ST337_LEN_NOPRE, FF_LEN_BITS, DTS_FSIZE | SIB |
| DTS burst = 2 words per sample of the frame (1024/2048/4096) | `test_dts_burst_length_is_two_words_per_sample` (secondary) | FF_DTS_PERIOD, FF_PERIOD_BYTES, DTS_NBLKS | SEC (note 1) |
| DTS payload = frame, begins 0x7FFE 0x8001 | `test_dts_payload_starts_with_the_sync_word` | DTS_SYNC, ST337_FIRST_BIT | SIB/CODEC |
| DTS odd-length frame: lone final byte in the high byte, zero after | `test_dts_odd_length_frame_last_byte_is_msb_aligned`, `..._fill_is_zero_and_period_kept` | FF_ODD, ST337_LAST_UNUSED, ST337_FIRST_BIT, ST337_UNUSED_ZERO, DTS_FSIZE | SIB |
| DTS refusals: no core sync, header cut short | `test_dts_rejects_missing_core_sync`, `..._header_cut_short` | DTS_SYNC, FF_DTS_BADSYNC, DTS_NBLKS, DTS_FSIZE | CODEC |
| DTS refusals: 256/4096-sample frames; frame too big for its period | `test_dts_rejects_frame_lengths_other_than_512_1024_2048`, `test_dts_rejects_frame_too_large_for_its_period` (secondary) | FF_DTS_UNSUPPORTED, FF_TOO_BIG, FF_DTS_PERIOD | SEC |

### parse_bursts (`test_parse.py`)

| Requirement | Test(s) | Keys | Tier |
|---|---|---|---|
| offset = index of Pa (leading zeros not part of the burst) | `test_parse_offset_is_index_of_pa_after_leading_zeros` | ST337_FRAME_PRE, ST337_FOUR_ZERO, ST337_EXT_SYNC | SIB |
| data_type bits 0-4, error_flag bit 7, dtd bits 8-12, stream bits 13-15 | `test_parse_pc_fields` (x4) | ST337_T7_*, FF_PC_BITS, FF_PC_STREAM | SIB |
| length_code is raw Pd | `test_parse_length_code_is_raw_pd` | ST337_FRAME_PRE | SIB |
| payload by Pd in bits (types 1, 11), odd byte counts, fill excluded | `test_parse_payload_in_bits_for_ac3_type`, `..._odd_byte_count_in_bits`, `..._excludes_fill` | ST337_LEN_BITS, ST337_LEN_NOPRE, ST337_LAST_UNUSED, ST338_AC3, ST338_DTS1 | SIB |
| payload by Pd in bytes for type 21 | `test_parse_payload_in_bytes_for_eac3_type` (secondary) | FF_EAC3_LEN, FF_PD_UNIT, IEC3_T4 | SEC |
| several bursts in order; all-zero stream has none | `test_parse_two_back_to_back_bursts`, `test_parse_all_zero_stream_has_no_burst` | ST337_FRAME_PRE, ST337_IDLE | SIB |
| burst running past the end of the stream is refused | `test_parse_rejects_payload_running_past_the_end` | ST337_LEN_BITS, ST337_PRE_FOLLOW | SIB |
| round trips (AC-3 fields, payload, offsets 0/3072/6144; E-AC-3 payload; DTS payloads and offsets) | `test_roundtrip_*` (5) | ST337_*, ST338_AC3, ST340_*, IEC3_T4, DTS_FSIZE | SIB/PP |

Notes
1. DTS: ST338's IEC column gives the codes (type I/II/III = 11/12/13) but not which frame length is which type; the
   link 512/1024/2048 samples <-> type I/II/III and the DTS repetition period appear only in FFmpeg (the
   period for AC-3 is in ST340; the DTS analogue is by FFmpeg alone). Both tests are therefore marked `secondary`
   although they also cite SIB/CODEC keys for the pieces those do settle.
2. `test_parse_payload_in_bytes_for_eac3_type` is marked `secondary` because the byte unit rests only on FFmpeg.
3. Where the professional text and FFmpeg disagree (E-AC-3 data_type 16 vs 21, Pd bits vs bytes, period 1536 vs 6144
   frames) the tests follow the consumer evidence (IEC preview table titles, ST338 IEC column, FFmpeg) and none expects
   the professional value. ST340_EAC3_TYPE_PRO and ST340_EAC3_PERIOD_PRO are cited in `citations.py` only to document this.

## Gaps (in scope, not settled by the public corpus, therefore NOT tested)

* **Consumer clauses of IEC 61937-1/-3/-5 are paywalled**: every consumer behaviour rests on the SMPTE sibling or FFmpeg.
  The IEC previews give only table/clause titles. Table 5 of IEC 61937-3 (max E-AC-3 payload per sampling frequency and IEC 60958 frame rate) is not readable, so the E-AC-3 repetition period for other sampling frequencies / interface rates is unknown; the test uses one case (FFmpeg: 12288 words).
* data_type_dependent for AC-3 bits 3-4 (consumer meaning), and the whole data_type_dependent field for E-AC-3 and DTS (IEC Tables 3-5 of parts 3 and 5, unavailable): not asserted (only AC-3 bits 0-2 via FFmpeg, and the bsmod-0 case, where professional and FFmpeg agree).
* Pd for odd-length payloads (exact bit count vs rounded up to a 16-bit word): ST337 says bits, FFmpeg rounds up; not asserted.
* How the repetition period behaves for E-AC-3 / DTS streams with sampling frequencies other than the one used; DTS sample rate (SFREQ) is never consulted by the tests.
* AC-3: reserved fscod (3), frmsizecod above 37, bad CRC (crc1/crc2): corpus gives validity rules for decoders, not for the formatter; the test frames carry a dummy crc1 and no valid CRC, so an implementation that checks CRCs would wrongly fail them (nothing in the corpus requires a formatter to check).
* AC-3 frames carrying trailing bytes beyond the syncframe, DTS frames longer than FSIZE+1 (FFmpeg drops the extra bytes), DTS 14-bit / little-endian forms: out of the interface contract or undecided.
* E-AC-3: dependent substreams / multiple substreams in one burst (ST340 5.3 "from all substreams"), partial final group at end of stream, the convsync rule for where a group may start (the test streams start groups on convsync=1 frames, which satisfy both readings), bsid <= 10 frames inside E-AC-3 (FFmpeg treats them as one-frame groups).
* Extended preamble (data_type 31, Pe/Pf), pause/null/time-stamp bursts, other data types in `parse_bursts` (payload unit for unknown types): out of scope or unknown.
* Minimum inter-burst padding ("at least two AES3 frames", ST340 Fig. 1) is implied by the fixed period but not tested separately.
* Channel status, sampling-rate relation of the PCM carrier, DoP PCM-rate relation: not exposed by the interface.

## Open choices (the corpus leaves a choice; tests assert neither option)

* `dop_pack` / `dop_unpack` with zero channels or zero-length channels; `dop_unpack([])` (empty list: return `([], x)` or refuse).
* Value of `first_marker` returned by `dop_unpack([])`.
* `parse_bursts([])`; a lone `0xF872 0x4E1F` pair at an odd word index (could be PCM); a truncated preamble at the very end of the list (only a payload running past the end is tested).
* `Burst.data_type` when Pc bits 5-6 are non-zero (bits 0-4 vs 0-6; the tests keep bits 5-6 zero).
* `parse_bursts` on a burst whose data_type is not 1, 11-13, 21 (payload unit unknown).
* `eac3_group` on a trailing incomplete group; `eac3_burst([])`.
* Whether `ac3_burst` / `dts_burst` accept inputs with trailing bytes beyond the frame's own size.
* Lengths of odd-size payloads in Pd (see Gaps).

## Choices the tests do commit to (flagged because they go beyond a literal quote)

* `dop_pack` refuses an odd byte count per channel and unequal channel lengths (the stub says "input this method cannot represent exactly"; padding would invent bits).
* `dop_pack` accepts only first_marker 0x05 / 0xFA.
* `ac3_burst` refuses a frame whose length is not the length implied by fscod/frmsizecod (here: a truncated 48 kHz frame) and a wrong syncword.
* `eac3_burst` refuses a group that does not add up to exactly six blocks.
* `dts_burst` accepts odd-byte-length frames (FSIZE+1 may be odd).
* A burst starts at word 0 of the lists returned by the three formatters (the stub: "one complete data burst ... followed by" the fill).

## Housekeeping disclosure

While gathering sources I ran one shell command that contained `cat > /tmp/x` (a slip), which created an empty file `/tmp/x`
outside the room; nothing was read from outside the room. `tools/find.py` (quote locator) and `tools/refimpl.py` (self-check
implementation) are in the room and are not part of the suite.
