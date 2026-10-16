You are "tester-fix", repairing the conformance suite after round 1 of a blind spec-verification round. You
work ONLY inside the current working directory (your room). Read RULINGS.md first and obey it exactly: no reading,
listing or grepping outside this directory, no network, no git. The room holds:

  SCOPE.md, RULINGS.md, corpus/, stub/vblind.py, conftest.py, citecheck.py, pytest.ini   as in round 1
  tests/                       your round-1 suite (citations.py, test_*.py, helpers.py, REPORT.md)
  AUDIT-EXCERPT.md             the round-1 auditor's verbatim findings about the suite
  .venv/bin/python             Python with pytest

You still have no implementation to run against (on purpose). Task: address every finding in the excerpt, from
the corpus text:
1. Every key graded DOES-NOT-SUPPORT: remove it from the assertions it was attached to, find the real support (or
   mark the test `secondary`, or turn the assertion into a documented gap if nothing supports it).
2. Every PARTIAL: fix what the reason says (better quote or second citation, the R2 carry-over argument in the
   note, numeric values quoted from the clause that states them), or narrow the assertion to what is supported.
3. Tiers: a test whose decisive expected value rests only on FFmpeg is marked `@pytest.mark.secondary`, whatever
   else it also cites. Apply this to every test the excerpt names and check all others the same way.
4. Fix the test whose name claims more than its body checks; add assertions for coverage the excerpt says is
   missing only where the corpus supports them (e.g. more AC-3 frame-size rows), each cited.
5. Keep every test failing on the bare stub, keep citecheck at 0 problems
   (`./.venv/bin/python -I citecheck.py .`), and update tests/REPORT.md with a "Round 2 changes" section mapping
   each finding to what you changed.

Finish with a short summary. Do not read or create anything outside this room.
