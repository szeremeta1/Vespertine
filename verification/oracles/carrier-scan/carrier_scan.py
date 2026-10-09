#!/usr/bin/env python3
"""carrier_scan.py - find AC-3, E-AC-3 and DTS frames in elementary streams and
in 16-bit PCM WAV carriers, using only the codecs' own frame syntax.

Sources (and only sources) for every field and constant below:
  [A52]  ATSC A/52:2018, Digital Audio Compression (AC-3, E-AC-3) Standard
         (body: AC-3; Annex D: alternate bsi syntax; Annex E: E-AC-3)
  [DTS]  ETSI TS 102 114 V1.6.1, DTS Coherent Acoustics; Core and Extensions

Usage:
  python3 carrier_scan.py frames  <stream>
  python3 carrier_scan.py scan    <carrier.wav>
  python3 carrier_scan.py compare <carrier.wav> <stream>
Add -v/--verbose (anywhere) to print why each rejected candidate was rejected.

Standard library only.
"""

import hashlib
import json
import struct
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# [A52] 5.4.1.1: "The syncword is always 0x0B77". [A52] Annex E Table E1.1:
# E-AC-3 syncinfo() is the same 16-bit syncword.
AC3_SYNC = b"\x0b\x77"

# [DTS] Table 5-1 (5.4.2): SYNC = ExtractBits(32); //0x7FFE8001. Also [DTS]
# Table 7-1 DTS_SYNCWORD_CORE = 0x7ffe8001.
DTS_CORE_SYNC = b"\x7f\xfe\x80\x01"

# [DTS] Table 7-1 DTS_SYNCWORD_SUBSTREAM = 0x64582025 and 7.5.2 SYNCEXTSSH
# ("The extension substream has a DWORD-aligned synchronization word with the
# hexadecimal value of 0x64582025").
DTS_EXSS_SYNC = b"\x64\x58\x20\x25"

# [A52] 7.10.1: CRC generator polynomial x^16 + x^15 + x^2 + 1, register reset
# to zero, data shifted in "in the order in which they appear in the data
# stream" (MSB first, [A52] 5.2/5.3).
A52_CRC_POLY = 0x8005
A52_CRC_INIT = 0x0000

# [DTS] Annex B: CRC16 polynomial G(x) = x^16 + x^12 + x^5 + 1 (CRC-CCITT),
# "initialized to the value of 0xFFFF before checksum computation commences".
DTS_CRC_POLY = 0x1021
DTS_CRC_INIT = 0xFFFF

# [A52] Table 5.18 Frame Size Code Table: words (16 bits) per syncframe,
# indexed [fscod][frmsizecod]; fscod per [A52] Table 5.6 (0=48 kHz,
# 1=44.1 kHz, 2=32 kHz). frmsizecod values 0..37 are the only rows of the
# table ("'100101' (18)" is the last), so 38..63 are not valid codes.
AC3_FRAME_WORDS = {
    0: [64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192,      # 48 kHz
        224, 224, 256, 256, 320, 320, 384, 384, 448, 448, 512, 512, 640, 640,
        768, 768, 896, 896, 1024, 1024, 1152, 1152, 1280, 1280],
    1: [69, 70, 87, 88, 104, 105, 121, 122, 139, 140, 174, 175, 208, 209,    # 44.1 kHz
        243, 244, 278, 279, 348, 349, 417, 418, 487, 488, 557, 558, 696, 697,
        835, 836, 975, 976, 1114, 1115, 1253, 1254, 1393, 1394],
    2: [96, 96, 120, 120, 144, 144, 168, 168, 192, 192, 240, 240, 288, 288,  # 32 kHz
        336, 336, 384, 384, 480, 480, 576, 576, 672, 672, 768, 768, 960, 960,
        1152, 1152, 1344, 1344, 1536, 1536, 1728, 1728, 1920, 1920],
}
AC3_NUM_FRMSIZECOD = 38  # [A52] Table 5.18 rows '000000'..'100101'

# [A52] Table 5.8 Audio Coding Mode: nfchans per acmod.
AC3_NFCHANS = [2, 1, 2, 3, 3, 4, 4, 5]

# [A52] Annex E Table E2.4: numblkscod -> audio blocks per syncframe
# ('11' -> 6; also implied by fscod == '11', Table E1.2).
EAC3_BLOCKS = [1, 2, 3, 6]

# [A52] Annex E Table E2.5 Custom Channel Map Locations: bits that denote a
# *pair* of channel locations (bit 0 = MSB of chanmap): 5 Lc/Rc, 6 Lrs/Rrs,
# 9 Lsd/Rsd, 10 Lw/Rw, 11 Vhl/Vhr, 13 Lts/Rts. All other bits are one channel.
EAC3_CHANMAP_PAIR_BITS = {5, 6, 9, 10, 11, 13}

# [DTS] Table 5-5 Core audio sampling frequencies: valid SFREQ codes
# (1=8k, 2=16k, 3=32k, 6=11.025k, 7=22.05k, 8=44.1k, 11=12k, 12=24k, 13=48k);
# 0, 4, 5, 9, 10, 14, 15 are "Invalid".
DTS_VALID_SFREQ = {1, 2, 3, 6, 7, 8, 11, 12, 13}

# [DTS] Table 5-7 RATE: 0b00000..0b11000 are bit rates, 0b11101 is "open",
# "other codes" are invalid.
DTS_VALID_RATE = set(range(0, 25)) | {29}

# [DTS] Table 5-11 EXT_AUDIO_ID: 0 = XCH, 2 = X96, 6 = XXCH; 1,3,4,5,7 Reserved.
DTS_VALID_EXT_AUDIO_ID = {0, 2, 6}

# [DTS] Table 5-17 PCMR: 0b000, 0b001, 0b010, 0b011, 0b110, 0b101 listed;
# "Others" (0b100, 0b111) invalid.
DTS_VALID_PCMR = {0, 1, 2, 3, 5, 6}

# [DTS] 5.4.2 NBLKS: "For normal frames, this indicates a window size of either
# 4 096, 2 048, 1 024, 512, or 256 samples per channel" with window size
# 32 x (NBLKS+1); i.e. NBLKS+1 in {8, 16, 32, 64, 128} for normal frames.
DTS_NORMAL_NBLKS = {7, 15, 31, 63, 127}

