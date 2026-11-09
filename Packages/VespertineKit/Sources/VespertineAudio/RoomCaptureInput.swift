//
// Vespertine: what rate and sample format to record a measurement microphone in. The microphone has its own limits
// (a UMIK-1 runs at 48 kHz, some units at 44.1 kHz) and the output has its own (a DAC at 176.4 kHz), so the input is
// never asked to follow the output: it records at a rate it supports and the measurement runs at that rate.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

/// How samples sit in a buffer the input's IOProc is handed. The real-time capture converts each to Float32.
public enum CaptureSampleKind: Int32, Sendable, Equatable {
    case float32 = 0, float64, int16, int24, int32
}

/// One stream format as Core Audio describes it (a stream's virtual format, or one of its available formats).
public struct CaptureStreamFormat: Equatable, Sendable {
    public var rateMin: Double
    public var rateMax: Double
    public var channels: Int
    public var isLinearPCM = true
    public var isFloat: Bool
    /// Bits in each sample's container (32 for Float32 and for 24-bit audio held in four bytes).
    public var bits: Int
    public var interleaved = true
    public var bigEndian = false
    /// Whether a sample narrower than its container is aligned to the top of it (Core Audio's usual).
    public var alignedHigh = true
    /// Bits actually used, when narrower than the container and packed into it.
    public var packed = true

    public init(rate: Double, channels: Int, isFloat: Bool, bits: Int, interleaved: Bool = true, bigEndian: Bool = false,
                alignedHigh: Bool = true, packed: Bool = true, isLinearPCM: Bool = true) {
        self.init(rateMin: rate, rateMax: rate, channels: channels, isFloat: isFloat, bits: bits, interleaved: interleaved,
                  bigEndian: bigEndian, alignedHigh: alignedHigh, packed: packed, isLinearPCM: isLinearPCM)
    }

    public init(rateMin: Double, rateMax: Double, channels: Int, isFloat: Bool, bits: Int, interleaved: Bool = true,
                bigEndian: Bool = false, alignedHigh: Bool = true, packed: Bool = true, isLinearPCM: Bool = true) {
        self.rateMin = rateMin
        self.rateMax = rateMax
        self.channels = channels
        self.isFloat = isFloat
        self.bits = bits
        self.interleaved = interleaved
        self.bigEndian = bigEndian
        self.alignedHigh = alignedHigh
        self.packed = packed
        self.isLinearPCM = isLinearPCM
    }

    public init(_ d: AudioStreamBasicDescription, rateMax: Double? = nil) {
        let flags = d.mFormatFlags
        self.init(rateMin: d.mSampleRate, rateMax: rateMax ?? d.mSampleRate, channels: Int(d.mChannelsPerFrame),
                  isFloat: flags & kAudioFormatFlagIsFloat != 0, bits: Int(d.mBitsPerChannel),
                  interleaved: flags & kAudioFormatFlagIsNonInterleaved == 0, bigEndian: flags & kAudioFormatFlagIsBigEndian != 0,
                  alignedHigh: flags & kAudioFormatFlagIsAlignedHigh != 0, packed: flags & kAudioFormatFlagIsPacked != 0,
                  isLinearPCM: d.mFormatID == kAudioFormatLinearPCM)
        // A float or a signed integer: unsigned integer audio doesn't occur in Core Audio's streams.
        if flags & kAudioFormatFlagIsFloat == 0, flags & kAudioFormatFlagIsSignedInteger == 0 { isLinearPCM = false }
    }

    public func supports(rate: Double) -> Bool { rate >= rateMin - 0.5 && rate <= rateMax + 0.5 }

    /// How the capture reads this format, nil when it can't (not linear PCM, byte-swapped, or in an arrangement the
    /// conversion doesn't know).
    public var sampleKind: CaptureSampleKind? {
        guard isLinearPCM, !bigEndian, channels > 0 else { return nil }
        if isFloat { return bits == 32 ? .float32 : bits == 64 ? .float64 : nil }
        switch bits {
        case 16: return .int16
        case 24: return packed ? .int24 : nil
        case 32: return alignedHigh ? .int32 : nil
        default: return nil
        }
    }

