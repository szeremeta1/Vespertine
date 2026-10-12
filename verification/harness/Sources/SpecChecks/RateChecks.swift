//
// Spec-traced checks for the rate-plan contract: device-rate choice and DoP planning (RATE-001 … RATE-010).
//
// Rates are compared with the contract's rule: two rates are equal when they differ by less than 0.5 Hz.
// Where a record leaves a choice open (which multiple, which higher rate, which divisor) a check accepts every rate
// the record allows, and nothing is asserted where no record says what happens (a forced rate the device doesn't
// offer, a match-source choice with no multiple, higher rate or divisor offered, DoP on a 16-bit-only device).
//

import Contracts
import SpecKit

public enum RateChecks {
    public static let all: [SpecCheck<any RatePlanner>] = [
        // REQ: RATE-001
        SpecCheck("DSD64 (2.8224 MHz) is carried as DoP at 176.4 kHz", requirements: ["RATE-001"]) { planner, checker in
            let dsd = 2_822_400.0
            let carrier = planner.dopCarrierRate(dsdRate: dsd)
            checker.expect(same(carrier, 176_400), "RATE-001",
                           "dopCarrierRate(dsdRate: \(dsd)) = \(carrier), expected 176400")
            var rng = Rng(seed: 0x0001_0001)
            for device in probeDevices(dsd: dsd, rng: &rng) {
                let plan = planner.planDSD(dsdRate: dsd, device: device)
                checker.expect(plan.mode != .dop || same(plan.deviceRate, 176_400), "RATE-001",
                               "planDSD(\(dsd)) on \(describe(device)) planned DoP at \(plan.deviceRate), expected 176400")
            }
        },

        // REQ: RATE-002
        SpecCheck("DSD128 (5.6448 MHz) is carried as DoP at 352.8 kHz, not 176.4 kHz", requirements: ["RATE-002"]) {
            planner, checker in
            let dsd = 5_644_800.0
            let carrier = planner.dopCarrierRate(dsdRate: dsd)
            checker.expect(same(carrier, 352_800), "RATE-002",
                           "dopCarrierRate(dsdRate: \(dsd)) = \(carrier), expected 352800")
            var rng = Rng(seed: 0x0002_0001)
            // Devices that offer 176.4 kHz but not 352.8 kHz must not get the 176.4 kHz method.
            var devices = probeDevices(dsd: dsd, rng: &rng)
            for offered: [Double] in [[176_400], [44_100, 88_200, 176_400], [176_400, 705_600], [192_000, 176_400, 96_000]] {
                for depths in deepDepths {
                    devices.append(DSDDevice(offeredRates: offered, dopEnabled: true, integerBitDepths: depths, channels: 2))
                }
            }
            for device in devices {
                let plan = planner.planDSD(dsdRate: dsd, device: device)
                checker.expect(plan.mode != .dop || same(plan.deviceRate, 352_800), "RATE-002",
                               "planDSD(\(dsd)) on \(describe(device)) planned DoP at \(plan.deviceRate), expected 352800")
            }
        },

        // REQ: RATE-003
        SpecCheck("The DoP carrier rate is the DSD rate divided by 16 at every DSD rate", requirements: ["RATE-003"]) {
            planner, checker in
            let named: [(Double, Double)] = [(11_289_600, 705_600), (22_579_200, 1_411_200)]
            for (dsd, expected) in named {
                let got = planner.dopCarrierRate(dsdRate: dsd)
                checker.expect(same(got, expected), "RATE-003",
                               "dopCarrierRate(dsdRate: \(dsd)) = \(got), expected \(expected)")
            }
            // Every DSD rate of both families, called up, down and interleaved.
            let sequence = dsdRates + Array(dsdRates.reversed()) + interleave(dsdRates44, Array(dsdRates48.reversed()))
            for dsd in sequence {
                let got = planner.dopCarrierRate(dsdRate: dsd)
                checker.expect(same(got, dsd / 16), "RATE-003",
                               "dopCarrierRate(dsdRate: \(dsd)) = \(got), expected \(dsd / 16)")
            }
        },

        // REQ: RATE-003
        SpecCheck("A DoP plan runs the device at the DSD rate divided by 16", requirements: ["RATE-003"]) {
            planner, checker in
            var rng = Rng(seed: 0x0003_0002)
            for dsd in dsdRates {
                for device in probeDevices(dsd: dsd, rng: &rng) {
                    let plan = planner.planDSD(dsdRate: dsd, device: device)
                    checker.expect(plan.mode != .dop || same(plan.deviceRate, dsd / 16), "RATE-003",
                                   "planDSD(\(dsd)) on \(describe(device)) planned DoP at \(plan.deviceRate), expected \(dsd / 16)")
                }
            }
        },

        // REQ: RATE-004
        SpecCheck("A device not marked as decoding DoP gets PCM at the DSD rate / 8", requirements: ["RATE-004"]) {
            planner, checker in
            var rng = Rng(seed: 0x0004_0001)
            for dsd in dsdRates {
                for device in dopOffDevices(dsd: dsd, rng: &rng) {
                    expectPCM(planner, checker, dsd: dsd, device: device, id: "RATE-004")
                }
            }
        },

        // REQ: RATE-004
        SpecCheck("A DoP device that doesn't offer the carrier rate gets PCM at the DSD rate / 8", requirements: ["RATE-004"]) {
            planner, checker in
            var rng = Rng(seed: 0x0004_0002)
            for dsd in dsdRates {
                for device in noCarrierDevices(dsd: dsd, rng: &rng) {
                    expectPCM(planner, checker, dsd: dsd, device: device, id: "RATE-004")
                }
            }
        },

        // REQ: RATE-004
        SpecCheck("A rate 1 Hz or more from the carrier rate is not the carrier rate", requirements: ["RATE-004"]) {
            planner, checker in
            for dsd in dsdRates {
                let carrier = dsd / 16
                let offsets: [Double] = [1, -1, 2, -3, 50]
                for delta in offsets {
                    let sets: [[Double]] = [
                        [carrier + delta],
                        [carrier + delta, carrier * 2],
                        [44_100, 48_000, carrier + delta],
                        [carrier / 2, carrier + delta, carrier * 4],
                    ]
                    for offered in sets {
                        for depths in [[16, 24, 32], [24]] {
                            let device = DSDDevice(offeredRates: offered, dopEnabled: true, integerBitDepths: depths,
                                                   channels: 2)
                            expectPCM(planner, checker, dsd: dsd, device: device, id: "RATE-004")
                        }
                    }
                }
            }
        },

        // REQ: RATE-004
        SpecCheck("After conversion to PCM the device rate is the ordinary choice for the PCM rate", requirements: ["RATE-004"]) {
            planner, checker in
            var rng = Rng(seed: 0x0004_0004)
            var cases: [(Double, DSDDevice)] = []
            for (dsd, offered, dop) in pcmDeviceRateCases {
                for depths in [[16, 24, 32], [16]] {
                    cases.append((dsd, DSDDevice(offeredRates: offered, dopEnabled: dop, integerBitDepths: depths,
                                                 channels: 2)))
                }
            }
            for dsd in dsdRates {
                for device in dopOffDevices(dsd: dsd, rng: &rng) + noCarrierDevices(dsd: dsd, rng: &rng) {
                    cases.append((dsd, device))
                }
            }
            for (dsd, device) in cases {
                let pcm = dsd / 8
                let expectation = matchExpectation(source: pcm, offered: device.offeredRates)
                guard expectation.rule != .open else { continue }
                for variant in reordered(device, &rng) {
                    let plan = planner.planDSD(dsdRate: dsd, device: variant)
                    checker.expect(expectation.allowed.contains { same($0, plan.deviceRate) }, "RATE-004",
                                   "planDSD(\(dsd)) on \(describe(variant)) -> \(describe(plan)); for PCM at \(pcm) the "
                                   + "device rate should be one of \(fmt(expectation.allowed)) (\(expectation.rule))")
                }
            }
        },

        // REQ: RATE-005
        SpecCheck("A DoP device that offers the carrier rate gets DoP at the carrier rate", requirements: ["RATE-005"]) {
            planner, checker in
            var rng = Rng(seed: 0x0005_0001)
            for dsd in dsdRates {
                for device in dopDevices(dsd: dsd, depths: deepDepths, rng: &rng) {
                    expectDoP(planner, checker, dsd: dsd, device: device, id: "RATE-005")
                }
            }
        },

        // REQ: RATE-005
        SpecCheck("DoP is planned on a DoP device whose integer formats are deeper than 24 bits", requirements: ["RATE-005"]) {
            planner, checker in
            var rng = Rng(seed: 0x0005_0002)
            for dsd in dsdRates {
                for device in dopDevices(dsd: dsd, depths: [[32], [16, 32]], rng: &rng) {
                    expectDoP(planner, checker, dsd: dsd, device: device, id: "RATE-005")
                }
            }
        },

        // REQ: RATE-005
        SpecCheck("An offered rate within 0.5 Hz of the carrier rate is the carrier rate", requirements: ["RATE-005"]) {
            planner, checker in
            for dsd in dsdRates {
                let carrier = dsd / 16
                for delta in [0.25, -0.25, 0.1, -0.3] {
                    let sets: [[Double]] = [
                        [carrier + delta],
                        [44_100, carrier + delta, carrier * 2],
                        [carrier / 2, carrier * 4, carrier + delta],
                    ]
                    for offered in sets {
                        let device = DSDDevice(offeredRates: offered, dopEnabled: true, integerBitDepths: [16, 24, 32],
                                               channels: 2)
                        expectDoP(planner, checker, dsd: dsd, device: device, id: "RATE-005")
                    }
                }
            }
        },

        // REQ: RATE-006
        SpecCheck("Match-source chooses the source rate when it is offered", requirements: ["RATE-006"]) {
            planner, checker in
            var rng = Rng(seed: 0x0006_0001)
            let explicit: [(Double, [Double])] = [
                (44_100, [44_100]),
                (44_100, [48_000, 88_200, 44_100, 176_400]),
                (96_000, [44_100, 48_000, 88_200, 96_000, 192_000, 384_000]),
                (192_000, [44_100, 192_000]),
                (384_000, [384_000, 768_000, 48_000]),
                (48_000, [96_000, 192_000, 48_000, 44_100, 22_050]),
                (705_600, [705_600, 1_411_200, 44_100]),
                (8_000, [16_000, 8_000, 48_000]),
                (11_025, [1_411_200, 44_100, 22_050, 11_025]),
                (50_000, [50_000, 100_000, 44_100]),
                (37_800, [75_600, 44_100, 37_800]),
            ]
            for (source, offered) in explicit {
                expectMatch(planner, checker, source: source, offered: offered, rule: .exact, rng: &rng)
            }
            for (source, offered) in matchScenarios(.exact, pool: widePool, count: 200, rng: &rng) {
                expectMatch(planner, checker, source: source, offered: offered, rule: .exact, rng: &rng)
            }
        },

        // REQ: RATE-006
        SpecCheck("Match-source treats rates within 0.5 Hz of the source as the source rate", requirements: ["RATE-006"]) {
            planner, checker in
            var rng = Rng(seed: 0x0006_0002)
            for source in [22_050.0, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000] {
                for delta in [0.2, -0.2, 0.3, -0.25] {
                    let others: [[Double]] = [[], [source * 2], [source * 2, source * 4, 1_536_000],
                                              [source / 2, source * 2]]
                    for extra in others {
                        // The device offers the source rate a little off.
                        expectMatch(planner, checker, source: source, offered: [source + delta] + extra, rule: .exact,
                                    rng: &rng)
                        // The source rate is a little off.
                        expectMatch(planner, checker, source: source + delta, offered: extra + [source], rule: .exact,
                                    rng: &rng)
                    }
                }
            }
        },

        // REQ: RATE-007
        SpecCheck("Match-source chooses an offered multiple when the source rate isn't offered", requirements: ["RATE-007"]) {
            planner, checker in
            var rng = Rng(seed: 0x0007_0001)
            let explicit: [(Double, [Double])] = [
                (44_100, [48_000, 96_000, 176_400]),
                (88_200, [44_100, 96_000, 192_000, 352_800]),
                (48_000, [44_100, 96_000, 88_200]),
                (44_100, [48_000, 88_200, 176_400, 352_800, 96_000]),
                (22_050, [44_100]),
                (11_025, [12_000, 1_411_200]),
                (96_000, [88_200, 176_400, 384_000]),
                (176_400, [192_000, 384_000, 705_600, 96_000]),
                (50_000, [44_100, 100_000, 96_000]),
                (44_100, [22_050, 48_000, 352_800, 192_000]),
            ]
            for (source, offered) in explicit {
                expectMatch(planner, checker, source: source, offered: offered, rule: .multiple, rng: &rng)
            }
            for (source, offered) in matchScenarios(.multiple, pool: corePool, count: 250, rng: &rng) {
                expectMatch(planner, checker, source: source, offered: offered, rule: .multiple, rng: &rng)
            }
        },

        // REQ: RATE-007
        SpecCheck("Match-source counts any integer multiple (three, six times …), not only powers of two",
                  requirements: ["RATE-007"]) { planner, checker in
            var rng = Rng(seed: 0x0007_0002)
            let explicit: [(Double, [Double])] = [
                (16_000, [44_100, 48_000]),
                (16_000, [11_025, 22_050, 44_100, 48_000, 88_200]),
                (32_000, [44_100, 88_200, 96_000, 176_400]),
                (8_000, [11_025, 44_100, 48_000]),
                (64_000, [44_100, 88_200, 192_000, 176_400]),
                (8_000, [11_025, 24_000]),
                (24_000, [8_000, 44_100, 72_000]),
                (44_100, [48_000, 132_300]),
                (16_000, [192_000, 176_400, 22_050]),
            ]
            for (source, offered) in explicit {
                expectMatch(planner, checker, source: source, offered: offered, rule: .multiple, rng: &rng)
            }
            for (source, offered) in matchScenarios(.multiple, pool: widePool, sources: family8k + [12_000, 24_000],
                                                    count: 200, rng: &rng) {
                expectMatch(planner, checker, source: source, offered: offered, rule: .multiple, rng: &rng)
            }
        },

        // REQ: RATE-007
        SpecCheck("A rate 1 Hz or more from the source rate is not the source rate", requirements: ["RATE-007"]) {
            planner, checker in
            var rng = Rng(seed: 0x0007_0003)
            for source in [44_100.0, 48_000, 88_200, 96_000, 176_400] {
                for delta in [1.0, -1.0, 2.0, -5.0] {
                    let sets: [[Double]] = [
                        [source + delta, source * 2],
                        [source * 4, source + delta],
                        [source / 2, source + delta, source * 2, source * 8],
                    ]
                    for offered in sets {
                        expectMatch(planner, checker, source: source, offered: offered, rule: .multiple, rng: &rng)
                    }
                }
            }
        },

        // REQ: RATE-008
        SpecCheck("Match-source chooses a higher rate when neither the source rate nor a multiple is offered",
                  requirements: ["RATE-008"]) { planner, checker in
            var rng = Rng(seed: 0x0008_0001)
            let explicit: [(Double, [Double])] = [
                (44_100, [48_000, 96_000, 32_000]),
                (96_000, [44_100, 88_200, 176_400]),
                (48_000, [44_100, 88_200, 176_400, 352_800]),
                (44_100, [22_050, 48_000]),
                (88_200, [44_100, 22_050, 96_000]),
                (192_000, [352_800, 96_000, 48_000]),
                (11_025, [12_000]),
                (50_000, [44_100, 96_000, 48_000]),
                (176_400, [192_000, 44_100, 88_200]),
                (352_800, [384_000, 176_400, 768_000]),
                (16_000, [22_050, 11_025, 44_100]),
            ]
            for (source, offered) in explicit {
                expectMatch(planner, checker, source: source, offered: offered, rule: .higher, rng: &rng)
            }
            for (source, offered) in matchScenarios(.higher, pool: widePool, count: 250, rng: &rng) {
                expectMatch(planner, checker, source: source, offered: offered, rule: .higher, rng: &rng)
            }
        },

        // REQ: RATE-009
        SpecCheck("Match-source chooses an offered divisor when every offered rate is lower", requirements: ["RATE-009"]) {
            planner, checker in
            var rng = Rng(seed: 0x0009_0001)
            let explicit: [(Double, [Double])] = [
                (192_000, [44_100, 48_000, 96_000]),
                (176_400, [48_000, 96_000, 44_100]),
                (352_800, [192_000, 96_000, 48_000, 88_200]),
                (192_000, [44_100, 96_000]),
                (96_000, [48_000]),
                (88_200, [22_050, 48_000]),
                (384_000, [44_100, 88_200, 176_400, 352_800, 192_000]),
                (1_536_000, [705_600, 768_000]),
                (705_600, [44_100, 384_000, 192_000, 96_000, 48_000]),
            ]
            for (source, offered) in explicit {
                expectMatch(planner, checker, source: source, offered: offered, rule: .divisor, rng: &rng)
            }
            for (source, offered) in matchScenarios(.divisor, pool: corePool, count: 250, rng: &rng) {
                expectMatch(planner, checker, source: source, offered: offered, rule: .divisor, rng: &rng)
            }
        },

        // REQ: RATE-009
        SpecCheck("Match-source counts any exact divisor (a third, a sixth …), not only powers of two",
                  requirements: ["RATE-009"]) { planner, checker in
            var rng = Rng(seed: 0x0009_0002)
            let explicit: [(Double, [Double])] = [
                (48_000, [16_000, 44_100, 22_050, 11_025]),
                (96_000, [32_000, 44_100, 88_200]),
                (192_000, [64_000, 176_400, 44_100]),
                (48_000, [8_000, 44_100]),
                (24_000, [8_000, 22_050, 11_025]),
                (132_300, [44_100, 48_000, 96_000]),
                (96_000, [88_200, 16_000, 64_000]),
            ]
            for (source, offered) in explicit {
                expectMatch(planner, checker, source: source, offered: offered, rule: .divisor, rng: &rng)
            }
            for (source, offered) in matchScenarios(.divisor, pool: widePool, sources: family48, count: 200, rng: &rng) {
                expectMatch(planner, checker, source: source, offered: offered, rule: .divisor, rng: &rng)
            }
        },

        // REQ: RATE-010
        SpecCheck("The maximum policy chooses the highest offered rate whatever the source rate", requirements: ["RATE-010"]) {
            planner, checker in
            var rng = Rng(seed: 0x0010_0001)
            var sets: [[Double]] = [
                [44_100], [48_000, 44_100], [44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
                [384_000, 44_100, 768_000, 48_000], [1_536_000, 8_000], [11_025, 12_000, 22_050],
            ]
            for _ in 0..<150 {
                let offered = rng.subset(widePool, percent: 30)
                if !offered.isEmpty { sets.append(rng.shuffled(offered)) }
            }
            for offered in sets {
                guard let highest = offered.max() else { continue }
                let lowest = offered.min() ?? highest
                var sources: [Double] = [1_000, 8_000, 44_100, 48_000, 96_000, 192_000, 384_000, 3_072_000,
                                         highest, lowest, highest * 2, lowest / 2]
                if let any = rng.pick(offered) { sources.append(any) }
                for source in sources {
                    for order in orders(offered, &rng) {
                        let got = planner.chooseRate(sourceRate: source, offeredRates: order, policy: .maximum)
                        checker.expect(same(got, highest), "RATE-010",
                                       "maximum, source \(source), offered \(fmt(order)): got \(got), expected \(highest)")
                    }
                }
            }
        },

        // REQ: RATE-010
        SpecCheck("A fixed rate the device offers is chosen whatever the source rate", requirements: ["RATE-010"]) {
            planner, checker in
            var rng = Rng(seed: 0x0010_0002)
            var sets: [[Double]] = [
                [44_100], [48_000, 44_100], [44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
                [384_000, 44_100, 768_000, 48_000], [1_536_000, 8_000], [11_025, 12_000, 22_050],
            ]
            for _ in 0..<120 {
                let offered = rng.subset(widePool, percent: 30)
                if !offered.isEmpty { sets.append(rng.shuffled(offered)) }
            }
            for offered in sets {
                for fixed in offered {
                    var sources: [Double] = [fixed, fixed * 2, fixed / 2, 44_100, 48_000, 192_000]
                    if let any = rng.pick(offered) { sources.append(any) }
                    for source in sources {
                        for order in orders(offered, &rng) {
                            let got = planner.chooseRate(sourceRate: source, offeredRates: order,
                                                         policy: .fixed(rate: fixed))
                            checker.expect(same(got, fixed), "RATE-010",
                                           "fixed(\(fixed)), source \(source), offered \(fmt(order)): got \(got)")
                        }
                    }
                }
            }
        },

        // REQ: RATE-010
        SpecCheck("A fixed rate within 0.5 Hz of an offered rate is an offered rate", requirements: ["RATE-010"]) {
            planner, checker in
            var rng = Rng(seed: 0x0010_0003)
            let sets: [[Double]] = [
                [44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
                [352_800, 384_000, 44_100],
                [48_000],
            ]
            for offered in sets {
                for rate in offered {
                    for delta in [0.2, -0.2, 0.3, -0.3] {
                        for source in [44_100.0, 96_000, rate] {
                            for order in orders(offered, &rng) {
                                let got = planner.chooseRate(sourceRate: source, offeredRates: order,
                                                             policy: .fixed(rate: rate + delta))
                                checker.expect(same(got, rate), "RATE-010",
                                               "fixed(\(rate + delta)), source \(source), offered \(fmt(order)): "
                                               + "got \(got), expected \(rate)")
                            }
                        }
                    }
                }
            }
        },
    ]
}

// MARK: - Rates

/// Two rates are equal when they differ by less than 0.5 Hz.
private func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }

/// The whole number nearest a non-negative finite `x` (below 2^53), computed without the C maths library.
private func nearestWhole(_ x: Double) -> Double? {
    guard x.isFinite, x >= 0, x < 9_007_199_254_740_992 else { return nil }
    return Double(Int64(x + 0.5))
}

/// `rate` is `k × source` for an integer `k ≥ 2`.
private func isMultiple(_ rate: Double, of source: Double) -> Bool {
    guard source > 0, source.isFinite, rate.isFinite, let k = nearestWhole(rate / source) else { return false }
    return k >= 2 && same(rate, k * source)
}

/// `rate` divides `source` exactly: `source` is `k × rate` for an integer `k ≥ 2`.
private func isDivisor(_ rate: Double, of source: Double) -> Bool {
    guard rate > 0, rate.isFinite, source.isFinite, let k = nearestWhole(source / rate) else { return false }
    return k >= 2 && same(source, k * rate)
}

private let family44: [Double] = [11_025, 22_050, 44_100, 88_200, 176_400, 352_800, 705_600, 1_411_200]
private let family48: [Double] = [12_000, 24_000, 48_000, 96_000, 192_000, 384_000, 768_000, 1_536_000]
/// Within a family every ratio is a power of two; across the families no ratio is an integer.
private let corePool: [Double] = family44 + family48
/// Rates with factor-of-three relations to the 48 kHz family (16 000 × 3 = 48 000, 8 000 × 3 = 24 000, …).
private let family8k: [Double] = [8_000, 16_000, 32_000, 64_000]
private let widePool: [Double] = corePool + family8k

private let dsdRates44: [Double] = [2_822_400, 5_644_800, 11_289_600, 22_579_200, 45_158_400]
private let dsdRates48: [Double] = [3_072_000, 6_144_000, 12_288_000, 24_576_000, 49_152_000]
private let dsdRates: [Double] = dsdRates44 + dsdRates48

/// Integer formats of 24 bits or deeper, as RATE-005's gap asks for when DoP is expected.
private let deepDepths: [[Int]] = [[16, 24, 32], [24], [24, 32], [16, 24]]
/// Any integer formats, for devices where the bit depth can't decide the plan.
private let anyDepths: [[Int]] = deepDepths + [[16], [], [32], [16, 32], [8, 16]]
private let channelCounts: [Int] = [2, 4, 6, 8]

private func fmt(_ rates: [Double]) -> String { "[" + rates.map { "\($0)" }.joined(separator: ", ") + "]" }

private func describe(_ device: DSDDevice) -> String {
    "device(offered \(fmt(device.offeredRates)), dopEnabled \(device.dopEnabled), depths \(device.integerBitDepths), "
        + "channels \(device.channels))"
}

private func describe(_ plan: DSDPlan) -> String {
    "plan(\(plan.mode), deviceRate \(plan.deviceRate), pcmRate \(plan.pcmRate.map { "\($0)" } ?? "nil"))"
}

private func interleave(_ a: [Double], _ b: [Double]) -> [Double] {
    var out: [Double] = []
    for i in 0..<max(a.count, b.count) {
        if i < a.count { out.append(a[i]) }
        if i < b.count { out.append(b[i]) }
    }
    return out
}

/// Appends `rate` unless an equal rate is already there (offered rates have no duplicates).
private func adding(_ rates: [Double], _ extra: [Double]) -> [Double] {
    var out = rates
    for rate in extra where !out.contains(where: { same($0, rate) }) { out.append(rate) }
    return out
}

// MARK: - Deterministic pseudo-random data

/// SplitMix64: a small seeded generator, so every run sees the same data.
private struct Rng {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<n (0 when n ≤ 0).
    mutating func below(_ n: Int) -> Int { n > 0 ? Int(next() % UInt64(n)) : 0 }

    mutating func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[below(items.count)] }

    mutating func subset<T>(_ items: [T], percent: Int) -> [T] {
        var out: [T] = []
        for item in items {
            if below(100) < percent { out.append(item) }
        }
        return out
    }

    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var out = items
        var i = out.count - 1
        while i > 0 {
            let j = below(i + 1)
            if j != i { out.swapAt(i, j) }
            i -= 1
        }
        return out
    }
}

