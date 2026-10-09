//
// Mutants for the rate-plan contract (device-rate choice and DoP planning), role C.
//
// Every mutant is a decorator over a correct `RatePlanner` handed in at run time. Each one replaces one function
// (sometimes only for a narrow set of inputs) and delegates everything else to the correct planner, so it breaks the
// requirement(s) it targets and, as far as possible, nothing else. None of them traps or loops: no force unwraps, no
// indexing, no Double-to-Int conversions.
//

import Contracts
import SpecKit

// MARK: - Rate arithmetic (the contract's 0.5 Hz equality)

private enum Hz {
    static let dsd64 = 2_822_400.0
    static let dsd128 = 5_644_800.0

    /// Two rates are equal when they differ by less than 0.5 Hz.
    static func eq(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }

    /// The nearest whole number to `x` (ties to even), in plain arithmetic so nothing needs libm. Values of 2^52 and
    /// beyond are already whole and come back unchanged, as do infinities and NaN.
    static func nearest(_ x: Double) -> Double {
        let big = 4_503_599_627_370_496.0  // 2^52
        guard abs(x) < big else { return x }
        return x >= 0 ? (x + big) - big : (x - big) + big
    }

    /// The largest whole number not above `x` (for finite `x` below 2^52 in magnitude).
    static func down(_ x: Double) -> Double {
        let r = nearest(x)
        return r > x ? r - 1 : r
    }

    /// The offered rate equal to `rate`, if any.
    static func offered(_ rates: [Double], _ rate: Double) -> Double? { rates.first { eq($0, rate) } }

    static func offers(_ rates: [Double], _ rate: Double) -> Bool { offered(rates, rate) != nil }

    /// `r` is higher than `s` (and not equal to it).
    static func higher(_ r: Double, than s: Double) -> Bool { r - s >= 0.5 }

    /// `r` is lower than `s` (and not equal to it).
    static func lower(_ r: Double, than s: Double) -> Bool { s - r >= 0.5 }

    /// The factor k ≥ 2 when `r` equals k·`s` (|r − k·s| < 0.5, the strictest reading).
    static func multipleFactor(_ r: Double, of s: Double) -> Double? {
        guard s > 0, s.isFinite, r.isFinite else { return nil }
        let k = nearest(r / s)
        return k >= 2 && abs(r - k * s) < 0.5 ? k : nil
    }

    static func isMultiple(_ r: Double, of s: Double) -> Bool { multipleFactor(r, of: s) != nil }

    /// `r` is an integer multiple of `s` under any reading of the 0.5 Hz rule (|r/k − s| < 0.5 also counts).
    static func isMultipleLoose(_ r: Double, of s: Double) -> Bool {
        guard s > 0, s.isFinite, r.isFinite else { return false }
        let k = nearest(r / s)
        return k >= 2 && abs(r - k * s) < 0.5 * k
    }

    /// The factor k ≥ 2 when `r`·k equals `s` (|s − k·r| < 0.5, the strictest reading).
    static func divisorFactor(_ r: Double, of s: Double) -> Double? {
        guard r > 0, r.isFinite, s.isFinite else { return nil }
        let k = nearest(s / r)
        return k >= 2 && abs(s - k * r) < 0.5 ? k : nil
    }

    static func isDivisor(_ r: Double, of s: Double) -> Bool { divisorFactor(r, of: s) != nil }

    /// `r` divides `s` under any reading of the 0.5 Hz rule (|r − s/k| < 0.5 also counts).
    static func isDivisorLoose(_ r: Double, of s: Double) -> Bool {
        guard r > 0, r.isFinite, s.isFinite else { return false }
        let k = nearest(s / r)
        return k >= 2 && abs(s / k - r) < 0.5
    }

    /// Which match-source rule (RATE-006 to RATE-009) governs `source` on `rates`. Situations that are ambiguous
    /// under the 0.5 Hz rule come out as `.other`, so mutants leave them alone.
    enum Situation { case offered, multiple, higher, divisor, other }

