# rate-A: final report

## What I delivered

**`/srv/cleanroom/rate-A/harness/Sources/SpecChecks/RateChecks.swift`** defines `public enum RateChecks { public static let all: [SpecCheck<any RatePlanner>] }` with 22 checks. Each check has a `// REQ:` line directly above it and asserts exactly one ID.

- `swift build` passes in Swift 6 mode with no warnings.
- The file imports only `Contracts` and `SpecKit`.
- No file I was given has changed. I used Scratch to try the checks and then put it back to its original single line.

**How the checks are built:**
- They never trap: there are no force unwraps or unchecked indexing, and every loop is bounded.
- They are deterministic: test data comes from my own seeded SplitMix64 generator.
- I compute rounding myself, without `rounded()`, because the sandbox linker can't find libm.
- Every rate comparison uses the contract's rule that two rates are equal when they differ by less than 0.5 Hz.
- Every offered-rate list is tried in five orders: as given, reversed, ascending, descending and shuffled.

**Checks per requirement:**
- **RATE-001** (1 check): the DSD64 carrier is 176.4 kHz, and any DoP plan for DSD64 runs the device at 176.4 kHz.
- **RATE-002** (1 check): the DSD128 carrier is 352.8 kHz. A DoP plan for DSD128 is never at 176.4 kHz, including on devices that offer 176.4 kHz but not 352.8 kHz.
- **RATE-003** (2 checks): `dopCarrierRate` is the DSD rate divided by 16 for DSD64 to DSD1024 in both the 44.1 kHz and 48 kHz families, called in several sequences. Any DoP plan runs the device at the DSD rate divided by 16.
- **RATE-004** (4 checks):
  - A device not marked as decoding DoP gets PCM, with `pcmRate` equal to the DSD rate divided by 8.
  - A DoP device that doesn't offer the carrier gets the same.
  - A rate 1 Hz or more away from the carrier does not count as the carrier.
  - After conversion to PCM, the device rate follows the ordinary choice for the PCM rate.
- **RATE-005** (3 checks):
  - A DoP device that offers the carrier gets DoP at the carrier. These devices offer 24-bit formats and have 2 to 8 channels.
  - The same holds for devices whose formats are only 32-bit, or 16-bit plus 32-bit.
  - A carrier offered within 0.5 Hz counts as offered.
- **RATE-006** (2 checks): the source rate is chosen when it is offered, also within 0.5 Hz either way.
- **RATE-007** (3 checks):
  - With rates related only by powers of two, an offered multiple is chosen.
  - Any integer multiple counts, such as three or six times.
  - A rate 1 Hz away from the source is not the source.
- **RATE-008** (1 check): when neither the source nor a multiple is offered, the result is an offered rate higher than the source.
- **RATE-009** (2 checks): when every offered rate is lower, an offered rate that divides the source exactly is chosen. One check uses only power-of-two divisors; the other includes divisors such as a third.
- **RATE-010** (3 checks): the maximum policy returns the highest offered rate whatever the source. A fixed rate that is offered is returned, including a fixed rate within 0.5 Hz of an offered one.

**Trial run:** I tried the checks in Scratch against a reference implementation I wrote.
- Four valid variants all passed. They differed in which multiple, higher rate or divisor they pick, and in using tolerances of 0.49 and 0.9 Hz.
- 31 broken variants were all caught. Examples: picking the highest or closest rate, applying the rules in the wrong order, assuming sorted input, carrier of DSD÷8, carrier capped at 352.8 kHz, using the 176.4 kHz method for DSD128, ignoring `dopEnabled`, `pcmRate` of DSD÷16 or nil, wrong PCM device rate, exact or too-loose rate equality.
- All checks together run in well under a second per implementation in a debug build.

## Ambiguous or contradictory points

- **RATE-004 gap:** it says the PCM device rate "follows the ordinary choice (RATE-006 to RATE-009)". This reads as an added rule rather than an open point, so I tested it in its own check under RATE-004. If it is meant to be untestable, only that check is affected.
- **RATE-007 and RATE-009:** "(twice, four times, …)" and "(half, a quarter, …)" could be read as powers of two only. The record text and the RATE-007 gap both say "integer multiple" or "divides exactly", so I count 3× and ÷3 as well. Those cases are in separate checks so the main checks don't depend on this reading.
- **RATE-005 gap:** "24-bit or deeper" — I treat a device with only 32-bit formats as qualifying, again in a separate check. I never test a DoP device that offers the carrier with only 16-bit formats, or with no integer formats.
- **RATE-001:** the "24-bit" part can't be observed through the API, which has no bit-depth output, so only the 176.4 kHz part is tested.
- **RATE-003 gap:** carrier rates above 384 kHz are "untested on hardware". The requirement still says DSD÷16 at every rate, so DSD256 and higher are tested, including DoP plans at those carriers.
- **Contract points with no requirement behind them are not asserted:**
  - `pcmRate` being nil for DoP.
  - The device rate being one of the offered rates in the cases no rule decides.
  - A fixed rate the device doesn't offer.
  - The match-source case where no multiple, higher rate or divisor is offered.

## Assumptions

- "The carrier rate" in RATE-004 and RATE-005 means DSD rate ÷ 16, as RATE-001 to RATE-003 define it, not whatever the implementation's own `dopCarrierRate` returns.
- The 0.5 Hz equality rule applies to the input side too, both to what counts as offered and to the source rate. Offsets of 0.1 to 0.3 Hz are equal; offsets of 1 Hz or more are not.
- The device channel count doesn't affect the DoP decision. I only used devices with 2 to 8 channels, never 1.
- Integer-multiple and divisor tests use exact, standard rates, plus a few non-standard ones such as 50 000, 37 800, 72 000 and 132 300 Hz, so no rounding edge cases come up.
- A higher rate that isn't a multiple means any offered rate above the source.
- "Every DSD rate" means DSD64 to DSD1024 in both the 44.1 kHz and 48 kHz families.
