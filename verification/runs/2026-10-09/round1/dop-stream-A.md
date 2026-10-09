# Review round: dop-stream-A

Sent to the same agent, resumed in its own workspace, after the round-0 scoring.

Review round for your DoP output stream checks: two broken implementations passed every one of them. This is the single review round; the rules of your brief still apply in full (work only in /srv/cleanroom/dop-stream-A, Bash only as `swiftbox /srv/cleanroom/dop-stream-A "<command>"`, no other paths or tools).

Your 55 checks were run against an independent implementation (it passed all 55) and against 30 deliberately broken implementations written by someone else from the same records. 28 failed a check of a requirement they target. These two passed everything:

- C-DOPS-007-c, targets [DOPS-007]: "Silence runs that start with the equalizer on use the complement (still valid) silence byte."
- C-DOPS-007-e, targets [DOPS-007]: "Silence runs that start with a gain other than 1.0 use the complement (still valid) silence byte."

Each is otherwise a correct stage: music frames are untouched, markers and the silence rules of DOPS-001 to DOPS-006 hold. Only the DSD byte of silence frames differs from what the same stage sends at unity gain with the equalizer off.

DOPS-007's requirement reads: "A software gain other than 1.0, or the equalizer turned on, leaves DoP output unchanged: the same frames come out as with unity gain and no equalizer." Your report says your DOPS-007 comparison lets silence frames differ in their silence byte.

Decide from the records and the contract alone:
1. If DOPS-007 as written rules these out, strengthen or add checks in `harness/Sources/SpecChecks/DoPStreamChecks.swift` so they fail, still following every rule in your brief (assert only what a requirement says, never trap or hang, deterministic, `// REQ:` lines, one ID per assertion). Make sure a correct stage that picks a different, but consistent, valid silence byte still passes.
2. If the records leave this open, change nothing and explain which words leave it open.

Rebuild with `swiftbox /srv/cleanroom/dop-stream-A "cd harness && swift build"`. Finish with a short report: what you changed (or why nothing), and any new ambiguity.