/// The same rates in several orders (offered rates are in no particular order).
private func orders(_ rates: [Double], _ rng: inout Rng) -> [[Double]] {
    [rates, Array(rates.reversed()), rates.sorted(), rates.sorted(by: >), rng.shuffled(rates)]
}

private func reordered(_ device: DSDDevice, _ rng: inout Rng) -> [DSDDevice] {
    orders(device.offeredRates, &rng).map { order in
        var copy = device
        copy.offeredRates = order
        return copy
    }
}

// MARK: - Match-source expectations (RATE-006 … RATE-009)

private enum MatchRule: String {
    case exact = "source rate (RATE-006)"
    case multiple = "integer multiple (RATE-007)"
    case higher = "higher rate (RATE-008)"
    case divisor = "integer divisor (RATE-009)"
    case open = "no rule"
}

private struct MatchExpectation {
    var rule: MatchRule
    /// The offered rates the rule allows.
    var allowed: [Double]
}

/// Which of RATE-006 … RATE-009 applies to `source` and `offered`, and which offered rates it allows.
private func matchExpectation(source: Double, offered: [Double]) -> MatchExpectation {
    let exact = offered.filter { same($0, source) }
    if !exact.isEmpty { return MatchExpectation(rule: .exact, allowed: exact) }
    let multiples = offered.filter { isMultiple($0, of: source) }
    if !multiples.isEmpty { return MatchExpectation(rule: .multiple, allowed: multiples) }
    let higher = offered.filter { $0 > source }
    if !higher.isEmpty { return MatchExpectation(rule: .higher, allowed: higher) }
    let divisors = offered.filter { isDivisor($0, of: source) }
    if !divisors.isEmpty { return MatchExpectation(rule: .divisor, allowed: divisors) }
    return MatchExpectation(rule: .open, allowed: [])
}

