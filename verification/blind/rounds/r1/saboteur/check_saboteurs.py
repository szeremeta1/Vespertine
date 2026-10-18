"""Deterministic local checks. Run from room: ./.venv/bin/python saboteurs/check_saboteurs.py.
Fixtures have valid framing headers; compressed audio decoding/CRCs are unverified.
"""
import importlib
import json
from pathlib import Path
import random
import base

rng = random.Random(61937)
NAMES = ("swapped_markers", "pc_datatype", "length_off_by_one", "padding", "byte_order", "dop_bit_order")
variants = {name: importlib.import_module("sab_" + name) for name in NAMES}

def ac3(rate=0, code=0, mode=3):
    f = bytearray(rng.randbytes(base.ac3_size(rate, code)))
    f[:6] = base.AC_SYNC + bytes((0, 0, (rate << 6) | code, (8 << 3) | mode))
    return bytes(f)

def eac3(code=3, typ=0, sid=0, size=32):
    f = bytearray(rng.randbytes(size))
    sizecode = size // 2 - 1
    f[:6] = base.AC_SYNC + bytes(((typ << 6) | (sid << 3) | (sizecode >> 8), sizecode & 255, code << 4, 16 << 3))
    return bytes(f)

def dts(samples, size=96):
    # Header layout: corpus etsi-ts-102114 §5.4.2 p.25.
    prefix = int.from_bytes(base.DTS_SYNC, "big")
    prefix = (prefix << 1) | 1  # FTYPE
    prefix = (prefix << 5) | 31 # SHORT
    prefix <<= 1               # CPF
    prefix = (prefix << 7) | (samples // 32 - 1)
    prefix = (prefix << 14) | (size - 1)
    f = bytearray(rng.randbytes(size))
    f[:8] = (prefix << 4).to_bytes(8, "big")
    return bytes(f)

def diff(a, b):
    assert len(a) == len(b)
    return {i for i, (x, y) in enumerate(zip(a, b)) if x != y}

checks = 0
observed = {name: set() for name in NAMES}
for trial in range(40):
    inputs = [("ac3_burst", ac3(trial % 3, trial % 38)),
              ("eac3_burst", [eac3(trial % 4) for _ in range((6, 3, 2, 1)[trial % 4])])]
    inputs += [("dts_burst", dts(samples, 96 + trial)) for samples in (512, 1024, 2048)]
    for fn, value in inputs:
        expected = getattr(base, fn)(value)
        payload = b"".join(value) if isinstance(value, list) else value
        decoded = base.parse_bursts(expected)
        assert len(decoded) == 1 and decoded[0].payload == payload
        payload_end = 4 + (len(payload) + 1) // 2
        for name, module in variants.items():
            actual = getattr(module, fn)(value)
            changed = diff(expected, actual)
            if name == "pc_datatype" and fn == "dts_burst" and base.dts_header(value) == "dts2048":
                assert changed == {2} and actual[2] == 0x0C
            elif name == "length_off_by_one" and fn == "eac3_burst":
                assert changed == {3} and actual[3] == expected[3] + 1
            elif name == "padding":
                assert changed == set(range(payload_end, len(expected)))
                assert all(x == 1 for x in actual[payload_end:])
            elif name == "byte_order":
                assert actual[:4] == expected[:4] and actual[payload_end:] == expected[payload_end:]
                assert actual[4:payload_end] == [((x & 255) << 8) | (x >> 8) for x in expected[4:payload_end]]
            else:
                assert actual == expected, (name, fn)
            if changed:
                observed[name].add(fn)
            # The IEC mutations change emitters only; parsers accept the valid baseline stream unchanged.
            assert module.parse_bursts(expected) == decoded
            checks += 1
    dsd = [rng.randbytes(2 * (trial + 1)) for _ in range(1 + trial % 4)]
    for marker in base.DOP_MARKERS:
        expected = base.dop_pack(dsd, marker)
        assert base.dop_unpack(expected) == (dsd, marker)
        for name, module in variants.items():
            actual = module.dop_pack(dsd, marker)
            if name == "swapped_markers":
                assert all((a & 0xFFFF) == (b & 0xFFFF) and (a >> 16) == ((b >> 16) ^ 255)
                           for ar, br in zip(actual, expected) for a, b in zip(ar, br))
            elif name == "dop_bit_order":
                assert all((a >> 16) == (b >> 16) and (a & 0xFFFF) == int(format(b & 0xFFFF, "016b")[::-1], 2)
                           for ar, br in zip(actual, expected) for a, b in zip(ar, br))
            else:
                assert actual == expected
            assert module.dop_unpack(actual) == (dsd, marker)
            module.dop_unpack(expected) # valid baseline input must run too
            if actual != expected:
                observed[name].update(("dop_pack", "dop_unpack"))
            checks += 1
    assert base.dop_pack(dsd, marker) == expected # no global contamination

# Every AC-3 table entry and rate runs, including the largest supported frame.
for rate in range(3):
    for code in range(38):
        f = ac3(rate, code)
        assert base.parse_bursts(base.ac3_burst(f))[0].payload == f
        checks += 1
# Multiple E-AC-3 substreams; dependent frames must stay in the completed group.
frames = [eac3(0, typ, sid) for _ in range(12) for typ, sid in ((0, 0), (1, 0), (0, 1), (1, 0))]
expected_groups = [list(range(24)), list(range(24, 48))]
assert base.eac3_group(frames) == expected_groups
for module in variants.values():
    assert module.eac3_group(frames) == expected_groups
    assert module.eac3_group([]) == []
    for ids in expected_groups:
        module.eac3_burst([frames[i] for i in ids])
        checks += 1
# Concatenation, offset tracking, and preamble-like payload words.
f = bytearray(ac3()); f[10:14] = bytes.fromhex("f8724e1f")
a = base.ac3_burst(bytes(f)); b = base.dts_burst(dts(1024))
assert [x.offset for x in base.parse_bursts(a+b)] == [0, len(a)]
for fn, args, exc in [
    (base.dop_pack, ([b"x"],), base.DoPError),
    (base.dop_pack, ([b""],), base.DoPError),
    (base.dop_unpack, ([],), base.DoPError),
    (base.dop_unpack, ([[0x051234], [0x055678]],), base.DoPError),
    (base.ac3_burst, (b"bad",), base.BurstError),
    (base.eac3_burst, ([eac3(0)],), base.BurstError),
    (base.dts_burst, (dts(512, 2048),), base.BurstError),
    (base.parse_bursts, ([*base.SYNC_WORDS],), base.BurstError),
    (base.parse_bursts, ([*base.SYNC_WORDS, 1, 1024, 1],), base.BurstError),
]:
    try:
        fn(*args)
    except exc:
        checks += 1
    else:
        raise AssertionError((fn.__name__, "accepted invalid input"))
assert all(observed.values())
result = {"status": "PASS", "checks": checks, "random_trials": 40,
          "changed_public_functions": {k: sorted(v) for k,v in observed.items()},
          "fixture_limit": "structurally valid framing headers; compressed decoding and CRCs unverified"}
Path(__file__).with_name("CHECK_RESULTS.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
