import Contracts

/// Two rates are equal when they differ by less than 0.5 Hz.
private func sameRate(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < 0.5
}

/// `x` rounded to the nearest whole number (as a Double), or nil when `x` is not a finite, sensible
/// positive ratio. Written without libm so the module links with the standard library alone.
private func nearestInteger(_ x: Double) -> Double? {
    guard x.isFinite, x >= 0, x < 1e15 else { return nil }
    return Double(Int(x + 0.5))
}

private struct B2RatePlanner: RatePlanner {
    func chooseRate(sourceRate: Double, offeredRates: [Double], policy: Policy) -> Double {
        // The contract rules out an empty list; answer something harmless instead of trapping.
        guard let first = offeredRates.first else { return sourceRate }

        switch policy {
        case .maximum:
            return highest(of: offeredRates, startingWith: first)

        case .fixed(let rate):
            if let match = closest(to: rate, in: offeredRates), sameRate(match, rate) {
                return match
            }
            // Not specified by the contract: hand the forced rate back unchanged.
            return rate

        case .matchSource:
            return matchSource(sourceRate: sourceRate, offeredRates: offeredRates, first: first)
        }
    }

    func dopCarrierRate(dsdRate: Double) -> Double {
        dsdRate / 16
    }

    func planDSD(dsdRate: Double, device: DSDDevice) -> DSDPlan {
        let carrier = dopCarrierRate(dsdRate: dsdRate)
        if device.dopEnabled,
           let offered = closest(to: carrier, in: device.offeredRates),
           sameRate(offered, carrier) {
            return DSDPlan(mode: .dop, deviceRate: offered, pcmRate: nil)
        }
        let pcmRate = dsdRate / 8
        let deviceRate = chooseRate(sourceRate: pcmRate, offeredRates: device.offeredRates, policy: .matchSource)
        return DSDPlan(mode: .pcm, deviceRate: deviceRate, pcmRate: pcmRate)
    }

    // MARK: - Helpers

    private func highest(of rates: [Double], startingWith first: Double) -> Double {
        var best = first
        for rate in rates where rate > best {
            best = rate
        }
        return best
    }

    /// The element of `rates` nearest to `target`, or nil if there is none.
    private func closest(to target: Double, in rates: [Double]) -> Double? {
        var best: Double?
        var bestDistance = Double.infinity
        for rate in rates {
            let distance = abs(rate - target)
            if best == nil || distance < bestDistance {
                best = rate
                bestDistance = distance
            }
        }
        return best
    }

    private func matchSource(sourceRate: Double, offeredRates: [Double], first: Double) -> Double {
        // 1. The source rate itself.
        if let match = closest(to: sourceRate, in: offeredRates), sameRate(match, sourceRate) {
            return match
        }

        // 2. An integer multiple of the source rate (smallest one offered).
        var multiple: Double?
        for rate in offeredRates {
            guard let k = nearestInteger(rate / sourceRate), k >= 2,
                  sameRate(rate, k * sourceRate) else { continue }
            if multiple == nil || rate < multiple! {
                multiple = rate
            }
        }
        if let multiple { return multiple }

        // 3. Any higher rate (smallest one offered).
        var higher: Double?
        for rate in offeredRates where rate - sourceRate >= 0.5 {
            if higher == nil || rate < higher! {
                higher = rate
            }
        }
        if let higher { return higher }

        // 4. Every offered rate is lower: an integer divisor of the source rate (largest one offered).
        var divisor: Double?
        for rate in offeredRates {
            guard let k = nearestInteger(sourceRate / rate), k >= 2,
                  sameRate(rate, sourceRate / k) else { continue }
            if divisor == nil || rate > divisor! {
                divisor = rate
            }
        }
        if let divisor { return divisor }

        // Not specified by the contract: fall back to the highest offered rate.
        return highest(of: offeredRates, startingWith: first)
    }
}

public enum B2Rate {
    public static let subject: (any RatePlanner)? = B2RatePlanner()
}