private func requirement(of rule: MatchRule) -> String {
    switch rule {
    case .exact: "RATE-006"
    case .multiple: "RATE-007"
    case .higher: "RATE-008"
    case .divisor: "RATE-009"
    case .open: ""
    }
}

/// Asserts the match-source choice for one scenario, with the offered rates in several orders, when `rule` is the
/// rule that applies to it; asserts nothing otherwise.
private func expectMatch(_ planner: any RatePlanner, _ checker: Checker, source: Double, offered: [Double],
                         rule: MatchRule, rng: inout Rng) {
    let expectation = matchExpectation(source: source, offered: offered)
    guard expectation.rule == rule, rule != .open, !expectation.allowed.isEmpty else { return }
    let id = requirement(of: rule)
    for order in orders(offered, &rng) {
        let got = planner.chooseRate(sourceRate: source, offeredRates: order, policy: .matchSource)
        checker.expect(expectation.allowed.contains { same($0, got) }, id,
                       "matchSource, source \(source), offered \(fmt(order)): got \(got), expected \(rule.rawValue) "
                       + "one of \(fmt(expectation.allowed))")
    }
}

/// Random match-source scenarios to which `rule` applies, drawn from `pool` with sources from `sources` (default:
/// the pool); at most `count` of them, from a bounded number of tries.
private func matchScenarios(_ rule: MatchRule, pool: [Double], sources: [Double]? = nil, count: Int,
                            rng: inout Rng) -> [(Double, [Double])] {
    let sourcePool = sources ?? pool
    var out: [(Double, [Double])] = []
    var tries = 0
    while out.count < count && tries < count * 40 {
        tries += 1
        guard let source = rng.pick(sourcePool) else { break }
        let others = pool.filter { !same($0, source) }
        var offered: [Double]
        switch rule {
        case .exact:
            offered = rng.subset(others, percent: 35) + [source]
        case .multiple:
            offered = rng.subset(others, percent: 35)
            if !offered.contains(where: { isMultiple($0, of: source) }),
               let m = rng.pick(pool.filter { isMultiple($0, of: source) }) {
                offered.append(m)
            }
        case .higher:
            let candidates = others.filter { !isMultiple($0, of: source) }
            offered = rng.subset(candidates, percent: 35)
            if !offered.contains(where: { $0 > source }), let h = rng.pick(candidates.filter { $0 > source }) {
                offered.append(h)
            }
        case .divisor:
            let lower = others.filter { $0 < source }
            offered = rng.subset(lower, percent: 40)
            if !offered.contains(where: { isDivisor($0, of: source) }),
               let d = rng.pick(lower.filter { isDivisor($0, of: source) }) {
                offered.append(d)
            }
        case .open:
            return out
        }
        offered = rng.shuffled(offered)
        guard !offered.isEmpty, matchExpectation(source: source, offered: offered).rule == rule else { continue }
        out.append((source, offered))
    }
    return out
}