    static func situation(_ s: Double, _ rates: [Double]) -> Situation {
        if offers(rates, s) { return .offered }
        if rates.contains(where: { isMultiple($0, of: s) }) { return .multiple }
        if rates.contains(where: { isMultipleLoose($0, of: s) }) { return .other }
        if rates.contains(where: { higher($0, than: s) }) { return .higher }
        if rates.allSatisfy({ lower($0, than: s) }), rates.contains(where: { isDivisor($0, of: s) }) {
            return .divisor
        }
        return .other
    }
}

// MARK: - The decorator

private typealias ChooseFn = @Sendable (any RatePlanner, Double, [Double], Policy) -> Double
private typealias CarrierFn = @Sendable (any RatePlanner, Double) -> Double
private typealias PlanFn = @Sendable (any RatePlanner, Double, DSDDevice) -> DSDPlan

/// A correct planner with some of its functions replaced.
private struct Overlay: RatePlanner {
    let base: any RatePlanner
    var choose: ChooseFn? = nil
    var carrier: CarrierFn? = nil
    var plan: PlanFn? = nil

    func chooseRate(sourceRate: Double, offeredRates: [Double], policy: Policy) -> Double {
        if let choose { return choose(base, sourceRate, offeredRates, policy) }
        return base.chooseRate(sourceRate: sourceRate, offeredRates: offeredRates, policy: policy)
    }

    func dopCarrierRate(dsdRate: Double) -> Double {
        if let carrier { return carrier(base, dsdRate) }
        return base.dopCarrierRate(dsdRate: dsdRate)
    }

    func planDSD(dsdRate: Double, device: DSDDevice) -> DSDPlan {
        if let plan { return plan(base, dsdRate, device) }
        return base.planDSD(dsdRate: dsdRate, device: device)
    }
}

/// Replaces `chooseRate` for the match-source policy where `f` returns a rate; delegates everywhere else.
private func matchSource(_ f: @escaping @Sendable (any RatePlanner, Double, [Double]) -> Double?) -> ChooseFn {
    { base, s, rates, policy in
        if policy == .matchSource, let rate = f(base, s, rates) { return rate }
        return base.chooseRate(sourceRate: s, offeredRates: rates, policy: policy)
    }
}

/// Replaces `chooseRate` for the other policies where `f` returns a rate; delegates everywhere else.
private func otherPolicy(_ f: @escaping @Sendable (any RatePlanner, Double, [Double], Policy) -> Double?) -> ChooseFn {
    { base, s, rates, policy in
        if let rate = f(base, s, rates, policy) { return rate }
        return base.chooseRate(sourceRate: s, offeredRates: rates, policy: policy)
    }
}

/// Replaces `dopCarrierRate` where `f` returns a rate; delegates everywhere else.
private func carrier(_ f: @escaping @Sendable (any RatePlanner, Double) -> Double?) -> CarrierFn {
    { base, d in f(base, d) ?? base.dopCarrierRate(dsdRate: d) }
}

/// Replaces `planDSD` where `f` (given the correct plan) returns a plan; delegates everywhere else.
private func plan(_ f: @escaping @Sendable (any RatePlanner, Double, DSDDevice, DSDPlan) -> DSDPlan?) -> PlanFn {
    { base, d, device in
        let correct = base.planDSD(dsdRate: d, device: device)
        return f(base, d, device, correct) ?? correct
    }
}

/// The correct plan for `device` with its DoP mark set to `dop`.
private func planWithDoP(_ base: any RatePlanner, _ d: Double, _ device: DSDDevice, _ dop: Bool) -> DSDPlan {
    var changed = device
    changed.dopEnabled = dop
    return base.planDSD(dsdRate: d, device: changed)
}

/// The correct match-source choice among `rates` with every rate `drop` matches removed (nil if none would remain).
private func chooseWithout(_ base: any RatePlanner, _ s: Double, _ rates: [Double],
                   _ drop: (Double) -> Bool) -> Double? {
    let rest = rates.filter { !drop($0) }
    guard !rest.isEmpty else { return nil }
    return base.chooseRate(sourceRate: s, offeredRates: rest, policy: .matchSource)
}

/// A PCM plan converting at `pcmRate`, with the device rate chosen for it the ordinary way.
private func pcmPlan(_ base: any RatePlanner, _ pcmRate: Double, _ device: DSDDevice) -> DSDPlan {
    DSDPlan(mode: .pcm,
            deviceRate: base.chooseRate(sourceRate: pcmRate, offeredRates: device.offeredRates, policy: .matchSource),
            pcmRate: pcmRate)
}

