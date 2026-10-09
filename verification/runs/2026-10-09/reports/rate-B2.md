# rate-B2: final report

## Report: rate, role B2

**Delivered:** `/srv/cleanroom/rate-B2/harness/Sources/CleanRoomB2/B2Rate.swift`. It defines `public enum B2Rate { public static let subject: (any RatePlanner)? = ... }`. `swift build` succeeds in Swift 6 mode. The file imports only `Contracts`, and I changed no provided file. I tried it in `Sources/Scratch` with my own cases for each rule plus NaN, infinity, zero, negative and empty-list inputs. All behaved as intended and nothing trapped.

**Behaviour:**
- **`dopCarrierRate`:** returns `dsdRate / 16`, which gives 176400, 352800, 705600 and 1411200 for DSD64 to DSD512 (RATE-001 to RATE-003).
- **`planDSD`, DoP case:** if `dopEnabled` is true and an offered rate equals the carrier (within 0.5 Hz), the plan is `dop`, `deviceRate` is that offered element, and `pcmRate` is nil (RATE-004, RATE-005).
- **`planDSD`, PCM case:** otherwise the plan is `pcm`, `pcmRate = dsdRate / 8`, and `deviceRate = chooseRate(sourceRate: pcmRate, offered, .matchSource)`.
- **`chooseRate`, `.maximum`:** the highest offered rate (RATE-010).
- **`chooseRate`, `.fixed(rate)`:** the offered element equal to `rate` when there is one (RATE-010).
- **`chooseRate`, `.matchSource`:** tried in this order (RATE-006 to RATE-009):
  1. The source rate, if offered, returned as the offered element.
  2. The smallest offered integer multiple, k ≥ 2.
  3. The smallest offered rate above the source rate.
  4. The largest offered integer divisor, k ≥ 2.
  5. Fallback: the highest offered rate.

**Ambiguities and gaps (by ID):**
- **RATE-005 / RATE-004 (bit depth):** "offers the carrier rate" could include bit depth. I ignored `integerBitDepths` and `channels` entirely, following the records literally and the brief's rule not to add behaviour. A device marked as decoding DoP that offers the carrier rate gets DoP even if it only has 16-bit formats. The RATE-005 gap says tests use 24-bit or deeper devices, so this shouldn't show.
- **RATE-007 / RATE-008 / RATE-009:** the records don't say which multiple, higher rate or divisor to pick when several are offered. I chose the smallest multiple, the smallest higher rate and the largest divisor, i.e. the closest to the source.
- **RATE-009:** nothing is specified when no offered rate is a multiple, higher, or a divisor. I return the highest offered rate (step 5).
- **RATE-010:** `fixed(rate)` for a rate that isn't offered is unspecified. I return the requested rate unchanged, which the contract's output exception allows. This is not an offered rate.
- **RATE-002:** the second DoP method (markers on a channel pair at 176.4 kHz) is not implemented, as the contract says.
- **RATE-003:** the note that carrier rates above 384 kHz are untested on hardware has no effect. The /16 rule applies at every DSD rate.

**Assumptions:**
- Equality tolerance is `abs(a - b) < 0.5` everywhere.
- A multiple matches when `|offered - k * source| < 0.5`. A divisor matches when `|offered - source / k| < 0.5`.
- A rate counts as "higher" only if it is at least 0.5 Hz above the source, so rates within tolerance of the source go through step 1.
- Rounding to the nearest integer is done by hand, as `Double(Int(x + 0.5))` behind finite and range guards. `Double.rounded()` caused undefined libm symbols at link time because Foundation is not imported. This also means no trap for NaN, infinity, zero or negative inputs.
- Input the contract rules out gets harmless results. With an empty `offeredRates`, `chooseRate` returns `sourceRate` for `.matchSource` and `.maximum` and the fixed rate for `.fixed`. In `planDSD` the empty list falls to the PCM branch and `deviceRate` is `dsdRate / 8`.
