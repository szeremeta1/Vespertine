"""vblind_ref: reference implementation of the vblind interface (DoP 1.1 and IEC 61937 bursts, two-channel
consumer interface, 16-bit frame mode, stream 0, AC-3 / E-AC-3 / DTS core).

Built only from the corpus in this room.  Citation form in comments:
    # [doc-id §section p.N] "short verbatim quote"  (tier)
Tiers: primary (dop-1.1), primary-preview (IEC previews: titles only), sibling-standard (SMPTE ST 337/338/340),
codec-spec (A/52, TS 102 366, TS 102 114), SECONDARY (FFmpeg n7.1: an implementation, not a specification).

OPEN CHOICES (the corpus allows more than one behaviour, or is silent and a choice had to be made)
 O1  dop_pack with an empty channel list raises DoPError; with channels of length 0 it returns [] (nothing to
     represent).  dop_unpack([]) raises DoPError (no marker, no channel count: nothing identifies DSD).
 O2  dop_unpack does not require the 32 consecutive markers that dop-1.1 §4 describes for a *receiver* switching
     modes ("recommended implementation"); any run of valid alternating-marker frames is accepted.
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
     "discard extraneous data"); shorter than FSIZE+1, odd length, or FSIZE+1 > period*4-8 bytes -> BurstError.
     A frame of exactly period*4 bytes (FFmpeg sends it without preamble) is refused: it is not a data burst.
 O10 AC-3: bsid must be <= 8 (A/52 §5.4.2.1); frame length must equal the Table 5.18 size exactly.
 O11 E-AC-3 grouping is by audio-block count of independent substream 0 (6 blocks), not FFmpeg's frame count;
     a trailing incomplete group is still returned by eac3_group (covers every frame) but eac3_burst refuses it.
 O12 fscod==3 E-AC-3 frames (fscod2, reduced rate, 6 blocks per A/52 Annex E) are accepted as 6-block frames.
 O13 parse_bursts: only Pa at an even word index (Ch1 subframe) counts as a burst start; unmatched words between
     bursts are ignored (stuffing); data_mode != 0, data_type 31 (six-word preamble), a length that is not a whole
     number of bytes, or a payload running past the end of the list -> BurstError.  Pause/null/other data types
     are parsed generically (bits unit).  Non-zero stuffing is not an error.
 O14 Fill after a burst is all zero words; padding word after an odd payload word count is zero.

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
"""
from __future__ import annotations

from dataclasses import dataclass


class DoPError(ValueError):
    """Raised for input that cannot be packed, or a PCM stream that is not valid DoP."""


class BurstError(ValueError):
    """Raised for input that cannot be framed, or a word stream that cannot be parsed."""


# --------------------------------------------------------------------------------------------------- DoP

# [dop-1.1 p.2 §2] "alternate with each sample between 0x05 and 0xFA" (primary)
_DOP_MARKERS = (0x05, 0xFA)


def dop_pack(dsd: list[bytes], first_marker: int = 0x05) -> list[list[int]]:
    # [dop-1.1 §2 p.2] "The remaining 16 lower bits are then used for the DSD data, first or oldest bit in slot
    #   t0" (primary): word = marker<<16 | byte0<<8 | byte1 (24-bit PCM frame, marker in the 8 MSbits).
    # [dop-1.1 §2 p.2] "Each channel within a sample contains the same marker." (primary)
    # [dop-1.1 §2 p.2] "each PCM Frame contains only DSD data corresponding to its assigned channel" (primary)
    if first_marker not in _DOP_MARKERS or isinstance(first_marker, bool):
        # [dop-1.1 §3 p.2] "A different marker byte is used to distinguish this method from the first one."
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
        # [dop-1.1 §2 p.2] "16 DSD Audio bits for 1 channel": a PCM frame holds exactly 16 bits per channel (O3)
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
                # [dop-1.1 §2 p.2] "24 bit PCM Frame" (primary)
                raise DoPError("PCM word is not a 24-bit value")
            m = w >> 16
            if marker is None:
                marker = m
            elif m != marker:
                # [dop-1.1 §2 p.2] "Each channel within a sample contains the same marker."
                raise DoPError("markers differ between channels")
            out[c].append((w >> 8) & 0xFF)
            out[c].append(w & 0xFF)
        if i == 0:
            if marker not in _DOP_MARKERS:
                raise DoPError("first marker is neither 0x05 nor 0xFA")
            first_marker = marker
        else:
            # [dop-1.1 §2 p.2] "alternate with each sample between 0x05 and 0xFA"
            expect = first_marker if i % 2 == 0 else (0xFA if first_marker == 0x05 else 0x05)
            if marker != expect:
                raise DoPError("marker does not alternate")
    return [bytes(b) for b in out], first_marker


