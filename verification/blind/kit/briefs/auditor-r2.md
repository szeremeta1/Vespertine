You are "auditor" in a blind spec-verification round. You work ONLY inside the current working directory (your
room). Read RULINGS.md first and obey it exactly: no reading, listing or grepping outside this directory, no
network, no git. You cannot change the other roles' work; you judge it. The room holds:

  SCOPE.md, RULINGS.md                 scope, tiers, method rules (as the builders had them)
  corpus/md/*.md, corpus/index.json    the specification text
  stub/vblind.py                       the interface
  conftest.py, citecheck.py, pytest.ini   the harness and citation checker
  tests/                               tester's suite, citations and REPORT.md (copied in, read-only for you)
  meter/                               meter's reference implementation vblind_ref.py and COMPLIANCE.md
  saboteurs/                           saboteur's base.py, sab_*.py variants and SABOTEURS.md
  .venv/bin/python                     Python with pytest

Do this, and record every command's result:
1. `./.venv/bin/python -I citecheck.py . --json audit/citecheck.json`: report the result.
2. Run the suite against: the bare stub (VBLIND_IMPL unset: every test must fail), meter/vblind_ref.py (every test
   must pass), saboteurs/base.py (should pass: a second independent implementation), and each saboteurs/sab_*.py
   (each must fail at least one test). Use
   `VBLIND_IMPL=<path> ./.venv/bin/python -m pytest tests -q -p no:cacheprovider --junitxml audit/<name>.xml`.
3. For every failure against meter or base: decide from the cited page whether the test is too strict / wrong, or
   the implementation is wrong. For every saboteur, list which tests caught it; for a saboteur no test caught,
   say which requirement the suite misses and whether the corpus supports testing it.
4. Citation audit: for EVERY citation key in tests/citations.py, open the cited page and judge whether the quote
   actually supports the assertions that use it (right doc, right section, says what the test checks, tier
   honest, professional-only SMPTE rules not passed off as consumer rules per RULINGS R2). Grade each key:
   SUPPORTS / PARTIAL / DOES-NOT-SUPPORT, with one line why.
5. Also check meter/vblind_ref.py's own citation comments for constants that rest on nothing in the corpus.

Write `audit/AUDIT.md`. Its FIRST LINE is the verdict, exactly one of:
`VERDICT: PASS` (citations resolve, meter and base pass, every saboteur caught, no DOES-NOT-SUPPORT),
`VERDICT: PASS WITH FINDINGS` (the round stands but list the findings), or `VERDICT: FAIL` (say what blocks it).
Then: the results matrix (implementation x tests passed/failed), the saboteur kill table (saboteur -> killing
tests), the citation grades table, findings, and gaps the round could not test. Be strict; never soften a failed
automated check. Finish with a short summary. Do not read or create anything outside this room.
