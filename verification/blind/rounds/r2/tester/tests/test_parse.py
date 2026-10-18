"""parse_bursts: decoding hand-built bursts and round trips of the formatters."""
import pytest

from helpers import ac3_frame, dts_frame, eac3_stream, hand_burst, body

P12 = body(12, 3)


def one(impl, words):
    got = impl.parse_bursts(words)
    assert len(got) == 1, f"[ST337_FRAME_PRE] expected exactly one burst, got {len(got)}"
    return got[0]


def test_parse_offset_is_index_of_pa_after_leading_zeros(impl):
    b = one(impl, hand_burst(1, P12, 96, lead=8, total=64))
    assert b.offset == 8, \
        "[ST337_FRAME_PRE,ST337_FOUR_ZERO,ST337_EXT_SYNC] offset = index of the burst's first preamble word (Pa), not of the zeros before it"


@pytest.mark.parametrize("field,expected", [
    ("data_type", 1), ("error_flag", 1), ("data_type_dependent", 0b10101), ("bitstream_number", 5)])
def test_parse_pc_fields(impl, field, expected):
    b = one(impl, hand_burst(1, P12, 96, err=1, dtd=0b10101, stream=5, total=64))
    assert getattr(b, field) == expected, \
        f"[ST337_T7_TYPE,ST337_T7_ERR,ST337_T7_DTD,ST337_T7_STREAM,FF_PC_BITS,FF_PC_STREAM] Pc field {field}: " \
        "data_type = bits 0-4, error_flag = bit 7, data_type_dependent = bits 8-12, stream = bits 13-15"


def test_parse_length_code_is_raw_pd(impl):
    b = one(impl, hand_burst(1, P12, 96, total=64))
    assert b.length_code == 96, "[ST337_FRAME_PRE] length_code is the raw Pd word (Pd is the 4th word)"


@pytest.mark.secondary
def test_parse_payload_in_bits_for_ac3_type(impl):
    b = one(impl, hand_burst(1, P12, 96, total=64))
    assert b.payload == P12, \
        "[ST337_LEN_BITS,ST337_FIRST_BIT,ST338_AC3,FF_LEN_BITS] data_type 1: Pd 96 = 96 bits = 12 payload bytes, big-endian words"


@pytest.mark.secondary
def test_parse_payload_odd_byte_count_in_bits(impl):
    # Interpret supplied Pd=40; do not prescribe the encoder Pd for odd DTS frames.
    # Shared structural extraction inference per ST337 8.2, not consumer normative rounding.
    odd = bytes([1, 2, 3, 4, 5])
    b = one(impl, hand_burst(11, odd, 40, total=64))
    assert b.payload == odd, \
        "[ST337_LEN_BITS,ST337_LAST_UNUSED,ST338_DTS1,FF_LEN_BITS,FF_PD_UNIT] data_type 11 with Pd 40 bits: 5 bytes; the padding in the last word is not payload"


@pytest.mark.secondary
def test_parse_payload_excludes_fill(impl):
    b = one(impl, hand_burst(1, P12, 96, total=200))
    assert len(b.payload) == 12, \
        "[ST337_LEN_NOPRE,ST337_LEN_BITS,ST337_UNUSED_ZERO,FF_LEN_BITS] the zero fill after the payload is not part of it"


@pytest.mark.secondary
def test_parse_payload_in_bytes_for_eac3_type(impl):
    p = body(10, 4)
    b = one(impl, hand_burst(21, p, 10, total=64))
    assert b.payload == p and b.data_type == 21, \
        "[FF_EAC3_LEN,FF_PD_UNIT,IEC3_T4] data_type 21: Pd counts bytes, so Pd 10 = 10 payload bytes"


@pytest.mark.secondary
def test_parse_two_back_to_back_bursts(impl):
    a, c = body(12, 1), body(8, 2)
    w = hand_burst(1, a, 96, total=64) + hand_burst(1, c, 64, total=64)
    got = impl.parse_bursts(w)
    assert [(b.offset, b.payload) for b in got] == [(0, a), (64, c)], \
        "[ST337_FRAME_PRE,ST337_UNUSED_ZERO,FF_LEN_BITS] every burst is found, in order, with the index of its own Pa"


def test_parse_all_zero_stream_has_no_burst(impl):
    assert list(impl.parse_bursts([0] * 64)) == [], "[ST337_IDLE] an idle (all-zero) stream carries no data burst"


