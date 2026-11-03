#!/usr/bin/env python3
"""Writes dolby-ac4-ims-stub.mp4, the AC-4 test fixture: a valid MP4 whose one audio track is a Dolby AC-4
immersive-stereo ('ac-4' sample entry, 'dac4' config, 16-bit 48 kHz in the entry as real AC-4 files have it)
holding 24 frames of silence-filled bytes. The container is real; the frames are not decodable AC-4, because
nothing here can encode it, and the tests only need the file to be recognized for what it claims to be.

    python3 scripts/make-ac4-fixture.py Packages/VespertineKit/Tests/VespertineAudioTests/Fixtures/dolby-ac4-ims-stub.mp4
"""
import struct
import sys

RATE, FRAME, FRAMES, PAYLOAD = 48_000, 2048, 24, 96

def box(kind, *parts):
    body = b"".join(parts)
    return struct.pack(">I4s", 8 + len(body), kind) + body

def full(kind, version, flags, *parts):
    return box(kind, struct.pack(">I", version << 24 | flags), *parts)

# AC-4 decoder configuration (ETSI TS 103 190-2 annex E): version 1 DSI, one stereo presentation.
DAC4 = bytes.fromhex("20ba02400000001fffffffe0020ff880000042000002501000000308c0010ff88000004200000250100000030080")
DURATION = FRAME * FRAMES
MATRIX = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)

def text(kind, value):
    return box(kind, box(b"data", struct.pack(">II", 1, 0), value.encode()))

def moov(offset):
    mvhd = full(b"mvhd", 0, 0, struct.pack(">IIII", 0, 0, RATE, DURATION), struct.pack(">IH", 0x10000, 0x100),
                bytes(10), MATRIX, bytes(24), struct.pack(">I", 2))
    tkhd = full(b"tkhd", 0, 7, struct.pack(">IIIII", 0, 0, 1, 0, DURATION), bytes(8), struct.pack(">HHHH", 0, 0, 0x100, 0),
                MATRIX, struct.pack(">II", 0, 0))
    mdhd = full(b"mdhd", 0, 0, struct.pack(">IIII", 0, 0, RATE, DURATION), struct.pack(">HH", 0x55C4, 0))
    hdlr = full(b"hdlr", 0, 0, struct.pack(">I4s", 0, b"soun"), bytes(12), b"SoundHandler\0")
    entry = box(b"ac-4", bytes(6), struct.pack(">HHHHHHHHH", 1, 0, 0, 0, 0, 2, 16, 0, 0), struct.pack(">I", RATE << 16), box(b"dac4", DAC4))
    stbl = box(b"stbl", full(b"stsd", 0, 0, struct.pack(">I", 1), entry),
               full(b"stts", 0, 0, struct.pack(">III", 1, FRAMES, FRAME)),
               full(b"stsc", 0, 0, struct.pack(">IIII", 1, 1, FRAMES, 1)),
               full(b"stsz", 0, 0, struct.pack(">II", PAYLOAD, FRAMES)),
               full(b"stco", 0, 0, struct.pack(">II", 1, offset)))
    minf = box(b"minf", full(b"smhd", 0, 0, bytes(4)), box(b"dinf", full(b"dref", 0, 0, struct.pack(">I", 1), full(b"url ", 0, 1))), stbl)
    trak = box(b"trak", tkhd, box(b"mdia", mdhd, hdlr, minf))
    ilst = box(b"ilst", text(b"\xa9nam", "Stub"), text(b"\xa9ART", "Nocturne Test"), text(b"\xa9alb", "Fixtures"))
    meta = full(b"meta", 0, 0, full(b"hdlr", 0, 0, struct.pack(">I4s", 0, b"mdir"), bytes(12), b"\0"), ilst)
    return box(b"moov", mvhd, trak, box(b"udta", meta))

ftyp = box(b"ftyp", b"mp42", struct.pack(">I", 1), b"mp42dby1")
first = len(ftyp) + len(moov(0)) + 8
out = ftyp + moov(first) + box(b"mdat", bytes(PAYLOAD * FRAMES))
open(sys.argv[1], "wb").write(out)
print(f"{sys.argv[1]}: {len(out)} bytes")
