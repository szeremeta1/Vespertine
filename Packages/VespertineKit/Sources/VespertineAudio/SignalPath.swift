//
// Vespertine: a truthful description of what happens between file and DAC.
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
    /// The room correction chosen for this output that doesn't apply to this stream (native DSD kept, bitstream,
    /// channels that don't match its speakers), by name; nil = none chosen.
    public var bypassedRoomCorrection: String? = nil
    /// A speaker's measured room correction filter is too long for this sample rate, so it's left out.
    public var roomFiltersSkipped = false
    /// For a speaker group: the DACs that carry some of the song and are resampled to follow the clock leader.
    public var resampledMembers: [String] = []
    /// A speaker group's own account of the song: which DACs carry it and what reaches each one. When set it decides the badge
    /// (`GroupSignalPath`), and a room correction that only delays in whole frames does not count as changing the samples.
    public var group: GroupSignalPath? = nil
    /// Shared mode only: another app is sending sound to the same device right now, so macOS mixes it in.
    public var otherAppsPlaying = false
    /// Frames of this track the decoder played as silence because the file is damaged there (SACD images).
    public var concealedFrames = 0
    /// Song transitions, while their master switch is on; nil while it's off.
    public var transition: TransitionStage? = nil
    /// The fader for play, pause, stop, skip and seek is ramping the samples right now (never for words it doesn't scale:
    /// DSD, bitstream, integer, matched 16-bit). While it does, the samples are no longer the file's.
    public var faderRamping = false
    /// A network renderer (UPnP AV / OpenHome) plays the song: what Vespertine sent it. When set it decides the badge, and the
    /// path is never `isBitPerfect` (that is a claim about what the DAC receives, which can't be read back from a renderer).
    public var renderer: RendererStage? = nil

    /// What Vespertine sends a network renderer.
    public struct RendererStage: Sendable, Hashable {
        /// What changed the samples before they were encoded (none: the original file's bytes were sent).
        public enum Processing: String, Sendable, Hashable, CaseIterable {
            // In the order the badge names them.
            case roomCorrection, equalizer, volume, replayGain, format
        }

        public var name: String
        /// "OpenHome" or "UPnP AV".
        public var protocolName: String
        public var processing: [Processing]
        /// The codec of the stream sent: the file's own when passed through, FLAC when processed.
        public var sentCodec: String
        public var sentSampleRate: Double
        public var sentBitDepth: Int?
        public var sentChannels: Int
        /// The renderer joins songs itself (OpenHome, AV with SetNextAVTransportURI).
        public var gapless: Bool
        /// What the renderer said it can play and this song goes beyond.
        public var warnings: [String]

        public init(name: String, protocolName: String, processing: [Processing], sentCodec: String, sentSampleRate: Double,
                    sentBitDepth: Int?, sentChannels: Int, gapless: Bool, warnings: [String] = []) {
            self.name = name
            self.protocolName = protocolName
            self.processing = processing
            self.sentCodec = sentCodec
            self.sentSampleRate = sentSampleRate
            self.sentBitDepth = sentBitDepth
            self.sentChannels = sentChannels
            self.gapless = gapless
            self.warnings = warnings
        }

        public var passesThrough: Bool { processing.isEmpty }

        /// The badge: what was sent, never a claim about the renderer's DAC.
        public func badge(source: SourceFormat) -> String {
            if let first = Processing.allCases.first(where: processing.contains) {
                return switch first {
                case .roomCorrection: String(localized: "PROCESSED · ROOM CORRECTION", comment: "Status badge (short, uppercase): a network renderer gets Vespertine's room-corrected stream.")
                case .equalizer: String(localized: "PROCESSED · EQ", comment: "Status badge (short, uppercase): a network renderer gets Vespertine's equalized stream.")
                case .volume: String(localized: "PROCESSED · VOLUME", comment: "Status badge (short, uppercase): a network renderer gets a stream with Vespertine's digital volume.")
                case .replayGain: String(localized: "PROCESSED · REPLAYGAIN", comment: "Status badge (short, uppercase): a network renderer gets a stream with ReplayGain applied.")
                case .format: String(localized: "PROCESSED · FLAC", comment: "Status badge (short, uppercase): the file was decoded and sent to a network renderer as FLAC (it doesn't take the file's own format).")
                }
            }
            switch source.encoding {
            case .lossy: return String(localized: "LOSSY SOURCE · SENT AS IS", comment: "Status badge (short, uppercase): a lossy file's own bytes were sent to a network renderer.")
            case .dsd: return String(localized: "NATIVE DSD · \(source.dsdName ?? "DSD") SENT", comment: "Status badge (short, uppercase): a DSD file's own bytes were sent to a network renderer; %@ is DSD64 etc.")
            case .pcm:
                let format = sentBitDepth.map { "\($0)/\(SampleRate.format(sentSampleRate))" } ?? SampleRate.format(sentSampleRate)
                return String(localized: "BIT-PERFECT · \(format) SENT", comment: "Status badge (short, uppercase): the file's own bytes were sent to a network renderer unchanged; %@ is e.g. 24/192. It says what was sent, not what the renderer's DAC received.")
            }
        }
    }

    /// The path of a song sent to a network renderer. The plan and "applied" format describe the stream sent.
    public static func renderer(_ stage: RendererStage, source: SourceFormat, decoderName: String, volume: VolumeStage,
                                replayGainDB: Double? = nil, equalizer: String? = nil, roomCorrection: String? = nil) -> SignalPath {
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: stage.sentSampleRate, decodedSampleRate: stage.sentSampleRate,
                              physicalBitDepth: stage.sentBitDepth ?? 0, channels: stage.sentChannels, dsdConvertedToPCM: false,
                              reason: "network renderer")
        let applied = AppliedFormat(sampleRate: stage.sentSampleRate, physicalBitDepth: stage.sentBitDepth ?? 0, physicalIsInteger: true,
                                    virtualChannels: stage.sentChannels, exclusive: false, bufferFrames: 0, physicalFormatKnown: false)
        var path = SignalPath(source: source, decoderName: decoderName, plan: plan, applied: applied, deviceName: stage.name,
                              deviceUID: "", deviceProfile: .networkRenderer(protocolName: stage.protocolName), volume: volume,
                              replayGainDB: replayGainDB, equalizer: equalizer, roomCorrection: roomCorrection)
        path.renderer = stage
        return path
    }

    /// The samples Vespertine produced are the file's: bit-perfect at the device, or the original bytes of a lossless or DSD file
    /// sent to a network renderer. The interface's brass styling follows this; the BIT-PERFECT claim itself is `isBitPerfect`.
    public var isUntouched: Bool {
        if let renderer { return renderer.passesThrough && source.encoding != .lossy }
        return isBitPerfect
    }

    /// Song transitions in the signal path: what the next boundary does, and whether a crossfade is heard right now.
    public struct TransitionStage: Sendable, Hashable {
        public var style: TransitionStyle
        /// The boundary after this song, once known.
        public var next: TransitionDecision?
        /// A crossfade or a dip's fade is being heard (held a moment longer so the badge doesn't flicker). Only then are
        /// the samples changed; before and after, the song plays as it would with transitions off.
        public var audible = false
        /// "Transitions first": integer mode and Match 16-bit aren't used, DSD plays as PCM, and a song at another rate
        /// may be resampled to blend.
        public var transitionsFirst = false

        public init(style: TransitionStyle, next: TransitionDecision? = nil, audible: Bool = false, transitionsFirst: Bool = false) {
            self.style = style
            self.next = next
            self.audible = audible
            self.transitionsFirst = transitionsFirst
        }

        /// What "transitions first" changes, for the signal path; nil with bit-perfect first.
        public var policyNote: String? {
            transitionsFirst ? String(localized: "Transitions first: no integer or 16-bit output, DSD as PCM, the next song resampled if it must be to blend", comment: "Signal path, transitions row: what the “Transitions first” choice changes while transitions are on.") : nil
        }

        /// The badge while it's audible: CROSSFADE for a crossfade, MIXING for Smart Mix and Live Set.
        public var badge: String {
            style == .crossfade ? String(localized: "CROSSFADE", comment: "Status badge (short, uppercase): two songs are crossfading right now.")
                                : String(localized: "MIXING", comment: "Status badge (short, uppercase): Smart Mix or Live Set is blending two songs right now.")
        }
    }

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
        if equalizer != nil { return true }
        if roomCorrection != nil, group?.stage != .integerDelay { return true }
        if case .digital(let db) = volume, db != 0 { return true }
        return false
    }

    /// True only when every sample reaches the DAC unaltered.
    public var isBitPerfect: Bool {
        if renderer != nil { return false }
        if let group { return groupIsBitPerfect(group) }
        guard transition?.audible != true, !faderRamping, foldedOnto == nil, deviceProfile.canBeBitPerfect, applied.physicalFormatKnown, applied.exclusive || !otherAppsPlaying, !modifiesSamples,
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

    /// A speaker group: bit-perfect only when the group says so (the DACs that play the song are untouched, nothing but timing
    /// is done to the samples) and nothing else changes them (a transition, the fader, damaged frames, Spatial Audio, another app).
    private func groupIsBitPerfect(_ group: GroupSignalPath) -> Bool {
        group.isBitPerfect && transition?.audible != true && !faderRamping && concealedFrames == 0 && plan.mode == .pcm
            && plan.spatial == .off && (applied.exclusive || !otherAppsPlaying) && !modifiesSamples
    }

    /// One-line state for badges and the menu bar (in the current language; English without a string table).
    public var statusLine: String {
        if let renderer { return renderer.badge(source: source) }
        if let transition, transition.audible { return transition.badge }
        if let group {
            if isBitPerfect { return String(localized: "BIT-PERFECT", comment: "Status badge (short, uppercase).") }
            if concealedFrames > 0 { return String(localized: "DAMAGED FRAMES SILENCED", comment: "Status badge (short, uppercase).") }
            if faderRamping || modifiesSamples, group.stage == .none { return String(localized: "DIGITAL GAIN", comment: "Status badge (short, uppercase).") }
            return group.badges.first { $0 != "BIT-PERFECT" && $0 != "SPEAKER GROUP" } ?? "SPEAKER GROUP"
        }
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
        if let onto = foldedOnto { return foldNotice(onto: onto) }
        if isBluetoothCallMode { return String(localized: "BLUETOOTH · CALL MODE", comment: "Status badge (short, uppercase): a Bluetooth headset is in its hands-free call mode, so music plays at phone quality.") }
        // A bitstream's two channels are IEC 61937 frames that carry all of the source's: nothing is mixed down.
        if plan.mode == .pcm, plan.channels < source.channels { return downmixNotice(from: ChannelLayouts.name(channels: source.channels), channels: plan.channels) }
        if !deviceProfile.canBeBitPerfect && !isResampling && !plan.dsdConvertedToPCM {
            switch deviceProfile.kind {
            case .airPlay: return String(localized: "AIRPLAY", comment: "Status badge (short, uppercase).")
            case .speakers: return String(localized: "SPEAKER PROCESSING", comment: "Status badge (short, uppercase).")
            case .virtualDevice:
                return deviceProfile.tag == DeviceProfile.aggregateTag ? String(localized: "AGGREGATE DEVICE", comment: "Status badge (short, uppercase).")
                                                                       : String(localized: "VIRTUAL DEVICE", comment: "Status badge (short, uppercase).")
            case .speakerGroup: return resampledMembers.isEmpty ? "SPEAKER GROUP" : "SPEAKER GROUP · RESAMPLED"
            default: return String(localized: "BLUETOOTH · LOSSY", comment: "Status badge (short, uppercase).")
            }
        }
        if plan.dsdConvertedToPCM { return Self.convertedFromDSD }
        if isResampling { return String(localized: "RESAMPLED", comment: "Status badge (short, uppercase).") }
        if source.encoding == .lossy { return String(localized: "LOSSY SOURCE", comment: "Status badge (short, uppercase).") }
        if !applied.exclusive, otherAppsPlaying { return String(localized: "MIXED WITH OTHER APPS", comment: "Status badge (short, uppercase).") }
        if roomCorrection != nil { return String(localized: "ROOM CORRECTION", comment: "Status badge (short, uppercase).") }
        if equalizer != nil { return String(localized: "EQUALIZER", comment: "Status badge (short, uppercase).") }
        if modifiesSamples || faderRamping { return String(localized: "DIGITAL GAIN", comment: "Status badge (short, uppercase).") }
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

    /// The notice for a fold onto a speaker setup, as for a downmix: "5.1.2 → 7.1".
    private func foldNotice(onto: String) -> String {
        "\(ChannelLayouts.name(labels: source.channelLabels, channels: source.channels)) → \(onto.uppercased())"
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
        let from = ChannelLayouts.name(labels: source.channelLabels, channels: source.channels)
        let downmix = foldedOnto.map { Downmix(from: from, to: $0) }
            ?? (plan.mode == .pcm && plan.spatial == .off && plan.channels < source.channels
                ? Downmix(from: from, to: ChannelLayouts.name(channels: plan.channels)) : nil)
        guard plan.dsdConvertedToPCM || downmix != nil else { return nil }
        return Conversion(dsdToPCM: plan.dsdConvertedToPCM, downmix: downmix)
    }

    /// The parts of `conversion` that `statusLine` doesn't already say, as short notices ("Converted from DSD", "Downmixed to stereo").
    public var conversionBadges: [String] {
        guard let conversion else { return [] }
        var badges: [String] = []
        if conversion.dsdToPCM, statusLine != Self.convertedFromDSD { badges.append(Self.convertedFromDSD) }
        // The status line says a downmix itself, unless damaged frames take its place.
        if let mix = conversion.downmix, concealedFrames > 0 {
            badges.append(foldedOnto.map(foldNotice(onto:)) ?? downmixNotice(from: mix.from, channels: plan.channels))
        }
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

    /// The speaker setup (its name, "7.1", "Quad") the file is folded onto: it has as many or fewer speakers than the file has
    /// channels, and some channels have no speaker of their own, so they are mixed into the nearest ones. nil: not folded.
    public var foldedOnto: String? = nil
}

extension SignalPath {
    /// The source line for a song streamed from TIDAL (`tidal://…`): "TIDAL · FLAC 24/192 (DASH)", "TIDAL · FLAC 16/44.1". The format
    /// is what the stream turned out to be, not what TIDAL lists. Nil for files and shares.
    public static func remoteSourceLabel(url: URL?, source: SourceFormat, isDASH: Bool?) -> String? {
        guard url?.scheme?.lowercased() == "tidal" else { return nil }
        let rate = SampleRate.format(source.sampleRate)
        let format = source.bitDepth.map { "\($0)/\(rate)" } ?? rate
        return "TIDAL · \(source.codec) \(format)" + (isDASH == true ? " (DASH)" : "")
    }
}
