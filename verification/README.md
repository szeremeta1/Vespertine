# Spec-traced verification

This directory checks Vespertine's claims about DoP, IEC 61937 passthrough, the BIT-PERFECT badge, integer mode,
float exactness, SACD/DST decoding and rate switching against the documents those claims rest on. Every test
assertion names a requirement, every requirement names its source, and every source is either a public standard,
a paywalled standard cited only by clause and hash, an independent implementation used as an oracle, or one of
Vespertine's own rules from its docs. Nothing here changes Vespertine itself.

Start with [MAINTAINER-CHECKLIST.md](MAINTAINER-CHECKLIST.md): what is proven, by which evidence, what is blocked
and what it would cost, and five spot checks you can run in under 30 minutes. The results of the clean-room run are
in [REPORT.md](REPORT.md), and anything Vespertine got wrong is in [FINDINGS.md](FINDINGS.md).

## Layout

| Path | What it is |
| --- | --- |
| `CLAIMS.md` | Every public claim this covers, quoted from the README and docs at the line it's on. CI fails when a quote moves. |
| `SOURCES.md` | Every source opened: version, URL, SHA-256 of the file, what was bought and what wasn't (with prices). |
| `requirements/*.yaml` | The requirement records (format and rules in `requirements/README.md`). |
| `contracts/*.md` | Interface contracts written from the requirements alone. The clean-room agents saw only these and the records. |
| `harness/` | A Swift package: the contracts in Swift, the checks (`SpecChecks`), the clean-room implementations (`CleanRoomB`, `CleanRoomB2`), the mutants (`Mutants`) and the adapters that put Vespertine behind the same contracts (`VespertineAdapters`). |
| `fixtures/dst/` | DST frames with the DSD they encode, confirmed against the reference decoder. |
| `oracles/` | Independent implementations used as second opinions, and the scripts that run them. |
| `hardware/` | Procedures that need a DAC, a loopback interface or real discs. |
| `runs/` | Every clean-room brief and every agent's output, with hashes. |
| `tools/` | `check_registry.py`, `spec_cache.py`, `fetch_oracles.py`, `cleanroom.py`, the DST fixture generator. |

## Running it

```sh
python3 verification/tools/fetch_oracles.py          # fetch pinned oracle sources (checked against the registry)
python3 verification/tools/check_registry.py         # the registry, claims and hashes
python3 verification/oracles/dst/check_fixtures.py   # every DST fixture against the reference decoder (x86-64)
cd verification/harness && swift test                # checks against the clean-room implementations, mutants and Vespertine
```

On macOS `swift test` builds Vespertine's own `VespertineAudio` and runs every check against it. On Linux it builds
only Vespertine's C real-time engine and DST decoder (the parts that don't need Core Audio) and skips the rest.

`spec-cache/` holds the text of the standards the hashes are computed from. It is git-ignored and must stay that way:
paywalled text never enters the repository. `python3 verification/tools/spec_cache.py fetch` rebuilds the public part.
