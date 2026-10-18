# Conformance suite for stub/vblind.py

Round 2: 276 cases, 77 test functions. Against the bare stub: **276 failed, 0 passed**
(exit 1, expected); no skips or xfails. Saved output: `tests/round2-stub-results.txt`.
Citation check: **93 citations resolve, 0 problems** (11 unused documentation keys).
Secondary selection: 170 cases; remaining selection: 106 cases. A test's listed citation
classes do not promote a consumer assertion whose decisive support is secondary.

Commands (run from this room):

```text
./.venv/bin/python -I citecheck.py .
./.venv/bin/python -m pytest tests -q --tb=no --basetemp=.pytest-tmp/run
./.venv/bin/python -m pytest tests --collect-only -q -m secondary
```

The stub run explicitly set VBLIND_IMPL to this room's stub/vblind.py. No implementation,
round-1 reference, or mutations were run or inspected. Round-1 implementation results are
historical auditor findings only, **unverified in this round**. The two audited odd-DTS
failures remain ordinary automated assertions; neither was deleted, skipped, or xfailed.
No claim of implementation conformance follows from the stub run.

## Round 2 changes

Every non-SUPPORTS citation finding is mapped below. Literal quotes resolve on their
single cited page; notes distinguish common structural inferences from consumer semantics.

| Audit finding / key | Change |
|---|---|
| DOES-NOT-SUPPORT: ST340_AC3_DTD_RESERVED | Removed the citation entry and its assertion attachment entirely. The bsmod-0 assertion now cites FF_AC3_TYPE, FF_AC3_BSMOD and FF_PC_BITS and is secondary. No professional reserved-bit or repetition-flag semantics are used to infer a consumer dependent field. |
| PARTIAL: DOP_MARKER_ALT | Note limits corpus support to values/alternation. Requested first phase, default 0x05 and unpack's inverse/returned phase are explicitly attributed to stub/vblind.py. Those remain interface checks alongside the primary DoP requirements, not a normative default DoP phase. |
| PARTIAL: ST337_T7_DTD, ST337_T7_STREAM | Added the R2 argument directly in each note: 8.2 shared preamble/extraction and 8.3 16-bit frame mode support the positions. They do not establish type-dependent contents under 8.4. Applied the same explanation to type/mode/error position keys. |
| PARTIAL: ST337_ERR0 | Quote now includes the consequence setting the bit to 0. Note states consumer carryover through 8.2-8.3 and distinguishes the error flag from the dependent-field differences in 8.4. |
| PARTIAL: ST337_LEN_BITS | Note now limits the clause to professional bits units. Consumer even-byte AC-3/DTS expectations cite FF_LEN_BITS and are secondary, including parser/roundtrip assertions that depend on that unit. Odd-DTS encoder Pd rounding is still a gap. The odd parser fixture merely interprets its supplied Pd=40, and is secondary; it does not require an encoder to emit 40. |
| PARTIAL: ST338_DTS1, ST338_DTS2, ST338_DTS3 | Notes explicitly separate informative IEC type allocations 11/12/13 from the 512/1024/2048 sample links, which rest on FF_DTS1/2/3. The type-by-length test stays secondary. |
| PARTIAL: ST340_AC3_PAYLOAD | Note labels professional one-frame coding as corroboration, with Same data a possible inference subject to 8.4. Whole-payload consumer tests now cite FF_PAYLOAD and are secondary. Codec syncword/size refusals retain codec plus interface support. |
| PARTIAL: ST340_AC3_PERIOD, ST340_AC3_PAD | Notes no longer equate Same data with identical consumer spacing. Consumer length/offset tests are secondary and cite FF_AC3_PERIOD, FF_PERIOD_BYTES and A52_DURATION as appropriate. |
| PARTIAL: ST340_EAC3_PAYLOAD | Explicit professional-only corroboration note. Added FF_EAC3_CONCAT with the actual memcpy for consumer concatenation; the grouped-payload and roundtrip assertions are secondary. The E-AC-3 cases of the shared payload test have individual secondary marks. |
| PARTIAL: ST340_EAC3_6BLK | Note restricts consumer evidence to FFmpeg's simple single-independent-substream model. Grouping/partial/more-than-six assertions now cite FF_EAC3_GROUP and FF_EAC3_GROUP_IDX as appropriate and are secondary. No convsync validation is claimed. |
| PARTIAL: IEC3_T5 | Unused note now establishes size/rate dependence only. It infers neither a numeric period nor a difference from 1536 from a table title. |
| PARTIAL: A52_SYNC, E_SYNCINFO | A52_SYNC note is AC-3-only; E_SYNCINFO establishes E-AC-3 width/layout only. Added E_SYNCWORD from TS102366 Annex J p.240, explicitly quoting 0x0B77 for the constrained AC-3/Enhanced AC-3 elementary streams. All E-AC-3 numeric syncword assertions use E_SYNCWORD instead of A52_SYNC. |
| PARTIAL: FF_PC_BITS | Note explicitly says FFmpeg describes bits 0-6. Five-bit extraction is limited to the scoped cases with bits 5-6 zero, supported separately by ST337_CONSUMER_16 / IEC3_T4_56. No universal five-bit consumer type is claimed. |
| PARTIAL: FF_AC3_PERIOD | Note discloses the missing AC3_FRAME_SIZE definition. Added A52_DURATION, quoting the actual 1536 samples per channel clause (8.2.1.2 p.110). Linking the macro to codec frame duration is a stated secondary inference, not a numeric definition in the supplied FFmpeg source. |
| Fixture precision: A52_SYNCINFO, E_NUMBLKS | Replaced the syntax-table title / single last row with actual syncword/crc1/fscod/frmsizecod width cells and all four 00/01/10/11 block-count rows. |
| Odd-DTS adjudications and overstated test name | Retained both 1025-byte encoder tests, marked both secondary. Added len(w)==1024 to the fill-and-period test, citing FF_DTS_PERIOD, FF_PERIOD_BYTES and DTS_NBLKS before testing fill. FF_ODD now quotes the actual shifted-byte write and FF_FILL_ZERO quotes ffio_fill. The fill test cannot pass on a short output. No assertion of encoder Pd rounding was added. |
| Per-assertion tier audit | Checked every test. In addition to named cases, consumer AC-3 timing/bsmod-0/Pd, E-AC-3 grouping/payload and parser/roundtrip unit-dependent expectations are secondary. Existing E-AC-3 byte-unit and period marks remain. Codec/header or preview type-code citations do not promote these compound assertions. The full resulting marker inventory is below. |
| Missing AC-3 size coverage | Added all 38 frmsizecod rows at all three sample rates: 114 cases. A52_SIZE_TABLE52/53 quote every literal row on its own page; A52_FSCOD now quotes all rate-code cells. Builders carry the transcribed table; each case checks Pd against the selected size and every payload byte through the final word. Consumer carriage/unit portions are secondary. |
| Other supported parser coverage | Added two truncated-preamble refusal cases (Pa/Pb and Pa/Pb/Pc), using ST337_FRAME_PRE plus the stub's explicit inconsistent-preamble refusal contract. Added an embedded, preamble-shaped payload sequence and checks for exactly one burst with the complete payload, citing structural extent rules plus secondary FF_LEN_BITS. |
| Blocking round-1 result / six variants | No implementation is present to repair or re-adjudicate. Historical base159/159, meter157/159 and six mutation kills are unverified here; no exhaustive mutation or all-reference-conformance claim is made. The odd-DTS cases remain runnable failures. |
| All remaining coverage / provenance gaps | Enumerated under Gaps and Open choices below; nothing was invented to settle absent consumer requirements or parser recovery policy. No reference implementation or provenance was inferred from the suite itself. |

