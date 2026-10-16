"""vblind_ref: reference implementation of the vblind interface (DoP 1.1 and IEC 61937 bursts, two-channel
consumer interface, 16-bit frame mode, stream 0, AC-3 / E-AC-3 / DTS core).

Built only from the corpus in this room. Citation comments are R1 JSON entries keyed C01 etc.
Sections name corpus anchors; notes identify finer printed clauses/tables. Quotes are verbatim
from one anchored page, with whitespace collapsed.
Tiers: primary (dop-1.1), primary-preview (IEC previews: titles only), sibling-standard (SMPTE ST 337/338/340),
codec-spec (A/52, TS 102 366, TS 102 114), SECONDARY (FFmpeg n7.1: an implementation, not a specification).

OPEN CHOICES (the corpus allows more than one behaviour, or is silent and a choice had to be made)
 O1  dop_pack with an empty channel list raises DoPError; with channels of length 0 it returns [] (nothing to
     represent).  dop_unpack([]) raises DoPError (no marker, no channel count: nothing identifies DSD).
 O2  dop_unpack does not require the 32 consecutive markers that dop-1.1 §4 describes for a *receiver* switching
     modes (recommended implementation); any run of valid alternating-marker frames is accepted.
 O3  dop_pack input whose length is odd (a DSD byte count that does not fill a whole 16-bit slot) raises DoPError
     (cannot be represented exactly; padding would invent DSD bits).  Unequal channel lengths / non-bytes: DoPError.
 O4  first_marker other than 0x05 / 0xFA raises DoPError (0x06/0xF9 belong to the out-of-scope second method).
 O5  AC-3 data_type_dependent: bits 0-2 = bsmod from the frame, bits 3-4 = 0 (SECONDARY, FFmpeg).  ST 340 (the
     professional text) says bits 0-2 "Reserved, must be set to 000"; per RULINGS R2 the consumer format governs
     and ST 337 §8.4 says the field "might differ", so the professional rule is NOT applied.
 O6  E-AC-3 data_type_dependent = 0 (SECONDARY, FFmpeg sets nothing there).
 O7  Length-code unit: bits for AC-3 and DTS (ST 337 §7.2.5 + FFmpeg agree), BYTES for E-AC-3 (SECONDARY only:
     FFmpeg's length_code = hd_buf_filled).  ST 337/ST 340 (professional) say bits for every type.  parse_bursts
     applies the same per-type unit (bytes for data_type 21, bits otherwise, including unknown types).
 O8  E-AC-3 repetition period: 6144 IEC 60958 frames (SECONDARY: FFmpeg pkt_offset 24576 bytes).  ST 340 §5.6 says
     1536 frames, but that is the professional rate; not applied (R2).
 O9  DTS: repetition period = 32 x (NBLKS+1) frames; types 512/1024/2048 samples -> data_type 11/12/13.
     Other sample counts -> BurstError.  A frame longer than FSIZE+1 is truncated to FSIZE+1 (SECONDARY, FFmpeg
     discards extraneous data); shorter than FSIZE+1 or FSIZE+1 > period*4-8 bytes -> BurstError.
     Odd sizes are accepted: the final byte occupies the high byte of a word, low byte zero; remaining fill is
     zero and the period is unchanged (SECONDARY, C25-C27; professional structure C12 is corroboration only).
     A frame of exactly period*4 bytes (FFmpeg sends it without preamble) is refused: it is not a data burst.
 O10 AC-3: bsid must be <= 8 (A/52 §5.4.2.1); frame length must equal the Table 5.18 size exactly.
 O11 E-AC-3 grouping (sibling-standard inference; consumer grouping is unconfirmed) counts audio blocks of
     independent substream 0 (6 blocks), rather than FFmpeg's frame count;
     a trailing incomplete group is still returned by eac3_group (covers every frame) but eac3_burst refuses it.
 O12 fscod==3 E-AC-3 frames (fscod2, reduced rate, 6 blocks per A/52 Annex E) are accepted as 6-block frames.
 O13 parse_bursts: only Pa at an even word index (Ch1 subframe) counts as a burst start; unmatched words between
     bursts are ignored (stuffing); data_mode != 0, data_type 31 (six-word preamble), a length that is not a whole
     number of bytes, or a payload running past the end of the list -> BurstError. Pause/null/other data types
     are parsed generically (bits unit, O16). Non-zero stuffing is not an error.
 O14 Fill after a burst is all zero words; padding word after an odd payload word count is zero.
 O15 Header guards (AC-3 8 bytes, E-AC-3 6, DTS 10) are implementation validation policies, not normative minima.
     Strict AC-3/E-AC-3 lengths, short DTS rejection and preamble-less DTS refusal are retained validation choices.
 O16 Unknown/pause/null parser types use bits as an out-of-scope policy, not a consumer-format requirement.

GAPS (public corpus does not settle them; what was done)
 G1  IEC 61937-1/-2/-3/-5 normative clauses (preamble, burst-info, stuffing, repetition periods, length units,
     AC-3/E-AC-3/DTS mappings) are not in the corpus.  Consumer sync words, data-type numbers 1/11/12/13/21,
     length unit and repetition periods are therefore sibling-standard / informative-column / SECONDARY.
 G2  Consumer data_type_dependent coding for AC-3 (O5), E-AC-3 (O6) and DTS (Tables 3-5 of IEC 61937-5 are only
     titles in the preview): DTS data_type_dependent is set to 0 (SECONDARY: FFmpeg sets none).
 G3  Whether the consumer E-AC-3 length_code is bytes (O7) and the consumer E-AC-3 period (O8): SECONDARY only.
 G4  E-AC-3 convsync check of the first frame of a group (ST 340 §5.3) is NOT performed: locating convsync needs
     the whole BSI parse and the mixdata field layout in TS 102 366 E.1.2.2 is ambiguous in the corpus text.
 G5  Reduced-rate E-AC-3 (fscod2) and 32/44.1 kHz repetition periods for consumer E-AC-3: not settled.
 G6  Error-flag setting: always 0 (ST 337 §7.2.4.4: 0 when unknown/error-free).
 G7  Consumer odd-DTS carriage is unconfirmed without normative IEC text. Acceptance/alignment follows FFmpeg
     (SECONDARY); ETSI byte sizes do not forbid odd lengths, and ST 337 zero bits do not upgrade that tier.
 G8  Consumer E-AC-3 grouping is unconfirmed. ST 340 six-block grouping is adopted as a sibling inference;
     ETSI Annex J p.240 governs ISOBMFF/CMAF samples, not IEC bursts. Single-substream FFmpeg agrees.
 G9  ATSC Annex E accepts reduced-rate fscod2; ETSI TS 102 366 p.127 reserves fscod=3. ATSC handling is retained.
 G10 Consumer AC-3 period 1536 is inferred from codec/sibling duration plus FFmpeg AC3_FRAME_SIZE << 2;
     the definition of AC3_FRAME_SIZE is in an absent header. A literal consumer 1536 definition is unavailable.
 G11 Odd DTS Pd preserves the round-1 FSIZE+1 bit count (C30). FFmpeg generic default (C50) instead rounds
     an untrimmed odd packet size up to even; its truncated-core path uses exact bits. Corpus does not settle
     consumer odd-DTS Pd. Exact byte count avoids inventing payload bytes; do not claim full FFmpeg identity.
"""
from __future__ import annotations