# ---------------------------------------------------------------------------------------------- IEC 61937

# [ffmpeg-spdif-n7.1/spdif file] "#define SYNCWORD1 0xF872" / "#define SYNCWORD2 0x4E1F" (SECONDARY)
# [smpte-st337-2015 §7.2.1 p.9] "= 0xF872 (16-bit mode)" Pa and "= 0x4E1F (16-bit mode)" Pb (sibling-standard;
#   §8.2 p.14 "The consumer bit stream format can, in general, be considered a subset of the professional bit
#   stream format" is what makes the sibling's 16-bit sync words carry over)
_PA = 0xF872
_PB = 0x4E1F

# data_type numbers.  [smpte-st338-2016 §4 p.4] Table 1 "IEC 61937-2 allocation (informative)" column:
#   AC-3 "1 AC-3 (audio) data ... Same data"; "DTS type I/II/III" on rows 11/12/13; row 21 "Enhanced AC-3 / Reserved
#   (depends on IEC 61937-2 sub data-type)" (sibling-standard, informative consumer allocation)
# [ffmpeg-spdif-n7.1/spdif file] "IEC61937_AC3 = 0x01", "IEC61937_DTS1 = 0x0B", "IEC61937_DTS2 = 0x0C",
#   "IEC61937_DTS3 = 0x0D", "IEC61937_EAC3 = 0x15" (SECONDARY)
# [iec61937-3-preview p.2 contents] "Data-type-dependent information when data-type bits 0-4 = 21 and data-" (the
#   E-AC-3 table is keyed on data-type 21) (primary-preview)
_DT_AC3 = 1
_DT_DTS = {512: 11, 1024: 12, 2048: 13}
_DT_EAC3 = 21
_DT_EXT = 31

# Pc layout, 16-bit mode.  [smpte-st337-2015 §7.2.4.1 p.10] Table 7, 16-bit column: "0-4 data_type", "5-6
#   data_mode", "7 error_flag", "8-12 data_type_dependent", "13-15 data_stream_number" (sibling-standard; same
#   layout in FFmpeg spdifenc header comment "data-type (bits 0-6), error flag (bit 7), data-type-dependent info
#   (bits 8-12) and bitstream number (bits 13-15)" SECONDARY)
# [smpte-st337-2015 §8.3 p.14] "all data bursts are restricted to the 16-bit frame mode (data_mode=0, both AES3-3
#   subframes used)" (sibling-standard, informative consumer compatibility; scope = frame mode, 16 bit)


def _pc(data_type: int, dtd: int = 0, error: int = 0, stream: int = 0) -> int:
    return data_type | (0 << 5) | (error << 7) | (dtd << 8) | (stream << 13)


# Repetition periods in IEC 60958 frames.
# AC-3: [smpte-st340-2015 §4.6 p.6] "occur 1536 AES3 frames apart" (sibling; consumer carry-over: the same
#   1536-sample sync frame; FFmpeg "ctx->pkt_offset = AC3_FRAME_SIZE << 2" = 6144 bytes = 1536 frames SECONDARY)
_AC3_PERIOD = 1536
# E-AC-3: [ffmpeg-spdif-n7.1/spdifenc file] "ctx->pkt_offset  = 24576;" (bytes; /4 = 6144 frames) SECONDARY (O8)
_EAC3_PERIOD = 6144
# DTS: [ffmpeg-spdif-n7.1/spdifenc file] "ctx->pkt_offset = blocks << 7;" (bytes; blocks=NBLKS+1 -> frames =
#   blocks*32 = samples per frame) SECONDARY

# [ffmpeg-spdif-n7.1/spdifenc file] "#define BURST_HEADER_SIZE 0x8" (4 words = 8 bytes) SECONDARY;
#   [smpte-st337-2015 §7.2.2 p.9] "The 4 preamble words shall be contained in 2 sequential frames."
_PREAMBLE_WORDS = 4