## Coverage and tier interpretation

DoP packing/unpacking covers both initial markers, marker position/alternation/channel equality,
bit and byte ordering, channel isolation, frame counts and malformed marker/word/length refusals.
DoP values come from the primary dop-1.1; requested/default phase and inverse representation
come from the interface contract.

Common burst preamble, field positions, serial MSB-first placement, unused-bit zeroing and
idle detection use the stated sibling structural inference under ST337 8.2-8.3. Codec header
and size facts use the codec specs. Consumer type allocations use the informative IEC column
or preview titles only for the facts those texts actually show. Professional-only field contents,
spacing and grouping cannot promote secondary consumer assertions.

Consumer cases cover AC-3 at 48/44.1/32 kHz, all frame-size rows and selected bsmod values;
simple E-AC-3 groups for all four block codes; DTS 512/1024/2048 samples and odd-sized payloads;
plus hand-built parser inputs and formatter/parser roundtrips. These are synthetic header and
byte-carriage fixtures, not playable compressed audio or CRC-valid decoder fixtures.

The following functions carry @pytest.mark.secondary (each case unless noted separately):

- `test_iec61937.py::test_ac3_pd_is_payload_length_in_bits`
- `test_iec61937.py::test_ac3_burst_is_1536_frames_long`
- `test_iec61937.py::test_ac3_payload_is_one_whole_syncframe_48k`
- `test_iec61937.py::test_ac3_data_type_dependent_zero_for_bsmod_0`
- `test_iec61937.py::test_ac3_bsmod_in_data_type_dependent_bits_0_2`
- `test_iec61937.py::test_eac3_pd_is_payload_length_in_bytes`
- `test_iec61937.py::test_eac3_burst_is_6144_frames_long`
- `test_iec61937.py::test_eac3_payload_is_the_frames_in_order`
- `test_iec61937.py::test_eac3_rejects_partial_group`
- `test_iec61937.py::test_eac3_rejects_more_than_six_blocks`
- `test_iec61937.py::test_eac3_group_is_six_blocks_per_burst`
- `test_iec61937.py::test_eac3_group_covers_every_frame_once_in_order`
- `test_iec61937.py::test_eac3_group_of_six_block_frames_feeds_eac3_burst`
- `test_iec61937.py::test_dts_data_type_by_frame_length`
- `test_iec61937.py::test_dts_pd_is_payload_length_in_bits`
- `test_iec61937.py::test_dts_burst_length_is_two_words_per_sample`
- `test_iec61937.py::test_dts_odd_length_frame_last_byte_is_msb_aligned`
- `test_iec61937.py::test_dts_odd_length_frame_fill_is_zero_and_period_kept`
- `test_iec61937.py::test_dts_rejects_frame_lengths_other_than_512_1024_2048`
- `test_iec61937.py::test_dts_rejects_frame_too_large_for_its_period`
- `test_iec61937.py::test_ac3_all_frame_size_rows_preserve_payload_and_bit_length`
- `test_parse.py::test_parse_payload_in_bits_for_ac3_type`
- `test_parse.py::test_parse_payload_odd_byte_count_in_bits`
- `test_parse.py::test_parse_payload_excludes_fill`
- `test_parse.py::test_parse_payload_in_bytes_for_eac3_type`
- `test_parse.py::test_parse_two_back_to_back_bursts`
- `test_parse.py::test_parse_rejects_payload_running_past_the_end`
- `test_parse.py::test_roundtrip_ac3_single_burst_fields`
- `test_parse.py::test_roundtrip_ac3_payload`
- `test_parse.py::test_roundtrip_ac3_three_bursts_offsets`
- `test_parse.py::test_roundtrip_eac3_payload`
- `test_parse.py::test_roundtrip_dts_payload_and_offsets`
- `test_parse.py::test_parse_sync_like_words_inside_payload_are_not_a_second_burst`