# [DTS] 7.4.2 / 7.5.1 / Table 7-2: up to four extension substreams
# (nExtSSIndex 0..3) may follow a core substream frame.
DTS_MAX_EXSS = 4


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class Invalid(Exception):
    """A candidate is not a valid frame (the message says why)."""


def _crc_table(poly):
    table = []
    for i in range(256):
        c = i << 8
        for _ in range(8):
            c = ((c << 1) ^ poly) if (c & 0x8000) else (c << 1)
            c &= 0xFFFF
        table.append(c)
    return table


_A52_CRC_TABLE = _crc_table(A52_CRC_POLY)
_DTS_CRC_TABLE = _crc_table(DTS_CRC_POLY)


def crc16(table, data, start, end, crc):
    """MSB-first (non-reflected) CRC-16 register update over data[start:end]."""
    t = table
    for b in data[start:end]:
        crc = ((crc << 8) & 0xFFFF) ^ t[(crc >> 8) ^ b]
    return crc


class BitReader:
    """Reads big-endian (MSB-first) bit fields; [A52] 5.2 / [DTS] 3.4."""

    __slots__ = ("d", "bit", "limit")

    def __init__(self, data, byte_pos, limit_byte):
        self.d = data
        self.bit = byte_pos * 8
        self.limit = limit_byte * 8

    def get(self, n):
        if n == 0:
            return 0
        if self.bit + n > self.limit:
            raise Invalid("header runs past the end of the frame/data")
        start = self.bit >> 3
        end = (self.bit + n + 7) >> 3
        v = int.from_bytes(self.d[start:end], "big")
        v >>= (end << 3) - (self.bit + n)
        self.bit += n
        return v & ((1 << n) - 1)

    def skip(self, n):
        if self.bit + n > self.limit:
            raise Invalid("header runs past the end of the frame/data")
        self.bit += n


# ---------------------------------------------------------------------------
# AC-3 ([A52] body + Annex D)
# ---------------------------------------------------------------------------

def _check_bsmod(bsmod, acmod):
    # [A52] Table 5.7: bsmod '111' is defined only with acmod '001' (VO) and
    # '010'-'111' (karaoke); bsmod 7 with acmod '000' is not a listed value.
    if bsmod == 7 and acmod == 0:
        raise Invalid("bsmod=7 with acmod=0 is not defined (A/52 Table 5.7)")


def _check_roomtyp(v, name):
    # [A52] Table 5.12 Room Type: '11' reserved.
    if v == 3:
        raise Invalid("%s=3 is reserved (A/52 Table 5.12)" % name)


def _check_dialnorm(v, name):
    # [A52] 5.4.2.8: "Valid values are 1-31. The value of 0 is reserved."
    if v == 0:
        raise Invalid("%s=0 is reserved (A/52 5.4.2.8)" % name)


