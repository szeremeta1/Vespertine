#!/usr/bin/env python3
"""Compare Vespertine's exported DoP / IEC 61937 output with the blind reference implementation, byte for byte.

Inputs: vectors/inputs.json (tools/vectors.py), vectors/vespertine.json (bridge/, `swift test`), and the reference
module (agents/meter/vblind_ref.py). The serialized forms compared are the ones a Core Audio buffer holds:
IEC 61937 carriers as interleaved signed 16-bit little-endian samples, DoP as interleaved 24-bit little-endian
samples. Offsets are byte offsets into those buffers.

Usage: python3 -I verification/blind/tools/compare.py <vectors_dir> <reference.py> [--json out.json] [--md out.md]
"""
import importlib.util
import json
import sys
from pathlib import Path


def load(path):
    p = Path(path).resolve()
    sys.path.insert(0, str(p.parent))
    spec = importlib.util.spec_from_file_location("vblind_reference", p)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def words_hex(h):
    return [int(h[i:i + 4], 16) for i in range(0, len(h), 4)]


def s16le(words):
    return b"".join(w.to_bytes(2, "little") for w in words)


def s24le(frames):
    return b"".join(w.to_bytes(3, "little") for f in frames for w in f)


def runs(idx):
    out = []
    for i in idx:
        if out and i == out[-1][1] + 1:
            out[-1][1] = i
        else:
            out.append([i, i])
    return out


