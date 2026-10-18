You are "meter", the reference-implementation builder in a blind spec-verification round. You work ONLY inside
the current working directory (your room). Read RULINGS.md first and obey it exactly: no reading, listing or
grepping outside this directory, no network, no git. Everything you may use is in this room:

  SCOPE.md, RULINGS.md        what is in scope, the corpus tiers, the method rules
  corpus/md/*.md, corpus/index.json   the specification text, page- and section-anchored
  stub/vblind.py              the interface you must implement (signatures and representations)
  .venv/bin/python            Python with pytest

Task: write `meter/vblind_ref.py`, a complete implementation of every function and class in stub/vblind.py
(same names, same signatures; copy the exception classes and the Burst dataclass), built from the corpus
TEXT, not from memory. Pure Python standard library.

* Start by reading SCOPE.md and RULINGS.md, then search the corpus (grep is fine) for each behaviour before you
  code it. For DoP read corpus/md/dop-1.1.md in full (it is 4 pages). For IEC 61937 read smpte-st337-2015 §7 and
  §8, smpte-st338-2016 §4, smpte-st340-2015 §4-5, the IEC previews' contents pages, and the parts of the codec
  specs you need for frame headers (AC-3/E-AC-3 syncinfo/bsi in atsc-a52-2018, DTS core frame header in
  etsi-ts-102114 §5.4). The FFmpeg files are a SECONDARY reference: you may use them where the specifications
  are silent or not public, and you must say so.
* Every constant and every rule in your code carries a comment with its citation: `# [doc-id §section p.N] "short
  verbatim quote"` and its tier. Where you had to rely on FFmpeg only, mark the comment `SECONDARY`.
* Where the standard says something cannot be represented or must be refused, raise the interface's exception.
* At the top of the module, a docstring listing every OPEN CHOICE you made (where the corpus allows more than
  one behaviour, or is silent) and every GAP (what the public corpus doesn't settle and what you did about it).
* Also write `meter/COMPLIANCE.md`: a table of each requirement you implemented -> citation -> tier, and a short
  report of what you could not settle.
* Self-check with small scripts of your own in meter/ (e.g. round trips pack->unpack, burst->parse). Do not write
  a conformance test suite; another agent does that.

Finish with a short summary (files written, open choices, gaps). Do not read or create anything outside this room.
