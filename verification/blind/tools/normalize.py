#!/usr/bin/env python3
"""Deterministic PDF/source -> markdown normalizer for the blind-agent spec corpus.

Every page becomes a fenced text block (pdftotext -layout keeps tables as fixed-width columns), preceded by a
page anchor. Section headings are detected per document and emitted as anchors between fences, so a citation
"doc, section, page" can be resolved exactly. Output is a pure function of the input bytes and the pinned
pdftotext version (recorded in corpus/index.json); re-running produces byte-identical files.

Usage: python3 -I tools/normalize.py <corpus_dir>
  reads  <corpus_dir>/sources.json and <corpus_dir>/raw/<id>/<file>
  writes <corpus_dir>/md/<id>.md and <corpus_dir>/index.json
"""
import hashlib
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

# Lines that look like section headings: "7.2 burst_preamble", "1. Motivation", "Annex A (normative) ...".
def heading_re(cfg: dict) -> re.Pattern:
    lead, gap = cfg.get("max_indent", 4), cfg.get("max_gap", 8)
    dot = r"\." if cfg.get("require_dot") else r"\.?"
    first = r"[A-Za-z_]" if cfg.get("allow_lowercase_title") else r"[A-Z_]"
    return re.compile(rf"^\s{{0,{lead}}}((?:\d+\.)*\d+){dot}\s{{1,{gap}}}({first}[^\n]{{1,90}})$")
ANNEX = re.compile(r"^\s{0,4}(Annex\s+[A-Z])\b\s*(.{0,90})$")
TOC_LINE = re.compile(r"(\.{4,}|…{2,}|\s\d+\s*$)")


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def clean(text: str) -> str:
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("­", "")       # soft hyphen
    text = text.replace("\t", "    ")
    lines = [ln.rstrip() for ln in text.split("\n")]
    out, blank = [], 0
    for ln in lines:
        blank = blank + 1 if not ln else 0
        if blank <= 2:
            out.append(ln)
    while out and not out[-1]:
        out.pop()
    while out and not out[0]:
        out.pop(0)
    return "\n".join(out)


def pdf_pages(pdf: Path) -> list[str]:
    info = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, text=True, check=True).stdout
    n = int(re.search(r"^Pages:\s+(\d+)", info, re.M).group(1))
    pages = []
    for i in range(1, n + 1):
        t = subprocess.run(["pdftotext", "-layout", "-enc", "UTF-8", "-f", str(i), "-l", str(i), str(pdf), "-"],
                           capture_output=True, text=True, check=True).stdout
        pages.append(clean(t.replace("\f", "")))
    return pages


def headings(page: str, cfg: dict) -> list[tuple[int, str, str]]:
    """(line index, section id, title) for heading lines on a page."""
    found = []
    min_title = cfg.get("min_title_len", 3)
    skip = [re.compile(s) for s in cfg.get("skip_heading_regex", [])]
    for i, ln in enumerate(page.split("\n")):
        if TOC_LINE.search(ln) and not cfg.get("headings_may_end_in_number"):
            continue
        m = ANNEX.match(ln)
        if m:
            found.append((i, m.group(1).replace(" ", "-"), ln.strip()))
            continue
        m = heading_re(cfg).match(ln)
        if not m:
            continue
        sec, title = m.group(1), m.group(2).strip()
        if len(title) < min_title or any(s.search(ln) for s in skip):
            continue
        if sec.count(".") > cfg.get("max_depth", 4) or int(sec.split(".")[0]) > cfg.get("max_top", 30):
            continue
        if "  " in title.strip() and not cfg.get("allow_gaps_in_title"):
            continue                       # table rows, not headings
        found.append((i, sec, title))
    return found


def render_pdf(doc: dict, pdf: Path) -> tuple[str, list[dict]]:
    did = doc["id"]
    cfg = doc.get("normalize", {})
    pages = pdf_pages(pdf)
    md = [f"# {doc['title']}", "",
          f"doc-id: `{did}` · tier: **{doc['tier']}** · source: {doc['url']} · sha256 `{sha256(pdf)}` · pages: {len(pages)}",
          "", f"> {doc['note']}" if doc.get("note") else "", ""]
    sections, current = [], {"id": "front", "title": "(before first heading)", "pages": []}
    sections.append(current)
    for pno, page in enumerate(pages, 1):
        md += [f'<a id="{did}:p{pno}"></a>', f"## [{did} p.{pno}]", ""]
        lines = page.split("\n")
        hs = {} if pno in cfg.get("skip_heading_pages", []) else {i: (s, t) for i, s, t in headings(page, cfg)}
        if pno not in current["pages"]:
            current["pages"].append(pno)
        block = []

        def flush():
            if block:
                md.extend(["```text", *block, "```", ""])
                block.clear()
        for i, ln in enumerate(lines):
            if i in hs:
                flush()
                sec, title = hs[i]
                anchor = f"{did}:s{sec}"
                md += [f'<a id="{anchor}"></a>', f"### §{sec} {title}  [{did} §{sec} p.{pno}]", ""]
                current = {"id": sec, "title": title, "pages": [pno]}
                sections.append(current)
            block.append(ln)
        flush()
    return "\n".join(md).rstrip() + "\n", sections, pages


def render_source(doc: dict, src: Path) -> tuple[str, list[dict], list[str]]:
    did = doc["id"]
    text = src.read_text(encoding="utf-8")
    lines = text.split("\n")
    width = len(str(len(lines)))
    numbered = [f"{str(i).rjust(width)}| {ln.rstrip()}" for i, ln in enumerate(lines, 1)]
    md = [f"# {doc['title']}", "",
          f"doc-id: `{did}` · tier: **{doc['tier']}** · source: {doc['url']} · sha256 `{sha256(src)}` · lines: {len(lines)}",
          "", f"> {doc['note']}" if doc.get("note") else "", "",
          f'<a id="{did}:p1"></a>', f"## [{did} p.1] (source file; cite section as `L<first>-<last>`)", "",
          "```c", *numbered, "```", ""]
    return "\n".join(md), [{"id": "file", "title": src.name, "pages": [1]}], ["\n".join(lines)]


def main(corpus: Path) -> int:
    sources = json.loads((corpus / "sources.json").read_text())
    (corpus / "md").mkdir(exist_ok=True)
    pdftotext_version = subprocess.run(["pdftotext", "-v"], capture_output=True, text=True).stderr.split("\n")[0]
    index = {"normalizer": "tools/normalize.py", "pdftotext": pdftotext_version, "docs": []}
    for doc in sources:
        raw = corpus / "raw" / doc["id"]
        files = sorted(raw.iterdir())
        for f in files:
            if f.name not in doc["files"]:
                continue
            out_id = doc["id"] if len(doc["files"]) == 1 else f"{doc['id']}/{f.stem}"
            d = dict(doc, id=out_id)
            if f.suffix == ".pdf":
                md, sections, pages = render_pdf(d, f)
            else:
                md, sections, pages = render_source(d, f)
            name = out_id.replace("/", "__") + ".md"
            (corpus / "md" / name).write_text(md)
            index["docs"].append({
                "id": out_id, "title": doc["title"], "tier": doc["tier"], "url": doc["url"],
                "file": f"md/{name}", "source_sha256": sha256(f),
                "md_sha256": hashlib.sha256(md.encode()).hexdigest(), "pages": len(pages),
                "sections": [{"id": s["id"], "title": s["title"], "pages": s["pages"]} for s in sections],
            })
            print(f"{out_id}: {len(pages)} pages, {len(sections) - 1} sections -> md/{name}")
    (corpus / "index.json").write_text(json.dumps(index, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
