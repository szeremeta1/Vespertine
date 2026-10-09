//
// Vespertine verification: contracts/rate-plan.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

public enum Policy: Sendable, Hashable {
    case matchSource
    case maximum
    case fixed(rate: Double)
}

public struct DSDDevice: Sendable, Hashable {
    /// The nominal rates the device can be set to (Hz): non-empty, no duplicates, in no particular order.
    public var offeredRates: [Double]
    /// The user marked the device as decoding DoP.
    public var dopEnabled: Bool
    /// Bit depths of the integer physical formats the device offers at every one of its rates, e.g. [16, 24, 32].
    public var integerBitDepths: [Int]
    /// The device's output channel count.
    public var channels: Int

    public init(offeredRates: [Double], dopEnabled: Bool, integerBitDepths: [Int], channels: Int) {
        self.offeredRates = offeredRates
        self.dopEnabled = dopEnabled
        self.integerBitDepths = integerBitDepths
        self.channels = channels
    }
}

public struct DSDPlan: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case dop, pcm }
    public var mode: Mode
    /// The rate the device is set to: one of the offered rates.
    public var deviceRate: Double
    /// For `pcm`, the rate DSD is converted to before any further resampling; nil for `dop`.
    public var pcmRate: Double?

    public init(mode: Mode, deviceRate: Double, pcmRate: Double?) {
        self.mode = mode
        self.deviceRate = deviceRate
        self.pcmRate = pcmRate
    }
}

/// Rates are in hertz; two rates are equal when they differ by less than 0.5 Hz.
public protocol RatePlanner: Sendable {
    /// Returns one of `offeredRates`, except for `fixed(rate)` when that rate isn't offered (not specified).
    func chooseRate(sourceRate: Double, offeredRates: [Double], policy: Policy) -> Double
    /// `dsdRate` is a DSD bit rate per channel (2 822 400 for DSD64).
    func dopCarrierRate(dsdRate: Double) -> Double
    /// For a stereo DSD source.
    func planDSD(dsdRate: Double, device: DSDDevice) -> DSDPlan
}