def diff_bytes(ref: bytes, ves: bytes, unit: int, describe):
    """Mismatching byte offsets, grouped into runs, each with a description of the first sample in it."""
    n = min(len(ref), len(ves))
    bad = [i for i in range(n) if ref[i] != ves[i]]
    res = {"ref_bytes": len(ref), "ves_bytes": len(ves), "mismatched_bytes": len(bad) + abs(len(ref) - len(ves)),
           "runs": []}
    for a, b in runs(bad)[:20]:
        s = a // unit * unit
        res["runs"].append({"from": a, "to": b, "first_sample": describe(s // unit),
                            "ref": ref[s:s + unit].hex(), "ves": ves[s:s + unit].hex()})
    if len(ref) != len(ves):
        res["length_differs"] = True
    return res


def main(vdir: Path, ref_path: str, out_json=None, out_md=None) -> int:
    inp = json.loads((vdir / "inputs.json").read_text())
    ves = json.loads((vdir / "vespertine.json").read_text())
    ref = load(ref_path)
    rows = []

    def record(kind, name, fn_ref, ves_entry, serialize, unit, describe, ves_refused=None):
        try:
            r = fn_ref()
        except Exception as e:                       # the reference refuses this input
            if ves_refused is not None:
                rows.append({"kind": kind, "name": name, "result": "BOTH-REFUSE",
                             "detail": f"reference {type(e).__name__}: {e}; Vespertine {ves_refused}"})
            else:
                rows.append({"kind": kind, "name": name, "result": "REF-REFUSES", "detail": f"{type(e).__name__}: {e}",
                             "ves_bytes": len(serialize(ves_entry))})
            return
        if ves_refused is not None:
            rows.append({"kind": kind, "name": name, "result": "VES-REFUSES", "detail": ves_refused})
            return
        rb, vb = serialize(r), serialize(ves_entry)
        if rb == vb:
            rows.append({"kind": kind, "name": name, "result": "MATCH", "bytes": len(rb)})
        else:
            rows.append({"kind": kind, "name": name, "result": "MISMATCH", "diff": diff_bytes(rb, vb, unit, describe)})

    for c, v in zip(inp["dop"], ves["dop"]):
        planes = [bytes.fromhex(p) for p in c["planes"]]
        ch = len(planes)
        record("dop", c["name"], lambda: ref.dop_pack(planes, c["first_marker"]), v["frames"], s24le, 3,
               lambda k, ch=ch: f"frame {k // ch} channel {k % ch}")
    for kind in ("ac3", "eac3", "dts"):
        for c, v in zip(inp[kind], ves[kind]):
            if kind == "ac3":
                fn = lambda c=c: ref.ac3_burst(bytes.fromhex(c["frame"]))
            elif kind == "eac3":
                fn = lambda c=c: ref.eac3_burst([bytes.fromhex(f) for f in c["frames"]])
            else:
                fn = lambda c=c: ref.dts_burst(bytes.fromhex(c["frame"]))
            record(kind, c["name"], fn, words_hex(v.get("words", "")), s16le, 2,
                   lambda k: f"word {k} (frame {k // 2} subframe {k % 2 + 1})", v.get("refused"))
    for c, v in zip(inp["eac3_group"], ves["eac3_group"]):
        frames = [bytes.fromhex(f) for f in c["frames"]]
        try:
            g = ref.eac3_group(frames)
            res = "MATCH" if [list(x) for x in g] == v["groups"] else "MISMATCH"
            rows.append({"kind": "eac3_group", "name": c["name"], "result": res, "ref": g, "ves": v["groups"]})
        except Exception as e:
            rows.append({"kind": "eac3_group", "name": c["name"], "result": "REF-REFUSES", "detail": str(e)})
    for c, v in zip(inp["ac3_stream"], ves["ac3_stream"]):
        frames = [bytes.fromhex(f) for f in c["frames"]]
        record("ac3_stream", c["name"], lambda: [w for f in frames for w in ref.ac3_burst(f)], words_hex(v["words"]),
               s16le, 2, lambda k: f"word {k} (burst {k // 3072}, word {k % 3072} in it)")
    for c, v in zip(inp["eac3_stream"], ves["eac3_stream"]):
        frames = [bytes.fromhex(f) for f in c["frames"]]
        record("eac3_stream", c["name"],
               lambda: [w for g in ref.eac3_group(frames) for w in ref.eac3_burst([frames[i] for i in g])],
               words_hex(v["words"]), s16le, 2, lambda k: f"word {k} (burst {k // 12288}, word {k % 12288} in it)")

    summary = {}
    for r in rows:
        summary[r["result"]] = summary.get(r["result"], 0) + 1
    report = {"summary": summary, "rows": rows}
    if out_json:
        Path(out_json).write_text(json.dumps(report, indent=1) + "\n")
    md = ["| Kind | Input | Result | Detail |", "|---|---|---|---|"]
    for r in rows:
        if r["result"] == "MATCH":
            d = f"{r.get('bytes', '')} bytes identical" if "bytes" in r else "same groups"
        elif r["result"] == "REF-REFUSES":
            d = f"reference refuses ({r['detail']}); Vespertine produced {r.get('ves_bytes', '?')} bytes"
        elif r["result"] == "BOTH-REFUSE":
            d = f"both refuse ({r['detail']})"
        elif r["result"] == "VES-REFUSES":
            d = f"Vespertine refuses ({r['detail']}); the reference produced output"
        elif "diff" in r:
            x = r["diff"]
            d = f"{x['mismatched_bytes']} bytes differ (ref {x['ref_bytes']} B, Vespertine {x['ves_bytes']} B); " + "; ".join(
                f"bytes {u['from']}-{u['to']}: {u['first_sample']} ref {u['ref']} vs {u['ves']}" for u in x["runs"][:4])
        else:
            d = f"ref {r['ref']} vs Vespertine {r['ves']}"
        md.append(f"| {r['kind']} | {r['name']} | {r['result']} | {d} |")
    text = "\n".join(md) + "\n"
    if out_md:
        Path(out_md).write_text(text)
    print(text)
    print("summary:", summary)
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    oj = a[a.index("--json") + 1] if "--json" in a else None
    om = a[a.index("--md") + 1] if "--md" in a else None
    sys.exit(main(Path(a[0]), a[1], oj, om))
