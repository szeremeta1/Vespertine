#!/usr/bin/env python3
# Synthesizes DSD (2nd-order sigma-delta of tones, one frequency per channel) and writes DSDIFF (MSB first, interleaved)
# and DSF (LSB first, blocks of 4096 per channel), so WavPack can encode both. Prints the SHA-256 of the MSB-first, channel-interleaved bytes.
import hashlib, math, struct, sys
def modulate(channels, nbytes, rate):
    planes = []
    for c in range(channels):
        i1 = i2 = 0.0
        f = 300.0 * (c + 1)
        out = bytearray(nbytes)
        for n in range(nbytes * 8):
            x = 0.4 * math.sin(2 * math.pi * f * n / rate)
            v = 1.0 if i2 >= 0 else -1.0
            i1 += x - v
            i2 += i1 - 2 * v
            if v > 0: out[n // 8] |= 0x80 >> (n % 8)
        planes.append(bytes(out))
    return planes
def rev(b): return int('{:08b}'.format(b)[::-1], 2)
def write_dff(path, planes, rate, ids):
    ch = len(planes); n = len(planes[0])
    data = bytearray()
    for i in range(n):
        for c in range(ch): data.append(planes[c][i])
    def chunk(tag, body):
        b = tag + struct.pack('>Q', len(body)) + body
        return b + (b'\0' if len(body) & 1 else b'')
    chnl = struct.pack('>H', ch) + b''.join(i.encode().ljust(4) for i in ids)
    prop = b'SND ' + chunk(b'FS  ', struct.pack('>I', rate)) + chunk(b'CHNL', chnl) + chunk(b'CMPR', b'DSD ' + bytes([14]) + b'not compressed')
    body = b'DSD ' + chunk(b'FVER', struct.pack('>I', 0x01050000)) + chunk(b'PROP', prop) + chunk(b'DSD ', bytes(data))
    open(path, 'wb').write(b'FRM8' + struct.pack('>Q', len(body)) + body)
def write_dsf(path, planes, rate, ctype):
    ch = len(planes); n = len(planes[0]); block = 4096
    nblocks = (n + block - 1) // block
    data = bytearray()
    for b in range(nblocks):
        for c in range(ch):
            seg = planes[c][b * block:(b + 1) * block]
            data += bytes(rev(x) for x in seg) + b'\0' * (block - len(seg))
    fmt = b'fmt ' + struct.pack('<QIIIIIIQI', 52, 1, 0, ctype, ch, rate, 1, n * 8, block) + b'\0\0\0\0'
    dchunk = b'data' + struct.pack('<Q', 12 + len(data)) + bytes(data)
    total = 28 + len(fmt) + len(dchunk)
    head = b'DSD ' + struct.pack('<QQQ', 28, total, 0)
    open(path, 'wb').write(head + fmt + dchunk)
def main():
    name, channels, mult, frames = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    rate = 2822400 * mult
    nbytes = 4704 * mult * frames
    planes = modulate(channels, nbytes, rate)
    ids = {2: ['SLFT', 'SRGT'], 6: ['MLFT', 'MRGT', 'C   ', 'LFE ', 'LS  ', 'RS  ']}[channels]
    write_dff(name + '.dff', planes, rate, ids)
    ctype = {2: 2, 6: 7}[channels]
    write_dsf(name + '.dsf', planes, rate, ctype)
    inter = bytearray()
    for i in range(nbytes):
        for c in range(channels): inter.append(planes[c][i])
    print(name, channels, rate, nbytes, hashlib.sha256(bytes(inter)).hexdigest())
main()
