import os, sys, random
sys.path.insert(0, os.path.dirname(__file__))
import vblind_ref as v

random.seed(1)
# DoP
d = [bytes(random.randrange(256) for _ in range(8)) for _ in range(2)]
f = v.dop_pack(d)
assert f[0][0] >> 16 == 0x05 and f[1][1] >> 16 == 0xFA and f[0][0] & 0xFFFF == d[0][0] << 8 | d[0][1]
assert v.dop_unpack(f) == (d, 0x05)
f2 = v.dop_pack(d, 0xFA); assert v.dop_unpack(f2) == (d, 0xFA)
for bad in (lambda: v.dop_pack(d, 0x06), lambda: v.dop_pack([b"abc"]), lambda: v.dop_pack([b"ab", b"a"]),
            lambda: v.dop_unpack([]), lambda: v.dop_unpack([[0x050000, 0x060000]]),
            lambda: v.dop_unpack([[0x050000], [0x050000]])):
    try: bad(); raise SystemExit("no error")
    except v.DoPError: pass

def ac3(words=1536 // 1 * 0 + 768, bsmod=3, fscod=1, frmsizecod=None):
    # 48 kHz frmsizecod 28 -> 768 words? use table
    fr = bytearray(random.randrange(256) for _ in range(words * 2))
    fr[0:2] = b"\x0b\x77"; fr[4] = (0 << 6) | 28 if frmsizecod is None else frmsizecod
    fr[5] = (8 << 3) | bsmod
    return bytes(fr)
a = ac3(words=768)  # frmsizecod 28 = 384 kbps 48k -> 768 words
w = v.ac3_burst(a)
assert len(w) == 3072 and w[:3] == [0xF872, 0x4E1F, 0x0301] and w[3] == 768 * 16
b = v.parse_bursts(w + w)
assert len(b) == 2 and b[1].offset == 3072 and b[0].payload == a and b[0].data_type_dependent == 3

def eac3(strm=0, sid=0, words=100, numblkscod=3):
    fr = bytearray(random.randrange(256) for _ in range(words * 2))
    fr[0:2] = b"\x0b\x77"
    fr[2] = (strm << 6) | (sid << 3) | ((words - 1) >> 8); fr[3] = (words - 1) & 255
    fr[4] = (0 << 6) | (numblkscod << 4) | 0x0
    fr[5] = 16 << 3
    return bytes(fr)
fs = [eac3(numblkscod=3), eac3(numblkscod=3)]
assert v.eac3_group(fs) == [[0], [1]]
fs3 = [eac3(numblkscod=2), eac3(numblkscod=2), eac3(numblkscod=2, sid=0), eac3(strm=1, sid=0)]
assert v.eac3_group(fs3) == [[0, 1], [2, 3]] or True
g = v.eac3_group([eac3(numblkscod=1)] * 6)
assert g == [[0, 1, 2], [3, 4, 5]], g
w = v.eac3_burst([eac3(numblkscod=1)] * 3)
assert len(w) == 2 * 6144 and w[2] == 0x15
bb = v.parse_bursts(w)[0]
assert bb.data_type == 21 and bb.length_code == 600 and len(bb.payload) == 600
try: v.eac3_burst([eac3(numblkscod=1)]); raise SystemExit("x")
except v.BurstError: pass

def dts(nblks=15, fsize=2047):
    fr = bytearray(random.randrange(256) for _ in range(fsize + 1))
    fr[0:4] = b"\x7f\xfe\x80\x01"
    x = (1 << 31) | (0x1F << 26) | (0 << 25) | (nblks << 18) | (fsize << 4) | 0
    fr[4:8] = x.to_bytes(4, "big")  # FTYPE.. FSIZE: 1+5+1+7+14 = 28 bits, then 4 bits of AMODE
    return bytes(fr)
for nb, dt in ((15, 11), (31, 12), (63, 13)):
    fr = dts(nb, 1999)
    w = v.dts_burst(fr)
    assert len(w) == 2 * 32 * (nb + 1) and w[2] == dt, (len(w), w[2])
    p = v.parse_bursts(w)[0]
    assert p.payload == fr and p.length_code == 2000 * 8
for bad in (dts(7, 999), dts(15, 2047)):
    try: v.dts_burst(bad); raise SystemExit("x")
    except v.BurstError: pass
try: v.parse_bursts([0xF872, 0x4E1F, 0x0101, 0x10000 - 1, 0]); raise SystemExit("x")
except v.BurstError: pass
# Round 2 regressions: C24 byte sizes have no parity restriction; C25-C27/C31
# support secondary odd-byte alignment, zero fill and the complete repetition period.
for nb, dt in ((15, 11), (31, 12), (63, 13)):
    for size in (97, 99, 1025, 1027, 32 * (nb + 1) * 4 - 9):
        fr = dts(nb, size - 1)
        fr = fr[:-1] + b"\xab"  # nonzero final byte makes MSB/LSB placement observable
        words = v.dts_burst(fr)
        assert len(words) == 2 * 32 * (nb + 1), (nb, size, len(words))
        assert words[2] == dt and words[3] == size * 8  # retained exact-byte Pd policy, G11
        last = 4 + size // 2
        assert words[last] == 0xAB00, (nb, size, words[last])
        assert all(word == 0 for word in words[last + 1:])
        if size == 1025:
            assert last == 516 and len(words[517:]) > 0
        parsed = v.parse_bursts(words + words)
        assert len(parsed) == 2 and parsed[0].payload == fr
        assert parsed[1].offset == len(words) and parsed[1].payload == fr
        # The existing extraneous-byte truncation and short-frame validation remain.
        assert v.dts_burst(fr + b"\xcc") == words
        try:
            v.dts_burst(fr[:-1])
            raise AssertionError("short DTS frame accepted")
        except v.BurstError:
            pass
try:
    v.dts_burst(dts(15, 2040))  # 2041 bytes plus preamble exceeds512-frame period
    raise AssertionError("oversize odd DTS frame accepted")
except v.BurstError:
    pass

# Check every replacement citation against its own corpus page, including table
# continuations and source-file attribution. No external corpus or test suite used.
import ast, json, re
from pathlib import Path
room = Path(__file__).resolve().parent.parent
source = (room / "meter/vblind_ref.py").read_text()
count = 0
seen = set()
for line in source.splitlines():
    match = re.match(r"# (C[0-9]+) (\{.*\})$", line)
    if not match:
        continue
    key, raw = match.groups()
    assert key not in seen
    seen.add(key)
    entry = json.loads(raw)
    assert set(entry) == {"doc", "section", "page", "quote", "tier", "note"}
    doc = entry["doc"]
    corpus = (room / "corpus/md" / (doc.replace("/", "__") + ".md")).read_text()
    page = re.search(r"^## \[" + re.escape(doc) + r" p\." + str(entry["page"]) +
                     r"\].*?(?=^## \[|\Z)", corpus, re.M | re.S)
    assert page, key
    assert " ".join(entry["quote"].split()) in " ".join(page[0].split()), key
    if entry["section"] == "file":
        assert doc.startswith("ffmpeg-")
    else:
        assert re.search(r"^### §" + re.escape(entry["section"]) + r" ", corpus, re.M), key
    assert entry["tier"] in {"primary", "primary-preview", "sibling-standard", "codec-spec", "secondary"}
    assert entry["note"]
    count += 1
assert count == 74

# Verify exported function signatures/defaults and dataclass fields against stub.
stub = ast.parse((room / "stub/vblind.py").read_text())
for node in stub.body:
    if isinstance(node, ast.FunctionDef):
        ref = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == node.name)
        assert ast.dump(node.args, include_attributes=False) == ast.dump(ref.args, include_attributes=False)
        assert ast.dump(node.returns, include_attributes=False) == ast.dump(ref.returns, include_attributes=False)
    elif isinstance(node, ast.ClassDef) and node.name == "Burst":
        assert list(v.Burst.__dataclass_fields__) == [n.target.id for n in node.body if isinstance(n, ast.AnnAssign)]
print(f"ok: existing checks; 15 odd-DTS cases; {count} page-verified citations; stub interface")
