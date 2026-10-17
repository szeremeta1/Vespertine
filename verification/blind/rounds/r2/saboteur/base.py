"""Corpus-derived baseline. Evidence tiers and deliberate policy choices: SABOTEURS.md.
No external dependencies, I/O, shared mutation, or compressed-audio decoding.
"""
from __future__ import annotations
from dataclasses import dataclass
from types import FunctionType

class DoPError(ValueError):
    pass

class BurstError(ValueError):
    pass

# [dop-1.1 §2 p.2] "0x05 and 0xFA. Each channel within a sample contains the same marker."
DOP_MARKERS = (0x05, 0xFA)

# [dop-1.1 §2 p.1] "24 bits at a sample rate of 176.4kHz."
# [dop-1.1 §2 p.2] "The remaining 16 lower bits are then used for the DSD data, first or oldest bit in slot t0."
def dop_layout():
    return 24, 16

# [dop-1.1 §2 p.2] "The 8 most significant bits are used for the DSD marker and alternate with each sample between 0x05 and 0xFA."
def dop_marker(first, index, decode=False):
    if first not in DOP_MARKERS:
        raise DoPError("invalid marker")
    return DOP_MARKERS[(DOP_MARKERS.index(first) + index) % len(DOP_MARKERS)]

# [dop-1.1 §2 p.2] "The remaining 16 lower bits are then used for the DSD data, first or oldest bit in slot t0."
def dop_data(value, decode=False):
    return value.to_bytes(2, "big") if decode else int.from_bytes(value, "big")