def parse_ac3(data, pos):
    """Validate an AC-3 syncframe at data[pos]; return its length in bytes."""
    n = len(data)
    if pos + 6 > n:
        raise Invalid("AC-3 header truncated by end of data")
    # [A52] Table 5.1 syncinfo: syncword 16, crc1 16, fscod 2, frmsizecod 6.
    fscod = data[pos + 4] >> 6
    frmsizecod = data[pos + 4] & 0x3F
    if fscod == 3:
        # [A52] Table 5.6: fscod '11' reserved.
        raise Invalid("fscod=3 is reserved (A/52 Table 5.6)")
    if frmsizecod >= AC3_NUM_FRMSIZECOD:
        # [A52] Table 5.18 has no row for frmsizecod >= 38.
        raise Invalid("frmsizecod=%d not in A/52 Table 5.18" % frmsizecod)
    words = AC3_FRAME_WORDS[fscod][frmsizecod]  # [A52] 5.4.1.4, Table 5.18
    length = 2 * words
    if pos + length > n:
        raise Invalid("AC-3 frame (%d bytes) extends past end of data" % length)

    r = BitReader(data, pos + 5, pos + length)
    # [A52] Table 5.2 bsi syntax; field semantics in [A52] 5.4.2.x as noted.
    bsid = r.get(5)                           # 5.4.2.1
    if bsid > 8:
        # [A52] 5.4.2.1: decoders "shall mute if the value of bsid is greater
        # than 8" (E-AC-3 values are handled by parse_eac3).
        raise Invalid("bsid=%d is not an AC-3 bsid (A/52 5.4.2.1)" % bsid)
    bsmod = r.get(3)                          # 5.4.2.2, Table 5.7
    acmod = r.get(3)                          # 5.4.2.3, Table 5.8 (all defined)
    _check_bsmod(bsmod, acmod)
    if (acmod & 0x1) and acmod != 0x1:
        cmixlev = r.get(2)                    # 5.4.2.4
        if cmixlev == 3:
            raise Invalid("cmixlev=3 is reserved (A/52 Table 5.9)")
    if acmod & 0x4:
        surmixlev = r.get(2)                  # 5.4.2.5
        if surmixlev == 3:
            raise Invalid("surmixlev=3 is reserved (A/52 Table 5.10)")
    if acmod == 0x2:
        dsurmod = r.get(2)                    # 5.4.2.6
        if dsurmod == 3:
            raise Invalid("dsurmod=3 is reserved (A/52 Table 5.11)")
    r.get(1)                                  # lfeon, 5.4.2.7
    _check_dialnorm(r.get(5), "dialnorm")     # dialnorm, 5.4.2.8
    if r.get(1):                              # compre, 5.4.2.9
        r.get(8)                              # compr, 5.4.2.10
    if r.get(1):                              # langcode, 5.4.2.11
        # [A52] 5.4.2.12: langcod "is an 8 bit reserved value that shall be set
        # to 0xFF if present".
        if r.get(8) != 0xFF:
            raise Invalid("langcod != 0xFF (A/52 5.4.2.12)")
    if r.get(1):                              # audprodie, 5.4.2.13
        r.get(5)                              # mixlevel, 5.4.2.14 (0..31 all valid)
        _check_roomtyp(r.get(2), "roomtyp")   # roomtyp, 5.4.2.15
    if acmod == 0:                            # 1+1 mode
        _check_dialnorm(r.get(5), "dialnorm2")  # dialnorm2, 5.4.2.16
        if r.get(1):                          # compr2e, 5.4.2.17
            r.get(8)                          # compr2, 5.4.2.18
        if r.get(1):                          # langcod2e, 5.4.2.19
            if r.get(8) != 0xFF:              # langcod2, 5.4.2.20
                raise Invalid("langcod2 != 0xFF (A/52 5.4.2.20)")
        if r.get(1):                          # audprodi2e, 5.4.2.21
            r.get(5)                          # mixlevel2, 5.4.2.22
            _check_roomtyp(r.get(2), "roomtyp2")  # roomtyp2, 5.4.2.23
    r.get(1)                                  # copyrightb, 5.4.2.24
    r.get(1)                                  # origbs, 5.4.2.25
    if bsid == 6:
        # [A52] Annex D 2.1: bsid == 6 means the alternate syntax of
        # Table D2.1, which replaces the time code fields.
        if r.get(1):                          # xbsi1e, D 2.3.1.1
            dmixmod = r.get(2)                # D 2.3.1.2
            r.get(3)                          # ltrtcmixlev, D 2.3.1.3 (Table D2.3 all defined)
            ltrtsurmixlev = r.get(3)          # D 2.3.1.4
            r.get(3)                          # lorocmixlev, D 2.3.1.5 (Table D2.5 all defined)
            lorosurmixlev = r.get(3)          # D 2.3.1.6
            # Table D2.2 note: dmixmod meaning defined only for 3/0 .. 3/2.
            if acmod >= 3 and dmixmod == 3:
                raise Invalid("dmixmod=3 is reserved (A/52 Table D2.2)")
            # Tables D2.4/D2.6 notes: defined only for 2/1, 3/1, 2/2, 3/2
            # (acmod & 4); there '000'..'010' are reserved.
            if acmod & 0x4:
                if ltrtsurmixlev < 3:
                    raise Invalid("ltrtsurmixlev<3 is reserved (A/52 Table D2.4)")
                if lorosurmixlev < 3:
                    raise Invalid("lorosurmixlev<3 is reserved (A/52 Table D2.6)")
        if r.get(1):                          # xbsi2e, D 2.3.1.7
            r.get(2)                          # dsurexmod, D 2.3.1.8 (Table D2.7 all defined)
            dheadphonmod = r.get(2)           # D 2.3.1.9
            r.get(1)                          # adconvtyp, D 2.3.1.10 (Table D2.9)
            xbsi2 = r.get(8)                  # D 2.3.1.11
            r.get(1)                          # encinfo, D 2.3.1.12
            # Table D2.8 note: meaning defined only for 2/0.
            if acmod == 2 and dheadphonmod == 3:
                raise Invalid("dheadphonmod=3 is reserved (A/52 Table D2.8)")
            # D 2.3.1.11: "Encoders shall set these bits to all 0's."
            if xbsi2 != 0:
                raise Invalid("xbsi2 != 0 (A/52 Annex D 2.3.1.11)")
    else:
        if r.get(1):                          # timecod1e, 5.4.2.26 / Table 5.13
            tc1 = r.get(14)                   # timecod1, 5.4.2.27
            # [A52] 5.4.2.27: hours (5 bits) 0-23, minutes (6 bits) 0-59.
            if (tc1 >> 9) > 23 or ((tc1 >> 3) & 0x3F) > 59:
                raise Invalid("timecod1 out of range (A/52 5.4.2.27)")
        if r.get(1):                          # timecod2e, 5.4.2.26 / Table 5.13
            tc2 = r.get(14)                   # timecod2, 5.4.2.28
            # [A52] 5.4.2.28: frames (middle 5 bits) 0-29.
            if ((tc2 >> 6) & 0x1F) > 29:
                raise Invalid("timecod2 out of range (A/52 5.4.2.28)")
    if r.get(1):                              # addbsie, 5.4.2.29
        addbsil = r.get(6)                    # addbsil, 5.4.2.30
        r.skip((addbsil + 1) * 8)             # addbsi, 5.4.2.31

    frame_bits = length * 8
    hdr_bits = r.bit - pos * 8
    # [A52] 5.5: syncinfo + bsi + blocks 0 and 1 "shall not exceed 5/8 of the
    # syncframe"; [A52] Table 5.5: errorcheck (crcrsv 1 + crc2 16) ends it.
    five8_words = (words >> 1) + (words >> 3)   # [A52] 7.10.1 / Table 7.34
    if hdr_bits > five8_words * 16:
        raise Invalid("syncinfo+bsi exceed 5/8 of the syncframe (A/52 5.5)")
    if hdr_bits + 17 > frame_bits:
        raise Invalid("bsi leaves no room for errorcheck")

    # [A52] 7.10.1: register reset to zero; shift in everything after the
    # sync word; zero after the first 5/8 of the syncframe -> crc1 valid;
    # continue to the end of the syncframe; zero again -> crc2 valid.
    c = crc16(_A52_CRC_TABLE, data, pos + 2, pos + 2 * five8_words, A52_CRC_INIT)
    if c != 0:
        raise Invalid("crc1 check failed (A/52 7.10.1)")
    c = crc16(_A52_CRC_TABLE, data, pos + 2 * five8_words, pos + length, c)
    if c != 0:
        raise Invalid("crc2 check failed (A/52 7.10.1)")
    return length


# ---------------------------------------------------------------------------
# E-AC-3 ([A52] Annex E)
# ---------------------------------------------------------------------------