from dataclasses import dataclass


class DoPError(ValueError):
    """Raised for input that cannot be packed, or a PCM stream that is not valid DoP."""


class BurstError(ValueError):
    """Raised for input that cannot be framed, or a word stream that cannot be parsed."""


# C01 {"doc": "dop-1.1", "section": "2", "page": 2, "quote": "The 8 most significant bits are used for the DSD marker and alternate with each sample between 0x05 and 0xFA. Each channel within a sample contains the same marker.", "tier": "primary", "note": "24-bit layout/markers; each channel uses the same alternating marker."}
# C02 {"doc": "dop-1.1", "section": "2", "page": 2, "quote": "The remaining 16 lower bits are then used for the DSD data, first or oldest bit in slot t0.", "tier": "primary", "note": "Byte0 precedes byte1 in the 16-bit payload; rejecting incomplete slots is O3."}
# C03 {"doc": "dop-1.1", "section": "2", "page": 2, "quote": "24 bit PCM Frame", "tier": "primary", "note": "Interface raw unsigned word is 24 bits."}
# C04 {"doc": "dop-1.1", "section": "3", "page": 2, "quote": "All the marker bytes and bit ordering remain the same.", "tier": "primary", "note": "Solution 1 raises the PCM sample rate; solution 2 marker values are out of scope."}
# C05 {"doc": "dop-1.1", "section": "4", "page": 3, "quote": "In order to switch from PCM to DSD mode the receiver has to detect 32 consecutive DSD marker bytes on all channels used.", "tier": "primary", "note": "Receiver acquisition recommendation; inverse pack/unpack accepts short runs (O2)."}
# C72 {"doc": "dop-1.1", "section": "2", "page": 2, "quote": "each PCM Frame contains only DSD data corresponding to its assigned channel.", "tier": "primary", "note": "One base-method DoP sample per DSD channel; interface groups channel words in frames."}
# C73 {"doc": "dop-1.1", "section": "3", "page": 2, "quote": "PCM frame 1 => 0x06 16 DSD bits ch1 0xF9 16 DSD bits ch1 0x06 16 DSD bits ch1", "tier": "primary", "note": "Alternative paired-channel method uses0x06/0xF9; excluded by SCOPE.md."}
_DOP_MARKERS = (0x05, 0xFA)


