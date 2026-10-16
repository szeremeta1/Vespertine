"""IEC 61937 data bursts, consumer interface, 16-bit frame mode, stream 0: ac3_burst / eac3_burst / dts_burst."""
import pytest

from helpers import (AC3_SIZE_ROWS, ac3_frame, eac3_frame, eac3_stream, dts_frame, words_of, bytes_of)

AC3 = {"ac3_48k": ac3_frame(0, 16), "ac3_44k": ac3_frame(1, 0), "ac3_32k": ac3_frame(2, 2)}
DTS = {"dts_512": (dts_frame(15, 1024), 512), "dts_1024": (dts_frame(31, 2000), 1024),
       "dts_2048": (dts_frame(63, 4000), 2048)}
EAC3_6x1 = eac3_stream(0, 1)          # six one-block frames  -> one burst
EAC3_1x6 = eac3_stream(3, 1, 300)     # one six-block frame   -> one burst
EAC3_2x3 = eac3_stream(1, 1, 250)     # three two-block frames

ALL = (["ac3_48k", "ac3_44k", "ac3_32k", "eac3_6x1", "eac3_1x6", "eac3_2x3", "dts_512", "dts_1024", "dts_2048"])


def build(impl, kind):
    """-> (words, payload bytes the burst must carry)"""
    if kind in AC3:
        return impl.ac3_burst(AC3[kind]), AC3[kind]
    if kind.startswith("eac3"):
        fr = {"eac3_6x1": EAC3_6x1, "eac3_1x6": EAC3_1x6, "eac3_2x3": EAC3_2x3}[kind]
        return impl.eac3_burst(fr), b"".join(fr)
    f, _ = DTS[kind]
    return impl.dts_burst(f), f


all_kinds = pytest.mark.parametrize("kind", ALL)


# ------------------------------------------------------------------------------ preamble, all kinds
@all_kinds
def test_pa_pb_are_the_sync_words_in_frame_one(impl, kind):
    w, _ = build(impl, kind)
    assert w[:2] == [0xF872, 0x4E1F], \
        "[ST337_PA,ST337_PB,ST337_EXT_SYNC,ST337_FRAME_PRE] Pa=0xF872 in the first frame's channel 1, Pb=0x4E1F in channel 2"


@all_kinds
def test_pc_data_mode_bits_are_zero(impl, kind):
    w, _ = build(impl, kind)
    assert (w[2] >> 5) & 3 == 0, \
        "[ST337_T7_MODE,ST337_T8_16,ST337_CONSUMER_16] Pc bits 5-6 (data_mode) are 0 for 16-bit mode"


@all_kinds
def test_pc_error_flag_clear(impl, kind):
    w, _ = build(impl, kind)
    assert (w[2] >> 7) & 1 == 0, \
        "[ST337_T7_ERR,ST337_ERR0] Pc bit 7 (error_flag) is 0 when nothing is known to be wrong"


@all_kinds
def test_pc_stream_number_is_zero(impl, kind):
    w, _ = build(impl, kind)
    assert (w[2] >> 13) & 7 == 0, \
        "[ST337_T7_STREAM,ST337_STREAM0] Pc bits 13-15 (data_stream_number) are 0 for the single stream"


@pytest.mark.parametrize("kind", [pytest.param(k, marks=pytest.mark.secondary) if k.startswith("eac3") else k for k in ALL])
def test_payload_follows_pd_big_endian(impl, kind):
    w, payload = build(impl, kind)
    n = (len(payload) + 1) // 2
    assert w[4:4 + n] == words_of(payload), \
        "[ST337_FRAME_PRE,ST337_PRE_FOLLOW,ST337_FIRST_BIT,FF_EAC3_CONCAT] payload words start at word 4 (frame 3 channel 1), " \
        "first byte in the high byte of each 16-bit word, in stream order"


@all_kinds
def test_fill_after_payload_is_zero(impl, kind):
    w, payload = build(impl, kind)
    n = (len(payload) + 1) // 2
    assert all(x == 0 for x in w[4 + n:]), \
        "[ST337_UNUSED_ZERO,FF_FILL_ZERO] every word between the end of the payload and the next burst is 0"


def test_unused_second_subframe_of_last_payload_frame_is_zero(impl):
    w = impl.ac3_burst(AC3["ac3_44k"])           # 69 payload words: the last frame only half used
    assert len(AC3["ac3_44k"]) // 2 == 69 and w[4 + 69] == 0, \
        "[ST337_LAST_UNUSED,A52_SIZE_44_0] the unused channel-2 word of the last payload frame is 0"