Additionally, the three E-AC-3 cases of `test_payload_follows_pd_big_endian` carry parameter
marks because expected concatenation rests on secondary consumer evidence. Other cases of
that shared function check common payload word placement. The index-coverage grouping test
is conservatively secondary because it calls grouping on the simple FFmpeg-supported model,
even though covering every input index in order is itself an interface requirement.

## Gaps

- Full normative IEC61937-1/-2/-3/-5 consumer clauses are absent. Primary consumer payload mapping,
  dependent-field content, stuffing, per-type length units and repetition rates are **unverified**.
  Obtain the actual clauses/tables to replace structural inference or secondary agreement.
- Odd DTS encoder Pd rounding is **unverified**: exact size*8 versus word-aligned size*8 is not
  settled by the available consumer text. FF_LEN_BITS rounds by default, with a separate truncation
  path; neither odd encoder test asserts Pd. A parser accepting a supplied bit length proves no
  normative choice of encoder rounding. Codec FSIZE permits odd sizes; that alone does not prove
  normative consumer acceptance. Both odd encoder checks remain secondary.
- E-AC-3 multiple independent/dependent substreams, codec ordering across substreams, convsync
  alignment/validation, sample-rate transitions and incomplete final eac3_group behavior are untested.
  Professional constraints do not settle consumer carriage. Need IEC61937-3 and broader fixtures.
- Reduced-rate E-AC-3 ATSC/ETSI edition/profile conflict, non-48k consumer E-AC-3/DTS timing,
  exact-fit no-preamble DTS and DTS other byte/14-bit forms remain untested or outside scope.
- AC-3 reserved fscod / out-of-range frmsizecod and CRC validation are untested formatter policy.
  Fixtures have synthetic payloads and invalid CRCs; no end-to-end decoder validity is claimed.
- Parser mode refusal, non-byte-aligned Pd, out-of-range input words, nonzero unused low-byte
  rejection and even-start enforcement remain untested. Scope defines 16-bit frame mode and input
  representation, but does not settle handling of every out-of-domain input or recovery rule;
  ST337 zeroing and positions alone do not prescribe a specific rejection policy. Need consumer
  receiver clauses or an explicit interface decision. Truncated preambles and embedded sync now
  have the limited, supported coverage described above.
- No actual transport/receiver runs, valid playable compressed-audio fixtures or hardware acceptance
  checks were performed. Channel status, acquisition latency and carrier/sample-rate relations are
  **unverified** or out of the exposed interface/scope.
- Six historical mutations do not establish exhaustive fault coverage. Builder independence and
  provenance remain **unverified** beyond the supplied declarations; no outside files were read.

## Open choices

No new policy was selected for cases without adequate corpus/interface support:

- Empty/zero-channel DoP and returned first_marker for empty input.
- parse_bursts([]); odd-index sync recovery; unsupported modes/types and per-type unknown units;
  non-byte-aligned lengths; range validation and rejection versus recovery for malformed input.
  A recognized, truncated Pa/Pb[/Pc] preamble now specifically exercises the contract's existing
  inconsistent-preamble refusal, rather than imposing a new scanning/recovery policy.
- Incomplete final eac3_group groups and eac3_burst([]).
- Trailing bytes beyond compressed-frame header sizes.
- Odd DTS encoder Pd exact versus rounded lengths.

Existing explicit interface choices retained: DoP rejects unrepresentable odd byte counts or
unequal channel lengths; accepts only the base method's marker values; formatters start their
returned burst at word 0; complete-group E-AC-3 calls reject fewer/more than six blocks under
the simple secondary grouping model. These refusals are not promoted to primary consumer law.
