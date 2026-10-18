"""Deterministic input builders and word helpers for the vblind suite (no expected values live here that the
tests do not cite: header layouts come from the codec specs, frame sizes from the cited table rows)."""


def body(n: int, seed: int) -> bytes:
    return bytes(((i * 37 + seed * 11 + 5) & 0xFF) for i in range(n))


def bits(fields):
    """fields: [(value, width)], MSB first -> (int, total width)."""
    acc, n = 0, 0
    for v, w in fields:
        assert 0 <= v < (1 << w)
        acc = (acc << w) | v
        n += w
    return acc, n


def bits_bytes(fields) -> bytes:
    acc, n = bits(fields)
    pad = (-n) % 8
    return (acc << pad).to_bytes((n + pad) // 8, "big")


# ---------------------------------------------------------------------------------------------- AC-3
# words per syncframe, from the cited rows of A/52 Table 5.18: (fscod, frmsizecod) -> words
# Table 5.18 pp.52-53: code, words at 48 / 44.1 / 32 kHz.
AC3_SIZE_ROWS = [(0, 64, 69, 96),
 (1, 64, 70, 96),
 (2, 80, 87, 120),
 (3, 80, 88, 120),
 (4, 96, 104, 144),
 (5, 96, 105, 144),
 (6, 112, 121, 168),
 (7, 112, 122, 168),
 (8, 128, 139, 192),
 (9, 128, 140, 192),
 (10, 160, 174, 240),
 (11, 160, 175, 240),
 (12, 192, 208, 288),
 (13, 192, 209, 288),
 (14, 224, 243, 336),
 (15, 224, 244, 336),
 (16, 256, 278, 384),
 (17, 256, 279, 384),
 (18, 320, 348, 480),
 (19, 320, 349, 480),
 (20, 384, 417, 576),
 (21, 384, 418, 576),
 (22, 448, 487, 672),
 (23, 448, 488, 672),
 (24, 512, 557, 768),
 (25, 512, 558, 768),
 (26, 640, 696, 960),
 (27, 640, 697, 960),
 (28, 768, 835, 1152),
 (29, 768, 836, 1152),
 (30, 896, 975, 1344),
 (31, 896, 976, 1344),
 (32, 1024, 1114, 1536),
 (33, 1024, 1115, 1536),
 (34, 1152, 1253, 1728),
 (35, 1152, 1254, 1728),
 (36, 1280, 1393, 1920),
 (37, 1280, 1394, 1920)]
AC3_WORDS = {(rate, code): sizes[rate] for code, *sizes in AC3_SIZE_ROWS for rate in range(3)}


def ac3_frame(fscod: int, frmsizecod: int, bsmod: int = 0, bsid: int = 8, seed: int = 1) -> bytes:
    n = AC3_WORDS[(fscod, frmsizecod)] * 2
    head = bits_bytes([(0x0B77, 16), (0x1234, 16), (fscod, 2), (frmsizecod, 6), (bsid, 5), (bsmod, 3)])
    return head + body(n - len(head), seed)


# ------------------------------------------------------------------------------------------- E-AC-3
def eac3_frame(numblkscod: int, nwords: int, convsync: int = 1, seed: int = 1) -> bytes:
    f = [(0x0B77, 16), (0, 2), (0, 3), (nwords - 1, 11), (0, 2), (numblkscod, 2), (2, 3), (0, 1), (16, 5),
         (27, 5), (0, 1), (0, 1), (0, 1)]          # ... dialnorm, compre, mixmdate, infomdate
    if numblkscod != 3:
        f.append((convsync, 1))
    f.append((0, 1))                                # addbsie
    head = bits_bytes(f)
    return head + body(nwords * 2 - len(head), seed)


def eac3_stream(numblkscod: int, ngroups: int, nwords: int = 200):
    """Frames of one independent substream; convsync=1 on the first frame of every group of six blocks."""
    per = {0: 6, 1: 3, 2: 2, 3: 1}[numblkscod]
    return [eac3_frame(numblkscod, nwords, convsync=1 if i % per == 0 else 0, seed=i + 1)
            for i in range(ngroups * per)]


# ------------------------------------------------------------------------------------------------ DTS
def dts_frame(nblks: int, size: int, seed: int = 1) -> bytes:
    head = bits_bytes([(0x7FFE8001, 32), (1, 1), (31, 5), (0, 1), (nblks, 7), (size - 1, 14), (2, 6), (13, 4),
                       (15, 5), (0, 1), (0, 1), (0, 1), (0, 1), (0, 1), (0, 3), (0, 1), (0, 1), (0, 2), (0, 1)])
    return head + body(size - len(head), seed)


# ------------------------------------------------------------------------------------------------ words
def words_of(data: bytes):
    """Big-endian 16-bit words of data; a lone final byte is MSB-aligned."""
    out = []
    for i in range(0, len(data), 2):
        out.append((data[i] << 8) | (data[i + 1] if i + 1 < len(data) else 0))
    return out


def bytes_of(words):
    return b"".join(w.to_bytes(2, "big") for w in words)


def hand_burst(data_type, payload, pd, err=0, dtd=0, stream=0, lead=0, total=None):
    """A burst built straight from the cited field layout (Pc: type 0-4, err 7, dtd 8-12, stream 13-15)."""
    pc = data_type | (err << 7) | (dtd << 8) | (stream << 13)
    w = [0] * lead + [0xF872, 0x4E1F, pc, pd] + words_of(payload)
    if total is not None:
        w += [0] * (total - len(w))
    elif len(w) % 2:
        w.append(0)
    return w