def parse_eac3(data, pos):
    """Validate an E-AC-3 syncframe at data[pos]; return its length in bytes."""
    n = len(data)
    if pos + 6 > n:
        raise Invalid("E-AC-3 header truncated by end of data")
    # [A52] Table E1.2: strmtyp 2, substreamid 3, frmsiz 11 follow the syncword.
    strmtyp = data[pos + 2] >> 6
    frmsiz = ((data[pos + 2] & 0x07) << 8) | data[pos + 3]
    if strmtyp == 3:
        # [A52] Table E2.1 / E2.3.1.1: Type 3 reserved.
        raise Invalid("strmtyp=3 is reserved (A/52 Table E2.1)")
    # [A52] E2.3.1.3: frmsiz is one less than the syncframe size in words.
    length = 2 * (frmsiz + 1)
    if pos + length > n:
        raise Invalid("E-AC-3 frame (%d bytes) extends past end of data" % length)

    # [A52] Table E1.2 bsi syntax; semantics in [A52] E2.3.1.x as noted, and
    # per [A52] E2.2 ("Unless otherwise specified, all bit stream elements
    # shall have the same meaning ... as described in the body and Annex D")
    # in [A52] 5.4.2.x / Annex D for the inherited fields.
    r = BitReader(data, pos + 4, pos + length)
    fscod = r.get(2)                          # E2.3.1.4, Table E2.2
    if fscod == 0x3:
        fscod2 = r.get(2)                     # E2.3.1.5
        if fscod2 == 3:
            # [A52] Table E2.3: fscod2 '11' reserved.
            raise Invalid("fscod2=3 is reserved (A/52 Table E2.3)")
        numblkscod = 0x3                      # Table E1.2: six blocks
    else:
        numblkscod = r.get(2)                 # E2.3.1.5, Table E2.4 (all defined)
    acmod = r.get(3)                          # 5.4.2.3, Table 5.8
    lfeon = r.get(1)                          # 5.4.2.7
    bsid = r.get(5)                           # E2.3.1.6
    if not 11 <= bsid <= 16:
        # [A52] E2.3.1.6: decode 0-8 (AC-3 syntax, see parse_ac3) and 11-16;
        # "shall mute if the value of bsid is 9, 10, or greater than 16".
        raise Invalid("bsid=%d is not an E-AC-3 bsid (A/52 E2.3.1.6)" % bsid)
    _check_dialnorm(r.get(5), "dialnorm")     # dialnorm, 5.4.2.8
    if r.get(1):                              # compre, 5.4.2.9
        r.get(8)                              # compr, 5.4.2.10
    if acmod == 0x0:
        _check_dialnorm(r.get(5), "dialnorm2")  # dialnorm2, 5.4.2.16
        if r.get(1):                          # compr2e, 5.4.2.17
            r.get(8)                          # compr2, 5.4.2.18
    if strmtyp == 0x1:                        # dependent substream
        if r.get(1):                          # chanmape, E2.3.1.7
            chanmap = r.get(16)               # chanmap, E2.3.1.8, Table E2.5
            # [A52] E2.3.1.8: "the number of channel locations indicated by the
            # chanmap field must equal the total number of coded channels ...
            # as indicated by the acmod and lfeon bit stream parameters".
            locs = 0
            for bit in range(16):             # bit 0 is the MSB
                if chanmap & (1 << (15 - bit)):
                    locs += 2 if bit in EAC3_CHANMAP_PAIR_BITS else 1
            if locs != AC3_NFCHANS[acmod] + lfeon:
                raise Invalid("chanmap channel count != acmod/lfeon (A/52 E2.3.1.8)")
    tail_checked = True
    if r.get(1):                              # mixmdate, E2.3.1.9
        if acmod > 0x2:
            dmixmod = r.get(2)                # D 2.3.1.2
            # E2.2 -> Annex D Table D2.2: '11' reserved.
            if dmixmod == 3:
                raise Invalid("dmixmod=3 is reserved (A/52 Table D2.2)")
        if (acmod & 0x1) and acmod > 0x2:
            r.get(3)                          # ltrtcmixlev, D 2.3.1.3 (Table D2.3)
            r.get(3)                          # lorocmixlev, D 2.3.1.5 (Table D2.5)
        if acmod & 0x4:
            ltrtsurmixlev = r.get(3)          # D 2.3.1.4
            lorosurmixlev = r.get(3)          # D 2.3.1.6
            # E2.2 -> Tables D2.4 / D2.6: '000'..'010' reserved.
            if ltrtsurmixlev < 3:
                raise Invalid("ltrtsurmixlev<3 is reserved (A/52 Table D2.4)")
            if lorosurmixlev < 3:
                raise Invalid("lorosurmixlev<3 is reserved (A/52 Table D2.6)")
        if lfeon:
            if r.get(1):                      # lfemixlevcode, E2.3.1.10
                r.get(5)                      # lfemixlevcod, E2.3.1.11 (0..31 valid)
        if strmtyp == 0x0:
            if r.get(1):                      # pgmscle, E2.3.1.12
                r.get(6)                      # pgmscl, E2.3.1.13 (0..63 valid)
            if acmod == 0x0:
                if r.get(1):                  # pgmscl2e, E2.3.1.14
                    r.get(6)                  # pgmscl2, E2.3.1.15
            if r.get(1):                      # extpgmscle, E2.3.1.16
                r.get(6)                      # extpgmscl, E2.3.1.17
            mixdef = r.get(2)                 # E2.3.1.18, Table E2.6 (all defined)
            if mixdef == 0x1:
                r.get(1)                      # premixcmpsel, E2.3.1.19
                r.get(1)                      # drcsrc, E2.3.1.20
                premixcmpscl = r.get(3)       # E2.3.1.21
                # Table E2.7 lists '000'-'101' and '111'; '110' is absent.
                if premixcmpscl == 6:
                    raise Invalid("premixcmpscl=6 not in A/52 Table E2.7")
            elif mixdef == 0x2:
                r.get(12)                     # mixdata, E2.3.1.23
            elif mixdef == 0x3:
                r.get(5)                      # mixdeflen, E2.3.1.22
                if r.get(1):                  # mixdata2e, E2.3.1.24
                    r.get(1)                  # premixcmpsel, E2.3.1.19
                    r.get(1)                  # drcsrc, E2.3.1.20
                    premixcmpscl = r.get(3)   # E2.3.1.21
                    if premixcmpscl == 6:
                        raise Invalid("premixcmpscl=6 not in A/52 Table E2.7")
                    # extpgmlscle/l, extpgmcscle/c, extpgmrscle/r,
                    # extpgmlsscle/ls, extpgmrsscle/rs, extpgmlfescle/lfe,
                    # dmixscle/dmixscl: E2.3.1.25-E2.3.1.38 (1-bit flag,
                    # 4-bit value per Table E2.8, all 16 values defined).
                    for _ in range(7):
                        if r.get(1):
                            r.get(4)
                    if r.get(1):              # addche, E2.3.1.39
                        for _ in range(2):    # extpgmaux1/2scle/scl, E2.3.1.40-43
                            if r.get(1):
                                r.get(4)
                if r.get(1):                  # mixdata3e, E2.3.1.44
                    r.get(5)                  # spchdat, E2.3.1.45
                    if r.get(1):              # addspchdate, E2.3.1.46
                        r.get(5)              # spchdat1, E2.3.1.47
                        r.get(2)              # spchan1att, E2.3.1.48
                        if r.get(1):          # addspchdat1e, E2.3.1.49
                            r.get(5)          # spchdat2, E2.3.1.50
                            r.get(3)          # spchan2att, E2.3.1.51
                # The rest of the mixdata field and mixdatafill (E2.3.1.52)
                # have an ambiguous length (Table E1.2 vs E3.10.4), so the
                # remaining bsi fields cannot be located reliably: stop here.
                tail_checked = False
            if tail_checked:
                if acmod < 0x2:
                    if r.get(1):              # paninfoe, E2.3.1.53
                        panmean = r.get(8)    # E2.3.1.54
                        r.get(6)              # paninfo, E2.3.1.55 (reserved field)
                        # E2.3.1.54: panmean 240..255 reserved.
                        if panmean >= 240:
                            raise Invalid("panmean>=240 is reserved (A/52 E2.3.1.54)")
                    if acmod == 0x0:
                        if r.get(1):          # paninfo2e, E2.3.1.56
                            panmean2 = r.get(8)   # E2.3.1.57
                            r.get(6)          # paninfo2, E2.3.1.58
                            if panmean2 >= 240:
                                raise Invalid("panmean2>=240 is reserved (A/52 E2.3.1.57)")
                if r.get(1):                  # frmmixcfginfoe, E2.3.1.59
                    if numblkscod == 0x0:
                        r.get(5)              # blkmixcfginfo[0], E2.3.1.61
                    else:
                        for _ in range(EAC3_BLOCKS[numblkscod]):
                            if r.get(1):      # blkmixcfginfoe, E2.3.1.60
                                r.get(5)      # blkmixcfginfo[blk], E2.3.1.61
    if tail_checked:
        if r.get(1):                          # infomdate, E2.3.1.62
            bsmod = r.get(3)                  # 5.4.2.2
            _check_bsmod(bsmod, acmod)        # via E2.2 -> Table 5.7
            r.get(1)                          # copyrightb, 5.4.2.24
            r.get(1)                          # origbs, 5.4.2.25
            if acmod == 0x2:
                if r.get(2) == 3:             # dsurmod, 5.4.2.6 / Table 5.11
                    raise Invalid("dsurmod=3 is reserved (A/52 Table 5.11)")
                if r.get(2) == 3:             # dheadphonmod, D 2.3.1.9 / Table D2.8
                    raise Invalid("dheadphonmod=3 is reserved (A/52 Table D2.8)")
            if acmod >= 0x6:
                r.get(2)                      # dsurexmod, D 2.3.1.8 (Table D2.7 all defined)
            if r.get(1):                      # audprodie, 5.4.2.13
                r.get(5)                      # mixlevel, 5.4.2.14
                _check_roomtyp(r.get(2), "roomtyp")   # roomtyp, 5.4.2.15
                r.get(1)                      # adconvtyp, D 2.3.1.10
            if acmod == 0x0:
                if r.get(1):                  # audprodi2e, 5.4.2.21
                    r.get(5)                  # mixlevel2, 5.4.2.22
                    _check_roomtyp(r.get(2), "roomtyp2")  # roomtyp2, 5.4.2.23
                    r.get(1)                  # adconvtyp2
            if fscod < 0x3:
                r.get(1)                      # sourcefscod, E2.3.1.63
            if strmtyp == 0x0 and numblkscod != 0x3:
                r.get(1)                      # convsync, E2.3.1.64
        if strmtyp == 0x2:
            # blkid, E2.3.1.65 (implied 1 for six-block frames, Table E1.2)
            blkid = 1 if numblkscod == 0x3 else r.get(1)
            if blkid:
                frmsizecod = r.get(6)         # 5.4.1.4
                # [A52] Table 5.18 has no row for frmsizecod >= 38.
                if frmsizecod >= AC3_NUM_FRMSIZECOD:
                    raise Invalid("frmsizecod=%d not in A/52 Table 5.18" % frmsizecod)
        if r.get(1):                          # addbsie, 5.4.2.29
            addbsil = r.get(6)                # addbsil, 5.4.2.30
            r.skip((addbsil + 1) * 8)         # addbsi, 5.4.2.31

    # [A52] Table E1.6 errorcheck: encinfo 1 + crc2 16 must still fit.
    if (r.bit - pos * 8) + 17 > length * 8:
        raise Invalid("bsi leaves no room for errorcheck")
    # [A52] E3.2: "E-AC-3 bit streams contain only one CRC word, which covers
    # the entire syncframe"; computed as in [A52] 7.10.1 (crc2, sync word not
    # covered, register reset to zero, result zero when valid).
    if crc16(_A52_CRC_TABLE, data, pos + 2, pos + length, A52_CRC_INIT) != 0:
        raise Invalid("crc2 check failed (A/52 E3.2 / 7.10.1)")
    return length


