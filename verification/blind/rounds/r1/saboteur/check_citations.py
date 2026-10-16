"""Validate all implementation citation comments against the cited corpus page."""
from pathlib import Path
import json
import re
root = Path(__file__).resolve().parent.parent
index = json.loads((root / "corpus/index.json").read_text())
docs = {d["id"]: d for d in index["docs"]}
rows = []
normalize = lambda value: " ".join(value.split())
files = [root / "saboteurs/base.py", *sorted((root / "saboteurs").glob("sab_*.py"))]
for file in files:
    for number, line in enumerate(file.read_text().splitlines(), 1):
        match = re.match(r'# \[(.+) §(.+) p\.(\d+)\] "(.*)"$', line)
        if not match:
            continue
        doc, section, page, quote = match.groups()
        page = int(page)
        entry = docs[doc]
        text = (root / "corpus" / entry["file"]).read_text()
        page_text = re.split(r"^## \[" + re.escape(doc) + r" p\." + str(page) + r"\].*$", text, flags=re.M)[1]
        page_text = re.split(r"^## \[", page_text, flags=re.M)[0]
        assert normalize(quote) in normalize(page_text), (file.name, number, quote)
        assert any(s["id"] == section and page in s["pages"] for s in entry["sections"]), (doc, section, page)
        tier = {"secondary-implementation": "secondary"}.get(entry["tier"], entry["tier"])
        note = {
            "primary": "Direct DoP requirement; neither phase is mandated as the first sample.",
            "codec-spec": "Codec syntax, not a consumer transport requirement.",
            "secondary": "Independent implementation evidence only; consumer normative text unavailable.",
            "sibling-standard": "Shared burst structure inferred applicable via ST 337 sections 8.2–8.3. Consumer applicability of exact bit lengths is unverified for odd-byte DTS payloads; FFmpeg normally rounds these to whole words.",
        }[tier]
        if doc == "smpte-st340-2015":
            note = "Sibling-only evidence: codec sample count and six-block payload grouping are inferred to carry over because they describe decoded audio duration; consumer grouping and synchronization applicability unverified. Professional repetition rates and dependent fields are not imported."
        rows.append(dict(doc=doc, section=section, page=page, quote=quote,
                         tier=tier, note=note, location=f"{file.name}:{number}"))
(root / "saboteurs/CITATIONS.json").write_text(json.dumps(rows, indent=2) + "\n")
print(f"PASS: {len(rows)} quotations and section/page anchors verified")