def _burst(data_type: int, dtd: int, payload: bytes, length_code: int, period_frames: int) -> list[int]:
    if not 0 <= length_code <= 0xFFFF:
        # [smpte-st337-2015 §7.2.5 p.12] "from 0 to 65,535 bits in the 16-bit mode"
        raise BurstError("length_code does not fit in 16 bits")
    # [smpte-st337-2015 §7.3.1 p.12] "the first bit of the first data word of the payload in a burst shall occupy
    #   the MSB bit position of subframe 1 ... Any unused bits in the last frame shall be set to 0." (sibling)
    # [ffmpeg-spdif-n7.1/spdifenc file] "a final lone byte has to be MSB aligned" (SECONDARY)
    # Payload bytes are packed big-endian into 16-bit words (the stream byte order of the interface docstring).
    data = bytes(payload) + (b"\x00" if len(payload) % 2 else b"")
    words = [(data[i] << 8) | data[i + 1] for i in range(0, len(data), 2)]
    if len(words) % 2:
        words.append(0)  # last frame has two subframes; O14
    out = [_PA, _PB, _pc(data_type, dtd), length_code] + words
    total = 2 * period_frames
    if len(out) > total:
        raise BurstError("burst does not fit in its repetition period")
    # [smpte-st340-2015 §4.1 p.4] "enough padding words are appended to it to make the resulting data burst
    #   duration exactly match" ; [smpte-st337-2015 §7.4 p.13] zero subframes before the next preamble (sibling)
    out.extend([0] * (total - len(out)))
    return out


# --- AC-3 -----------------------------------------------------------------------------------------------

# [atsc-a52-2018 p.52 Table 5.18] words/syncframe for fscod 0 (48k), 1 (44.1k), 2 (32k); index = frmsizecod>>1
# for 48 and 32 kHz; 44.1 kHz uses the odd/even frmsizecod rows ("'000000' (0) 69 / '000001' (0) 70")
_AC3_WORDS_48 = [64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 640, 768, 896, 1024, 1152, 1280]
_AC3_WORDS_32 = [96, 120, 144, 168, 192, 240, 288, 336, 384, 480, 576, 672, 768, 960, 1152, 1344, 1536, 1728, 1920]
_AC3_WORDS_441 = [69, 87, 104, 121, 139, 174, 208, 243, 278, 348, 417, 487, 557, 696, 835, 975, 1114, 1253, 1393]


def _ac3_size(frame: bytes) -> int:
    # [atsc-a52-2018 p.31 Table 5.1] syncinfo: "syncword 16, crc1 16, fscod 2, frmsizecod 6"
    # [atsc-a52-2018 §5.4.1.1] "The syncword is always 0x0B77" (codec-spec)
    if len(frame) < 8 or frame[0] != 0x0B or frame[1] != 0x77:
        raise BurstError("not an AC-3 syncframe")
    fscod = frame[4] >> 6
    frmsizecod = frame[4] & 0x3F
    # [atsc-a52-2018 p.20 Table 5.6] "'11' reserved"
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


def ac3_burst(frame: bytes) -> list[int]:
    frame = bytes(frame)
    size = _ac3_size(frame)
    if len(frame) != size:
        raise BurstError("frame length differs from the length given by frmsizecod")
    # [atsc-a52-2018 p.39 §5.4.2.1] "decoders built to this standard shall mute if the value of bsid is greater
    #   than 8" (codec-spec) -> bsid <= 8 is AC-3; larger values are E-AC-3 (E.1.3.1.6)  (O10)
    bsid = frame[5] >> 3
    if bsid > 8:
        raise BurstError("bsid > 8: not an AC-3 syncframe")
    # [atsc-a52-2018 p.39 §5.4.2.2] bsmod is the 3 bits after bsid (syncword 2 + crc1 2 + fscod/frmsizecod 1 =
    #   bytes 0-4; bsid 5 bits, bsmod 3 bits = byte 5)
    # [ffmpeg-spdif-n7.1/spdifenc file] "int bitstream_mode = pkt->data[5] & 0x7;" "ctx->data_type =
    #   IEC61937_AC3 | (bitstream_mode << 8);" (SECONDARY; O5)
    bsmod = frame[5] & 7
    # [smpte-st340-2015 §4.3 p.5] "The Burst Payload of each AC-3 data burst shall contain one complete AC-3 Sync
    #   Frame." (sibling)
    # [smpte-st337-2015 §7.2.5 p.12] length_code = payload length "in bits" (sibling); FFmpeg
    #   "ctx->length_code = FFALIGN(pkt->size, 2) << 3;" (SECONDARY)
    return _burst(_DT_AC3, bsmod, frame, size * 8, _AC3_PERIOD)


# --- E-AC-3 ---------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class _Eac3Info:
    strmtyp: int
    substreamid: int
    size: int
    numblks: int
    bsid: int