def parse_ac3_family(data, pos):
    """Return (codec, length) for a valid AC-3 or E-AC-3 frame at pos."""
    if pos + 6 > len(data):
        raise Invalid("header truncated by end of data")
    # [A52] Annex E 2.1: "the bsid field is placed the same number of bytes
    # from the beginning of the syncframe" in AC-3 and E-AC-3 (5 bits at the
    # top of byte 5); bsid 16 (11..16 per E2.3.1.6) selects E-AC-3 syntax,
    # bsid <= 8 the AC-3 syntax.
    bsid = data[pos + 5] >> 3
    if bsid <= 8:
        return "ac3", parse_ac3(data, pos)
    if 11 <= bsid <= 16:
        return "eac3", parse_eac3(data, pos)
    raise Invalid("bsid=%d is neither AC-3 nor E-AC-3 (A/52 5.4.2.1, E2.3.1.6)" % bsid)


# ---------------------------------------------------------------------------
# DTS core ([DTS] clause 5) and extension substream header ([DTS] 7.5.2)
# ---------------------------------------------------------------------------

def parse_dts_core(data, pos):
    """Validate a DTS core frame header at data[pos]; return the core length."""
    n = len(data)
    if pos + 16 > n:
        raise Invalid("DTS header truncated by end of data")
    # [DTS] Table 5-1 Core Frame Header. Read FSIZE first so that the rest of
    # the header can be bounded by the frame.
    # Field semantics: [DTS] 5.4.2 (bit stream header) and 5.4.3 (primary
    # audio coding header), one paragraph per field name.
    r = BitReader(data, pos + 4, n)
    ftype = r.get(1)                          # FTYPE, 5.4.2 / Table 5-2
    short = r.get(5)                          # SHORT, 5.4.2 / Table 5-3
    cpf = r.get(1)                            # CPF, 5.4.2
    nblks = r.get(7)                          # NBLKS, 5.4.2
    fsize = r.get(14)                         # FSIZE, 5.4.2
    # [DTS] Table 5-3: a normal frame (FTYPE=1) has SHORT = 31; a termination
    # frame (FTYPE=0) has SHORT in [0, 30].
    if ftype == 1 and short != 31:
        raise Invalid("normal frame with SHORT=%d (DTS Table 5-3)" % short)
    if ftype == 0 and short > 30:
        raise Invalid("termination frame with SHORT=31 (DTS Table 5-3)")
    # [DTS] 5.4.2 NBLKS: "Valid range for NBLKS: 5 to 127. Invalid range for
    # NBLKS: 0 to 4", and for normal frames 256..4096 samples per channel.
    if nblks < 5:
        raise Invalid("NBLKS=%d is invalid (DTS 5.4.2)" % nblks)
    if ftype == 1 and nblks not in DTS_NORMAL_NBLKS:
        raise Invalid("normal frame with NBLKS=%d (DTS 5.4.2)" % nblks)
    # [DTS] 5.4.2 FSIZE: "(FSIZE+1) is the total byte size of the current
    # frame"; "Valid range for FSIZE: 95 to 16 383. Invalid range: 0 to 94."
    if fsize < 95:
        raise Invalid("FSIZE=%d is invalid (DTS 5.4.2)" % fsize)
    length = fsize + 1
    if pos + length > n:
        raise Invalid("DTS frame (%d bytes) extends past end of data" % length)
    r.limit = (pos + length) * 8
    r.get(6)                                  # AMODE, 5.4.2 / Table 5-4 (16..63 user defined)
    sfreq = r.get(4)                          # SFREQ, 5.4.2
    if sfreq not in DTS_VALID_SFREQ:
        raise Invalid("SFREQ=%d is invalid (DTS Table 5-5)" % sfreq)
    rate = r.get(5)                           # RATE, 5.4.2
    if rate not in DTS_VALID_RATE:
        raise Invalid("RATE=%d is invalid (DTS Table 5-7)" % rate)
    if r.get(1) != 0:                         # FixedBit, 5.4.2
        # [DTS] 5.4.2 FixedBit: "This field is always set to 0."
        raise Invalid("FixedBit=1 (DTS 5.4.2)")
    r.get(1)                                  # DYNF, 5.4.2 / Table 5-8
    r.get(1)                                  # TIMEF, 5.4.2 / Table 5-9
    r.get(1)                                  # AUXF, 5.4.2 / Table 5-10
    r.get(1)                                  # HDCD, 5.4.2
    ext_audio_id = r.get(3)                   # EXT_AUDIO_ID, 5.4.2
    ext_audio = r.get(1)                      # EXT_AUDIO, 5.4.2 / Table 5-12
    # [DTS] Table 5-11: EXT_AUDIO_ID "has meaning only if the EXT_AUDIO = 1".
    if ext_audio == 1 and ext_audio_id not in DTS_VALID_EXT_AUDIO_ID:
        raise Invalid("EXT_AUDIO_ID=%d is reserved (DTS Table 5-11)" % ext_audio_id)
    r.get(1)                                  # ASPF, 5.4.2 / Table 5-13
    lff = r.get(2)                            # LFF, 5.4.2
    if lff == 3:
        raise Invalid("LFF=3 is invalid (DTS Table 5-14)")
    r.get(1)                                  # HFLAG, 5.4.2
    if cpf == 1:
        # [DTS] 5.4.2 HCRC: present if CPF=1; "The CRC value test shall not be
        # applied."
        r.get(16)
    r.get(1)                                  # FILTS, 5.4.2 / Table 5-15
    vernum = r.get(4)                         # VERNUM, 5.4.2
    if vernum > 7:
        # [DTS] Table 5-16: 8..15 "Future revision (incompatible with the
        # present document)"; such a decoder "shall mute its outputs".
        raise Invalid("VERNUM=%d is incompatible (DTS Table 5-16)" % vernum)
    r.get(2)                                  # CHIST, 5.4.2
    pcmr = r.get(3)                           # PCMR, 5.4.2
    if pcmr not in DTS_VALID_PCMR:
        raise Invalid("PCMR=%d is invalid (DTS Table 5-17)" % pcmr)
    r.get(1)                                  # SUMF, 5.4.2 / Table 5-18
    r.get(1)                                  # SUMS, 5.4.2 / Table 5-19
    r.get(4)                                  # DIALNORM / UNSPEC, 5.4.2 / Table 5-20 (all defined)

    # [DTS] Table 5-21 Primary audio coding header (5.4.3).
    r.get(4)                                  # SUBFS, 5.4.3
    pchs = r.get(3)                           # PCHS, 5.4.3
    npchs = pchs + 1
    if npchs > 5:
        # [DTS] 5.4.3 PCHS: "nPCHS = PCHS+1 < 5 primary audio channels"; the
        # core carries at most 5 primary channels ("If AMODE flag indicates
        # more than five channels ... the additional channels are the
        # extended channels").
        raise Invalid("nPCHS=%d exceeds 5 (DTS 5.4.3)" % npchs)
    r.skip(5 * npchs)                         # SUBS[ch], 5.4.3
    r.skip(5 * npchs)                         # VQSUB[ch], 5.4.3
    r.skip(3 * npchs)                         # JOINX[ch], 5.4.3 / Table 5-22
    r.skip(2 * npchs)                         # THUFF[ch], 5.4.3 / Table 5-23 (all defined)
    for _ in range(npchs):
        if r.get(3) == 7:                     # SHUFF[ch], 5.4.3
            raise Invalid("SHUFF=7 is invalid (DTS Table 5-24)")
    for _ in range(npchs):
        if r.get(3) == 7:                     # BHUFF[ch], 5.4.3
            raise Invalid("BHUFF=7 is invalid (DTS Table 5-25)")
    # SEL[ch][n] (5.4.3): n=0 1 bit; n=1..4 2 bits; n=5..9 3 bits (Table 5-26:
    # every transmitted code is defined). ADJ (5.4.3, 2 bits, Table 5-27)
    # follows each SEL that selects a Huffman codebook (Table 5-21).
    sel = [[0] * 10 for _ in range(npchs)]
    for ch in range(npchs):
        sel[ch][0] = r.get(1)
    for nn in range(1, 5):
        for ch in range(npchs):
            sel[ch][nn] = r.get(2)
    for nn in range(5, 10):
        for ch in range(npchs):
            sel[ch][nn] = r.get(3)
    for ch in range(npchs):                   # ABITS = 1: ADJ if SEL == 0
        if sel[ch][0] == 0:
            r.get(2)
    for nn in range(1, 5):                    # ABITS = 2..5: ADJ if SEL < 3
        for ch in range(npchs):
            if sel[ch][nn] < 3:
                r.get(2)
    for nn in range(5, 10):                   # ABITS = 6..10: ADJ if SEL < 7
        for ch in range(npchs):
            if sel[ch][nn] < 7:
                r.get(2)
    if cpf == 1:
        r.get(16)                             # AHCRC, 5.4.3 (test "shall not be applied")
    return length


