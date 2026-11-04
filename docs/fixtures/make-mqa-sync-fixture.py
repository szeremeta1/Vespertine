#!/usr/bin/env python3
# 0.256 s of a 24-bit stereo tone whose 16th bit (left XOR right) carries MQA's 36-bit synchronisation word 0xBE0498C88,
# repeated every 4096 frames, as the detection in UndecodedFormat.hasMQASync expects. Not MQA audio: only that one pattern.
import math, struct, sys
pattern = [int(b) for b in format(0xBE0498C88, '036b')]
n = 12288
out = bytearray()
for i in range(n):
    v = int(0.3 * 8388607 * math.sin(2 * math.pi * 440 * i / 48000))
    l = v & ~(1 << 16)
    bit = pattern[(i % 4096)] if (i % 4096) < 36 else 0
    r = (int(0.3 * 8388607 * math.sin(2 * math.pi * 550 * i / 48000)) & ~(1 << 16)) | (bit << 16)
    for s in (l, r):
        out += struct.pack('<i', s)[:3]
open(sys.argv[1], 'wb').write(out)
