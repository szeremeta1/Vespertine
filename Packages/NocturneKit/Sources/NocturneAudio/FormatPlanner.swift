//
// Nocturne — decides the device format for a given source.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure logic, no Core Audio calls, so every decision is unit-testable.
//

import Foundation

public enum FormatPlanner {
    /// DSD bit rate → PCM rate produced by SFBDSDPCMDecoder (one PCM frame per DSD byte).
    public static func dsdToPCMRate(_ dsdRate: Double) -> Double { dsdRate / 8 }
    /// DSD bit rate → carrier PCM rate for DSD-over-PCM (16 DSD bits per 24-bit frame).
    public static func dopCarrierRate(_ dsdRate: Double) -> Double { dsdRate / 16 }

    public static func plan(source: SourceFormat, device: DeviceCapabilities, policy: RatePolicy = .matchSource) -> OutputPlan {
        let channels = max(1, min(source.channels, max(device.outputChannels, 1)))

        // DSD: native DoP when the user has confirmed the DAC understands it and the carrier rate exists.
        if source.encoding == .dsd {
            let carrier = dopCarrierRate(source.sampleRate)
            if device.supportsDoP, device.supports(rate: carrier), device.bestIntegerBitDepth(at: carrier) >= 24 {
                return OutputPlan(mode: .dop, deviceSampleRate: carrier, decodedSampleRate: carrier,
                                  physicalBitDepth: device.bestIntegerBitDepth(at: carrier), channels: channels,
                                  dsdConvertedToPCM: false,
                                  reason: "\(source.dsdName ?? "DSD") sent natively as DoP at \(SampleRate.format(carrier)) kHz")
            }
            let pcmRate = dsdToPCMRate(source.sampleRate)
            let rate = chooseRate(for: pcmRate, device: device, policy: policy)
            let why = device.supportsDoP
                ? "DoP needs \(SampleRate.format(carrier)) kHz, which this device can't do; converted to PCM"
                : "Device is PCM-only (DoP off); DSD converted to PCM"
            return OutputPlan(mode: .pcm, deviceSampleRate: rate, decodedSampleRate: pcmRate,
                              physicalBitDepth: device.bestIntegerBitDepth(at: rate), channels: channels,
                              dsdConvertedToPCM: true, reason: why)
        }

        let rate = chooseRate(for: source.sampleRate, device: device, policy: policy)
        let reason: String
        if abs(rate - source.sampleRate) < 0.5 {
            reason = "Device switched to match source (\(SampleRate.format(rate)) kHz)"
        } else {
            switch policy {
            case .matchSource:
                reason = "Device can't run at \(SampleRate.format(source.sampleRate)) kHz; converted to \(SampleRate.format(rate)) kHz"
            case .fixed(let fixed):
                reason = "Fixed output rate \(SampleRate.format(fixed)) kHz"
            case .maximum:
                reason = "Upsampled to device maximum \(SampleRate.format(rate)) kHz"
            }
        }
        return OutputPlan(mode: .pcm, deviceSampleRate: rate, decodedSampleRate: source.sampleRate,
                          physicalBitDepth: device.bestIntegerBitDepth(at: rate), channels: channels,
                          dsdConvertedToPCM: false, reason: reason)
    }

    /// Picks the device rate for a PCM stream at `rate`.
    ///
    /// Order of preference when the exact rate is unavailable:
    ///  1. the smallest integer multiple of the source rate (same family: 44.1 → 88.2)
    ///  2. the smallest rate above the source
    ///  3. the largest integer divisor of the source (384 → 192)
    ///  4. the highest rate the device offers
    public static func chooseRate(for rate: Double, device: DeviceCapabilities, policy: RatePolicy) -> Double {
        let rates = device.sampleRates
        guard !rates.isEmpty else { return rate }

        switch policy {
        case .maximum:
            return rates.last!
        case .fixed(let fixed):
            if device.supports(rate: fixed) { return fixed }
        case .matchSource:
            break
        }

        if device.supports(rate: rate) { return rate }
        if let multiple = rates.first(where: { SampleRate.isIntegerMultiple($0, of: rate) }) { return multiple }
        if let above = rates.first(where: { $0 > rate }) { return above }
        if let divisor = rates.last(where: { SampleRate.isIntegerMultiple(rate, of: $0) }) { return divisor }
        return rates.last!
    }
}