def dop_pack(dsd: list[bytes], first_marker: int = 0x05) -> list[list[int]]:
    dop_marker(first_marker, 0)
    if not dsd or any(not isinstance(c, bytes) for c in dsd):
        raise DoPError("at least one bytes channel required")
    n = len(dsd[0])
    if n == 0 or n % 2 or any(len(c) != n for c in dsd):
        raise DoPError("equal channel lengths and whole DSD words required")
    _, shift = dop_layout()
    return [[(dop_marker(first_marker, i // 2) << shift) | dop_data(c[i:i+2])
             for c in dsd] for i in range(0, n, 2)]

def dop_unpack(frames: list[list[int]]) -> tuple[list[bytes], int]:
    if not frames or not frames[0]:
        raise DoPError("empty stream has no recoverable channel count or phase")
    width, shift = dop_layout()
    channels = [bytearray() for _ in frames[0]]
    raw_first = frames[0][0] >> shift
    first = dop_marker(raw_first, 0, decode=True)
    for i, row in enumerate(frames):
        if len(row) != len(channels):
            raise DoPError("channel count changed")
        marker = dop_marker(first, i)
        for channel, word in zip(channels, row):
            if not isinstance(word, int) or not 0 <= word < (1 << width):
                raise DoPError("sample outside word width")
            if word >> shift != marker:
                raise DoPError("inconsistent or nonalternating marker")
            channel.extend(dop_data(word & ((1 << shift) - 1), decode=True))
    return [bytes(c) for c in channels], first

# [ffmpeg-spdif-n7.1/spdif §file p.1] "#define SYNCWORD1 0xF872"
# [ffmpeg-spdif-n7.1/spdif §file p.1] "#define SYNCWORD2 0x4E1F"
SYNC_WORDS = (0xF872, 0x4E1F)

# [ffmpeg-spdif-n7.1/spdif §file p.1] "IEC61937_AC3                = 0x01,          ///< AC-3 data"
# [ffmpeg-spdif-n7.1/spdif §file p.1] "IEC61937_EAC3               = 0x15,          ///< E-AC-3 data"
# [ffmpeg-spdif-n7.1/spdif §file p.1] "IEC61937_DTS1               = 0x0B,          ///< DTS type I   (512 samples)"
# [ffmpeg-spdif-n7.1/spdif §file p.1] "IEC61937_DTS2               = 0x0C,          ///< DTS type II  (1024 samples)"
# [ffmpeg-spdif-n7.1/spdif §file p.1] "IEC61937_DTS3               = 0x0D,          ///< DTS type III (2048 samples)"
def data_type(kind, decode=False):
    return {"ac3": 0x01, "eac3": 0x15, "dts512": 0x0B,
            "dts1024": 0x0C, "dts2048": 0x0D}[kind]

# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "Pc - burst-info, contains data-type (bits 0-6), error flag (bit 7), data-type-dependent info (bits 8-12)"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "and bitstream number (bits 13-15)"
def pc_fields(value=None, *, kind=None, dependent=0):
    if value is None:
        return data_type(kind) | (dependent << 8)
    return value & 0x7F, (value >> 8) & 0x1F, (value >> 7) & 1, (value >> 13) & 7

# [smpte-st337-2015 §7.2.5 p.12] "The length_code shall indicate the length of the burst_payload in bits."
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ctx->length_code = ctx->hd_buf_filled;"
def length_code(kind, size, decode=False):
    unit = 1 if kind == "eac3" else 8
    if decode:
        if size <= 0 or size % unit:
            raise BurstError("empty or non-byte-aligned payload")
        return size // unit
    return size * unit

# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ctx->pkt_offset = AC3_FRAME_SIZE << 2;"
# [smpte-st340-2015 §4.1 p.4] "A Sync Frame begins with a sync word and contains 1536"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ctx->pkt_offset  = 24576;"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ctx->pkt_offset = blocks << 7;"
def burst_period(kind):
    return {"ac3": 1536, "eac3": 6144, "dts512": 512,
            "dts1024": 1024, "dts2048": 2048}[kind]

# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ffio_fill(s->pb, 0, padding);"
def burst_fill(count):
    return [0] * count

# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "ff_spdif_bswap_buf16((uint16_t *)ctx->buffer, (const uint16_t *)ctx->out_buf, ctx->out_bytes >> 1);"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "/* a final lone byte has to be MSB aligned */"
def payload_words(payload):
    return [int.from_bytes(payload[i:i+2].ljust(2, b"\0"), "big")
            for i in range(0, len(payload), 2)]

# [smpte-st337-2015 §7.2.2 p.9] "The next frame shall contain Pc in Ch1 and Pd in Ch2."
def make_burst(kind, payload, dependent=0):
    words = [*SYNC_WORDS, pc_fields(kind=kind, dependent=dependent),
             length_code(kind, len(payload)), *payload_words(payload)]
    count = burst_period(kind) * 2 - len(words)
    if count < 0 or not 0 <= words[3] <= 0xFFFF:
        raise BurstError("payload exceeds burst capacity")
    return words + burst_fill(count)

# [etsi-ts-102366 §4.4.0 p.32] "The syncword is always 0x0B77, or 0000 1011 0111 0111."
AC_SYNC = b"\x0b\x77"

# [etsi-ts-102366 §4.4.4.0 p.45] "Table 4.13: Frame size code table (1 word = 16 bits)"
# [etsi-ts-102366 §4.4.4.0 p.45] "000000 (0)                32                       96                     69                       64"
# [etsi-ts-102366 §4.4.4.0 p.46] "100101 (18)              640                       1 920                    1 394                    1 280"
# [etsi-ts-102366 §4.4.4.0 p.45] "000000 (0)                32                       96                     69                       64"
# [etsi-ts-102366 §4.4.4.0 p.45] "000001 (0)                32                       96                     70                       64"
# [etsi-ts-102366 §4.4.4.0 p.45] "000010 (1)                40                      120                     87                       80"
# [etsi-ts-102366 §4.4.4.0 p.45] "000011 (1)                40                      120                     88                       80"
# [etsi-ts-102366 §4.4.4.0 p.45] "000100 (2)                48                      144                    104                       96"
# [etsi-ts-102366 §4.4.4.0 p.45] "000101 (2)                48                      144                    105                       96"
# [etsi-ts-102366 §4.4.4.0 p.45] "000110 (3)                56                      168                    121                      112"
# [etsi-ts-102366 §4.4.4.0 p.45] "000111 (3)                56                      168                    122                      112"
# [etsi-ts-102366 §4.4.4.0 p.45] "001000 (4)                64                      192                    139                      128"
# [etsi-ts-102366 §4.4.4.0 p.45] "001001 (4)                64                      192                    140                      128"
# [etsi-ts-102366 §4.4.4.0 p.45] "001010 (5)                80                      240                    174                      160"
# [etsi-ts-102366 §4.4.4.0 p.45] "001011 (5)                80                      240                    175                      160"
# [etsi-ts-102366 §4.4.4.0 p.45] "001100 (6)                96                      288                    208                      192"
# [etsi-ts-102366 §4.4.4.0 p.45] "001101 (6)                96                      288                    209                      192"
# [etsi-ts-102366 §4.4.4.0 p.45] "001110 (7)               112                      336                    243                      224"
# [etsi-ts-102366 §4.4.4.0 p.45] "001111 (7)               112                      336                    244                      224"
# [etsi-ts-102366 §4.4.4.0 p.45] "010000 (8)               128                      384                    278                      256"
# [etsi-ts-102366 §4.4.4.0 p.45] "010001 (8)               128                      384                    279                      256"
# [etsi-ts-102366 §4.4.4.0 p.45] "010010 (9)               160                      480                    348                      320"
# [etsi-ts-102366 §4.4.4.0 p.45] "010011 (9)               160                      480                    349                      320"
# [etsi-ts-102366 §4.4.4.0 p.45] "010100 (10)               192                      576                    417                      384"
# [etsi-ts-102366 §4.4.4.0 p.45] "010101 (10)               192                      576                    418                      384"
# [etsi-ts-102366 §4.4.4.0 p.45] "010110 (11)               224                      672                    487                      448"
# [etsi-ts-102366 §4.4.4.0 p.46] "010111 (11)              224                        672                      488                      448"
# [etsi-ts-102366 §4.4.4.0 p.46] "011000 (12)              256                        768                      557                      512"
# [etsi-ts-102366 §4.4.4.0 p.46] "011001 (12)              256                        768                      558                      512"
# [etsi-ts-102366 §4.4.4.0 p.46] "011010 (13)              320                        960                      696                      640"
# [etsi-ts-102366 §4.4.4.0 p.46] "011011 (13)              320                        960                      697                      640"
# [etsi-ts-102366 §4.4.4.0 p.46] "011100 (14)              384                       1 152                     835                      768"
# [etsi-ts-102366 §4.4.4.0 p.46] "011101 (14)              384                       1 152                     836                      768"
# [etsi-ts-102366 §4.4.4.0 p.46] "011110 (15)              448                       1 344                     975                      896"
# [etsi-ts-102366 §4.4.4.0 p.46] "011111 (15)              448                       1 344                     976                      896"
# [etsi-ts-102366 §4.4.4.0 p.46] "100000 (16)              512                       1 536                    1 114                    1 024"
# [etsi-ts-102366 §4.4.4.0 p.46] "100001 (16)              512                       1 536                    1 115                    1 024"
# [etsi-ts-102366 §4.4.4.0 p.46] "100010 (17)              576                       1 728                    1 253                    1 152"
# [etsi-ts-102366 §4.4.4.0 p.46] "100011 (17)              576                       1 728                    1 254                    1 152"
# [etsi-ts-102366 §4.4.4.0 p.46] "100100 (18)              640                       1 920                    1 393                    1 280"
# [etsi-ts-102366 §4.4.4.0 p.46] "100101 (18)              640                       1 920                    1 394                    1 280"
def ac3_size(fscod, code):
    rates = (32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640)
    words441 = (69, 87, 104, 121, 139, 174, 208, 243, 278, 348, 417, 487, 557, 696, 835, 975, 1114, 1253, 1393)
    if fscod not in (0, 1, 2) or not 0 <= code < 38:
        raise BurstError("reserved AC-3 size code")
    rate = rates[code // 2]
    return 2 * (rate * 2 if fscod == 0 else
                words441[code // 2] + code % 2 if fscod == 1 else rate * 3)

# [etsi-ts-102366 §4.3.0 p.28] "bsid ....................................................................................... 5"
# [etsi-ts-102366 §4.3.0 p.28] "bsmod ...................................................................................... 3"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "int bitstream_mode = pkt->data[5] & 0x7;"
def ac3_header(frame):
    if not isinstance(frame, bytes) or len(frame) < 6 or frame[:2] != AC_SYNC:
        raise BurstError("invalid AC-3 header")
    if frame[5] >> 3 > 10 or len(frame) != ac3_size(frame[4] >> 6, frame[4] & 63):
        raise BurstError("AC-3 size or bitstream identification mismatch")
    return frame[5] & 7

def ac3_burst(frame: bytes) -> list[int]:
    return make_burst("ac3", frame, ac3_header(frame))

# [etsi-ts-102366 §Annex-E p.127] "00             1 block per syncframe"
# [etsi-ts-102366 §Annex-E p.127] "01             2 blocks per syncframe"
# [etsi-ts-102366 §Annex-E p.127] "10             3 blocks per syncframe"
# [etsi-ts-102366 §Annex-E p.127] "11             6 blocks per syncframe"
EAC_BLOCKS = (1, 2, 3, 6)

# [etsi-ts-102366 §Annex-E p.114] "strmtyp .................................................................................... 2"
# [etsi-ts-102366 §Annex-E p.114] "substreamid ................................................................................ 3"
# [etsi-ts-102366 §Annex-E p.114] "frmsiz .................................................................................... 11"
# [etsi-ts-102366 §Annex-E p.127] "The frmsiz field indicates a value one less than the overall size of the coded syncframe in 16-bit words."
def eac3_header(frame):
    if not isinstance(frame, bytes) or len(frame) < 6 or frame[:2] != AC_SYNC:
        raise BurstError("invalid E-AC-3 header")
    if frame[5] >> 3 <= 10:
        ac3_header(frame)
        return 0, 0, EAC_BLOCKS[-1], frame[4] >> 6
    typ, sid = frame[2] >> 6, (frame[2] >> 3) & 7
    size = 2 * (((frame[2] & 7) << 8 | frame[3]) + 1)
    rate = frame[4] >> 6
    if typ == 3 or rate == 3 or size != len(frame) or frame[5] >> 3 > 16:
        raise BurstError("reserved E-AC-3 field or frame size mismatch")
    return typ, sid, EAC_BLOCKS[(frame[4] >> 4) & 3], rate

# [smpte-st340-2015 §5.3 p.10] "deliver six blocks of audio data from all substreams being carried in the bitstream."
# [etsi-ts-102366 §Annex-E p.126] "The independent substream assigned substream ID 0 shall be the first substream present in the bit stream."
# [etsi-ts-102366 §Annex-E p.126] "Dependent substreams shall immediately follow the independent substream with which they are associated."
def eac3_group(frames: list[bytes]) -> list[list[int]]:
    groups, current, counts = [], [], {}
    owner = None
    rate = None
    def close():
        if any(n != EAC_BLOCKS[-1] for n in counts.values()):
            raise BurstError("incomplete or unequal E-AC-3 substream blocks")
        groups.append(current[:])
    for i, frame in enumerate(frames):
        typ, sid, blocks, this_rate = eac3_header(frame)
        anchor = typ != 1 and sid == 0
        if anchor and counts.get((0, 0), 0) == EAC_BLOCKS[-1]:
            close()
            current, counts, owner, rate = [], {}, None, None
        if not current and not anchor:
            raise BurstError("group must start with independent substream zero")
        if rate is not None and this_rate != rate:
            raise BurstError("sample rate changed inside group")
        rate = this_rate
        if typ == 1:
            if owner is None:
                raise BurstError("dependent substream without independent substream")
            key = (1, owner, sid)
        else:
            owner = sid
            key = (0, sid)
        counts[key] = counts.get(key, 0) + blocks
        if counts[key] > EAC_BLOCKS[-1]:
            raise BurstError("more than six blocks in group")
        current.append(i)
    if current:
        close()
    return groups

def eac3_burst(frames: list[bytes]) -> list[int]:
    if not frames or eac3_group(frames) != [list(range(len(frames)))]:
        raise BurstError("exactly one complete E-AC-3 group required")
    return make_burst("eac3", b"".join(frames))

# [etsi-ts-102114 §5.4.2 p.25] "SYNC = ExtractBits(32); //0x7FFE8001"
DTS_SYNC = b"\x7f\xfe\x80\x01"

# [etsi-ts-102114 §5.4.2 p.26] "(FSIZE+1) is the total byte size of the current frame including primary audio data as well as any extension audio data."
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "blocks = (AV_RB16(pkt->data + 4) >> 2) & 0x7f;"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "core_size = ((AV_RB24(pkt->data + 5) >> 4) & 0x3fff) + 1;"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "case  512 >> 5: ctx->data_type = IEC61937_DTS1; break;"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "case 1024 >> 5: ctx->data_type = IEC61937_DTS2; break;"
# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "case 2048 >> 5: ctx->data_type = IEC61937_DTS3; break;"
def dts_header(frame):
    if not isinstance(frame, bytes) or len(frame) < 9 or frame[:4] != DTS_SYNC:
        raise BurstError("expected big-endian 16-bit DTS core")
    blocks = ((int.from_bytes(frame[4:6], "big") >> 2) & 127) + 1
    size = ((int.from_bytes(frame[5:8], "big") >> 4) & 16383) + 1
    if size != len(frame) or size < 96 or blocks not in (16, 32, 64):
        raise BurstError("DTS size or sample count not supported")
    return "dts" + str(blocks << 5)

def dts_burst(frame: bytes) -> list[int]:
    return make_burst(dts_header(frame), frame)

@dataclass(frozen=True)
class Burst:
    offset: int
    data_type: int
    data_type_dependent: int
    error_flag: int
    bitstream_number: int
    length_code: int
    payload: bytes

# [ffmpeg-spdif-n7.1/spdifenc §file p.1] "Pd - length code (number of bits or bytes of encapsuled frame - according to data_type)"
def payload_size(code, typ):
    # The field interpretation is the inverse of the single length_code rule.
    kind = next((k for k in ("ac3", "eac3", "dts512", "dts1024", "dts2048")
                 if data_type(k, decode=True) == typ), None)
    if kind is None:
        raise BurstError("data type outside scope")
    return length_code(kind, code, decode=True), kind

# [smpte-st337-2015 §7.2.2 p.9] "The frame beginning the data burst shall contain preamble word Pa in the Ch1 subframe, and Pb in the Ch2 subframe."
def parse_bursts(words: list[int]) -> list[Burst]:
    if any(not isinstance(w, int) or not 0 <= w <= 0xFFFF for w in words):
        raise BurstError("not 16-bit sample words")
    bursts, i = [], 0
    while i < len(words):
        if words[i] != SYNC_WORDS[0]:
            i += 1
            continue
        if i % 2 or i + 4 > len(words) or words[i+1] != SYNC_WORDS[1]:
            raise BurstError("truncated or misaligned preamble")
        typ, dep, error, stream = pc_fields(words[i+2])
        size, kind = payload_size(words[i+3], typ)
        end = i + 4 + (size + 1) // 2
        if end > len(words) or end - i > 2 * burst_period(kind):
            raise BurstError("length exceeds stream or repetition capacity")
        raw = b"".join(w.to_bytes(2, "big") for w in words[i+4:end])
        if size % 2 and raw[-1] != 0:
            raise BurstError("nonzero unused half-word")
        bursts.append(Burst(i, typ, dep, error, stream, words[i+3], raw[:size]))
        i = end
    return bursts

PUBLIC_FUNCTIONS = ("dop_pack", "dop_unpack", "ac3_burst", "eac3_burst", "eac3_group", "dts_burst", "parse_bursts")

def rebind(overrides):
    """Clone the function graph with one changed rule; never mutate base or another variant."""
    env = dict(globals())
    for name, value in list(env.items()):
        if isinstance(value, FunctionType) and value.__module__ == __name__:
            env[name] = FunctionType(value.__code__, env, value.__name__, value.__defaults__, value.__closure__)
            env[name].__kwdefaults__ = value.__kwdefaults__
            env[name].__annotations__ = value.__annotations__
    env.update(overrides)
    return {name: env[name] for name in PUBLIC_FUNCTIONS}