// MARK: - DSD plans (RATE-001 … RATE-005)

/// DoP-enabled devices with 24-bit or deeper formats, offering rates around the carrier rate (`dsd / 16`) — with
/// and without it — for checks that only constrain plans that come out as DoP.
private func probeDevices(dsd: Double, rng: inout Rng) -> [DSDDevice] {
    let near: [Double] = [dsd / 32, dsd / 16, dsd / 8, dsd / 4]
    var sets: [[Double]] = [
        [dsd / 16], [dsd / 16, dsd / 8], [dsd / 32, dsd / 16], [dsd / 32], [dsd / 8], [dsd / 32, dsd / 8],
        adding([44_100, 48_000, 88_200, 96_000], [dsd / 16]), adding([44_100, 48_000, 88_200, 96_000, 176_400], []),
        adding([dsd / 4, dsd / 32], [dsd / 16]),
    ]
    for _ in 0..<12 {
        let offered = adding(rng.subset(corePool, percent: 30), rng.subset(near, percent: 50))
        if !offered.isEmpty { sets.append(rng.shuffled(offered)) }
    }
    var devices: [DSDDevice] = []
    for offered in sets {
        let depths = rng.pick(deepDepths) ?? [24]
        let channels = rng.pick(channelCounts) ?? 2
        devices.append(DSDDevice(offeredRates: offered, dopEnabled: true, integerBitDepths: depths, channels: channels))
    }
    return devices
}