# ---------------------------------------------------------------------------------- AC-3
@pytest.mark.parametrize("kind", list(AC3))
def test_ac3_data_type_is_1(impl, kind):
    w = impl.ac3_burst(AC3[kind])
    assert w[2] & 0x1F == 1, \
        "[IEC3_T3,ST340_AC3_TYPE,ST338_AC3,ST337_T7_TYPE] Pc bits 0-4 (data_type) = 1 for AC-3"


@pytest.mark.parametrize("kind", list(AC3))
@pytest.mark.secondary
def test_ac3_pd_is_payload_length_in_bits(impl, kind):
    w = impl.ac3_burst(AC3[kind])
    assert w[3] == 8 * len(AC3[kind]), \
        "[ST337_LEN_BITS,ST337_LEN_NOPRE,ST338_AC3,FF_LEN_BITS] Pd = number of payload bits, preamble not counted"


@pytest.mark.parametrize("kind", list(AC3))
@pytest.mark.secondary
def test_ac3_burst_is_1536_frames_long(impl, kind):
    w = impl.ac3_burst(AC3[kind])
    assert len(w) == 2 * 1536, \
        "[ST340_AC3_PERIOD,ST340_AC3_PAD,FF_AC3_PERIOD,A52_DURATION,FF_PERIOD_BYTES] repetition period 1536 IEC 60958 frames = 3072 words"


@pytest.mark.parametrize("kind", list(AC3))
def test_ac3_payload_starts_with_the_syncword(impl, kind):
    w = impl.ac3_burst(AC3[kind])
    assert w[4] == 0x0B77, \
        "[A52_SYNC,ST340_AC3_PAYLOAD,ST337_FIRST_BIT] first payload word is the AC-3 syncword 0x0B77 (syncframe not shifted)"


@pytest.mark.secondary
def test_ac3_payload_is_one_whole_syncframe_48k(impl):
    f = AC3["ac3_48k"]
    w = impl.ac3_burst(f)
    assert len(f) == 512 and bytes_of(w[4:4 + 256]) == f, \
        "[ST340_AC3_PAYLOAD,A52_SIZE_48_128,FF_PAYLOAD] the payload is the complete 512-byte syncframe, last word included"


@pytest.mark.secondary
def test_ac3_data_type_dependent_zero_for_bsmod_0(impl):
    w = impl.ac3_burst(ac3_frame(0, 16, bsmod=0))
    assert (w[2] >> 8) & 0x1F == 0, \
        "[FF_AC3_TYPE,FF_AC3_BSMOD,FF_PC_BITS] data_type_dependent (Pc bits 8-12) is 0 for a full main service (bsmod 0)"


@pytest.mark.secondary
@pytest.mark.parametrize("bsmod", [1, 3, 5, 7])
def test_ac3_bsmod_in_data_type_dependent_bits_0_2(impl, bsmod):
    w = impl.ac3_burst(ac3_frame(0, 16, bsmod=bsmod))
    assert (w[2] >> 8) & 7 == bsmod, \
        "[FF_AC3_TYPE,FF_AC3_BSMOD,FF_PC_BITS] Pc bits 8-10 carry the frame's bsmod (byte 5, low 3 bits)"


def test_ac3_rejects_wrong_syncword(impl, raises_cited):
    f = bytearray(AC3["ac3_48k"])
    f[0], f[1] = 0x0B, 0x78
    with raises_cited("BurstError", "[A52_SYNC,ST340_AC3_PAYLOAD]"):
        impl.ac3_burst(bytes(f))


def test_ac3_rejects_truncated_syncframe(impl, raises_cited):
    with raises_cited("BurstError", "[ST340_AC3_PAYLOAD,A52_SIZE_48_128,A52_SYNCINFO]"):
        impl.ac3_burst(AC3["ac3_48k"][:300])


# -------------------------------------------------------------------------------- E-AC-3
@pytest.mark.parametrize("kind", ["eac3_6x1", "eac3_1x6", "eac3_2x3"])
def test_eac3_data_type_is_21_with_bits_5_6_zero(impl, kind):
    w, _ = build(impl, kind)
    assert w[2] & 0x7F == 21, \
        "[IEC3_T4,IEC3_T4_56,ST338_EAC3_IEC] Pc bits 0-4 = 21 and bits 5-6 = 0 for enhanced AC-3 (not the professional 16)"


@pytest.mark.secondary
@pytest.mark.parametrize("kind", ["eac3_6x1", "eac3_1x6", "eac3_2x3"])
def test_eac3_pd_is_payload_length_in_bytes(impl, kind):
    w, payload = build(impl, kind)
    assert w[3] == len(payload), \
        "[FF_EAC3_LEN,FF_PD_UNIT] for E-AC-3 Pd counts payload BYTES (all grouped syncframes together)"


