//
// Vespertine — value types describing sources, devices and the chosen output plan.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What a decoded file natively is.
public struct SourceFormat: Sendable, Hashable, Codable {
    public enum Encoding: String, Sendable, Codable {
        case pcm       // integer or float PCM, lossless
        case lossy     // MP3, AAC, Vorbis, Opus …
        case dsd       // DSF / DSDIFF
    }

    public var encoding: Encoding
    public var codec: String            // "FLAC", "ALAC", "WAV" …
    /// PCM sample rate; for DSD the 1-bit rate (e.g. 2_822_400).
    public var sampleRate: Double
    /// Bits per sample for integer PCM; nil for lossy / float / DSD.
    public var bitDepth: Int?
    public var channels: Int

    public init(encoding: Encoding, codec: String, sampleRate: Double, bitDepth: Int?, channels: Int) {
        self.encoding = encoding
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
    }

    /// "DSD64", "DSD128" … for DSD sources.
    public var dsdName: String? {
        guard encoding == .dsd else { return nil }
        return "DSD\(Int((sampleRate / 44_100).rounded()))"
    }

    public var shortDescription: String {
        if let dsdName { return dsdName }
        let rate = SampleRate.format(sampleRate)
        if let bitDepth { return "\(bitDepth)/\(rate)" }
        return rate + " kHz"
    }
}

/// One physical format a device stream can be switched to.
public struct PhysicalFormat: Sendable, Hashable, Codable {
    public var minRate: Double
    public var maxRate: Double
    public var bitDepth: Int
    public var isInteger: Bool
    public var isMixable: Bool
    public var channels: Int

    public init(minRate: Double, maxRate: Double, bitDepth: Int, isInteger: Bool, isMixable: Bool, channels: Int) {
        self.minRate = minRate
        self.maxRate = maxRate
        self.bitDepth = bitDepth
        self.isInteger = isInteger
        self.isMixable = isMixable
        self.channels = channels
    }

    public func supports(rate: Double) -> Bool {
        rate >= minRate - 0.5 && rate <= maxRate + 0.5
    }
}

/// What the planner needs to know about an output device.
public struct DeviceCapabilities: Sendable, Hashable, Codable {
    /// Discrete nominal rates the device can be set to, ascending.
    public var sampleRates: [Double]
    public var physicalFormats: [PhysicalFormat]
    public var outputChannels: Int
    /// User opted in: the DAC decodes DSD-over-PCM markers.
    public var supportsDoP: Bool
    /// Channels in the device's configured speaker layout (Audio MIDI Setup → Configure Speakers),
    /// when those channels carry real speaker positions. nil when unconfigured or just numbered.
    public var speakerLayoutChannels: Int?

    public init(sampleRates: [Double], physicalFormats: [PhysicalFormat], outputChannels: Int, supportsDoP: Bool,
                speakerLayoutChannels: Int? = nil) {
        self.sampleRates = sampleRates.sorted()
        self.physicalFormats = physicalFormats
        self.outputChannels = outputChannels
        self.supportsDoP = supportsDoP
        self.speakerLayoutChannels = speakerLayoutChannels
    }

    public func supports(rate: Double) -> Bool {
        sampleRates.contains { abs($0 - rate) < 0.5 }
    }

    /// Highest integer bit depth available at `rate` (falls back to 24).
    public func bestIntegerBitDepth(at rate: Double) -> Int {
        let depths = physicalFormats.filter { $0.isInteger && $0.supports(rate: rate) }.map(\.bitDepth)
        return depths.max() ?? physicalFormats.filter { $0.supports(rate: rate) }.map(\.bitDepth).max() ?? 24
    }
}

/// How the user wants the device rate chosen.
public enum RatePolicy: Sendable, Hashable, Codable {
    /// Switch to the source rate; convert only when the device cannot.
    case matchSource
    /// Always run at one rate (e.g. 96 kHz).
    case fixed(Double)
    /// Always run at the device maximum.
    case maximum
}

/// Everything the engine will do between file and DAC.
public struct OutputPlan: Sendable, Hashable {
    /// `pcm`: decoded audio. `dop`: DSD in DoP frames. `bitstream`: Dolby/DTS frames in IEC 61937 bursts
    /// for a receiver to decode. The last two must reach the device untouched.
    public enum Mode: String, Sendable { case pcm, dop, bitstream }
    /// Passed through untouched (no gain, dither or resampling), with the device held exclusively.
    public var isPassthrough: Bool { mode != .pcm }

    public var mode: Mode
    public var deviceSampleRate: Double
    /// Rate of the PCM stream fed to the converter (DSD→PCM output rate, or the PCM source rate).
    public var decodedSampleRate: Double
    public var physicalBitDepth: Int
    public var channels: Int
    public var resamples: Bool { abs(decodedSampleRate - deviceSampleRate) > 0.5 }
    public var dsdConvertedToPCM: Bool
    public var reason: String
    /// Channels the device receives when they differ from `channels` (Spatial Audio renders to 2).
    public var deviceChannelCount: Int? = nil
    /// Multichannel rendered for headphones with Spatial Audio.
    public var spatial: SpatialMode = .off
    /// Integer mode requested: decoded straight to 32-bit integers and sent to a non-mixable Int32 device
    /// format untouched (32-bit sources exact). Only for plain PCM with nothing to change the samples.
    public var integerSamples = false

    /// Channels the decoded stream (and ring) carries: `channels`. Channels written to the device:
    public var deviceChannels: Int { deviceChannelCount ?? channels }

    /// Two plans can be joined gaplessly when the device does not need to be touched.
    public func isDeviceCompatible(with other: OutputPlan) -> Bool {
        mode == other.mode && integerSamples == other.integerSamples && abs(deviceSampleRate - other.deviceSampleRate) < 0.5
            && physicalBitDepth == other.physicalBitDepth && channels == other.channels
            && deviceChannels == other.deviceChannels && spatial == other.spatial
    }
}

public enum SampleRate {
    public static let family441: [Double] = [44_100, 88_200, 176_400, 352_800, 705_600]
    public static let family48: [Double] = [48_000, 96_000, 192_000, 384_000, 768_000]

    /// "44.1", "48", "192", "352.8"
    public static func format(_ rate: Double) -> String {
        let k = rate / 1000
        if abs(k.rounded() - k) < 0.01 { return String(Int(k.rounded())) }
        return String(format: "%.1f", k)
    }

    public static func isFamily441(_ rate: Double) -> Bool {
        let ratio = rate / 44_100
        return abs(ratio.rounded() - ratio) < 0.0001 && ratio >= 1
    }

    static func isIntegerMultiple(_ a: Double, of b: Double) -> Bool {
        guard b > 0 else { return false }
        let r = a / b
        return r >= 1 && abs(r.rounded() - r) < 0.0001
    }
}
