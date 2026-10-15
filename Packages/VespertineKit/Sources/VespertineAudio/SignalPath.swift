//
// Vespertine — a truthful description of what happens between file and DAC.
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
    /// The equalizer preset applied (its name), nil = none.
    public var equalizer: String? = nil
    /// The room correction applied (its profile's name), nil = none.
    public var roomCorrection: String? = nil
    /// Shared mode only: another app is sending sound to the same device right now, so macOS mixes it in.
    public var otherAppsPlaying = false
    /// Frames of this track the decoder played as silence because the file is damaged there (SACD images).
    public var concealedFrames = 0

    public var isResampling: Bool { plan.resamples }

    /// Gain other than exactly unity is applied somewhere in software.
    public var modifiesSamples: Bool {
        if let rg = replayGainDB, rg != 0 { return true }
        if equalizer != nil || roomCorrection != nil { return true }
        if case .digital(let db) = volume, db != 0 { return true }
        return false
    }

    /// True only when every sample reaches the DAC unaltered.
    public var isBitPerfect: Bool {
        guard deviceProfile.canBeBitPerfect, applied.physicalFormatKnown, applied.exclusive || !otherAppsPlaying, !modifiesSamples,
              plan.spatial == .off, concealedFrames == 0, plan.channels == source.channels, applied.virtualChannels >= source.channels
        else { return false }
        switch plan.mode {
        case .dop:
            return applied.physicalBitDepth >= 24 && abs(applied.sampleRate - plan.deviceSampleRate) < 0.5
        case .bitstream:
            return applied.physicalIsInteger && applied.physicalBitDepth >= 16 && abs(applied.sampleRate - plan.deviceSampleRate) < 0.5
        case .pcm:
            guard source.encoding == .pcm, !plan.dsdConvertedToPCM, !isResampling else { return false }
            guard abs(applied.sampleRate - source.sampleRate) < 0.5 else { return false }
            // The Float32 pipeline carries 24 significant bits exactly; wider sources are rounded, unless
            // integer mode sends 32-bit integers straight to the DAC.
            let bits = source.bitDepth ?? 32
            guard bits <= (applied.integerMode ? 32 : 24) else { return false }
            // Integer DACs need at least the source word length; float devices need full Float32.
            return applied.physicalIsInteger ? applied.physicalBitDepth >= bits : applied.physicalBitDepth >= 32
        }
    }

    /// One-line state for badges and the menu bar (in the current language; English without a string table).
    public var statusLine: String {
        if isBitPerfect {
            switch plan.mode {
            case .dop: return String(localized: "NATIVE DSD · DoP", comment: "Status badge (short, uppercase).")
            case .bitstream:
                let codec = (BitstreamFormat(codec: source.codec)?.name ?? source.codec).uppercased()
                return String(localized: "BITSTREAM · \(codec)", comment: "Status badge (short, uppercase), then the codec, e.g. DOLBY DIGITAL.")
            case .pcm: return String(localized: "BIT-PERFECT", comment: "Status badge (short, uppercase).")
            }
        }
        if concealedFrames > 0 { return String(localized: "DAMAGED FRAMES SILENCED", comment: "Status badge (short, uppercase).") }
        if plan.spatial != .off {
            return plan.spatial == .headTracked ? String(localized: "SPATIAL · HEAD TRACKED", comment: "Status badge (short, uppercase).") : String(localized: "SPATIAL AUDIO", comment: "Status badge (short, uppercase).")
        }
        if plan.channels < source.channels { return "\(ChannelLayouts.name(channels: source.channels)) → \(ChannelLayouts.name(channels: plan.channels).uppercased())" }
        if !deviceProfile.canBeBitPerfect && !isResampling && !plan.dsdConvertedToPCM {
            switch deviceProfile.kind {
            case .airPlay: return String(localized: "AIRPLAY", comment: "Status badge (short, uppercase).")
            case .speakers: return String(localized: "SPEAKER PROCESSING", comment: "Status badge (short, uppercase).")
            case .virtualDevice:
                return deviceProfile.tag == DeviceProfile.aggregateTag ? String(localized: "AGGREGATE DEVICE", comment: "Status badge (short, uppercase).")
                                                                       : String(localized: "VIRTUAL DEVICE", comment: "Status badge (short, uppercase).")
            default: return String(localized: "BLUETOOTH · LOSSY", comment: "Status badge (short, uppercase).")
            }
        }
        if plan.dsdConvertedToPCM { return "DSD → PCM" }
        if isResampling { return String(localized: "RESAMPLED", comment: "Status badge (short, uppercase).") }
        if source.encoding == .lossy { return String(localized: "LOSSY SOURCE", comment: "Status badge (short, uppercase).") }
        if !applied.exclusive, otherAppsPlaying { return String(localized: "MIXED WITH OTHER APPS", comment: "Status badge (short, uppercase).") }
        if roomCorrection != nil { return String(localized: "ROOM CORRECTION", comment: "Status badge (short, uppercase).") }
        if equalizer != nil { return String(localized: "EQUALIZER", comment: "Status badge (short, uppercase).") }
        if modifiesSamples { return String(localized: "DIGITAL GAIN", comment: "Status badge (short, uppercase).") }
        if !applied.physicalFormatKnown { return String(localized: "FORMAT UNCONFIRMED", comment: "Status badge (short, uppercase).") }
        return String(localized: "CONVERTED", comment: "Status badge (short, uppercase).")
    }

    /// What "Match 16-bit sources" did, from the format the device reports, not the one asked for. nil: it didn't apply.
    public var sixteenBitNote: String? {
        guard let match = plan.sixteenBit else { return nil }
        let rate = SampleRate.format(applied.sampleRate)
        let depth = applied.physicalBitDepth
        switch match {
        case .requested where depth == 16 && applied.physicalIsInteger:
            return String(localized: "16-bit source sent as 16-bit at \(rate) kHz")
        case .requested:
            return String(localized: "Asked for 16-bit at \(rate) kHz; the device stayed at \(depth)-bit (same samples, zero-padded)")
        case .noMode:
            return String(localized: "No 16-bit mode at \(rate) kHz; sent as \(depth)-bit (same samples, zero-padded)")
        }
    }

    /// "24/192" as shown on the device chip (what the DAC receives).
    public var deviceFormatShort: String {
        "\(applied.physicalBitDepth)/\(SampleRate.format(applied.sampleRate))"
    }
}
