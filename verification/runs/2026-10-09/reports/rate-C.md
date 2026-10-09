# rate-C: final report

## Report (rate, role C: mutants)

I wrote `/srv/cleanroom/rate-C/harness/Sources/Mutants/RateMutants.swift`. It defines `public enum RateMutants { public static let all: [Mutant<any RatePlanner>] }` with 38 mutants, at least 3 for every testable requirement. It builds with `swift build` in Swift 6 language mode with no warnings and imports only `Contracts` and `SpecKit`. I changed none of the files I was given; my test program lives only in `Sources/Scratch`, as the brief allows.

**How it's built.** Each mutant wraps the correct planner and replaces one function, often only for a narrow set of inputs. Everything else is passed straight to the correct planner. Every helper is file-private, so `RateMutants` is the only name the file exports.

**How I checked it.** In Scratch I wrote two correct planners that make opposite choices wherever the records leave the answer open, plus my own requirement checks.
- Both correct planners pass all my checks.
- Every mutant fails my checks on both planners, and only on requirements in its own `targets`. This held in debug and release builds.
- About 137,000 calls with extreme inputs (NaN, ±infinity, 0, negative, huge values, empty lists, odd channel counts) caused no trap or hang.

**The mutants** (IDs are `C-RATE-00x-a`, `-b`, …):
- **RATE-001** (each also targets 003; c also targets 005):
  - a: carrier for DSD64 is DSD/8.
  - b: carrier for DSD64 is exactly 0.5 Hz high (176 400.5).
  - c: `planDSD` sends DSD64 as DoP at 352.8 kHz when the device offers that too.
- **RATE-002** (each also targets 003; c also targets 005):
  - a: carrier for DSD128 stays at 176.4 kHz.
  - b: carrier for DSD128 is cut to 352 000.
  - c: `planDSD` sends DSD128 as DoP at 176.4 kHz when offered.
- **RATE-003:**
  - a: carrier capped at 352.8 kHz.
  - b: carrier capped at 768 kHz, so only DSD512 and above are wrong.
  - c: carrier is 176.4 kHz times the nearest whole DSD64 multiple, so 48 kHz-family DSD and DSD32 come out wrong.
  - d (also targets 005): `planDSD` sends DSD256 and above as DoP at 352.8 kHz.
- **RATE-004:**
  - a: the DoP mark is ignored.
  - b: PCM conversion at DSD/16.
  - c: PCM conversion rate capped at 705.6 kHz.
  - d: an unmarked device still gets DoP, for DSD64 only.
  - e: `pcmRate` reports the device rate.
- **RATE-005:**
  - a: DoP is never planned.
  - b: DoP also needs a 32-bit format.
  - c: DoP is refused on devices with more than 2 channels.
  - d: DoP is refused when the carrier is above 384 kHz.
  - e: the offered carrier must match bit-exactly.
- **RATE-006:**
  - a: picks the highest offered rate.
  - b: picks the first source-or-multiple in list order.
  - c: the source must match bit-exactly.
  - d: a source equal to the highest offered rate is passed over.
- **RATE-007:**
  - a: picks the lowest higher rate.
  - b: only power-of-two multiples count.
  - c: prefers an integer divisor.
- **RATE-008:**
  - a: picks the highest lower rate.
  - b: picks the nearest rate.
  - c: prefers an integer divisor.
- **RATE-009:**
  - a: picks the highest offered rate.
  - b: only halves and quarters count as divisors.
  - c: picks the first rate in list order.
- **RATE-010:**
  - a: `maximum` picks the highest rate in the source's family.
  - b: `maximum` returns the last list element.
  - c: an offered fixed rate below the source is ignored.
  - d: a fixed rate must match bit-exactly.
  - e: `maximum` ignores rates above 384 kHz.

**Ambiguities and contradictions**
- **RATE-001:** the "24-bit" part can't be observed, because `DSDPlan` has no bit depth. Only the 176.4 kHz rate is testable.
- **RATE-001, RATE-002 and RATE-003 overlap.** RATE-003 says DSD/16 "at every DSD rate", so it also covers DSD64 and DSD128, and those mutants list both IDs. A DoP plan at the wrong rate also breaks RATE-005's "at the carrier rate", so the `planDSD` versions list all three.
- **RATE-002 gap:** I treated DoP at 176.4 kHz for DSD128 (the second method) as a violation, because the contract uses the first method only.
- **RATE-003:** "every DSD rate" is not defined. I counted 48 kHz-family DSD (3.072 MHz and its multiples) and DSD32; mutant 003-c depends on that. The gap says carriers above 384 kHz are "untested". I read that as not exempting DSD256 and above from RATE-005; mutant 005-d depends on that.
- **RATE-004 gap / RATE-005:** the device rate after PCM conversion "follows the ordinary choice", but planDSD takes no policy. Mutants 004-b and 004-c recompute the device rate with match-source. My `chooseRate` mutants don't feed into `planDSD`.
- **RATE-005 gap (bit depth):** mutant 005-b only shows up on a device that has 24-bit but no 32-bit format. That is in scope under the gap. I never rely on a 16-bit-only device.
- **The 0.5 Hz rule (RATE-006 to RATE-010):** the rule isn't transitive. "k times" can be read as |r − k·s| < 0.5 or |r/k − s| < 0.5, and the same goes for divisors. Mutants only misbehave where every reading agrees; inputs where the readings disagree are left to the correct planner.
- **Tolerance mutants:** 001-b, 005-e, 006-c and 010-d only show up with rates off by a fraction of a hertz, or (001-b) off by exactly 0.5 Hz.
- **The contract's "`pcmRate` is nil for `dop`"** has no requirement ID, so no mutant targets it.

**Assumptions**
- Mutant IDs use lowercase letters.
- `planDSD`'s PCM device rate uses the match-source policy.
- "Higher" and "lower" mean at least 0.5 Hz apart.
- None of the mutants keeps state between calls ("wrong on the second call"). Doing that safely would need a module outside the workspace package (Synchronization or Foundation).
- The sandbox doesn't link libm, so calls like `rounded()` fail at link time. The file rounds with plain arithmetic instead.