def _eac3_info(frame: bytes) -> _Eac3Info:
    # [etsi-ts-102366 p.114 §E.1.2.1/E.1.2.2] "syncword 16" then bsi: "strmtyp 2, substreamid 3, frmsiz 11,
    #   fscod 2, numblkscod 2, acmod 3, lfeon 1, bsid 5" (codec-spec)
    if len(frame) < 6 or frame[0] != 0x0B or frame[1] != 0x77:
        raise BurstError("not an E-AC-3 syncframe")
    strmtyp = frame[2] >> 6
    substreamid = (frame[2] >> 3) & 7
    frmsiz = ((frame[2] & 7) << 8) | frame[3]
    fscod = frame[4] >> 6
    numblkscod = (frame[4] >> 4) & 3
    bsid = frame[5] >> 3
    # [etsi-ts-102366 p.127 §E.1.3.1.3] "a value one less than the overall size of the coded syncframe in 16-bit
    #   words"
    size = (frmsiz + 1) * 2
    if strmtyp == 3:
        # [etsi-ts-102366 §E.1.3.1.1] "Type 3: Reserved."
        raise BurstError("reserved stream type")
    if fscod == 3:
        # [atsc-a52-2018 p.161 E2.3.1.5] "If the fscod field contains '11' ... the number of blocks per syncframe
        #   shall be 6" (O12); fscod2 '11' reserved
        if numblkscod == 3:
            raise BurstError("reserved fscod2")
        numblks = 6
    else:
        # [etsi-ts-102366 p.127 Table E.1.3] "00 1 block ... 01 2 blocks ... 10 3 blocks ... 11 6 blocks"
        numblks = (1, 2, 3, 6)[numblkscod]
    # [etsi-ts-102366 p.127 §E.1.3.1.6] "shall decode ... if the value of bsid is 0 to 8, or 11 to 16"; AC-3
    #   (0..8) is not an E-AC-3 frame here, 9/10 and >16 mute.
    if not 11 <= bsid <= 16:
        raise BurstError("bsid is not an E-AC-3 value")
    if len(frame) != size:
        raise BurstError("frame length differs from frmsiz")
    return _Eac3Info(strmtyp, substreamid, size, numblks, bsid)


def _is_indep0(i: _Eac3Info) -> bool:
    return i.strmtyp != 1 and i.substreamid == 0


def eac3_group(frames: list[bytes]) -> list[list[int]]:
    # [smpte-st340-2015 §5.3 p.9-10] "the Burst Payload shall contain the number of Sync Frames needed to deliver
    #   six blocks of audio data from all substreams being carried in the bitstream" (sibling; this is a property
    #   of the A/52 stream, same for the consumer format)
    # [etsi-ts-102366 p.241 §J.1.4.1] "the number of Enhanced AC-3 syncframes required to deliver six blocks of
    #   audio data from every substream present, beginning with independent substream 0" (codec-spec)
    # [ffmpeg-spdif-n7.1/spdifenc file] "static const uint8_t eac3_repeat[4] = {6, 3, 2, 1};" (SECONDARY; agrees
    #   for single-substream streams)  (O11)
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


def eac3_burst(frames: list[bytes]) -> list[int]:
    if not frames:
        raise BurstError("no frames")
    infos = [_eac3_info(bytes(f)) for f in frames]
    if not _is_indep0(infos[0]):
        # [smpte-st340-2015 §5.3 p.10] "the first Sync Frame in the data-burst is always the Sync Frame whose
        #   'Converter Synchronization Flag' flag is set" ; [etsi-ts-102366 p.241 §J.1.4.1] first syncframe has
        #   "a stream type value of 0 (independent); and a substream ID value of 0" (G4: convsync not checked)
        raise BurstError("first frame of a burst must be independent substream 0")
    if sum(i.numblks for i in infos if _is_indep0(i)) != 6:
        # [smpte-st340-2015 §5.3 p.10] six blocks per burst payload
        raise BurstError("frames do not make up exactly six audio blocks of substream 0")
    payload = b"".join(bytes(f) for f in frames)
    # [ffmpeg-spdif-n7.1/spdifenc file] "ctx->length_code = ctx->hd_buf_filled;" bytes (SECONDARY; O7);
    #   "ctx->data_type = IEC61937_EAC3;" (SECONDARY; O6)
    return _burst(_DT_EAC3, 0, payload, len(payload), _EAC3_PERIOD)


# --- DTS ------------------------------------------------------------------------------------------------