    public var isFloat32: Bool { sampleKind == .float32 }

    /// Lower is better: Float32 needs no conversion, then the widest integer.
    var preference: Int {
        switch sampleKind {
        case .float32?: 0
        case .int32?: 1
        case .int24?: 2
        case .float64?: 3
        case .int16?: 4
        case nil: 99
        }
    }
}

/// What the microphone offers: its rates and, for each stream, the format it is in and the ones it can be put in.
public struct CaptureInputDescription: Equatable, Sendable {
    public struct Stream: Equatable, Sendable {
        public var current: CaptureStreamFormat
        public var available: [CaptureStreamFormat]
        public init(current: CaptureStreamFormat, available: [CaptureStreamFormat]) {
            self.current = current
            self.available = available
        }
    }

    public var name: String
    public var nominalRate: Double
    /// The device's nominal rates (Core Audio's available list, ranges already expanded).
    public var supportedRates: [Double]
    public var streams: [Stream]
    /// The microphone is the output device too (an interface with both): its rate is the output's and can't move.
    public var sharesDeviceWithOutput: Bool

    public init(name: String, nominalRate: Double, supportedRates: [Double], streams: [Stream], sharesDeviceWithOutput: Bool = false) {
        self.name = name
        self.nominalRate = nominalRate
        self.supportedRates = supportedRates
        self.streams = streams
        self.sharesDeviceWithOutput = sharesDeviceWithOutput
    }
}

/// A hardware problem that reads as a sentence (no Core Audio code behind it).
public struct RoomHardwareError: Error, LocalizedError, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public enum CaptureInputError: Error, Equatable, LocalizedError {
    case noStreams(String)
    /// The input has no rate the measurement can use (it needs room for a 20 kHz sweep).
    case noUsableRate(String, offered: [Double])
    /// The input's rate is fixed (it is the output too), and its streams can't be read at it.
    case noUsableFormat(String, rate: Double)

    public var errorDescription: String? {
        switch self {
        case .noStreams(let name): String(localized: "\(name) has no input to record from.")
        case .noUsableRate(let name, let offered):
            String(localized: "\(name) offers no sample rate the measurement can record at (it needs 44.1 kHz or more; the input offers \(Self.list(offered))).")
        case .noUsableFormat(let name, let rate):
            String(localized: "\(name) can't be recorded at \(SampleRate.format(rate)) kHz: none of its sample formats is one Vespertine can read (linear PCM, 16 to 32 bits, or Float32/Float64).")
        }
    }

    private static func list(_ rates: [Double]) -> String {
        rates.isEmpty ? String(localized: "none") : rates.map { SampleRate.format($0) + " kHz" }.joined(separator: ", ")
    }
}

/// How a microphone is set up for a recording.
public struct CaptureInputPlan: Equatable, Sendable {
    /// The rate the input records at, and so the rate the measurement runs at.
    public var captureRate: Double
    /// The input device's rate must be set to `captureRate` first (false when it is there already).
    public var changesNominalRate: Bool
    /// Streams (by index) whose format has to be set before recording, and to what. Empty when each is readable as it is.
    public var streamChanges: [Int: CaptureStreamFormat]
    /// How each stream's samples are read once recording.
    public var kinds: [CaptureSampleKind]
}

public enum CaptureInputPlanner {
    /// Rates the measurement may run at: the sweep goes to 20 kHz, and a rate past 96 kHz only makes files longer.
    public static let usableRates: ClosedRange<Double> = 44_100...96_000

