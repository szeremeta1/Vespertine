# rate-B: final report

## Report: rate, role B (implementation)

**What I delivered**
I wrote `/srv/cleanroom/rate-B/harness/Sources/CleanRoomB/BRate.swift`. It defines `public enum BRate { public static let subject: (any RatePlanner)? = BRatePlanner() }`, and `BRatePlanner` is an internal struct that conforms to `RatePlanner`. It imports only `Contracts`.
- It builds with `swift build` (Swift 6 mode) after a clean `.build`, in both debug and release.
- I checked it with a scratch program covering RATE-001 to RATE-010 and the 0.5 Hz tolerance. All checks passed, and it did not crash on NaN, ±infinity, 0, negative, tiny or huge rates, or on empty or odd `offeredRates` lists.
- I put `Sources/Scratch/main.swift` back to its original one-line content, so none of the files I was given has changed.
- The module avoids `rounded()` and does its rounding with plain arithmetic. With `rounded()`, linking failed with undefined references to `round`, `floor` and the like, because no maths library is linked into the package.

**How it behaves**
- **Rate equality:** two rates count as equal when they differ by less than 0.5 Hz. Whenever an offered rate is chosen, the function returns the exact value from `offeredRates`, never the source or fixed value.
- **`dopCarrierRate`:** `dsdRate / 16` (RATE-001, 002, 003).
- **`planDSD`:**
  - If `dopEnabled` is true and the device offers the carrier rate, the plan is `.dop` at that offered rate with `pcmRate` nil (RATE-005).
  - Otherwise the plan is `.pcm` with `pcmRate = dsdRate / 8`, and the device rate is the match-source choice for that PCM rate (RATE-004 and its gap note).
- **`chooseRate(.maximum)`:** the highest offered rate (RATE-010).
- **`chooseRate(.fixed(r))`:** the offered rate equal to `r`, if there is one (RATE-010).
- **`chooseRate(.matchSource)`**, checked in this order:
  1. The source rate itself, if offered (RATE-006).
  2. Otherwise an integer multiple k ≥ 2, if any is offered (RATE-007).
  3. Otherwise the lowest offered rate above the source (RATE-008).
  4. Otherwise, with every offered rate lower, an integer divisor if any is offered: the highest one (RATE-009).
  5. Otherwise the highest offered rate.

**Ambiguous or open points (by ID)**
- **RATE-007:** the records don't say which multiple to pick when several are offered. "Integer multiple" in the requirement also conflicts with the "(twice, four times, …)" wording, which suggests powers of two only.
- **RATE-009:** the records don't say which divisor to pick. They also conflict on any integer divisor versus "(half, a quarter, …)", and they don't say what happens when no rate is equal, a multiple, higher or a divisor.
- **RATE-008:** the records don't say which higher rate to pick.
- **RATE-010 / Output:** the result for a fixed rate the device doesn't offer is not specified.
- **RATE-007 / RATE-009 with the 0.5 Hz rule:** it is unclear whether "offered = k × source" compares k × source with the offered rate, or offered ÷ k with the source. The two readings differ once the source is off by more than about 0.25 Hz.
- **RATE-004 / RATE-005:** "offers the carrier rate" might also require a bit depth of 24 or more. The `integerBitDepths` and `channels` fields are never used by any record.
- **RATE-003:** carrier rates above 384 kHz are untested on hardware, according to the records. I applied ÷16 anyway.

**Assumptions I made**
1. Any integer k ≥ 2 counts as a multiple or divisor. When several qualify, the code first prefers ones that hold under the stricter reading (k × smaller rate within 0.5 Hz of the larger), then powers of two. Among those it takes the lowest multiple or the highest divisor. This satisfies both the "any integer" and the "powers of two only" readings in non-pathological cases.
2. The code accepts a multiple or divisor under either 0.5 Hz reading. It prefers the stricter one, which is safe because any multiple is also a higher rate.
3. A fixed rate the device doesn't offer falls back to the match-source choice for `sourceRate`, so the result is still one of the offered rates.
4. When none of RATE-006 to RATE-009 applies, the result is the highest offered rate, which is the one closest below the source.
5. DoP is decided only by `dopEnabled` and whether the carrier rate is offered. There is no check on bit depth or channel count, because RATE-005 states those two conditions as sufficient.
6. The carrier rate counts as offered if it matches an offered rate within 0.5 Hz, and `deviceRate` is that offered value.
7. For input the contract rules out (such as an empty `offeredRates`), the code never traps and never converts to an integer type. It ignores NaN entries where it can and returns the source rate when nothing is offered.