/// DoP-enabled devices that offer the carrier rate (`dsd / 16`), with integer formats from `depths`.
private func dopDevices(dsd: Double, depths: [[Int]], rng: inout Rng) -> [DSDDevice] {
    let carrier = dsd / 16
    var sets: [[Double]] = [
        [carrier], [carrier, dsd / 8], [dsd / 8, carrier], [carrier / 2, carrier], [carrier * 4, carrier, carrier / 2],
        adding([44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000], [carrier]),
        adding([44_100, 48_000], [carrier]), adding([1_536_000, 1_411_200], [carrier]),
    ]
    for _ in 0..<16 {
        sets.append(rng.shuffled(adding(rng.subset(corePool, percent: 35), [carrier])))
    }
    var devices: [DSDDevice] = []
    for (i, offered) in sets.enumerated() {
        let d = depths.isEmpty ? [24] : depths[i % depths.count]
        let channels = channelCounts[i % channelCounts.count]
        devices.append(DSDDevice(offeredRates: offered, dopEnabled: true, integerBitDepths: d, channels: channels))
    }
    for device in Array(devices.prefix(3)) {
        devices.append(contentsOf: reordered(device, &rng))
    }
    return devices
}

/// Devices not marked as decoding DoP, some offering the carrier rate.
private func dopOffDevices(dsd: Double, rng: inout Rng) -> [DSDDevice] {
    let carrier = dsd / 16
    var sets: [[Double]] = [
        [carrier], [carrier, dsd / 8], [dsd / 8], [44_100], [44_100, 48_000, 88_200, 96_000],
        adding([44_100, 88_200, 176_400, 352_800, 705_600], [carrier]), [carrier / 2, carrier, carrier * 4],
    ]
    for _ in 0..<14 {
        var offered = rng.subset(corePool, percent: 35)
        if rng.below(2) == 0 { offered = adding(offered, [carrier]) }
        if offered.isEmpty { offered = [carrier] }
        sets.append(rng.shuffled(offered))
    }
    var devices: [DSDDevice] = []
    for (i, offered) in sets.enumerated() {
        devices.append(DSDDevice(offeredRates: offered, dopEnabled: false,
                                 integerBitDepths: anyDepths[i % anyDepths.count],
                                 channels: channelCounts[i % channelCounts.count]))
    }
    return devices
}

