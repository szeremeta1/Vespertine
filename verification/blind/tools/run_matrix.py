#!/usr/bin/env python3
"""Run the tester's suite against every implementation and tabulate the results.

Usage: python3 -I verification/blind/tools/run_matrix.py <round_dir> <python_with_pytest> [--vespertine] [--out DIR]
  <round_dir> (rounds/rN) holds tester/ (tests/, conftest.py, pytest.ini, stub/), meter/vblind_ref.py and
  saboteur/{base,sab_*}.py. --vespertine adds Vespertine through tools/vespertine_adapter.py (needs the bridge
  built: cd bridge && swift build --build-tests). Writes <out>/matrix.json and <out>/matrix.md.
"""
import json
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def run(room: Path, py: str, impl: Path | None, extra_env=None) -> dict:
    with tempfile.TemporaryDirectory() as t:
        xml = Path(t) / "r.xml"
        env = dict(os.environ, **(extra_env or {}))
        env.pop("VBLIND_IMPL", None)
        if impl:
            env["VBLIND_IMPL"] = str(impl)
        subprocess.run([py, "-m", "pytest", "tests", "-q", "-p", "no:cacheprovider", f"--junitxml={xml}"],
                       cwd=room, env=env, capture_output=True, text=True, timeout=3600)
        res = {}
        for tc in ET.parse(xml).getroot().iter("testcase"):
            name = f"{tc.get('classname').split('.')[-1]}::{tc.get('name')}"
            fail = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
            if tc.find("skipped") is not None:
                res[name] = {"outcome": "skipped"}
            elif fail is not None:
                msg = (fail.get("message") or "")[:300]
                out = "n/a" if "NotApplicable" in msg or "NotApplicable" in (fail.text or "")[-2000:] else "failed"
                res[name] = {"outcome": out, "message": msg}
            else:
                res[name] = {"outcome": "passed"}
        return res


def main(argv):
    rnd, py = Path(argv[0]).resolve(), argv[1]
    out = Path(argv[argv.index("--out") + 1]) if "--out" in argv else rnd / "results"
    out.mkdir(parents=True, exist_ok=True)
    room = rnd / "tester"
    impls = {"stub (null)": None, "meter (reference)": rnd / "meter/vblind_ref.py",
             "saboteur base": rnd / "saboteur/base.py"}
    for p in sorted((rnd / "saboteur").glob("sab_*.py")):
        impls[p.stem] = p
    env = {}
    if "--vespertine" in argv:
        adapter = Path(__file__).resolve().parent / "vespertine_adapter.py"
        impls["Vespertine"] = adapter
        impls["Vespertine + reference parser"] = adapter
    results = {}
    for name, impl in impls.items():
        e = {"VBLIND_REF_PARSER": str(rnd / "meter/vblind_ref.py")} if name.endswith("reference parser") else {}
        print(f"running {name} ...", flush=True)
        results[name] = run(room, py, impl, e)
    tests = sorted({t for r in results.values() for t in r})
    (out / "matrix.json").write_text(json.dumps({"tests": tests, "results": results}, indent=1) + "\n")
    md = ["| Implementation | passed | failed | n/a | skipped |", "|---|---|---|---|---|"]
    for name, r in results.items():
        c = {k: sum(1 for v in r.values() if v["outcome"] == k) for k in ("passed", "failed", "n/a", "skipped")}
        md.append(f"| {name} | {c['passed']} | {c['failed']} | {c['n/a']} | {c['skipped']} |")
    md += ["", "| Saboteur | caught by |", "|---|---|"]
    for name, r in results.items():
        if name.startswith("sab_"):
            killers = [t for t, v in r.items() if v["outcome"] == "failed"]
            md.append(f"| {name} | {len(killers)} tests: " + ", ".join(f"`{k.split('::')[-1]}`" for k in killers[:8]) +
                      (" ..." if len(killers) > 8 else "") + " |")
    for name in ("Vespertine", "Vespertine + reference parser"):
        if name in results:
            md += ["", f"Failures against {name}:", ""]
            for t, v in results[name].items():
                if v["outcome"] == "failed":
                    md.append(f"- `{t}`: {v['message'][:220]}")
    (out / "matrix.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
