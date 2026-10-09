//
// Implementation (role B) of the device-rate choice and DoP planning contract.
//

import Contracts

public enum BRate {
    public static let subject: (any RatePlanner)? = BRatePlanner()
}

struct BRatePlanner: RatePlanner {
    /// Two rates are equal when they differ by less than this many hertz.
    private static let tolerance = 0.5

    // MARK: - RatePlanner

    func chooseRate(sourceRate: Double, offeredRates: [Double], policy: Policy) -> Double {
        switch policy {
        case .matchSource:
            return Self.matchSource(sourceRate, offeredRates)
        case .maximum:
            // RATE-010: the highest offered rate, whatever the source rate.
            return Self.highest(offeredRates) ?? sourceRate
        case .fixed(let rate):
            // RATE-010: a fixed rate the device offers is chosen.
            if let offered = Self.nearestEqual(to: rate, in: offeredRates) {
                return offered
            }
            // Not specified by the contract: fall back to the match-source choice.
            return Self.matchSource(sourceRate, offeredRates)
        }
    }

    func dopCarrierRate(dsdRate: Double) -> Double {
        // RATE-001, RATE-002, RATE-003: the DSD rate divided by 16 at every DSD rate.
        dsdRate / 16
    }

    func planDSD(dsdRate: Double, device: DSDDevice) -> DSDPlan {
        // RATE-005: marked as decoding DoP and offering the carrier rate -> DoP at the carrier rate.
        let carrier = dopCarrierRate(dsdRate: dsdRate)
        if device.dopEnabled, let rate = Self.nearestEqual(to: carrier, in: device.offeredRates) {
            return DSDPlan(mode: .dop, deviceRate: rate, pcmRate: nil)
        }
        // RATE-004: otherwise convert to PCM at the DSD rate divided by 8; the device rate then follows the
        // ordinary (match-source) choice for that PCM rate.
        let pcmRate = dsdRate / 8
        let deviceRate = chooseRate(sourceRate: pcmRate, offeredRates: device.offeredRates, policy: .matchSource)
        return DSDPlan(mode: .pcm, deviceRate: deviceRate, pcmRate: pcmRate)
    }

    // MARK: - Match-source choice

    private static func matchSource(_ source: Double, _ offered: [Double]) -> Double {
        // RATE-006: the source rate itself.
        if let same = nearestEqual(to: source, in: offered) {
            return same
        }

        // RATE-007: an integer multiple of the source rate (the lowest one, preferring the closest match and
        // power-of-two multiples).
        var bestMultiple: (rate: Double, match: Match)?
        for rate in offered {
            guard let match = multiple(large: rate, small: source) else { continue }
            if let current = bestMultiple {
                if match.rank < current.match.rank
                    || (match.rank == current.match.rank && rate < current.rate) {
                    bestMultiple = (rate, match)
                }
            } else {
                bestMultiple = (rate, match)
            }
        }
        if let bestMultiple {
            return bestMultiple.rate
        }

        // RATE-008: some higher rate (the lowest one above the source rate).
        var lowestHigher: Double?
        for rate in offered where rate > source {
            if let current = lowestHigher, rate >= current { continue }
            lowestHigher = rate
        }
        if let lowestHigher {
            return lowestHigher
        }

        // RATE-009: every offered rate is lower; an integer divisor of the source rate (the highest one,
        // preferring the closest match and power-of-two divisors).
        var bestDivisor: (rate: Double, match: Match)?
        for rate in offered {
            guard let match = multiple(large: source, small: rate) else { continue }
            if let current = bestDivisor {
                if match.rank < current.match.rank
                    || (match.rank == current.match.rank && rate > current.rate) {
                    bestDivisor = (rate, match)
                }
            } else {
                bestDivisor = (rate, match)
            }
        }
        if let bestDivisor {
            return bestDivisor.rate
        }

        // Not specified by the contract: the highest offered rate (the closest one below the source rate).
        return highest(offered) ?? source
    }

    /// How `large` relates to `small` as an integer multiple.
    private struct Match {
        /// `k × small` and `large` differ by less than 0.5 Hz (otherwise only `large ÷ k` and `small` do).
        var exact: Bool
        /// `k` is a power of two (twice, four times, …).
        var powerOfTwo: Bool

        /// Lower is preferred.
        var rank: Int { (exact ? 0 : 2) + (powerOfTwo ? 0 : 1) }
    }

    /// Whether `large` is an integer multiple `k ≥ 2` of `small`, with rates compared to within 0.5 Hz.
    private static func multiple(large: Double, small: Double) -> Match? {
        guard small.isFinite, large.isFinite, small > 0, large > 0 else { return nil }
        let k = nearestInteger(large / small)
        guard k.isFinite, k >= 2 else { return nil }
        let exact = abs(large - k * small) < tolerance
        let scaled = abs(large / k - small) < tolerance
        guard exact || scaled else { return nil }
        return Match(exact: exact, powerOfTwo: k.significand == 1)
    }

    // MARK: - Helpers

    /// `x` rounded to the nearest integer, for finite non-negative `x`. Done with plain arithmetic so the module
    /// needs no maths library.
    private static func nearestInteger(_ x: Double) -> Double {
        let twoTo52 = 4_503_599_627_370_496.0
        guard x.isFinite, x >= 0, x < twoTo52 else { return x }
        return (x + twoTo52) - twoTo52
    }

    /// The offered rate equal to `rate` (within 0.5 Hz), the closest one if several are.
    private static func nearestEqual(to rate: Double, in offered: [Double]) -> Double? {
        var best: (rate: Double, distance: Double)?
        for candidate in offered {
            let distance = abs(candidate - rate)
            guard distance < tolerance else { continue }
            if let current = best, distance >= current.distance { continue }
            best = (candidate, distance)
        }
        return best?.rate
    }

    /// The highest of `rates`, ignoring NaN where possible.
    private static func highest(_ rates: [Double]) -> Double? {
        var best: Double?
        for rate in rates where !rate.isNaN {
            if let current = best, rate <= current { continue }
            best = rate
        }
        return best ?? rates.first
    }
}
