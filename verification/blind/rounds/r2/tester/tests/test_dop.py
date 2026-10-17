"""DoP (dop-1.1): dop_pack / dop_unpack."""
import pytest

CH0 = bytes([0x80, 0x00, 0x01, 0x00, 0xA5, 0x3C, 0xFF, 0x0F])
CH1 = bytes([0x12, 0x34, 0x00, 0x01, 0x5A, 0xC3, 0x00, 0xF0])
CH2 = bytes([0xFE, 0xDC, 0x80, 0x80, 0x01, 0x02, 0x7F, 0xFE])
M = lambda w: w >> 16  # noqa: E731
LOW = lambda w: w & 0xFFFF  # noqa: E731


def test_pack_markers_alternate_from_05(impl):
    f = impl.dop_pack([CH0, CH1], 0x05)
    assert [M(fr[0]) for fr in f] == [0x05, 0xFA, 0x05, 0xFA], \
        "[DOP_MARKER_ALT] marker alternates 0x05, 0xFA, ... with each sample, starting from first_marker=0x05"


def test_pack_markers_alternate_from_fa(impl):
    f = impl.dop_pack([CH0, CH1], 0xFA)
    assert [M(fr[0]) for fr in f] == [0xFA, 0x05, 0xFA, 0x05], \
        "[DOP_MARKER_ALT] first_marker=0xFA: the stream continues 0xFA, 0x05, 0xFA, 0x05"


def test_pack_default_first_marker(impl):
    f = impl.dop_pack([CH0, CH1])
    assert M(f[0][0]) == 0x05, "[DOP_MARKER_ALT] the default first marker (interface default) is 0x05"


def test_pack_same_marker_on_every_channel(impl):
    f = impl.dop_pack([CH0, CH1, CH2], 0x05)
    for n, fr in enumerate(f):
        assert len({M(w) for w in fr}) == 1, \
            f"[DOP_MARKER_SAME] frame {n}: every channel carries the same marker, got {[hex(M(w)) for w in fr]}"


def test_pack_marker_is_the_8_msbs_of_a_24_bit_word(impl):
    f = impl.dop_pack([CH0, CH1], 0x05)
    for n, fr in enumerate(f):
        for c, w in enumerate(fr):
            assert 0 <= w <= 0xFFFFFF, \
                f"[DOP_24BIT] frame {n} ch {c}: word {w:#x} must fit the 24-bit PCM word"
            assert (w >> 16) in (0x05, 0xFA), \
                f"[DOP_MARKER_MSB] frame {n} ch {c}: the marker is bits 23..16, word {w:#x}"


def test_pack_oldest_bit_is_bit15(impl):
    f = impl.dop_pack([bytes([0x80, 0x00])], 0x05)
    assert f == [[0x058000]], \
        "[DOP_BITS_OLDEST,DOP_DIAGRAM] oldest DSD bit (MSB of byte 0) is t0, directly under the marker: word 0x058000"


def test_pack_bit_order_within_first_byte(impl):
    f = impl.dop_pack([bytes([0x01, 0x00])], 0x05)
    assert f == [[0x050100]], \
        "[DOP_DIAGRAM] t0..t7 are the 8 bits of byte 0 (t0 = its MSB, t7 = its LSB) at word bits 15..8"


def test_pack_second_byte_in_low_half(impl):
    f = impl.dop_pack([bytes([0x00, 0x01])], 0x05)
    assert f == [[0x050001]], \
        "[DOP_DIAGRAM] t8..t15 (byte 1, newer bits) sit in word bits 7..0, t15 (LSB of byte 1) at bit 0"


def test_pack_sixteen_bits_per_frame_in_time_order(impl):
    f = impl.dop_pack([CH0], 0x05)
    assert [LOW(fr[0]) for fr in f] == [0x8000, 0x0100, 0xA53C, 0xFF0F], \
        "[DOP_BITS_OLDEST,DOP_DIAGRAM] two bytes per frame, byte 2k then byte 2k+1, frames in time order"


def test_pack_frame_count_and_width(impl):
    f = impl.dop_pack([CH0, CH1, CH2], 0x05)
    assert len(f) == 4 and all(len(fr) == 3 for fr in f), \
        "[DOP_BITS_OLDEST,DOP_PER_CHANNEL] 16 DSD bits per channel per frame: 8 bytes -> 4 frames of 3 channels"