@pytest.mark.secondary
@pytest.mark.parametrize("kind", ["eac3_6x1", "eac3_1x6", "eac3_2x3"])
def test_eac3_burst_is_6144_frames_long(impl, kind):
    w, _ = build(impl, kind)
    assert len(w) == 12288, \
        "[FF_EAC3_PERIOD,FF_PERIOD_BYTES] E-AC-3 repetition period 24576 bytes = 6144 IEC 60958 frames = 12288 words"


@pytest.mark.secondary
def test_eac3_payload_is_the_frames_in_order(impl):
    w = impl.eac3_burst(EAC3_2x3)
    joined = b"".join(EAC3_2x3)
    assert bytes_of(w[4:4 + len(joined) // 2]) == joined, \
        "[ST340_EAC3_PAYLOAD,ST337_FIRST_BIT,FF_EAC3_CONCAT] payload = the grouped syncframes concatenated unchanged, in order"


def test_eac3_payload_starts_with_the_syncword(impl):
    w = impl.eac3_burst(EAC3_1x6)
    assert w[4] == 0x0B77, "[E_SYNCWORD,E_SYNCINFO,ST337_FIRST_BIT] first payload word is the syncword 0x0B77"


@pytest.mark.secondary
def test_eac3_rejects_partial_group(impl, raises_cited):
    with raises_cited("BurstError", "[ST340_EAC3_6BLK,E_NUMBLKS,FF_EAC3_GROUP,FF_EAC3_GROUP_IDX]"):
        impl.eac3_burst(EAC3_6x1[:3])


@pytest.mark.secondary
def test_eac3_rejects_more_than_six_blocks(impl, raises_cited):
    with raises_cited("BurstError", "[ST340_EAC3_6BLK,E_NUMBLKS,FF_EAC3_GROUP,FF_EAC3_GROUP_IDX]"):
        impl.eac3_burst(EAC3_6x1 + eac3_stream(0, 1))


def test_eac3_rejects_wrong_syncword(impl, raises_cited):
    bad = bytearray(EAC3_1x6[0])
    bad[0], bad[1] = 0x77, 0x0B
    with raises_cited("BurstError", "[E_SYNCWORD,E_SYNCINFO]"):
        impl.eac3_burst([bytes(bad)])


# ---------------------------------------------------------------------------- E-AC-3 grouping
@pytest.mark.parametrize("numblkscod,per", [(0, 6), (1, 3), (2, 2), (3, 1)])
@pytest.mark.secondary
def test_eac3_group_is_six_blocks_per_burst(impl, numblkscod, per):
    frames = eac3_stream(numblkscod, 3)
    groups = impl.eac3_group(frames)
    assert [len(g) for g in groups] == [per, per, per], \
        f"[ST340_EAC3_6BLK,E_NUMBLKS,FF_EAC3_GROUP,FF_EAC3_GROUP_IDX] numblkscod {numblkscod}: {per} syncframes make six audio blocks, one burst"


@pytest.mark.secondary
def test_eac3_group_covers_every_frame_once_in_order(impl):
    frames = eac3_stream(1, 4)
    groups = impl.eac3_group(frames)
    assert [i for g in groups for i in g] == list(range(len(frames))), \
        "[ST340_EAC3_6BLK,ST340_EAC3_PAYLOAD,FF_EAC3_GROUP] groups are index lists covering each frame exactly once, in order"


@pytest.mark.secondary
def test_eac3_group_of_six_block_frames_feeds_eac3_burst(impl):
    frames = eac3_stream(0, 2)
    for g in impl.eac3_group(frames):
        w = impl.eac3_burst([frames[i] for i in g])
        assert w[:2] == [0xF872, 0x4E1F] and (w[2] & 0x7F) == 21, \
            "[ST340_EAC3_6BLK,IEC3_T4,FF_EAC3_GROUP,ST337_PA,ST337_PB] every group returned by eac3_group is acceptable to eac3_burst"


# ------------------------------------------------------------------------------------ DTS
@pytest.mark.secondary
@pytest.mark.parametrize("kind,code", [("dts_512", 11), ("dts_1024", 12), ("dts_2048", 13)])
def test_dts_data_type_by_frame_length(impl, kind, code):
    w = impl.dts_burst(DTS[kind][0])
    assert w[2] & 0x1F == code, \
        "[FF_DTS1,FF_DTS2,FF_DTS3,ST338_DTS1,ST338_DTS2,ST338_DTS3,DTS_NBLKS] 512/1024/2048-sample core frames " \
        "are DTS type I/II/III = data_type 11/12/13 (the samples-to-type link is FFmpeg only)"


@pytest.mark.parametrize("kind", list(DTS))
@pytest.mark.secondary
def test_dts_pd_is_payload_length_in_bits(impl, kind):
    f = DTS[kind][0]
    w = impl.dts_burst(f)
    assert len(f) % 2 == 0 and w[3] == 8 * len(f), \
        "[ST337_LEN_BITS,ST337_LEN_NOPRE,FF_LEN_BITS,DTS_FSIZE] Pd = number of payload bits (frame is FSIZE+1 bytes)"


@pytest.mark.secondary
@pytest.mark.parametrize("kind", list(DTS))
def test_dts_burst_length_is_two_words_per_sample(impl, kind):
    w = impl.dts_burst(DTS[kind][0])
    assert len(w) == 2 * DTS[kind][1], \
        "[FF_DTS_PERIOD,FF_PERIOD_BYTES,DTS_NBLKS] repetition period = samples per frame IEC 60958 frames (2 words each)"


@pytest.mark.parametrize("kind", list(DTS))
def test_dts_payload_starts_with_the_sync_word(impl, kind):
    w = impl.dts_burst(DTS[kind][0])
    assert w[4:6] == [0x7FFE, 0x8001], \
        "[DTS_SYNC,ST337_FIRST_BIT] payload words 4,5 are the big-endian sync word 0x7FFE8001"


@pytest.mark.secondary
def test_dts_odd_length_frame_last_byte_is_msb_aligned(impl):
    f = dts_frame(15, 1025)
    w = impl.dts_burst(f)
    assert w[4:4 + 512] == words_of(f[:1024]) and w[4 + 512] == f[1024] << 8, \
        "[FF_ODD,ST337_LAST_UNUSED,ST337_FIRST_BIT,DTS_FSIZE] a lone final byte occupies the high byte of the last word, low byte 0"


@pytest.mark.secondary
def test_dts_odd_length_frame_fill_is_zero_and_period_kept(impl):
    w = impl.dts_burst(dts_frame(15, 1025))
    assert len(w) == 1024, "[FF_DTS_PERIOD,FF_PERIOD_BYTES,DTS_NBLKS] 512-sample frame keeps its 1024-word period, including odd payloads"
    assert all(x == 0 for x in w[4 + 513:]), \
        "[ST337_UNUSED_ZERO,ST337_LAST_UNUSED,FF_ODD,FF_FILL_ZERO] after the padded last word everything up to the next burst is 0"


def test_dts_rejects_missing_core_sync(impl, raises_cited):
    f = bytearray(dts_frame(15, 1024))
    f[0:4] = b"\x00\x00\x00\x00"
    with raises_cited("BurstError", "[DTS_SYNC,FF_DTS_BADSYNC]"):
        impl.dts_burst(bytes(f))


def test_dts_rejects_header_cut_short(impl, raises_cited):
    with raises_cited("BurstError", "[DTS_SYNC,DTS_NBLKS,DTS_FSIZE]"):
        impl.dts_burst(dts_frame(15, 1024)[:4])


@pytest.mark.secondary
@pytest.mark.parametrize("nblks,size", [(7, 600), (127, 3000)])
def test_dts_rejects_frame_lengths_other_than_512_1024_2048(impl, raises_cited, nblks, size):
    with raises_cited("BurstError", "[FF_DTS_UNSUPPORTED]"):
        impl.dts_burst(dts_frame(nblks, size))


@pytest.mark.secondary
def test_dts_rejects_frame_too_large_for_its_period(impl, raises_cited):
    with raises_cited("BurstError", "[FF_TOO_BIG,FF_DTS_PERIOD]"):
        impl.dts_burst(dts_frame(15, 2100))


@pytest.mark.secondary
@pytest.mark.parametrize("code,w48,w44,w32", AC3_SIZE_ROWS)
@pytest.mark.parametrize("fscod", [0, 1, 2])
def test_ac3_all_frame_size_rows_preserve_payload_and_bit_length(impl, code, w48, w44, w32, fscod):
    # Consumer carriage/unit support is secondary; every numeric size is a codec table cell.
    nwords = (w48, w44, w32)[fscod]
    frame = ac3_frame(fscod, code)
    w = impl.ac3_burst(frame)
    assert len(frame) == 2 * nwords and w[3] == 16 * nwords, \
        "[A52_SIZE_TABLE52,A52_SIZE_TABLE53,A52_FSCOD,A52_SYNCINFO,FF_LEN_BITS] Table 5.18 size at the selected sample rate determines payload bits"
    assert bytes_of(w[4:4 + nwords]) == frame, \
        "[A52_SIZE_TABLE52,A52_SIZE_TABLE53,FF_PAYLOAD,ST337_FIRST_BIT] every table-sized syncframe is carried unchanged through its last word"
