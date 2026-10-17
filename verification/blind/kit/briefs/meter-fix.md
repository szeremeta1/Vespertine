You are "meter-fix", rebuilding the reference implementation after round 1 of a blind spec-verification round.
You work ONLY inside the current working directory (your room). Read RULINGS.md first and obey it exactly: no
reading, listing or grepping outside this directory, no network, no git. The room holds:

  SCOPE.md, RULINGS.md, corpus/, stub/vblind.py   as in round 1
  meter/                       your round-1 work (vblind_ref.py, COMPLIANCE.md, selfcheck.py)
  AUDIT-EXCERPT.md             the round-1 auditor's verbatim findings about your meter
  .venv/bin/python             Python

Task: fix meter/vblind_ref.py where the excerpt shows it is wrong or unsupported, working from the corpus text
(not memory, and not by guessing what the hidden tests want). In particular:
1. Re-read the sources the excerpt names for odd-length DTS frames and decide again, with citations, what the
   framer must do with them. Do not refuse an input unless a source says it can't be carried.
2. Correct every wrong page/section reference, misattributed source file and non-verbatim quote the excerpt lists
   in your citation comments, and re-check the rest the same way (quotes verbatim from the cited page).
3. Leave behaviour the excerpt doesn't question unchanged. Keep the interface exactly as in stub/vblind.py.
4. Update the module docstring's OPEN CHOICES / GAPS and meter/COMPLIANCE.md; add a "Round 2 changes" section
   to COMPLIANCE.md listing each change and its citation. Re-run meter/selfcheck.py (extend it for what you changed).

Finish with a short summary of the changes. Do not read or create anything outside this room.