def test_pack_channel_k_goes_to_pcm_channel_k(impl):
    f = impl.dop_pack([CH0, CH1, CH2], 0x05)
    assert [[LOW(w) for w in fr] for fr in f] == [
        [0x8000, 0x1234, 0xFEDC], [0x0100, 0x0001, 0x8080], [0xA53C, 0x5AC3, 0x0102], [0xFF0F, 0x00F0, 0x7FFE]], \
        "[DOP_PER_CHANNEL] each PCM channel carries only the DSD data of its assigned channel"


@pytest.mark.parametrize("bad", [0x06, 0xF9, 0x00, 0xFF, 0x04])
def test_pack_rejects_marker_not_of_base_method(impl, raises_cited, bad):
    with raises_cited("DoPError", "[DOP_MARKER_ALT,DOP_OTHER_MARKER,DOP_ALT_MARKERS]"):
        impl.dop_pack([CH0, CH1], bad)


def test_pack_rejects_odd_byte_count(impl, raises_cited):
    with raises_cited("DoPError", "[DOP_BITS_OLDEST]"):
        impl.dop_pack([CH0[:7], CH1[:7]], 0x05)


def test_pack_rejects_unequal_channel_lengths(impl, raises_cited):
    with raises_cited("DoPError", "[DOP_MARKER_SAME,DOP_PER_CHANNEL]"):
        impl.dop_pack([CH0, CH1[:6]], 0x05)


@pytest.mark.parametrize("first", [0x05, 0xFA])
def test_unpack_inverts_pack(impl, first):
    f = impl.dop_pack([CH0, CH1, CH2], first)
    dsd, fm = impl.dop_unpack(f)
    assert list(dsd) == [CH0, CH1, CH2], "[DOP_BITS_OLDEST,DOP_DIAGRAM] unpack returns the original DSD bytes"
    assert fm == first, "[DOP_MARKER_ALT] unpack returns the marker of the first frame"


def test_unpack_reads_hand_built_stream(impl):
    frames = [[0x058000, 0x051234], [0xFA0100, 0xFA0001]]
    dsd, fm = impl.dop_unpack(frames)
    assert list(dsd) == [bytes([0x80, 0x00, 0x01, 0x00]), bytes([0x12, 0x34, 0x00, 0x01])] and fm == 0x05, \
        "[DOP_MARKER_ALT,DOP_BITS_OLDEST,DOP_DIAGRAM] hand-built frames decode to oldest-bit-first bytes"


def test_unpack_rejects_non_alternating_markers(impl, raises_cited):
    with raises_cited("DoPError", "[DOP_MARKER_ALT]"):
        impl.dop_unpack([[0x058000], [0x050100], [0x05A53C]])


def test_unpack_rejects_marker_differing_between_channels(impl, raises_cited):
    with raises_cited("DoPError", "[DOP_MARKER_SAME]"):
        impl.dop_unpack([[0x058000, 0xFA1234], [0xFA0100, 0x050001]])


def test_unpack_rejects_channel_without_marker(impl, raises_cited):
    with raises_cited("DoPError", "[DOP_RX_MISSING,DOP_MARKER_SAME]"):
        impl.dop_unpack([[0x058000, 0x001234], [0xFA0100, 0xFA0001]])


def test_unpack_rejects_markers_of_other_method(impl, raises_cited):
    with raises_cited("DoPError", "[DOP_OTHER_MARKER,DOP_ALT_MARKERS]"):
        impl.dop_unpack([[0x068000], [0xF90100]])


def test_unpack_rejects_pcm_audio(impl, raises_cited):
    with raises_cited("DoPError", "[DOP_RX_MISSING,DOP_MARKER_ALT]"):
        impl.dop_unpack([[0x123456, 0x654321], [0x0A0B0C, 0x0C0B0A]])


def test_unpack_rejects_word_wider_than_24_bits(impl, raises_cited):
    with raises_cited("DoPError", "[DOP_24BIT,DOP_MARKER_MSB]"):
        impl.dop_unpack([[0x0105_8000]])