def parse_dts_exss(data, pos):
    """Validate a DTS extension substream header at data[pos] ([DTS] 7.5.2,
    Table 7-2); return nuExtSSFsize (bytes, including the header)."""
    n = len(data)
    # Field semantics: [DTS] 7.5.2, one paragraph per field name.
    r = BitReader(data, pos + 4, n)           # after SYNCEXTSSH (32 bits)
    r.get(8)                                  # UserDefinedBits (not CRC-covered)
    r.get(2)                                  # nExtSSIndex (0..3 all valid)
    if r.get(1):                              # bHeaderSizeType
        bits4header, bits4fsize = 12, 20      # Table 7-2
    else:
        bits4header, bits4fsize = 8, 16       # Table 7-2
    hdr_size = r.get(bits4header) + 1         # nuExtSSHeaderSize
    fsize = r.get(bits4fsize) + 1             # nuExtSSFsize
    if r.get(1):                              # bStaticFieldsPresent
        if r.get(2) == 3:                     # nuRefClockCode
            # [DTS] Table 7-3: nuRefClockCode 3 "Unused".
            raise Invalid("nuRefClockCode=3 is unused (DTS Table 7-3)")
    min_hdr = (r.bit - pos * 8 + 7) // 8 + 2
    if hdr_size < min_hdr or hdr_size > fsize:
        raise Invalid("inconsistent extension substream sizes (DTS 7.5.2)")
    if pos + fsize > n:
        raise Invalid("extension substream extends past end of data")
    # [DTS] 7.5.2 nCRC16ExtSSHeader: CRC16 "from positions nExtSSIndex to
    # ByteAlign, inclusive", stored at byte nuExtSSHeaderSize-2; Annex B CRC.
    crc = crc16(_DTS_CRC_TABLE, data, pos + 5, pos + hdr_size - 2, DTS_CRC_INIT)
    stored = (data[pos + hdr_size - 2] << 8) | data[pos + hdr_size - 1]
    if crc != stored:
        raise Invalid("extension substream header CRC failed (DTS 7.5.2, Annex B)")
    return fsize