def dts_burst(frame: bytes) -> list[int]:
    frame = bytes(frame)
    # [etsi-ts-102114 §5.4.2 p.25] Table 5-1: "SYNC 32, FTYPE 1, SHORT 5, CPF 1, NBLKS 7, FSIZE 14" and "For a
    #   core substream, the sync word is 0x7ffe8001" (codec-spec); 16-bit big-endian form per the interface.
    if len(frame) < 10 or frame[:4] != b"\x7f\xfe\x80\x01":
        raise BurstError("not a DTS core frame (16-bit big-endian)")
    # FTYPE(1) SHORT(5) CPF(1) NBLKS(7) FSIZE(14) follow the 32-bit sync: NBLKS = bits 8..2 of the next 16 bits,
    # FSIZE = the following 14 bits (agrees with FFmpeg "(AV_RB16(pkt->data + 4) >> 2) & 0x7f" SECONDARY)
    nblks = (int.from_bytes(frame[4:6], "big") >> 2) & 0x7F
    fsize = (int.from_bytes(frame[5:8], "big") >> 4) & 0x3FFF
    # [etsi-ts-102114 §5.4.2 p.25] "Valid range for NBLKS: 5 to 127" ; "Valid range for FSIZE: 95 to 16 383"
    if nblks < 5 or fsize < 95:
        raise BurstError("invalid NBLKS or FSIZE")
    samples = 32 * (nblks + 1)  # "(NBLKS+1) blocks (a block = 32 PCM core samples per channel"
    if samples not in _DT_DTS:
        # [ffmpeg-spdif-n7.1/spdifenc file] "%i samples in DTS frame not supported" (SECONDARY);
        # [smpte-st338-2016 §4 p.4] only DTS type I/II/III (512/1024/2048) are in scope (SCOPE.md)
        raise BurstError("only 512/1024/2048-sample DTS core frames can be carried")
    size = fsize + 1  # "(FSIZE+1) is the total byte size of the current frame"
    if len(frame) < size:
        raise BurstError("frame shorter than FSIZE+1")
    payload = frame[:size]  # SECONDARY "discard extraneous data by default" (O9)
    if size % 2:
        raise BurstError("odd DTS frame size cannot be packed in 16-bit words")
    period = samples
    if size > period * 4 - 8:
        # [ffmpeg-spdif-n7.1/spdifenc file] "padding < 0 -> bitrate is too high"; exactly period*4 bytes would be
        #   sent without preamble ("skip the preamble as it would not fit"): not a data burst (O9)
        raise BurstError("frame does not fit in the repetition period together with the preamble")
    # [ffmpeg-spdif-n7.1/spdifenc file] "ctx->length_code = core_size << 3;" bits (SECONDARY); ST 337 §7.2.5 bits
    return _burst(_DT_DTS[samples], 0, payload, size * 8, period)


# --- parsing --------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Burst:
    offset: int                 # index (into the word list) of the burst's first preamble word
    data_type: int
    data_type_dependent: int
    error_flag: int
    bitstream_number: int
    length_code: int            # the raw value of the length word, unconverted
    payload: bytes              # exactly the payload bytes the burst carries (per the length code and its unit)


def parse_bursts(words: list[int]) -> list[Burst]:
    for w in words:
        if not isinstance(w, int) or isinstance(w, bool) or not 0 <= w <= 0xFFFF:
            raise BurstError("words must be 16-bit unsigned integers")
    out: list[Burst] = []
    n = len(words)
    i = 0
    while i + 1 < n:
        # [smpte-st337-2015 §7.2.2 p.9] "The frame beginning the data burst shall contain preamble word Pa in the
        #   Ch1 subframe, and Pb in the Ch2 subframe." -> Pa at an even index (O13)
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
            # [smpte-st337-2015 §7.2.4.3 p.11] Table 8: "0 16-bit mode", 1/2 are 20/24-bit, 3 reserved (out of scope)
            raise BurstError("data_mode is not the 16-bit mode")
        if data_type == _DT_EXT:
            # [smpte-st337-2015 §7.2.1 p.9] "The six subframe version shall be used when data_type has the value 31"
            raise BurstError("six-word preamble is out of scope")
        if data_type == _DT_EAC3:
            nbytes = pd  # bytes: SECONDARY (O7)
        else:
            if pd % 8:
                # [smpte-st337-2015 §7.2.5 p.12] "The length_code shall indicate the length of the burst_payload in
                #   bits"; a payload is a whole number of bytes here
                raise BurstError("length_code is not a whole number of bytes")
            nbytes = pd // 8
        nwords = (nbytes + 1) // 2
        start = i + 4
        if start + nwords > n:
            raise BurstError("payload runs past the end of the word list")
        data = b"".join(w.to_bytes(2, "big") for w in words[start:start + nwords])[:nbytes]
        out.append(Burst(i, data_type, dtd, error, stream, pd, data))
        # next search position: after the payload frames (payload occupies whole frames, 2 words each)
        i = start + nwords + (nwords % 2)
    return out
