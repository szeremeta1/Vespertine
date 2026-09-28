//
// Nocturne — a truthful description of what happens between file and DAC.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct SignalPath: Sendable, Hashable {
    public enum VolumeStage: Sendable, Hashable {
        case hardware          // DAC's own control; samples untouched
        case digital(dB: Double)
        case fixed             // no volume control; samples untouched
    }

    public var source: SourceFormat
    public var decoderName: String
    public var plan: OutputPlan
    public var applied: AppliedFormat
    public var deviceName: String
    public var deviceUID: String
    public var deviceProfile: DeviceProfile
    public var volume: VolumeStage
    public var replayGainDB: Double?

    public var isResampling: Bool { plan.resamples }

    /// Gain other than exactly unity is applied somewhere in software.
    public var modifiesSamples: Bool {
        if let rg = replayGainDB, rg != 0 { return true }
        if case .digital(let db) = volume, db != 0 { return true }
        return false
    }

    /// True only when every sample reaches the DAC unaltered.
    public var isBitPerfect: Bool {
        guard deviceProfile.canBeBitPerfect, applied.exclusive, !modifiesSamples, plan.spatial == .off,
              plan.channels == source.channels, applied.virtualChannels >= source.channels else { return false }
        switch plan.mode {
        case .dop:
            return applied.physicalBitDepth >= 24 && abs(applied.sampleRate - plan.deviceSampleRate) < 0.5
        case .pcm:
            guard source.encoding == .pcm, !plan.dsdConvertedToPCM, !isResampling else { return false }
            guard abs(applied.sampleRate - source.sampleRate) < 0.5 else { return false }
            // Our pipeline is Float32, which carries 24 significant bits exactly; wider sources are rounded.
            let bits = source.bitDepth ?? 32
            guard bits <= 24 else { return false }
            // Integer DACs need at least the source word length; float devices need full Float32.
            return applied.physicalIsInteger ? applied.physicalBitDepth >= bits : applied.physicalBitDepth >= 32
        }
    }

    /// One-line state for badges and the menu bar.
    public var statusLine: String {
        if isBitPerfect { return plan.mode == .dop ? "NATIVE DSD · DoP" : "BIT-PERFECT" }
        if plan.spatial != .off { return plan.spatial == .headTracked ? "SPATIAL · HEAD TRACKED" : "SPATIAL AUDIO" }
        if plan.channels < source.channels { return "\(ChannelLayouts.name(channels: source.channels)) → \(ChannelLayouts.name(channels: plan.channels).uppercased())" }
        if !deviceProfile.canBeBitPerfect && !isResampling && !plan.dsdConvertedToPCM {
            return deviceProfile.kind == .airPlay ? "AIRPLAY" : "BLUETOOTH · LOSSY"
        }
        if plan.dsdConvertedToPCM { return "DSD → PCM" }
        if isResampling { return "RESAMPLED" }
        if source.encoding == .lossy { return "LOSSY SOURCE" }
        if !applied.exclusive { return "SHARED" }
        if modifiesSamples { return "DIGITAL GAIN" }
        return "CONVERTED"
    }

    /// "24/192" as shown on the device chip (what the DAC receives).
    public var deviceFormatShort: String {
        "\(applied.physicalBitDepth)/\(SampleRate.format(applied.sampleRate))"
    }
}
