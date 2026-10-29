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
    /// The preset chosen for this output that can't be applied to this stream (DoP, bitstream), by name; nil = none chosen.
    public var bypassedEqualizer: String? = nil
    /// The room correction profile applied (its name), nil = none.
    public var roomCorrection: String? = nil
    /// The room correction chosen for this output that doesn't apply to this stream (DoP, bitstream, not two
    /// channels), by name; nil = none chosen.
    public var bypassedRoomCorrection: String? = nil
    /// Shared mode only: another app is sending sound to the same device right now, so macOS mixes it in.
    public var otherAppsPlaying = false
    /// Frames of this track the decoder played as silence because the file is damaged there (SACD images).
    public var concealedFrames = 0

    public var isResampling: Bool { plan.resamples }

    /// Why an equalizer wouldn't apply to this stream: it reaches the device untouched. nil: PCM Vespertine renders.
    public var equalizerBypass: EqualizerStatus.Bypass? {
        switch plan.mode {
        case .pcm: nil
        case .dop: .dopBypass
        case .bitstream: .bitstreamBypass
        }
    }

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
        if plan.channels < source.channels { return downmixNotice(from: ChannelLayouts.name(channels: source.channels), channels: plan.channels) }
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
        if plan.dsdConvertedToPCM { return Self.convertedFromDSD }
        if isResampling { return String(localized: "RESAMPLED", comment: "Status badge (short, uppercase).") }
        if source.encoding == .lossy { return String(localized: "LOSSY SOURCE", comment: "Status badge (short, uppercase).") }
        if !applied.exclusive, otherAppsPlaying { return String(localized: "MIXED WITH OTHER APPS", comment: "Status badge (short, uppercase).") }
        if roomCorrection != nil { return String(localized: "ROOM CORRECTION", comment: "Status badge (short, uppercase).") }
        if equalizer != nil { return String(localized: "EQUALIZER", comment: "Status badge (short, uppercase).") }
        if modifiesSamples { return String(localized: "DIGITAL GAIN", comment: "Status badge (short, uppercase).") }
        if !applied.physicalFormatKnown { return String(localized: "FORMAT UNCONFIRMED", comment: "Status badge (short, uppercase).") }
        return String(localized: "CONVERTED", comment: "Status badge (short, uppercase).")
    }

    /// The notice for DSD played as PCM. "DSD" stays untranslated.
    static var convertedFromDSD: String { String(localized: "Converted from DSD", comment: "Notice (badge, menu-bar line): the DSD music was converted to PCM for this output. DSD stays untranslated.") }

    /// The notice for channels mixed down: "Downmixed to stereo", or "5.1 → MONO" for the rare mono output.
    private func downmixNotice(from: String, channels: Int) -> String {
        channels == 2 ? String(localized: "Downmixed to stereo", comment: "Notice (badge, menu-bar line): a surround track's channels were mixed down to two.")
                      : "\(from) → \(ChannelLayouts.name(channels: channels).uppercased())"
    }

    /// A source's channels mixed into fewer ("5.1" → "Stereo").
    public struct Downmix: Sendable, Hashable {
        public var from: String
        public var to: String
    }

    /// What was done to the music on the way that the listener is told about whatever the status badge shows
    /// (Spatial Audio, Bluetooth, a downmix): DSD converted to PCM, channels mixed down.
    public struct Conversion: Sendable, Hashable {
        public var dsdToPCM: Bool
        /// nil: every channel is heard on its own (Spatial Audio renders each one as a virtual speaker).
        public var downmix: Downmix?
    }

    /// nil: neither happened.
    public var conversion: Conversion? {
        let downmix = plan.mode == .pcm && plan.spatial == .off && plan.channels < source.channels
            ? Downmix(from: ChannelLayouts.name(labels: source.channelLabels, channels: source.channels), to: ChannelLayouts.name(channels: plan.channels))
            : nil
        guard plan.dsdConvertedToPCM || downmix != nil else { return nil }
        return Conversion(dsdToPCM: plan.dsdConvertedToPCM, downmix: downmix)
    }

    /// The parts of `conversion` that `statusLine` doesn't already say, as short notices ("Converted from DSD", "Downmixed to stereo").
    public var conversionBadges: [String] {
        guard let conversion else { return [] }
        var badges: [String] = []
        if conversion.dsdToPCM, statusLine != Self.convertedFromDSD { badges.append(Self.convertedFromDSD) }
        // The status line says a downmix itself, unless damaged frames take its place.
        if let mix = conversion.downmix, concealedFrames > 0 { badges.append(downmixNotice(from: mix.from, channels: plan.channels)) }
        return badges
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