def parse_dts(data, pos):
    """Return (codec, length) for a valid DTS core frame at pos, including any
    extension substream(s) that directly follow it ([DTS] 7.5.1)."""
    end = pos + parse_dts_core(data, pos)
    for _ in range(DTS_MAX_EXSS):
        # [DTS] 7.5.1: core and extension substream sync words are aligned to
        # 32-bit boundaries; "from one to three null bytes" may separate them.
        pad = (-(end - pos)) % 4
        sp = end + pad
        if data[sp:sp + 4] != DTS_EXSS_SYNC or any(data[end:sp]):
            break
        try:
            size = parse_dts_exss(data, sp)
        except Invalid:
            break
        end = sp + size
    return "dts", end - pos


# ---------------------------------------------------------------------------
# Frame splitting and scanning
# ---------------------------------------------------------------------------

def frame_record(data, offset, codec, length):
    return {
        "offset": offset,
        "codec": codec,
        "length": length,
        "sha256": hashlib.sha256(data[offset:offset + length]).hexdigest(),
    }


def try_frame(data, pos):
    """(codec, length) for a valid frame starting at pos, else raise Invalid.
    Returns None if no sync word starts at pos."""
    if data[pos:pos + 2] == AC3_SYNC:
        return parse_ac3_family(data, pos)
    if data[pos:pos + 4] == DTS_CORE_SYNC:
        return parse_dts(data, pos)
    return None


def split_stream(data):
    """Split an elementary stream; returns (frames, error_message_or_None)."""
    frames = []
    pos = 0
    n = len(data)
    if n == 0:
        return frames, "empty file"
    while pos < n:
        try:
            res = try_frame(data, pos)
        except Invalid as e:
            return frames, "invalid frame at offset %d: %s" % (pos, e)
        if res is None:
            return frames, "no AC-3/E-AC-3/DTS sync word at offset %d" % pos
        codec, length = res
        frames.append(frame_record(data, pos, codec, length))
        pos += length
    return frames, None


def _find_even(data, pat, start):
    i = data.find(pat, start)
    while i != -1 and (i & 1):
        i = data.find(pat, i + 1)
    return i


def scan_bytes(data, log=None):
    """Scan a byte stream for frames whose sync word is at an even offset.
    Returns (frames, rejected_candidates)."""
    frames = []
    rejected = 0
    pos = 0
    na = _find_even(data, AC3_SYNC, 0)
    nd = _find_even(data, DTS_CORE_SYNC, 0)
    while True:
        if na != -1 and na < pos:
            na = _find_even(data, AC3_SYNC, pos)
        if nd != -1 and nd < pos:
            nd = _find_even(data, DTS_CORE_SYNC, pos)
        if na == -1 and nd == -1:
            break
        p = nd if na == -1 else (na if nd == -1 else min(na, nd))
        try:
            codec, length = try_frame(data, p)
        except Invalid as e:
            rejected += 1
            if log:
                log("rejected candidate at %d: %s" % (p, e))
            pos = p + 2
            continue
        frames.append(frame_record(data, p, codec, length))
        pos = p + length
        if pos & 1:                           # next candidate on a 16-bit word
            pos += 1
    return frames, rejected


# ---------------------------------------------------------------------------
# WAV carrier
# ---------------------------------------------------------------------------

class WavError(Exception):
    pass