def dop_pack(dsd: list[bytes], first_marker: int = 0x05) -> list[list[int]]:
    if first_marker not in _DOP_MARKERS or isinstance(first_marker, bool):
        raise DoPError("first_marker must be 0x05 or 0xFA")
    if not isinstance(dsd, (list, tuple)) or len(dsd) == 0:
        raise DoPError("at least one DSD channel is required")  # O1
    for ch in dsd:
        if not isinstance(ch, (bytes, bytearray)):
            raise DoPError("DSD channels must be bytes")
    n = len(dsd[0])
    if any(len(ch) != n for ch in dsd):
        raise DoPError("all channels must have the same length")
    if n % 2:
        raise DoPError("DSD byte count per channel must be even (16 DSD bits per PCM frame)")
    other = _DOP_MARKERS[1] if first_marker == _DOP_MARKERS[0] else _DOP_MARKERS[0]
    frames = []
    for i in range(n // 2):
        marker = first_marker if i % 2 == 0 else other
        frames.append([(marker << 16) | (ch[2 * i] << 8) | ch[2 * i + 1] for ch in dsd])
    return frames


def dop_unpack(frames: list[list[int]]) -> tuple[list[bytes], int]:
    if not frames:
        raise DoPError("no frames: cannot identify DSD or the channel count")  # O1
    nch = len(frames[0])
    if nch == 0:
        raise DoPError("frame without channels")
    out = [bytearray() for _ in range(nch)]
    first_marker = None
    for i, fr in enumerate(frames):
        if len(fr) != nch:
            raise DoPError("frames differ in channel count")
        marker = None
        for c, w in enumerate(fr):
            if not isinstance(w, int) or isinstance(w, bool) or not 0 <= w <= 0xFFFFFF:
                raise DoPError("PCM word is not a 24-bit value")
            m = w >> 16
            if marker is None:
                marker = m
            elif m != marker:
                raise DoPError("markers differ between channels")
            out[c].append((w >> 8) & 0xFF)
            out[c].append(w & 0xFF)
        if i == 0:
            if marker not in _DOP_MARKERS:
                raise DoPError("first marker is neither 0x05 nor 0xFA")
            first_marker = marker
        else:
            expect = first_marker if i % 2 == 0 else (0xFA if first_marker == 0x05 else 0x05)
            if marker != expect:
                raise DoPError("marker does not alternate")
    return [bytes(b) for b in out], first_marker


# C06 {"doc": "ffmpeg-spdif-n7.1/spdif", "section": "file", "page": 1, "quote": "#define SYNCWORD1 0xF872", "tier": "secondary", "note": "Pa; spdif.h, not spdifenc.c."}
# C07 {"doc": "ffmpeg-spdif-n7.1/spdif", "section": "file", "page": 1, "quote": "#define SYNCWORD2 0x4E1F", "tier": "secondary", "note": "Pb."}
# C09 {"doc": "smpte-st337-2015", "section": "7.2.1", "page": 9, "quote": "= 0xF872 (16-bit mode)", "tier": "sibling-standard", "note": "Pa; shared preamble inferred from consumer subset discussion in section 8.2, not consumer normative text."}
# C10 {"doc": "smpte-st337-2015", "section": "7.2.1", "page": 9, "quote": "= 0x4E1F (16-bit mode)", "tier": "sibling-standard", "note": "Pb; same carry-over rationale as C09."}
# C14 {"doc": "smpte-st337-2015", "section": "8.2", "page": 14, "quote": "The consumer bit stream format can, in general, be considered a subset of the professional bit stream format defined by this standard.", "tier": "sibling-standard", "note": "Rationale for structural carry-over only; section 8.4 limits type-specific inference."}
_PA = 0xF872
_PB = 0x4E1F

# C32 {"doc": "ffmpeg-spdif-n7.1/spdif", "section": "file", "page": 1, "quote": "IEC61937_DTS1 = 0x0B, ///< DTS type I (512 samples)", "tier": "secondary", "note": "Explicit samples-to-consumer-code link; ST338 informative column alone does not supply sample counts."}
# C33 {"doc": "ffmpeg-spdif-n7.1/spdif", "section": "file", "page": 1, "quote": "IEC61937_DTS2 = 0x0C, ///< DTS type II (1024 samples)", "tier": "secondary", "note": "Explicit samples-to-consumer-code link; ST338 informative column alone does not supply sample counts."}
# C34 {"doc": "ffmpeg-spdif-n7.1/spdif", "section": "file", "page": 1, "quote": "IEC61937_DTS3 = 0x0D, ///< DTS type III (2048 samples)", "tier": "secondary", "note": "Explicit samples-to-consumer-code link; ST338 informative column alone does not supply sample counts."}
# C35 {"doc": "ffmpeg-spdif-n7.1/spdif", "section": "file", "page": 1, "quote": "IEC61937_AC3 = 0x01, ///< AC-3 data", "tier": "secondary", "note": "AC-3 code; ST338 consumer column corroborates."}
# C36 {"doc": "ffmpeg-spdif-n7.1/spdif", "section": "file", "page": 1, "quote": "IEC61937_EAC3 = 0x15, ///< E-AC-3 data", "tier": "secondary", "note": "Consumer E-AC-3 code; professional E-AC-3 code is different."}
# C37 {"doc": "smpte-st338-2016", "section": "4", "page": 4, "quote": "1 AC-3 (audio) data ST 340 Same data", "tier": "sibling-standard", "note": "Table 1 informative consumer allocation; not professional-only numbering."}
# C38 {"doc": "smpte-st338-2016", "section": "4", "page": 4, "quote": "MPEG-4 HE-AAC (audio) data in ST 2041-2 DTS type I 11 ADTS or LATM/LOAS 12 Reserved for compatibility with IEC DTS type II 13 Reserved for compatibility with IEC DTS type III", "tier": "sibling-standard", "note": "Table 1 consumer column: DTS I/II/III at 11/12/13; sample linkage remains secondary C32-C34."}
# C39 {"doc": "smpte-st338-2016", "section": "4", "page": 4, "quote": "Enhanced AC-3 / Reserved (depends on 21 Reserved for compatibility with IEC IEC 61937-2 sub data-type)", "tier": "sibling-standard", "note": "Table 1 informative consumer allocation at row21; retain sub-data-type qualification."}
# C19 {"doc": "smpte-st337-2015", "section": "7.2.1", "page": 9, "quote": "The six subframe version shall be used when data_type has the value 31; otherwise, the four subframe version shall be used.", "tier": "sibling-standard", "note": "Shared preamble structure inferred under section 8.2; six-word preambles excluded by scope."}
_DT_AC3 = 1
_DT_DTS = {512: 11, 1024: 12, 2048: 13}
_DT_EAC3 = 21
_DT_EXT = 31


# C15 {"doc": "smpte-st337-2015", "section": "8.3", "page": 14, "quote": "When consumer format compatibility is required, all data bursts are restricted to the 16-bit frame mode (data_mode=0, both AES3-3 subframes used).", "tier": "sibling-standard", "note": "Explicit informative consumer compatibility; stream 0 also imposed by scope."}
# C16 {"doc": "smpte-st337-2015", "section": "8.4", "page": 14, "quote": "For some data types, the data_type_dependent field might differ between professional and consumer specifications.", "tier": "sibling-standard", "note": "Do not apply professional bsmod or E-AC-3 period/units as consumer requirements; payload and spacing differences also discussed here."}
# C17 {"doc": "smpte-st337-2015", "section": "7.2.4.1", "page": 10, "quote": "8-12 4-8 0-4 data_type (5-bit unsigned integer = 0 to 31) 13-14 9-10 5-6 data_mode error_flag 1 indicates data burst may contain errors 15 11 7 0 indicates data may be valid. 16-20 12-16 8-12 data_type_dependent 21-23 17-19 13-15 data_stream_number", "tier": "sibling-standard", "note": "Table 7 full relevant rows: type 0-4, mode 5-6, error 7, dtd 8-12, stream 13-15 in 16-bit mode. Structural inference under section 8.2; FFmpeg calls bits0-6 type, agreeing here only with scoped mode0."}
# C18 {"doc": "smpte-st337-2015", "section": "7.2.4.3", "page": 11, "quote": "0 16-bit mode Subframe time slots 27-12", "tier": "sibling-standard", "note": "Table 8 row: mode0 only, explicitly consumer-compatible under section 8.3."}
# C49 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "* Pc - burst-info, contains data-type (bits 0-6), error flag (bit 7), data-type-dependent info (bits 8-12)", "tier": "secondary", "note": "Seven consumer type bits described here; five-bit type/mode layout agrees only under scoped mode0. Next line states stream13-15."}
# C69 {"doc": "smpte-st337-2015", "section": "7.2.4.4", "page": 11, "quote": "then the value of this bit shall be set to a ‘0’.", "tier": "sibling-standard", "note": "When error-free or error status unknown; shared preamble inference under8.2, no CRC verification."}
# C70 {"doc": "smpte-st340-2015", "section": "4.2.2", "page": 5, "quote": "0-2 Reserved, must be set to 000", "tier": "sibling-standard", "note": "Professional table1 rule is deliberately not applied to consumer dependent bits (ST337 section8.4)."}
# C71 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "* and bitstream number (bits 13-15)", "tier": "secondary", "note": "Consumer stream field corroborates scoped structural layout; stream0 is scope."}
def _pc(data_type: int, dtd: int = 0, error: int = 0, stream: int = 0) -> int:
    return data_type | (0 << 5) | (error << 7) | (dtd << 8) | (stream << 13)


# C40 {"doc": "smpte-st340-2015", "section": "4.6", "page": 6, "quote": "bursts (in the same data stream number) occur 1536 AES3 frames apart.", "tier": "sibling-standard", "note": "Professional period; consumer duration inference, not normative consumer authority, because ST337 section8.4 permits spacing differences."}
# C42 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ctx->pkt_offset = AC3_FRAME_SIZE << 2;", "tier": "secondary", "note": "Consumer AC-3 period agreement inferred using sibling/codec 1536-sample duration. AC3_FRAME_SIZE definition absent from corpus; no literal consumer1536 claim."}
_AC3_PERIOD = 1536
# C43 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ctx->pkt_offset = 24576;", "tier": "secondary", "note": "Consumer E-AC-3 period /4 =6144 frames; do not substitute professional1536."}
# C74 {"doc": "smpte-st340-2015", "section": "5.6", "page": 10, "quote": "number occur at 1536 AES3 frame intervals.", "tier": "sibling-standard", "note": "Professional E-AC-3 period; not consumer authority because ST337 section8.4 permits spacing differences."}
_EAC3_PERIOD = 6144

# C08 {"doc": "ffmpeg-spdif-n7.1/spdif", "section": "file", "page": 1, "quote": "#define BURST_HEADER_SIZE 0x8", "tier": "secondary", "note": "Eight bytes, four 16-bit words; definition is in spdif.h."}
# C11 {"doc": "smpte-st337-2015", "section": "7.2.2", "page": 9, "quote": "The 4 preamble words shall be contained in 2 sequential frames. The frame beginning the data burst shall contain preamble word Pa in the Ch1 subframe, and Pb in the Ch2 subframe. The next frame shall contain Pc in Ch1 and Pd in Ch2.", "tier": "sibling-standard", "note": "Shared burst structure inferred from section 8.2; scope uses 16-bit frame mode."}
_PREAMBLE_WORDS = 4


# C12 {"doc": "smpte-st337-2015", "section": "7.3.1", "page": 12, "quote": "Considering the burst_payload as a serial stream of bits, the first bit of the first data word of the payload in a burst shall occupy the MSB bit position of subframe 1 (time slot 27) and the last bit of the first data word shall occupy the LSB bit position (according to the data_mode setting) of subframe 2. The last data bits of the burst_payload may occupy only a fraction of the last frame. Any unused bits in the last frame shall be set to 0.", "tier": "sibling-standard", "note": "Shared frame-mode packing inferred from section 8.2. Corroborates unused zeros; does not establish consumer odd-DTS acceptance."}
# C13 {"doc": "smpte-st337-2015", "section": "6.1", "page": 6, "quote": "Unused bit locations within a sub-frame or in subframes between bursts shall be set to ‘0’.", "tier": "sibling-standard", "note": "Zero fill inferred as shared structure under section 8.2; consumer fill independently agrees in C27."}
# C20 {"doc": "smpte-st337-2015", "section": "7.2.5", "page": 12, "quote": "The length_code shall indicate the length of the burst_payload in bits.", "tier": "sibling-standard", "note": "Professional bits unit agrees with AC-3/DTS secondary path, not E-AC-3. Consumer units remain secondary; unknown types are O16."}
# C21 {"doc": "smpte-st337-2015", "section": "7.2.5", "page": 12, "quote": "from 0 to 65,535 bits in the 16-bit mode", "tier": "sibling-standard", "note": "16-bit field range inferred as shared preamble structure under section 8.2; consumer E-AC-3 unit differs."}
# C25 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "/* a final lone byte has to be MSB aligned */", "tier": "secondary", "note": "Explicit odd-byte support, L666; consumer acceptance/alignment remains secondary."}
# C26 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "spdif_put_16(ctx, s->pb, ctx->out_buf[ctx->out_bytes - 1] << 8);", "tier": "secondary", "note": "L668: final byte high, low byte zero. ST337 cannot upgrade consumer odd-DTS tier."}
# C27 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ffio_fill(s->pb, 0, padding);", "tier": "secondary", "note": "L670: remaining fill zero; padding computed from pkt_offset and payload at L643."}
# C31 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "padding = (ctx->pkt_offset - ctx->use_preamble * BURST_HEADER_SIZE - ctx->out_bytes) & ~1;", "tier": "secondary", "note": "Padding preserves period for odd bytes (rounded word consumes missing byte); negative padding fails. Preamble-less exact fits are excluded by interface."}
def _burst(data_type: int, dtd: int, payload: bytes, length_code: int, period_frames: int) -> list[int]:
    if not 0 <= length_code <= 0xFFFF:
        raise BurstError("length_code does not fit in 16 bits")
    data = bytes(payload) + (b"\x00" if len(payload) % 2 else b"")
    words = [(data[i] << 8) | data[i + 1] for i in range(0, len(data), 2)]
    if len(words) % 2:
        words.append(0)  # last frame has two subframes; O14
    out = [_PA, _PB, _pc(data_type, dtd), length_code] + words
    total = 2 * period_frames
    if len(out) > total:
        raise BurstError("burst does not fit in its repetition period")
    out.extend([0] * (total - len(out)))
    return out


# C55 {"doc": "atsc-a52-2018", "section": "5.4", "page": 52, "quote": "Table 5.18 Frame Size Code Table (1 word = 16 bits) frmsizecod Nominal Bit Rate fs = 32 kHz fs = 44.1 kHz fs = 48 kHz words/syncframe words/syncframe words/syncframe ‘000000’ (0) 32 kbps 96 69 64 ‘000001’ (0) 32 kbps 96 70 64 ‘000010’ (1) 40 kbps 120 87 80 ‘000011’ (1) 40 kbps 120 88 80 ‘000100’ (2) 48 kbps 144 104 96 ‘000101’ (2) 48 kbps 144 105 96 ‘000110’ (3) 56 kbps 168 121 112 ‘000111’ (3) 56 kbps 168 122 112 ‘001000’ (4) 64 kbps 192 139 128 ‘001001’ (4) 64 kbps 192 140 128 ‘001010’ (5) 80 kbps 240 174 160 ‘001011’ (5) 80 kbps 240 175 160 ‘001100’ (6) 96 kbps 288 208 192 ‘001101’ (6) 96 kbps 288 209 192 ‘001110’ (7) 112 kbps 336 243 224 ‘001111’ (7) 112 kbps 336 244 224 ‘010000’ (8) 128 kbps 384 278 256 ‘010001’ (8) 128 kbps 384 279 256 ‘010010’ (9) 160 kbps 480 348 320 ‘010011’ (9) 160 kbps 480 349 320 ‘010100’ (10) 192 kbps 576 417 384 ‘010101’ (10) 192 kbps 576 418 384 ‘010110’ (11) 224 kbps 672 487 448 ‘010111’ (11) 224 kbps 672 488 448 ‘011000’ (12) 256 kbps 768 557 512 ‘011001’ (12) 256 kbps 768 558 512 ‘011010’ (13) 320 kbps 960 696 640 ‘011011’ (13) 320 kbps 960 697 640 ‘011100’ (14) 384 kbps 1152 835 768 ‘011101’ (14) 384 kbps 1152 836 768 ‘011110’ (15) 448 kbps 1344 975 896", "tier": "codec-spec", "note": "All low/mid-rate table rows including odd/even44.1k sizes; continuation is C56."}
# C56 {"doc": "atsc-a52-2018", "section": "5.4", "page": 53, "quote": "frmsizecod Nominal Bit Rate fs = 32 kHz fs = 44.1 kHz fs = 48 kHz words/syncframe words/syncframe words/syncframe ‘011111’ (15) 448 kbps 1344 976 896 ‘100000’ (16) 512 kbps 1536 1114 1024 ‘100001’ (16) 512 kbps 1536 1115 1024 ‘100010’ (17) 576 kbps 1728 1253 1152 ‘100011’ (17) 576 kbps 1728 1254 1152 ‘100100’ (18) 640 kbps 1920 1393 1280 ‘100101’ (18) 640 kbps 1920 1394 1280", "tier": "codec-spec", "note": "Table5.18 continuation/high-rate rows; the tables were not wholly on p.52."}
# Table 5.18: columns32k/44.1k/48k; 44.1k base rows plus odd/even increment.
_AC3_WORDS_48 = [64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 640, 768, 896, 1024, 1152, 1280]
_AC3_WORDS_32 = [96, 120, 144, 168, 192, 240, 288, 336, 384, 480, 576, 672, 768, 960, 1152, 1344, 1536, 1728, 1920]
_AC3_WORDS_441 = [69, 87, 104, 121, 139, 174, 208, 243, 278, 348, 417, 487, 557, 696, 835, 975, 1114, 1253, 1393]


# C52 {"doc": "atsc-a52-2018", "section": "5.3", "page": 31, "quote": "syncword 16 crc1 16 fscod 2 frmsizecod 6", "tier": "codec-spec", "note": "Printed clause5.3.1/Table5.1 within anchor5.3; header field positions."}
# C53 {"doc": "atsc-a52-2018", "section": "5.4", "page": 38, "quote": "The syncword is always 0x0B77, or ‘0000 1011 0111 0111’.", "tier": "codec-spec", "note": "Printed clause5.4.1.1; corpus p.38, printed p.20."}
# C54 {"doc": "atsc-a52-2018", "section": "5.4", "page": 38, "quote": "‘11’ reserved", "tier": "codec-spec", "note": "Table5.6 fscod reserved code; p.38 anchor, not printed p.20."}
# 8-byte guard is validation policy O15, not a normative header minimum.
def _ac3_size(frame: bytes) -> int:
    if len(frame) < 8 or frame[0] != 0x0B or frame[1] != 0x77:
        raise BurstError("not an AC-3 syncframe")
    fscod = frame[4] >> 6
    frmsizecod = frame[4] & 0x3F
    if fscod == 3 or frmsizecod > 37:
        raise BurstError("reserved fscod or frmsizecod")
    idx = frmsizecod >> 1
    if fscod == 0:
        words = _AC3_WORDS_48[idx]
    elif fscod == 2:
        words = _AC3_WORDS_32[idx]
    else:
        words = _AC3_WORDS_441[idx] + (frmsizecod & 1)
    return words * 2


# C41 {"doc": "smpte-st340-2015", "section": "4.3", "page": 5, "quote": "The Burst Payload of each AC-3 data burst shall contain one complete AC-3 Sync Frame.", "tier": "sibling-standard", "note": "Adopt same codec frame unit for consumer framing; FFmpeg AC-3 path corroborates, but ST337 section8.4 permits differences."}
# C46 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "int bitstream_mode = pkt->data[5] & 0x7;", "tier": "secondary", "note": "AC-3 bsmod extraction in byte5, lower three bits."}
# C47 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ctx->data_type = IEC61937_AC3 | (bitstream_mode << 8);", "tier": "secondary", "note": "Consumer dependent bits use bsmod; professional Reserved000 rule is not used."}
# C50 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ctx->length_code = FFALIGN(pkt->size, 2) << 3;", "tier": "secondary", "note": "Generic default bit length; AC-3 sizes are even. DTS core-size override C30 uses exact bytes; odd untrimmed FFmpeg default differs by eight bits (gap)."}
# C57 {"doc": "atsc-a52-2018", "section": "5.4", "page": 39, "quote": "decoders built to this standard shall mute if the value of bsid is greater than 8", "tier": "codec-spec", "note": "Printed5.4.2.1; AC-3 validation <=8. Annex E exception follows in source; >8 is not categorically E-AC-3."}
def ac3_burst(frame: bytes) -> list[int]:
    frame = bytes(frame)
    size = _ac3_size(frame)
    if len(frame) != size:
        raise BurstError("frame length differs from the length given by frmsizecod")
    bsid = frame[5] >> 3
    if bsid > 8:
        raise BurstError("bsid > 8: not an AC-3 syncframe")
    bsmod = frame[5] & 7
    return _burst(_DT_AC3, bsmod, frame, size * 8, _AC3_PERIOD)


@dataclass(frozen=True)
class _Eac3Info:
    strmtyp: int
    substreamid: int
    size: int
    numblks: int
    bsid: int


# C58 {"doc": "etsi-ts-102366", "section": "Annex-E", "page": 114, "quote": "syncword .................................................................................. 16 } /* end of syncinfo */ E.1.2.2 bsi - Bit stream information Syntax Word size bsi() { strmtyp .................................................................................... 2 substreamid ................................................................................ 3 frmsiz .................................................................................... 11 fscod ...................................................................................... 2 numblkscod ................................................................................. 2 acmod ...................................................................................... 3 lfeon ...................................................................................... 1 bsid ....................................................................................... 5", "tier": "codec-spec", "note": "Printed E.1.2.1/E.1.2.2 syntax: exact dots and word sizes, not a compressed invented quote."}
# C59 {"doc": "etsi-ts-102366", "section": "Annex-E", "page": 127, "quote": "The frmsiz field indicates a value one less than the overall size of the coded syncframe in 16-bit words.", "tier": "codec-spec", "note": "PrintedE.1.3.1.3: (frmsiz+1)*2 bytes."}
# C60 {"doc": "etsi-ts-102366", "section": "Annex-E", "page": 126, "quote": "Type 3: Reserved.", "tier": "codec-spec", "note": "PrintedE.1.3.1.1 stream-type validation."}
# C61 {"doc": "etsi-ts-102366", "section": "Annex-E", "page": 127, "quote": "00 1 block per syncframe 01 2 blocks per syncframe 10 3 blocks per syncframe 11 6 blocks per syncframe", "tier": "codec-spec", "note": "TableE.1.3 exact row cells: 1,2,3,6 blocks."}
# C62 {"doc": "etsi-ts-102366", "section": "Annex-E", "page": 127, "quote": "shall decode and reproduce audio if the value of bsid is 0 to 8, or 11 to 16.", "tier": "codec-spec", "note": "PrintedE.1.3.1.6: AC-3 0..8 excluded by E-AC-3 interface; E-AC-3 accepts11..16."}
# C63 {"doc": "atsc-a52-2018", "section": "2.3", "page": 161, "quote": "fscod2 – If the fscod field contains ‘11’ then the 2-bit fscod2 code shall indicate the reduced sample rate as shown in Table E2.3, and the number of blocks per syncframe shall be 6.", "tier": "codec-spec", "note": "Annex E printed2.3.1.5: ATSC reduced-rate branch, unlike ETSI p.127 reserved fscod3."}
# C64 {"doc": "atsc-a52-2018", "section": "2.3", "page": 161, "quote": "‘11’ reserved", "tier": "codec-spec", "note": "TableE2.3 fscod2 reserved; preserve ATSC profile handling."}
# 6-byte guard is validation policy O15. ATSC reduced-rate profile retained (G9).
def _eac3_info(frame: bytes) -> _Eac3Info:
    if len(frame) < 6 or frame[0] != 0x0B or frame[1] != 0x77:
        raise BurstError("not an E-AC-3 syncframe")
    strmtyp = frame[2] >> 6
    substreamid = (frame[2] >> 3) & 7
    frmsiz = ((frame[2] & 7) << 8) | frame[3]
    fscod = frame[4] >> 6
    numblkscod = (frame[4] >> 4) & 3
    bsid = frame[5] >> 3
    size = (frmsiz + 1) * 2
    if strmtyp == 3:
        raise BurstError("reserved stream type")
    if fscod == 3:
        if numblkscod == 3:
            raise BurstError("reserved fscod2")
        numblks = 6
    else:
        numblks = (1, 2, 3, 6)[numblkscod]
    if not 11 <= bsid <= 16:
        raise BurstError("bsid is not an E-AC-3 value")
    if len(frame) != size:
        raise BurstError("frame length differs from frmsiz")
    return _Eac3Info(strmtyp, substreamid, size, numblks, bsid)


def _is_indep0(i: _Eac3Info) -> bool:
    return i.strmtyp != 1 and i.substreamid == 0


# C48 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "static const uint8_t eac3_repeat[4] = {6, 3, 2, 1};", "tier": "secondary", "note": "Agrees with six-block grouping for single independent substream; does not settle multi-substream consumer grouping."}
# C65 {"doc": "smpte-st340-2015", "section": "5.3", "page": 10, "quote": "then the Burst Payload shall contain the number of Sync Frames needed to deliver six blocks of audio data from all substreams being carried in the bitstream.", "tier": "sibling-standard", "note": "Six-block grouping adopted because same E-AC-3 stream unit and single-substream FFmpeg agrees. Applicability to consumer multi-substream grouping not stated; retain as inference, not codec/consumer authority."}
# C67 {"doc": "etsi-ts-102366", "section": "Annex-J", "page": 240, "quote": "the number of Enhanced AC-3 syncframes required to deliver six blocks of audio data from every substream present, beginning with independent substream 0.", "tier": "codec-spec", "note": "PrintedJ.1.4.1 is ISOBMFF/CMAF sample storage ONLY. Context for retained O11; not authority for IEC grouping."}
# C68 {"doc": "etsi-ts-102366", "section": "Annex-E", "page": 126, "quote": "All Enhanced AC-3 bit streams shall contain an independent substream assigned substream ID 0. The independent substream assigned substream ID 0 shall be the first substream present in the bit stream.", "tier": "codec-spec", "note": "PrintedE.1.3.1.2 codec stream order; adopting this at every burst boundary is retained O11/sibling inference, not established consumer burst rule."}
# O11/G8: sibling grouping inference; Annex J citation explicitly is not IEC authority.
def eac3_group(frames: list[bytes]) -> list[list[int]]:
    groups: list[list[int]] = []
    cur: list[int] = []
    acc = 0
    for idx, fr in enumerate(frames):
        info = _eac3_info(bytes(fr))
        if cur and acc >= 6 and _is_indep0(info):
            groups.append(cur)
            cur, acc = [], 0
        cur.append(idx)
        if _is_indep0(info):
            acc += info.numblks
    if cur:
        groups.append(cur)
    return groups


# C44 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ctx->length_code = ctx->hd_buf_filled;", "tier": "secondary", "note": "Consumer E-AC-3 length bytes, unlike professional bits."}
# C45 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ctx->data_type = IEC61937_EAC3;", "tier": "secondary", "note": "No E-AC-3 dependent bits set."}
# C66 {"doc": "smpte-st340-2015", "section": "5.3", "page": 10, "quote": "the first Sync Frame in the data-burst is always the Sync Frame whose “Converter Synchronization Flag” flag is set to “1”", "tier": "sibling-standard", "note": "Professional first-frame condition; not validated here (G4). Consumer applicability unconfirmed."}
# C65/C68: independent0/six-block policy retained; convsync not parsed (G4).
def eac3_burst(frames: list[bytes]) -> list[int]:
    if not frames:
        raise BurstError("no frames")
    infos = [_eac3_info(bytes(f)) for f in frames]
    if not _is_indep0(infos[0]):
        raise BurstError("first frame of a burst must be independent substream 0")
    if sum(i.numblks for i in infos if _is_indep0(i)) != 6:
        raise BurstError("frames do not make up exactly six audio blocks of substream 0")
    payload = b"".join(bytes(f) for f in frames)
    return _burst(_DT_EAC3, 0, payload, len(payload), _EAC3_PERIOD)


# C22 {"doc": "etsi-ts-102114", "section": "5.4.2", "page": 25, "quote": "SYNC = ExtractBits(32); //0x7FFE8001 32 FTYPE = ExtractBits(1); 1 SHORT = ExtractBits(5); 5 CPF = ExtractBits(1); 1 NBLKS = ExtractBits(7); 7 FSIZE = ExtractBits(14); 14", "tier": "codec-spec", "note": "Table 5-1 exact syntax for sync and DTS header field widths/positions."}
# C23 {"doc": "etsi-ts-102114", "section": "5.4.2", "page": 26, "quote": "The actual core encoding window size is 32 × (NBLKS+1) PCM samples per channel. Valid range for NBLKS: 5 to 127.", "tier": "codec-spec", "note": "NBLKS semantics are p.26, not syntax p.25."}
# C24 {"doc": "etsi-ts-102114", "section": "5.4.2", "page": 26, "quote": "(FSIZE+1) is the total byte size of the current frame including primary audio data as well as any extension audio data. Valid range for FSIZE: 95 to 16 383. Invalid range for FSIZE: 0 to 94.", "tier": "codec-spec", "note": "Byte sizes 96..16384, no even restriction. Codec syntax alone does not prove IEC consumer carriage."}
# C28 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "/* discard extraneous data by default */", "tier": "secondary", "note": "Truncate excess bytes to FSIZE+1; short-frame rejection is retained validation policy."}
# C29 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ctx->pkt_offset = blocks << 7;", "tier": "secondary", "note": "DTS bytes per burst = (NBLKS+1)*128; divide by four for two 16-bit samples per interface frame."}
# C30 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "ctx->length_code = core_size << 3;", "tier": "secondary", "note": "DTS core byte count converted to bits; code is in truncation branch. Round1 policy uses exact FSIZE+1 bits, including odd frames; generic default rounds packet size to even (C50)."}
# C25-C27/C31: accept odd sizes with MSB-aligned final byte, zero fill, full period. 10-byte guard is O15.
def dts_burst(frame: bytes) -> list[int]:
    frame = bytes(frame)
    if len(frame) < 10 or frame[:4] != b"\x7f\xfe\x80\x01":
        raise BurstError("not a DTS core frame (16-bit big-endian)")
    nblks = (int.from_bytes(frame[4:6], "big") >> 2) & 0x7F
    fsize = (int.from_bytes(frame[5:8], "big") >> 4) & 0x3FFF
    if nblks < 5 or fsize < 95:
        raise BurstError("invalid NBLKS or FSIZE")
    samples = 32 * (nblks + 1)  # C23: codec sample-block formula.
    if samples not in _DT_DTS:
        raise BurstError("only 512/1024/2048-sample DTS core frames can be carried")
    size = fsize + 1  # C24: byte size, with no even-length restriction.
    if len(frame) < size:
        raise BurstError("frame shorter than FSIZE+1")
    payload = frame[:size]  # C28: secondary truncation policy (O9).
    period = samples
    if size > period * 4 - 8:
        raise BurstError("frame does not fit in the repetition period together with the preamble")
    return _burst(_DT_DTS[samples], 0, payload, size * 8, period)


@dataclass(frozen=True)
class Burst:
    offset: int                 # index (into the word list) of the burst's first preamble word
    data_type: int
    data_type_dependent: int
    error_flag: int
    bitstream_number: int
    length_code: int            # the raw value of the length word, unconverted
    payload: bytes              # exactly the payload bytes the burst carries (per the length code and its unit)


# C51 {"doc": "ffmpeg-spdif-n7.1/spdifenc", "section": "file", "page": 1, "quote": "* Pd - length code (number of bits or bytes of encapsuled frame - according to data_type)", "tier": "secondary", "note": "Units depend on type. Unknown types cannot be asserted to always use bits (O16)."}
# C11/C17-C21: decode frame-mode preambles; unknown-type bits unit is policy O16.
def parse_bursts(words: list[int]) -> list[Burst]:
    for w in words:
        if not isinstance(w, int) or isinstance(w, bool) or not 0 <= w <= 0xFFFF:
            raise BurstError("words must be 16-bit unsigned integers")
    out: list[Burst] = []
    n = len(words)
    i = 0
    while i + 1 < n:
        if i % 2 or words[i] != _PA or words[i + 1] != _PB:
            i += 1
            continue
        if i + 3 >= n:
            raise BurstError("truncated preamble")
        pc, pd = words[i + 2], words[i + 3]
        data_type = pc & 0x1F
        data_mode = (pc >> 5) & 3
        error = (pc >> 7) & 1
        dtd = (pc >> 8) & 0x1F
        stream = pc >> 13
        if data_mode != 0:
            raise BurstError("data_mode is not the 16-bit mode")
        if data_type == _DT_EXT:
            raise BurstError("six-word preamble is out of scope")
        if data_type == _DT_EAC3:
            nbytes = pd  # bytes: SECONDARY (O7)
        else:
            if pd % 8:
                raise BurstError("length_code is not a whole number of bytes")
            nbytes = pd // 8
        nwords = (nbytes + 1) // 2
        start = i + 4
        if start + nwords > n:
            raise BurstError("payload runs past the end of the word list")
        data = b"".join(w.to_bytes(2, "big") for w in words[start:start + nwords])[:nbytes]
        out.append(Burst(i, data_type, dtd, error, stream, pd, data))
        i = start + nwords + (nwords % 2)
    return out