    /// The rate to record at, in order of preference: the one the microphone is at when it is already 44.1 or 48 kHz,
    /// then the output's family (44.1 kHz for 44.1, 88.2, 176.4 kHz so the stimulus converts by a whole number),
    /// 48 kHz, 44.1 kHz, 96 kHz, 88.2 kHz and finally the nearest to 48 kHz.
    static func candidates(supported: [Double], nominal: Double, outputRate: Double) -> [Double] {
        let usable = supported.filter { usableRates.contains($0) }
        var order: [Double] = []
        func add(_ r: Double) { if usable.contains(where: { abs($0 - r) < 0.5 }) && !order.contains(where: { abs($0 - r) < 0.5 }) { order.append(r) } }
        if abs(nominal - 48_000) < 0.5 || abs(nominal - 44_100) < 0.5 { add(nominal) }
        let ofOutput441 = (outputRate / 44_100).rounded() * 44_100
        let exact441 = abs(outputRate - ofOutput441) < 0.5 && ofOutput441 > 0
        let exact48 = abs(outputRate / 48_000 - (outputRate / 48_000).rounded()) < 1e-9
        if exact441 && !exact48 { add(44_100) }
        for r in [48_000.0, 44_100, 96_000, 88_200] { add(r) }
        for r in usable.sorted(by: { abs($0 - 48_000) < abs($1 - 48_000) }) { add(r) }
        return order
    }

    public static func plan(_ input: CaptureInputDescription, outputRate: Double) throws -> CaptureInputPlan {
        guard !input.streams.isEmpty else { throw CaptureInputError.noStreams(input.name) }
        // An input that is also the output keeps the rate it has: moving it would change the listener's setup.
        let rates = input.sharesDeviceWithOutput ? [input.nominalRate] : input.supportedRates
        let candidates = input.sharesDeviceWithOutput ? [input.nominalRate] : Self.candidates(supported: rates, nominal: input.nominalRate, outputRate: outputRate)
        guard !candidates.isEmpty else { throw CaptureInputError.noUsableRate(input.name, offered: input.supportedRates) }
        var lastFormatFailure: Double?
        for rate in candidates {
            if let plan = Self.plan(input, at: rate) { return plan }
            lastFormatFailure = rate
        }
        throw CaptureInputError.noUsableFormat(input.name, rate: lastFormatFailure ?? candidates[0])
    }

    /// Each stream at `rate`: left as it is when it is already readable there, otherwise the best available format.
    private static func plan(_ input: CaptureInputDescription, at rate: Double) -> CaptureInputPlan? {
        var changes: [Int: CaptureStreamFormat] = [:]
        var kinds: [CaptureSampleKind] = []
        for (i, stream) in input.streams.enumerated() {
            let atRate = stream.available.filter { $0.supports(rate: rate) && $0.channels == stream.current.channels && $0.sampleKind != nil }
            let best = atRate.min { $0.preference < $1.preference }
            let current = stream.current
            // Readable as it is: a format the capture knows, already at this rate (or with no list of others to go by,
            // when the stream follows the device's rate on its own).
            let readableNow = current.sampleKind != nil && (current.supports(rate: rate) || stream.available.isEmpty)
            // Float32 is read without conversion, so it is worth changing to when the stream isn't on it already.
            if let best, best.isFloat32, !(current.isFloat32 && current.supports(rate: rate)) {
                changes[i] = best
                kinds.append(.float32)
            } else if readableNow {
                kinds.append(current.sampleKind!)
            } else if let best {
                changes[i] = best
                kinds.append(best.sampleKind!)
            } else {
                return nil
            }
        }
        return CaptureInputPlan(captureRate: rate, changesNominalRate: abs(input.nominalRate - rate) > 0.5, streamChanges: changes, kinds: kinds)
    }
}

// MARK: - Stimulus at the output's rate

public enum RoomStimulusRate {
    /// `samples`, made for a measurement at `from`, converted to the `to` the output runs at, with the same length in
    /// seconds and the same level. Nil when the converter fails. Done before playback starts, never on the I/O thread.
    public static func convert(_ samples: [Float], from: Double, to: Double) -> [Float]? {
        guard abs(from - to) >= 0.5 else { return samples }
        guard !samples.isEmpty, let converted = RoomImpulse.resample(samples, from: from, to: to) else { return samples.isEmpty ? [] : nil }
        // `resample` keeps an impulse response's gain, which scales a signal by from / to: take that back out.
        let gain = Float(to / from)
        let expected = Int((Double(samples.count) * to / from).rounded())
        var out = converted.map { $0 * gain }
        if out.count > expected { out.removeLast(out.count - expected) }
        if out.count < expected { out.append(contentsOf: [Float](repeating: 0, count: expected - out.count)) }
        return out
    }
}