def read_wav_samples(path):
    """Return (sample_bytes, big_endian_samples) of a 16-bit integer PCM WAV."""
    with open(path, "rb") as f:
        blob = f.read()
    if len(blob) < 12 or blob[8:12] != b"WAVE" or blob[0:4] not in (b"RIFF", b"RIFX"):
        raise WavError("not a RIFF/WAVE file")
    e = "<" if blob[0:4] == b"RIFF" else ">"
    pos = 12
    fmt = None
    data = None
    while pos + 8 <= len(blob):
        cid = blob[pos:pos + 4]
        size = struct.unpack(e + "I", blob[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b"fmt ":
            fmt = blob[body:body + size]
        elif cid == b"data":
            avail = len(blob) - body
            if size == 0 or size > avail:     # streamed/unfinished header
                size = avail
            data = blob[body:body + size]
            if fmt is not None:
                break
        pos = body + size + (size & 1)
    if fmt is None or len(fmt) < 16:
        raise WavError("missing or short 'fmt ' chunk")
    if data is None:
        raise WavError("missing 'data' chunk")
    tag, channels, _rate, _bps, block_align, bits = struct.unpack(e + "HHIIHH", fmt[:16])
    if tag == 0xFFFE and len(fmt) >= 26:      # WAVE_FORMAT_EXTENSIBLE
        tag = struct.unpack(e + "H", fmt[24:26])[0]
    if tag != 1:
        raise WavError("not integer PCM (format tag %d)" % tag)
    if bits != 16:
        raise WavError("not 16-bit PCM (%d bits per sample)" % bits)
    if channels < 1 or block_align != 2 * channels:
        raise WavError("inconsistent channel count / block align")
    if len(data) & 1:
        data = data[:-1]
    return data, (e == ">")


def carrier_streams(sample_bytes, stored_big_endian):
    """The two byte streams: 'big' puts each sample's high byte first,
    'little' its low byte first."""
    swapped = bytearray(len(sample_bytes))
    swapped[0::2] = sample_bytes[1::2]
    swapped[1::2] = sample_bytes[0::2]
    swapped = bytes(swapped)
    if stored_big_endian:
        return {"big": sample_bytes, "little": swapped}
    return {"little": sample_bytes, "big": swapped}


def scan_carrier(path, log=None):
    """Returns (order or None, frames, rejected, per_order_results)."""
    samples, stored_be = read_wav_samples(path)
    streams = carrier_streams(samples, stored_be)
    results = {}
    for order in ("big", "little"):
        results[order] = scan_bytes(streams[order],
                                    (lambda m, o=order: log("[%s] %s" % (o, m))) if log else None)
    found = [o for o in ("big", "little") if results[o][0]]
    if not found:
        return None, [], 0, results

    def score(o):
        fr, rej = results[o]
        return (len(fr), sum(x["length"] for x in fr), -rej)
    best = max(found, key=score)              # ties keep "big" (first)
    return best, results[best][0], results[best][1], results


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")


def err(msg):
    sys.stderr.write("carrier_scan: %s\n" % msg)


def cmd_frames(path, verbose):
    with open(path, "rb") as f:
        data = f.read()
    frames, error = split_stream(data)
    for fr in frames:
        emit(fr)
    if error:
        err(error)
        return 1
    return 0


def cmd_scan(path, verbose):
    log = err if verbose else None
    try:
        order, frames, rejected, results = scan_carrier(path, log)
    except (WavError, OSError) as e:
        err("%s: %s" % (path, e))
        return 1
    if order is None:
        err("no frames found in either byte order (rejected candidates: big=%d, little=%d)"
            % (results["big"][1], results["little"][1]))
        return 1
    other = "little" if order == "big" else "big"
    if results[other][0]:
        err("warning: the %s byte order also found %d frame(s)" % (other, len(results[other][0])))
    emit({"byte_order": order})
    for fr in frames:
        emit(fr)
    emit({"rejected_candidates": rejected})
    return 0


def _brief(fr):
    if fr is None:
        return None
    return {"offset": fr["offset"], "codec": fr["codec"], "length": fr["length"],
            "sha256": fr["sha256"]}


def cmd_compare(carrier, stream, verbose):
    log = err if verbose else None
    with open(stream, "rb") as f:
        sdata = f.read()
    sframes, error = split_stream(sdata)
    if error:
        err("stream %s is not entirely valid frames: %s" % (stream, error))
        emit({"match": False, "reason": "invalid stream", "detail": error,
              "stream_frames": len(sframes)})
        return 1
    try:
        order, cframes, rejected, _ = scan_carrier(carrier, log)
    except (WavError, OSError) as e:
        err("%s: %s" % (carrier, e))
        emit({"match": False, "reason": "unreadable carrier", "detail": str(e)})
        return 1

    def key(fr):
        return (fr["codec"], fr["length"], fr["sha256"])
    ck = [key(f) for f in cframes]
    sk = [key(f) for f in sframes]
    if ck == sk:
        emit({"match": True, "byte_order": order, "frames": len(sk),
              "rejected_candidates": rejected})
        return 0

    first = None
    for i in range(max(len(ck), len(sk))):
        a = ck[i] if i < len(ck) else None
        b = sk[i] if i < len(sk) else None
        if a != b:
            first = {"index": i,
                     "carrier": _brief(cframes[i]) if i < len(cframes) else None,
                     "stream": _brief(sframes[i]) if i < len(sframes) else None}
            break
    remaining = {}
    for k in sk:
        remaining[k] = remaining.get(k, 0) + 1
    extra = 0
    for k in ck:
        if remaining.get(k, 0) > 0:
            remaining[k] -= 1
        else:
            extra += 1
    missing = sum(remaining.values())
    emit({"match": False, "byte_order": order, "carrier_frames": len(ck),
          "stream_frames": len(sk), "missing": missing, "extra": extra,
          "reordered": missing == 0 and extra == 0,
          "rejected_candidates": rejected, "first_mismatch": first})
    return 1


USAGE = ("usage: carrier_scan.py frames <stream>\n"
         "       carrier_scan.py scan <carrier.wav>\n"
         "       carrier_scan.py compare <carrier.wav> <stream>\n"
         "       (add -v to explain rejected candidates on stderr)\n")


def main(argv):
    verbose = False
    args = []
    for a in argv:
        if a in ("-v", "--verbose"):
            verbose = True
        else:
            args.append(a)
    try:
        if len(args) == 2 and args[0] == "frames":
            return cmd_frames(args[1], verbose)
        if len(args) == 2 and args[0] == "scan":
            return cmd_scan(args[1], verbose)
        if len(args) == 3 and args[0] == "compare":
            return cmd_compare(args[1], args[2], verbose)
    except OSError as e:
        err(str(e))
        return 1
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
