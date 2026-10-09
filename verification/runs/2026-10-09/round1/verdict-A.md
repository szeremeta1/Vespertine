# Review round: verdict-A

Sent to the same agent, resumed in its own workspace, after the round-0 scoring.

Review round for your BIT-PERFECT verdict checks: one broken implementation passed every one of them. This is the single review round; the rules of your brief still apply in full (work only in /srv/cleanroom/verdict-A, Bash only as `swiftbox /srv/cleanroom/verdict-A "<command>"`, no other paths or tools).

Your 30 checks were run against two independent implementations (both passed all 30) and against 79 deliberately broken implementations written by someone else from the same records. 78 failed a check of a requirement they target. This one passed everything:

- C-BPV-012-c, targets [BPV-012, BPV-015]: "AirPods Max on USB-C: BIT-PERFECT only while the player holds the device in hog mode."

That is: on `airPodsMaxUSBC`, with every other condition met, it gives BIT-PERFECT when `hogOwnerPID == ownPID`, and something else when the device isn't held (shared mode, nobody else playing). Elsewhere it is correct.

Your report says you assert that shared mode with no other app playing gives BIT-PERFECT, in its own check, using `usbDAC`, and that your BPV-012 checks use one readback.

Decide from the records and the contract alone:
1. If BPV-012 and BPV-015 as written rule this out, strengthen or add checks in `harness/Sources/SpecChecks/VerdictChecks.swift` so it fails, still following every rule in your brief.
2. If the records leave this open, change nothing and explain which words leave it open.

Rebuild with `swiftbox /srv/cleanroom/verdict-A "cd harness && swift build"`. Finish with a short report: what you changed (or why nothing), and any new ambiguity.
