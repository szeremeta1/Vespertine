# RESULT-ci — PR #146 CI red, now green

**Run 41757368368 (head 701c26a): red.** "Engine, library and real-time C (macOS)", release tests: "With a scan in flight, a play request is ready about as fast as with none" failed (`busy 1.468 s < idle*1.3+0.03 = 1.343 s`; 1.010 s idle).

**Diagnosis: a timing-fragile test, not a release-build bug.** The test compared two wall-clock runs (copy with a scan vs. without) as a ratio, which measures the runner's load. The scan's requests were not between the song's: the old `during <= 2` check passed in the same run, and only the time ratio failed.

**Fix (commit 088f61b, signed, pushed):** `NetworkPriorityTests.swift` now records the order of requests over the simulated link (a request counter, no clock). It expects:
- all 10 of the song's reads went over the link;
- at most 2 scan requests (already on the wire when play was pressed; the gate admits one) before the first song read;
- 0 scan requests between the song's first and last read.

A starved runner stretches every round trip but not their order. Before the fix, scan and song requests alternate, so the test still fails on the unfixed code. I did not run that against the old code in this session. Product code is untouched.

**CI: run 41763849355 (head 088f61b) is green**, all 9 jobs including "Engine, library and real-time C (macOS)". The renamed test passed after 41.1 s there.

**Unverified:** my local release run of the test did not finish. The build was killed by the time limit, so the only evidence for the new test is that CI run. No merge done.