/// Devices marked as decoding DoP, with 24-bit or deeper formats, that don't offer the carrier rate.
private func noCarrierDevices(dsd: Double, rng: inout Rng) -> [DSDDevice] {
    let carrier = dsd / 16
    var sets: [[Double]] = [
        [dsd / 8], [carrier / 2], [carrier / 2, dsd / 8], [dsd / 8, dsd / 4], [44_100, 48_000],
        [carrier * 4, carrier / 4],
    ]
    for _ in 0..<14 {
        var offered = rng.subset(corePool.filter { !same($0, carrier) }, percent: 35)
        if offered.isEmpty { offered = [dsd / 8] }
        sets.append(rng.shuffled(offered))
    }
    var devices: [DSDDevice] = []
    for (i, offered) in sets.enumerated() where !offered.contains(where: { same($0, carrier) }) {
        devices.append(DSDDevice(offeredRates: offered, dopEnabled: true,
                                 integerBitDepths: deepDepths[i % deepDepths.count],
                                 channels: channelCounts[i % channelCounts.count]))
    }
    return devices
}

/// PCM plans whose device rate one of RATE-006 … RATE-009 decides for the PCM rate `dsd / 8`.
private let pcmDeviceRateCases: [(Double, [Double], Bool)] = [
    // DSD64: PCM at 352.8 kHz, carrier 176.4 kHz.
    (2_822_400, [44_100, 88_200, 176_400, 352_800], false),   // the PCM rate is offered
    (2_822_400, [176_400, 352_800], false),
    (2_822_400, [352_800, 705_600], true),                    // DoP device without the carrier
    (2_822_400, [44_100, 96_000, 705_600], true),             // a multiple is offered
    (2_822_400, [48_000, 384_000, 44_100], true),             // only a higher rate
    (2_822_400, [44_100, 48_000, 96_000, 192_000], false),    // every rate lower: 44.1 kHz divides
    (2_822_400, [44_100, 88_200, 176_400], false),
    (2_822_400, [176_400, 44_100], false),
    // DSD128: PCM at 705.6 kHz, carrier 352.8 kHz.
    (5_644_800, [176_400, 44_100], true),
    (5_644_800, [705_600, 1_411_200], true),
    (5_644_800, [44_100, 48_000, 96_000, 192_000, 384_000, 352_800], false),
    (5_644_800, [768_000, 192_000], true),
    // DSD256: PCM at 1411.2 kHz, carrier 705.6 kHz.
    (11_289_600, [44_100, 88_200, 176_400, 352_800, 1_411_200], true),
    (11_289_600, [384_000, 88_200, 1_536_000], false),
    // DSD64 at 3.072 MHz: PCM at 384 kHz, carrier 192 kHz.
    (3_072_000, [44_100, 48_000, 96_000, 384_000], false),
    (3_072_000, [48_000, 96_000, 176_400], true),
    (3_072_000, [768_000, 352_800], true),
    (3_072_000, [192_000, 48_000], false),
]

private func expectPCM(_ planner: any RatePlanner, _ checker: Checker, dsd: Double, device: DSDDevice, id: String) {
    let plan = planner.planDSD(dsdRate: dsd, device: device)
    checker.expect(plan.mode == .pcm, id,
                   "planDSD(\(dsd)) on \(describe(device)) -> \(describe(plan)), expected PCM")
    checker.expect(plan.pcmRate.map { same($0, dsd / 8) } ?? false, id,
                   "planDSD(\(dsd)) on \(describe(device)) -> \(describe(plan)), expected pcmRate \(dsd / 8)")
}

private func expectDoP(_ planner: any RatePlanner, _ checker: Checker, dsd: Double, device: DSDDevice, id: String) {
    let plan = planner.planDSD(dsdRate: dsd, device: device)
    checker.expect(plan.mode == .dop, id,
                   "planDSD(\(dsd)) on \(describe(device)) -> \(describe(plan)), expected DoP")
    checker.expect(same(plan.deviceRate, dsd / 16), id,
                   "planDSD(\(dsd)) on \(describe(device)) -> \(describe(plan)), expected device rate \(dsd / 16)")
}
