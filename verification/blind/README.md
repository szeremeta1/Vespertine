# Blind-agent round (DoP, IEC 61937)

Tests written from the public standards by agents that never saw Vespertine, proved able to fail by deliberate
saboteurs, then run against Vespertine. Method, results and limits: [docs/VERIFICATION-BLIND.md](../../docs/VERIFICATION-BLIND.md).
Clause-by-clause source map: [SCOPE.md](SCOPE.md).

| Path | What it is |
|---|---|
| `corpus/` | `sources.json` (documents, tiers), `sources.lock.json` (URLs, SHA-256 of every file and of its normalized markdown). The text is fetched, not committed: `tools/fetch_corpus.py`. |
| `kit/` | What the agents were given: `SCOPE.md`, `RULINGS.md`, `stub/vblind.py` (the interface), `harness/` (pytest fixture, citation checker), `briefs/` (one per role), `excerpts/` (the round-1 audit findings handed to the round-2 fixers). |
| `rounds/r1`, `rounds/r2` | Each role's output exactly as written in its room (`meter/`, `tester/`, `saboteur/`, `auditor/`), with `ROOM-MANIFEST.txt` (every file the room held, hashed) and `ISOLATION.txt` (the trace check), and `results/` (the matrix and the byte comparisons). One edit on commit: an absolute path in `r1/tester/tools/refimpl.py` made relative. |
| `vectors/` | `inputs.json` (the fixed inputs, `tools/vectors.py`) and `vespertine.json` (what Vespertine produced for them, from `bridge/`). |
| `bridge/` | Swift package over VespertineKit (read-only): `export` writes `vespertine.json`; `serve` puts Vespertine behind the blind interface for `tools/vespertine_adapter.py`. |
| `tools/` | `normalize.py`, `fetch_corpus.py`, `make_room.py`, `isolation.py`, `vectors.py`, `compare.py`, `run_matrix.py`, `vespertine_adapter.py`. |
