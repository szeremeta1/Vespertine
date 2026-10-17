| Implementation | passed | failed | n/a | skipped |
|---|---|---|---|---|
| stub (null) | 0 | 159 | 0 | 0 |
| meter (reference) | 157 | 2 | 0 | 0 |
| saboteur base | 159 | 0 | 0 | 0 |
| sab_byte_order | 136 | 23 | 0 | 0 |
| sab_dop_bit_order | 153 | 6 | 0 | 0 |
| sab_length_off_by_one | 155 | 4 | 0 | 0 |
| sab_padding | 148 | 11 | 0 | 0 |
| sab_pc_datatype | 158 | 1 | 0 | 0 |
| sab_swapped_markers | 152 | 7 | 0 | 0 |
| Vespertine | 115 | 10 | 34 | 0 |
| Vespertine + reference parser | 142 | 10 | 7 | 0 |

| Saboteur | caught by |
|---|---|
| sab_byte_order | 23 tests: `test_payload_follows_pd_big_endian[ac3_48k]`, `test_payload_follows_pd_big_endian[ac3_44k]`, `test_payload_follows_pd_big_endian[ac3_32k]`, `test_payload_follows_pd_big_endian[eac3_6x1]`, `test_payload_follows_pd_big_endian[eac3_1x6]`, `test_payload_follows_pd_big_endian[eac3_2x3]`, `test_payload_follows_pd_big_endian[dts_512]`, `test_payload_follows_pd_big_endian[dts_1024]` ... |
| sab_dop_bit_order | 6 tests: `test_pack_oldest_bit_is_bit15`, `test_pack_bit_order_within_first_byte`, `test_pack_second_byte_in_low_half`, `test_pack_sixteen_bits_per_frame_in_time_order`, `test_pack_channel_k_goes_to_pcm_channel_k`, `test_unpack_reads_hand_built_stream` |
| sab_length_off_by_one | 4 tests: `test_eac3_pd_is_payload_length_in_bytes[eac3_6x1]`, `test_eac3_pd_is_payload_length_in_bytes[eac3_1x6]`, `test_eac3_pd_is_payload_length_in_bytes[eac3_2x3]`, `test_roundtrip_eac3_payload` |
| sab_padding | 11 tests: `test_fill_after_payload_is_zero[ac3_48k]`, `test_fill_after_payload_is_zero[ac3_44k]`, `test_fill_after_payload_is_zero[ac3_32k]`, `test_fill_after_payload_is_zero[eac3_6x1]`, `test_fill_after_payload_is_zero[eac3_1x6]`, `test_fill_after_payload_is_zero[eac3_2x3]`, `test_fill_after_payload_is_zero[dts_512]`, `test_fill_after_payload_is_zero[dts_1024]` ... |
| sab_pc_datatype | 1 tests: `test_dts_data_type_by_frame_length[dts_2048-13]` |
| sab_swapped_markers | 7 tests: `test_pack_markers_alternate_from_05`, `test_pack_markers_alternate_from_fa`, `test_pack_default_first_marker`, `test_pack_oldest_bit_is_bit15`, `test_pack_bit_order_within_first_byte`, `test_pack_second_byte_in_low_half`, `test_unpack_reads_hand_built_stream` |

Failures against Vespertine:

- `test_dop::test_pack_rejects_odd_byte_count`: Failed: DID NOT RAISE DoPError
- `test_iec61937::test_ac3_rejects_wrong_syncword`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_ac3_rejects_truncated_syncframe`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_eac3_rejects_partial_group`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_eac3_rejects_more_than_six_blocks`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_eac3_rejects_wrong_syncword`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_dts_rejects_missing_core_sync`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_dts_rejects_frame_lengths_other_than_512_1024_2048[7-600]`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_dts_rejects_frame_lengths_other_than_512_1024_2048[127-3000]`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_dts_rejects_frame_too_large_for_its_period`: Failed: DID NOT RAISE BurstError

Failures against Vespertine + reference parser:

- `test_dop::test_pack_rejects_odd_byte_count`: Failed: DID NOT RAISE DoPError
- `test_iec61937::test_ac3_rejects_wrong_syncword`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_ac3_rejects_truncated_syncframe`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_eac3_rejects_partial_group`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_eac3_rejects_more_than_six_blocks`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_eac3_rejects_wrong_syncword`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_dts_rejects_missing_core_sync`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_dts_rejects_frame_lengths_other_than_512_1024_2048[7-600]`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_dts_rejects_frame_lengths_other_than_512_1024_2048[127-3000]`: Failed: DID NOT RAISE BurstError
- `test_iec61937::test_dts_rejects_frame_too_large_for_its_period`: Failed: DID NOT RAISE BurstError
