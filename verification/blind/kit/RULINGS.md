# Rulings for this round (method decisions, made by the orchestrator before any agent ran)

These are rules of the method, not answers about the standards. They apply to every role.

**R0 Isolation.** Read, write and run only inside this room (the current working directory and below). Do not
open, list, grep or `cd` into any path outside it, do not use the network, do not use git. Allowed commands:
`python`, `pytest` (via `./.venv/bin/python -m pytest`), `grep`, `ls`, `cat`, `sed`, `head`, `tail`, `wc`.
Nothing else is needed. If something you need is missing from the room, say so in your report instead of
looking for it elsewhere.

**R1 Sources only, never memory.** Every value a test expects or an implementation produces (marker bytes,
sync words, data-type codes, field positions, length units, repetition periods, fill rules, byte order) must
come from text in `corpus/`. Knowing it from memory doesn't count: if you can't find it in the corpus, it is a
gap (R3). Cite as an entry of the form

    {"doc": "<doc-id>", "section": "<section id as in the anchors, e.g. 7.2.5, 3, Annex-A, or 'front' / 'file'>",
     "page": <page number as in the anchors>, "quote": "<verbatim text from that page>",
     "tier": "primary|primary-preview|sibling-standard|codec-spec|secondary", "note": "<why this supports it>"}

The quote must be copied verbatim from a single page (line breaks and runs of spaces may be collapsed; the
checker compares with all whitespace collapsed). For tables, quote the row cells you rely on. For FFmpeg source,
`section` is `file` and the quote is code or a comment from it.

**R2 Tiers.** The tier of a requirement is the best tier among its citations. Where the sibling (SMPTE,
professional) standard and the consumer format can differ (SMPTE ST 337 §8.4 says data_type_dependent fields,
payload coding and burst spacing may), the consumer format governs. Do not turn a professional-only rule
(professional data_type numbers, professional data_type_dependent bits, professional repetition rates) into a
consumer requirement. If the only support for a consumer behaviour is FFmpeg, its tier is `secondary`. If the
only support is a sibling clause whose applicability to the consumer format is not stated, its tier is
`sibling-standard` and the note must say what makes you think it carries over.

**R3 Gaps.** Where the corpus is silent or the consumer text is not public, write the gap to your report under
"Gaps" (what is unknown, what you would need) and do not assert it, and do not invent a value. Where the corpus
leaves a choice open (e.g. what to do with an empty input), choose, and list the choice under "Open choices".

**R4 Bit-exact.** There are no tolerances: outputs are compared word for word.

**R5 Interface.** `stub/vblind.py` is the contract. Don't add required parameters or change signatures.
Helpers inside your own files are fine.