@pytest.mark.secondary
def test_parse_rejects_payload_running_past_the_end(impl, raises_cited):
    w = hand_burst(1, P12, 96, total=64)[:8]
    with raises_cited("BurstError", "[ST337_LEN_BITS,ST337_PRE_FOLLOW,FF_LEN_BITS]"):
        impl.parse_bursts(w)


# ---------------------------------------------------------------------------------- round trips
@pytest.mark.secondary
def test_roundtrip_ac3_single_burst_fields(impl):
    f = ac3_frame(0, 16, bsmod=0)
    b = one(impl, impl.ac3_burst(f))
    assert (b.offset, b.data_type, b.error_flag, b.bitstream_number, b.length_code) == (0, 1, 0, 0, 8 * len(f)), \
        "[ST337_FRAME_PRE,ST338_AC3,ST337_ERR0,ST337_STREAM0,ST337_LEN_BITS,FF_LEN_BITS] parse(ac3_burst(f)) recovers the preamble"


@pytest.mark.secondary
def test_roundtrip_ac3_payload(impl):
    f = ac3_frame(1, 0)
    b = one(impl, impl.ac3_burst(f))
    assert b.payload == f, "[ST340_AC3_PAYLOAD,ST337_LEN_BITS,FF_LEN_BITS,FF_PAYLOAD] parse(ac3_burst(f)).payload == f, 138-byte frame"


@pytest.mark.secondary
def test_roundtrip_ac3_three_bursts_offsets(impl):
    fs = [ac3_frame(0, 16, seed=s) for s in (1, 2, 3)]
    w = [x for f in fs for x in impl.ac3_burst(f)]
    got = impl.parse_bursts(w)
    assert [b.offset for b in got] == [0, 3072, 6144] and [b.payload for b in got] == fs, \
        "[ST340_AC3_PERIOD,ST337_FRAME_PRE,FF_AC3_PERIOD,A52_DURATION,FF_PERIOD_BYTES,FF_LEN_BITS,FF_PAYLOAD] three consecutive AC-3 bursts: Pa at 0, 3072, 6144, payloads recovered"


@pytest.mark.secondary
def test_roundtrip_eac3_payload(impl):
    fs = eac3_stream(1, 1, 250)
    b = one(impl, impl.eac3_burst(fs))
    assert b.payload == b"".join(fs) and b.data_type == 21, \
        "[ST340_EAC3_PAYLOAD,IEC3_T4,FF_EAC3_CONCAT,FF_EAC3_LEN,FF_PD_UNIT,FF_EAC3_GROUP] parse(eac3_burst(frames)).payload is the concatenated syncframes"


@pytest.mark.secondary
def test_roundtrip_dts_payload_and_offsets(impl):
    fs = [dts_frame(15, 1024, seed=s) for s in (1, 2)]
    w = [x for f in fs for x in impl.dts_burst(f)]
    got = impl.parse_bursts(w)
    assert [b.payload for b in got] == fs and got[0].offset == 0 and got[1].offset == len(w) // 2, \
        "[ST337_LEN_BITS,ST337_FRAME_PRE,DTS_FSIZE,FF_LEN_BITS] two consecutive DTS bursts: payloads recovered, second Pa after the first burst"


@pytest.mark.parametrize("tail", [[0xF872, 0x4E1F], [0xF872, 0x4E1F, 1]])
def test_parse_rejects_truncated_preamble(impl, raises_cited, tail):
    # Interface explicitly requires BurstError for an inconsistent preamble.
    with raises_cited("BurstError", "[ST337_FRAME_PRE]"):
        impl.parse_bursts([0] * 4 + tail)


@pytest.mark.secondary
def test_parse_sync_like_words_inside_payload_are_not_a_second_burst(impl):
    # An arbitrary payload may contain a complete preamble-shaped byte sequence.
    payload = bytes.fromhex("f8724e1f000100100b77")
    got = impl.parse_bursts(hand_burst(1, payload, 80, total=64))
    assert len(got) == 1 and got[0].offset == 0 and got[0].payload == payload, \
        "[ST337_LEN_BITS,ST337_LEN_NOPRE,ST337_PRE_FOLLOW,FF_LEN_BITS] declared payload extent consumes sync-like words within it"