// MARK: - The mutants

public enum RateMutants {
    public static let all: [Mutant<any RatePlanner>] = [

        // RATE-001: DSD64 is carried at 176.4 kHz.

        Mutant("C-RATE-001-a", targets: ["RATE-001", "RATE-003"],
               summary: "dopCarrierRate(DSD64) is DSD/8 = 352.8 kHz; every other DSD rate and planDSD are correct") { base in
            Overlay(base: base, carrier: carrier { _, d in Hz.eq(d, Hz.dsd64) ? d / 8 : nil })
        },
        Mutant("C-RATE-001-b", targets: ["RATE-001", "RATE-003"],
               summary: "dopCarrierRate(DSD64) is exactly 0.5 Hz high (176 400.5 Hz), the smallest gap the contract counts as a different rate") { base in
            Overlay(base: base, carrier: carrier { _, d in Hz.eq(d, Hz.dsd64) ? d / 16 + 0.5 : nil })
        },
        Mutant("C-RATE-001-c", targets: ["RATE-001", "RATE-003", "RATE-005"],
               summary: "planDSD sends DSD64 as DoP at 352.8 kHz instead of 176.4 kHz when a DoP device offers both; dopCarrierRate is correct") { base in
            Overlay(base: base, plan: plan { _, d, device, correct in
                guard correct.mode == .dop, Hz.eq(d, Hz.dsd64),
                      let wrong = Hz.offered(device.offeredRates, 352_800) else { return nil }
                return DSDPlan(mode: .dop, deviceRate: wrong, pcmRate: nil)
            })
        },

        // RATE-002: DSD128 is carried at 352.8 kHz.

        Mutant("C-RATE-002-a", targets: ["RATE-002", "RATE-003"],
               summary: "dopCarrierRate(DSD128) stays at 176.4 kHz (DSD/32, the channel-pair method); other rates are correct") { base in
            Overlay(base: base, carrier: carrier { _, d in Hz.eq(d, Hz.dsd128) ? d / 32 : nil })
        },
        Mutant("C-RATE-002-b", targets: ["RATE-002", "RATE-003"],
               summary: "dopCarrierRate(DSD128) is truncated to whole kilohertz: 352 000 Hz instead of 352 800 Hz") { base in
            Overlay(base: base, carrier: carrier { b, d in
                Hz.eq(d, Hz.dsd128) ? Hz.down(b.dopCarrierRate(dsdRate: d) / 1000) * 1000 : nil
            })
        },
        Mutant("C-RATE-002-c", targets: ["RATE-002", "RATE-003", "RATE-005"],
               summary: "planDSD sends DSD128 as DoP at 176.4 kHz instead of 352.8 kHz when a DoP device offers both; dopCarrierRate is correct") { base in
            Overlay(base: base, plan: plan { _, d, device, correct in
                guard correct.mode == .dop, Hz.eq(d, Hz.dsd128),
                      let wrong = Hz.offered(device.offeredRates, 176_400) else { return nil }
                return DSDPlan(mode: .dop, deviceRate: wrong, pcmRate: nil)
            })
        },

        // RATE-003: the carrier is DSD/16 at every DSD rate.

        Mutant("C-RATE-003-a", targets: ["RATE-003"],
               summary: "dopCarrierRate is capped at 352.8 kHz, so DSD256 and DSD512 come out at 352.8 kHz") { base in
            Overlay(base: base, carrier: carrier { b, d in
                Hz.higher(b.dopCarrierRate(dsdRate: d), than: 352_800) ? 352_800 : nil
            })
        },
        Mutant("C-RATE-003-b", targets: ["RATE-003"],
               summary: "dopCarrierRate is capped at 768 kHz, so only DSD512 and above are wrong (DSD512 gives 768 kHz, not 1411.2 kHz)") { base in
            Overlay(base: base, carrier: carrier { b, d in
                Hz.higher(b.dopCarrierRate(dsdRate: d), than: 768_000) ? 768_000 : nil
            })
        },
        Mutant("C-RATE-003-c", targets: ["RATE-003"],
               summary: "dopCarrierRate is 176.4 kHz times the nearest whole DSD64 multiple: right for the 44.1 kHz DSD family, wrong for 48 kHz-family DSD (3.072 MHz gives 176.4 kHz, not 192 kHz) and for DSD32") { base in
            Overlay(base: base, carrier: carrier { _, d in 176_400 * max(1, Hz.nearest(d / Hz.dsd64)) })
        },
        Mutant("C-RATE-003-d", targets: ["RATE-003", "RATE-005"],
               summary: "planDSD sends DSD256 and above as DoP at 352.8 kHz when a DoP device offers both that and the true carrier; dopCarrierRate is correct") { base in
            Overlay(base: base, plan: plan { b, d, device, correct in
                guard correct.mode == .dop, !Hz.lower(b.dopCarrierRate(dsdRate: d), than: 705_600),
                      let wrong = Hz.offered(device.offeredRates, 352_800) else { return nil }
                return DSDPlan(mode: .dop, deviceRate: wrong, pcmRate: nil)
            })
        },

        // RATE-004: DoP only when marked and the carrier is offered; otherwise PCM at DSD/8.

        Mutant("C-RATE-004-a", targets: ["RATE-004"],
               summary: "planDSD ignores the DoP mark: any device that offers the carrier rate gets DoP") { base in
            Overlay(base: base, plan: plan { b, d, device, _ in
                device.dopEnabled ? nil : planWithDoP(b, d, device, true)
            })
        },
        Mutant("C-RATE-004-b", targets: ["RATE-004"],
               summary: "the PCM fallback converts DSD at DSD/16 (the carrier rate) instead of DSD/8") { base in
            Overlay(base: base, plan: plan { b, d, device, correct in
                correct.mode == .pcm ? pcmPlan(b, d / 16, device) : nil
            })
        },
        Mutant("C-RATE-004-c", targets: ["RATE-004"],
               summary: "the PCM conversion rate is capped at 705.6 kHz, so only DSD256 and above convert at the wrong rate") { base in
            Overlay(base: base, plan: plan { b, d, device, correct in
                correct.mode == .pcm && Hz.higher(d / 8, than: 705_600) ? pcmPlan(b, 705_600, device) : nil
            })
        },
        Mutant("C-RATE-004-d", targets: ["RATE-004"],
               summary: "a device not marked for DoP still gets DoP for DSD64 (only) when it offers 176.4 kHz") { base in
            Overlay(base: base, plan: plan { b, d, device, _ in
                !device.dopEnabled && Hz.eq(d, Hz.dsd64) ? planWithDoP(b, d, device, true) : nil
            })
        },
        Mutant("C-RATE-004-e", targets: ["RATE-004"],
               summary: "the PCM plan reports the device rate as the conversion rate, wrong whenever the device doesn't offer DSD/8") { base in
            Overlay(base: base, plan: plan { _, _, _, correct in
                correct.mode == .pcm ? DSDPlan(mode: .pcm, deviceRate: correct.deviceRate, pcmRate: correct.deviceRate) : nil
            })
        },

        // RATE-005: marked and carrier offered gives DoP at the carrier.

        Mutant("C-RATE-005-a", targets: ["RATE-005"],
               summary: "planDSD never plans DoP: DSD always goes to PCM at DSD/8") { base in
            Overlay(base: base, plan: plan { b, d, device, correct in
                correct.mode == .dop ? planWithDoP(b, d, device, false) : nil
            })
        },
        Mutant("C-RATE-005-b", targets: ["RATE-005"],
               summary: "DoP also requires a 32-bit integer format, so a 24-bit-only DoP device gets PCM") { base in
            Overlay(base: base, plan: plan { b, d, device, correct in
                correct.mode == .dop && !device.integerBitDepths.contains(32) ? planWithDoP(b, d, device, false) : nil
            })
        },
        Mutant("C-RATE-005-c", targets: ["RATE-005"],
               summary: "DoP is refused on devices with more than two output channels (they get PCM)") { base in
            Overlay(base: base, plan: plan { b, d, device, correct in
                correct.mode == .dop && device.channels > 2 ? planWithDoP(b, d, device, false) : nil
            })
        },
        Mutant("C-RATE-005-d", targets: ["RATE-005"],
               summary: "DoP is refused when the carrier is above 384 kHz (DSD256 and up go to PCM even when offered)") { base in
            Overlay(base: base, plan: plan { b, d, device, correct in
                correct.mode == .dop && Hz.higher(b.dopCarrierRate(dsdRate: d), than: 384_000)
                    ? planWithDoP(b, d, device, false) : nil
            })
        },
        Mutant("C-RATE-005-e", targets: ["RATE-005"],
               summary: "the carrier must be offered bit-exactly: an offered rate within 0.5 Hz of the carrier (e.g. 176 400.3) gives PCM") { base in
            Overlay(base: base, plan: plan { b, d, device, correct in
                let c = b.dopCarrierRate(dsdRate: d)
                return correct.mode == .dop && !device.offeredRates.contains(where: { $0 == c })
                    ? planWithDoP(b, d, device, false) : nil
            })
        },

        // RATE-006: match source, source offered: the source rate.

        Mutant("C-RATE-006-a", targets: ["RATE-006"],
               summary: "match-source with the source offered picks the highest offered rate instead") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                Hz.situation(s, rates) == .offered ? rates.max() : nil
            })
        },
        Mutant("C-RATE-006-b", targets: ["RATE-006"],
               summary: "match-source picks the first offered rate (list order) that is the source or a multiple of it, so a multiple listed before the source wins") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                guard Hz.situation(s, rates) == .offered else { return nil }
                return rates.first { Hz.eq($0, s) || Hz.isMultiple($0, of: s) }
            })
        },
        Mutant("C-RATE-006-c", targets: ["RATE-006"],
               summary: "the source counts as offered only on bit-exact equality: an offered rate within 0.5 Hz of the source is passed over") { base in
            Overlay(base: base, choose: matchSource { b, s, rates in
                guard Hz.situation(s, rates) == .offered, !rates.contains(where: { $0 == s }) else { return nil }
                return chooseWithout(b, s, rates) { Hz.eq($0, s) }
            })
        },
        Mutant("C-RATE-006-d", targets: ["RATE-006"],
               summary: "off by one at the top: a source equal to the device's highest offered rate is passed over for a lower one") { base in
            Overlay(base: base, choose: matchSource { b, s, rates in
                guard Hz.situation(s, rates) == .offered, let top = rates.max(), Hz.eq(top, s) else { return nil }
                return chooseWithout(b, s, rates) { Hz.eq($0, s) }
            })
        },

        // RATE-007: match source, a multiple offered: a multiple.

        Mutant("C-RATE-007-a", targets: ["RATE-007"],
               summary: "with the source not offered, match-source picks the lowest higher rate even when it isn't a multiple (44.1 kHz on [48k, 88.2k] gives 48 kHz)") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                Hz.situation(s, rates) == .multiple ? rates.filter { Hz.higher($0, than: s) }.min() : nil
            })
        },
        Mutant("C-RATE-007-b", targets: ["RATE-007"],
               summary: "only power-of-two multiples (2x, 4x, 8x...) count, so a source whose only offered multiples are 3x, 5x, 6x... gets a non-multiple") { base in
            Overlay(base: base, choose: matchSource { b, s, rates in
                guard Hz.situation(s, rates) == .multiple,
                      !rates.contains(where: { Hz.multipleFactor($0, of: s)?.significand == 1 }) else { return nil }
                return chooseWithout(b, s, rates) { Hz.isMultipleLoose($0, of: s) }
            })
        },
        Mutant("C-RATE-007-c", targets: ["RATE-007"],
               summary: "with the source not offered, an offered integer divisor is preferred over an offered multiple") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                Hz.situation(s, rates) == .multiple ? rates.filter { Hz.isDivisor($0, of: s) }.max() : nil
            })
        },

        // RATE-008: match source, no multiple but a higher rate: a higher rate.

        Mutant("C-RATE-008-a", targets: ["RATE-008"],
               summary: "with neither the source nor a multiple offered, the highest rate below the source is picked even though a higher one is offered") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                Hz.situation(s, rates) == .higher ? rates.filter { Hz.lower($0, than: s) }.max() : nil
            })
        },
        Mutant("C-RATE-008-b", targets: ["RATE-008"],
               summary: "with neither the source nor a multiple offered, the nearest offered rate is picked, which may be lower (48 kHz on [44.1k, 88.2k] gives 44.1 kHz)") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                Hz.situation(s, rates) == .higher ? rates.min { abs($0 - s) < abs($1 - s) } : nil
            })
        },
        Mutant("C-RATE-008-c", targets: ["RATE-008"],
               summary: "an offered integer divisor is preferred over an offered higher rate (96 kHz on [48k, 176.4k] gives 48 kHz)") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                Hz.situation(s, rates) == .higher ? rates.filter { Hz.isDivisor($0, of: s) }.max() : nil
            })
        },

        // RATE-009: match source, all lower, a divisor offered: a divisor.

        Mutant("C-RATE-009-a", targets: ["RATE-009"],
               summary: "with every offered rate below the source, the highest is picked whether or not it divides the source") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                Hz.situation(s, rates) == .divisor ? rates.max() : nil
            })
        },
        Mutant("C-RATE-009-b", targets: ["RATE-009"],
               summary: "only halves and quarters count as divisors, so a source whose only offered divisors are 1/3, 1/8, ... gets a non-divisor") { base in
            Overlay(base: base, choose: matchSource { b, s, rates in
                guard Hz.situation(s, rates) == .divisor,
                      !rates.contains(where: { Hz.divisorFactor($0, of: s) == 2 || Hz.divisorFactor($0, of: s) == 4 })
                else { return nil }
                return chooseWithout(b, s, rates) { Hz.isDivisorLoose($0, of: s) }
            })
        },
        Mutant("C-RATE-009-c", targets: ["RATE-009"],
               summary: "with every offered rate below the source, the first offered rate in list order is picked, divisor or not") { base in
            Overlay(base: base, choose: matchSource { _, s, rates in
                Hz.situation(s, rates) == .divisor ? rates.first : nil
            })
        },

        // RATE-010: maximum gives the highest offered rate; an offered fixed rate is chosen.

        Mutant("C-RATE-010-a", targets: ["RATE-010"],
               summary: "maximum picks the highest offered rate in the source's family (source, multiple or divisor), not the highest overall") { base in
            Overlay(base: base, choose: otherPolicy { _, s, rates, policy in
                guard policy == .maximum else { return nil }
                return rates.filter { Hz.eq($0, s) || Hz.isMultipleLoose($0, of: s) || Hz.isDivisorLoose($0, of: s) }.max()
            })
        },
        Mutant("C-RATE-010-b", targets: ["RATE-010"],
               summary: "maximum returns the last offered rate, assuming the list is sorted ascending") { base in
            Overlay(base: base, choose: otherPolicy { _, _, rates, policy in
                policy == .maximum ? rates.last : nil
            })
        },
        Mutant("C-RATE-010-c", targets: ["RATE-010"],
               summary: "an offered fixed rate lower than the source is ignored and the match-source choice is used instead") { base in
            Overlay(base: base, choose: otherPolicy { b, s, rates, policy in
                guard case .fixed(let f) = policy, Hz.offers(rates, f), Hz.lower(f, than: s) else { return nil }
                return b.chooseRate(sourceRate: s, offeredRates: rates, policy: .matchSource)
            })
        },
        Mutant("C-RATE-010-d", targets: ["RATE-010"],
               summary: "a fixed rate counts as offered only on bit-exact equality; within 0.5 Hz it falls back to the match-source choice") { base in
            Overlay(base: base, choose: otherPolicy { b, s, rates, policy in
                guard case .fixed(let f) = policy, Hz.offers(rates, f), !rates.contains(where: { $0 == f }) else { return nil }
                return b.chooseRate(sourceRate: s, offeredRates: rates, policy: .matchSource)
            })
        },
        Mutant("C-RATE-010-e", targets: ["RATE-010"],
               summary: "maximum ignores offered rates above 384 kHz whenever a lower one is offered") { base in
            Overlay(base: base, choose: otherPolicy { _, _, rates, policy in
                policy == .maximum ? rates.filter { !Hz.higher($0, than: 384_000) }.max() : nil
            })
        },
    ]
}
