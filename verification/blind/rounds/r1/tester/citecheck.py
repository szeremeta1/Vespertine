#!/usr/bin/env python3
"""Citation checker for the blind-agent round.

Checks, without importing or running any test code:
  1. every entry of CITATIONS (tests/citations.py, parsed as a literal) resolves: the doc exists in
     corpus/index.json, the page exists, the quote occurs verbatim on that page (whitespace collapsed), and the
     section exists in the index and covers that page (or a heading line with that number is on the page or
     one of the 3 pages before it);
  2. every `assert` in tests/test_*.py carries a message whose leading "[KEY,KEY]" names existing citations;
  3. every raises_cited(...) call names existing citations;
  4. every test function contains at least one cited assertion or raises_cited.

Usage: python -I citecheck.py <room_dir> [--json out.json]     exit 0 = all good, 1 = problems
"""
import ast
import json
import re
import sys
from pathlib import Path

PAGE = re.compile(r'^<a id="([^"]+):p(\d+)"></a>$')
KEYS = re.compile(r"^\[([A-Za-z0-9_\-, ]+)\]")


def ws(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def load_pages(md: Path) -> dict:
    pages, cur, infence = {}, None, False
    for ln in md.read_text().split("\n"):
        m = PAGE.match(ln)
        if m:
            cur = int(m.group(2))
            pages[cur] = []
            continue
        if ln.startswith("```"):
            infence = not infence
            continue
        if cur is not None and infence:
            pages[cur].append(ln)
    return {k: "\n".join(v) for k, v in pages.items()}


def check_citation(key, c, corpus, cache, index):
    errs = []
    doc = next((d for d in index["docs"] if d["id"] == c.get("doc")), None)
    if not doc:
        return [f"{key}: unknown doc {c.get('doc')!r}"]
    if doc["id"] not in cache:
        cache[doc["id"]] = load_pages(corpus / doc["file"])
    pages = cache[doc["id"]]
    page = c.get("page")
    if page not in pages:
        return [f"{key}: {doc['id']} has no page {page!r}"]
    quote = ws(str(c.get("quote", "")))
    if len(quote) < 8:
        errs.append(f"{key}: quote too short to be checkable ({quote!r})")
    elif quote not in ws(pages[page]):
        errs.append(f"{key}: quote not found on {doc['id']} p.{page}: {quote[:90]!r}")
    sec = str(c.get("section", ""))
    ok = any(s["id"] == sec and page in s["pages"] for s in doc["sections"])
    if not ok and sec:
        num = re.escape(sec.replace("Annex-", "Annex "))
        pat = re.compile(rf"^\s*{num}\.?\s", re.M)
        ok = any(pat.search(pages.get(p, "")) for p in range(page - 3, page + 1))
    if not ok:
        errs.append(f"{key}: section {sec!r} not found covering {doc['id']} p.{page}")
    if c.get("tier") not in ("primary", "primary-preview", "sibling-standard", "codec-spec", "secondary"):
        errs.append(f"{key}: bad tier {c.get('tier')!r}")
    elif c["tier"] != doc["tier"] and not (c["tier"] == "secondary" and doc["tier"] == "secondary-implementation"):
        errs.append(f"{key}: tier {c['tier']!r} but {doc['id']} is {doc['tier']!r}")
    return errs


def msg_keys(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        s = node.value
    elif isinstance(node, ast.JoinedStr) and node.values and isinstance(node.values[0], ast.Constant):
        s = str(node.values[0].value)
    else:
        return None
    m = KEYS.match(s)
    return [k.strip() for k in m.group(1).split(",")] if m else None


def main(room: Path, out=None) -> int:
    corpus = room / "corpus"
    index = json.loads((corpus / "index.json").read_text())
    cit_file = room / "tests" / "citations.py"
    problems, cache, report = [], {}, {"citations": {}, "tests": {}}
    tree = ast.parse(cit_file.read_text())
    cits = None
    for n in tree.body:
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "CITATIONS" for t in n.targets):
            cits = ast.literal_eval(n.value)
    if not isinstance(cits, dict):
        print("tests/citations.py must define CITATIONS = {...} as a literal dict")
        return 1
    for k, c in cits.items():
        e = check_citation(k, c, corpus, cache, index)
        report["citations"][k] = {"ok": not e, "errors": e, "tier": c.get("tier"), "doc": c.get("doc")}
        problems += e
    used = set()
    for f in sorted((room / "tests").glob("test_*.py")):
        t = ast.parse(f.read_text())
        for fn in ast.walk(t):
            if not (isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)) and fn.name.startswith("test")):
                continue
            n_cited, keys_here = 0, set()
            for node in ast.walk(fn):
                if isinstance(node, ast.Assert):
                    ks = msg_keys(node.msg) if node.msg is not None else None
                    if not ks:
                        problems.append(f"{f.name}:{node.lineno} {fn.name}: assert without a leading [KEY] message")
                        continue
                    n_cited += 1
                    keys_here.update(ks)
                elif isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", "")) == "raises_cited":
                    ks = [a.value for a in node.args[1:] if isinstance(a, ast.Constant) and isinstance(a.value, str)]
                    if not ks:
                        problems.append(f"{f.name}:{node.lineno} {fn.name}: raises_cited without citation keys")
                        continue
                    n_cited += 1
                    keys_here.update(k.strip("[] ") for s in ks for k in s.split(","))
            for k in keys_here:
                if k not in cits:
                    problems.append(f"{f.name} {fn.name}: unknown citation key {k!r}")
            if n_cited == 0:
                problems.append(f"{f.name} {fn.name}: no cited assertion")
            used |= keys_here
            tiers = sorted({cits[k].get("tier") for k in keys_here if k in cits})
            report["tests"][f"{f.name}::{fn.name}"] = {"cited_assertions": n_cited, "keys": sorted(keys_here), "tiers": tiers}
    unused = sorted(set(cits) - used)
    report["unused_citations"] = unused
    report["problems"] = problems
    if out:
        Path(out).write_text(json.dumps(report, indent=1) + "\n")
    print(f"citations: {len(cits)} ({sum(1 for v in report['citations'].values() if v['ok'])} resolve); "
          f"tests: {len(report['tests'])}; problems: {len(problems)}; unused citations: {len(unused)}")
    for p in problems:
        print("  -", p)
    return 1 if problems else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    out = a[a.index("--json") + 1] if "--json" in a else None
    sys.exit(main(Path(a[0]), out))
