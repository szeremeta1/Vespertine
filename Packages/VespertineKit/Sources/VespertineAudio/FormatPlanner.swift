//
// Vespertine: decides the device format for a given source.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure logic, no Core Audio calls, so every decision is unit-testable.
//

import CoreAudio
import Foundation

public enum FormatPlanner {
    /// DSD bit rate → PCM rate produced by SFBDSDPCMDecoder (one PCM frame per DSD byte).
    public static func dsdToPCMRate(_ dsdRate: Double) -> Double { dsdRate / 8 }
    /// DSD bit rate → carrier PCM rate for DSD-over-PCM (16 DSD bits per 24-bit frame).
    public static func dopCarrierRate(_ dsdRate: Double) -> Double { dsdRate / 16 }

    public static func plan(source: SourceFormat, device rawDevice: DeviceCapabilities, policy: RatePolicy = .matchSource,
                            spatial: SpatialMode = .off, bitstream: Bool = false, spatializeStereo: Bool = false,
                            dsdToPCMForRoom: Bool = false, dsdToPCMForTransitions: Bool = false) -> OutputPlan {
        if bitstream, let kind = BitstreamFormat(codec: source.codec) {
            // A receiver on this output decodes Dolby and DTS itself: send the frames untouched.
            let carrier = kind.carrierRate(for: source.sampleRate)
            if rawDevice.supports(rate: carrier), rawDevice.outputChannels >= 2, rawDevice.bestIntegerBitDepth(at: carrier) >= 16 {
                return OutputPlan(mode: .bitstream, deviceSampleRate: carrier, decodedSampleRate: carrier,
                                  physicalBitDepth: rawDevice.bestIntegerBitDepth(at: carrier), channels: 2, dsdConvertedToPCM: false,
                                  reason: "\(kind.name) sent untouched to the receiver (IEC 61937 at \(SampleRate.format(carrier)) kHz)")
            }
        }
        if spatializeStereo, let upmixed = upmixPlan(source: source, device: rawDevice, policy: policy, spatial: spatial,
                                                     dsdToPCMForRoom: dsdToPCMForRoom, dsdToPCMForTransitions: dsdToPCMForTransitions) {
            return upmixed
        }
        var plan = basePlan(source: source, device: rawDevice, policy: policy, dsdToPCMForRoom: dsdToPCMForRoom,
                            dsdToPCMForTransitions: dsdToPCMForTransitions)
        // Multichannel music: Spatial Audio on headphones, every channel on multichannel outputs,
        // otherwise a standard downmix (the converter mixes by channel layout).
        guard plan.mode == .pcm, source.channels > 2 else { return plan }
        let name = ChannelLayouts.name(labels: source.channelLabels, channels: source.channels)
        if spatial != .off, rawDevice.outputChannels >= 2 {
            plan.channels = source.channels
            // The source's own speakers; unlabeled or discrete channels are taken in WAV order for their count (wavOrderLabels),
            // as the engine routes them (PlaybackEngine.Decoding).
            let labels = ChannelLayouts.speakerLabels(source.channelLabels.flatMap { $0.count == source.channels ? $0 : nil })
                ?? ChannelLayouts.wavOrderLabels(channels: source.channels)
            if let labels, let bed = ChannelLayouts.spatialBed(for: labels) {
                plan.spatialBed = bed.tag
                plan.channels = bed.channels
            }
            plan.deviceChannelCount = 2
            plan.spatial = spatial
            plan.reason = "\(name) rendered with Spatial Audio (\(spatial == .headTracked ? "head tracked" : "fixed")). " + plan.reason
        } else if let speakers = rawDevice.speakerLayoutChannels, speakers >= 3, speakers <= rawDevice.outputChannels {
            // A configured speaker layout: channels are placed by speaker position (5.1 into a 7.1 room,
            // 7.1 folded into a 5.1 room), so every source channel reaches the right speaker.
            plan.channels = speakers
            plan.reason = speakers == source.channels
                ? "\(name) to \(name) speakers. " + plan.reason
                : "\(name) placed on the \(ChannelLayouts.name(channels: speakers)) speaker setup. " + plan.reason
        } else if plan.channels < source.channels {
            plan.reason = "\(name) downmixed to \(ChannelLayouts.name(channels: plan.channels)). " + plan.reason
        } else {
            plan.routeLabels = ChannelLayouts.discreteLabels(source: source.channelLabels, channels: source.channels)
            plan.reason = "\(name) to \(source.channels) outputs in standard order (L R C LFE Ls Rs…). " + plan.reason
        }
        return plan
    }

    /// Where Spatialize stereo puts its 5.1 on `device`; nil when there is nowhere (a stereo DAC with Spatial Audio off).
    enum StereoUpmixTarget { case headphones, speakers(Int), outputs }
    static func stereoUpmixTarget(device: DeviceCapabilities, spatial: SpatialMode) -> StereoUpmixTarget? {
        if spatial != .off, device.outputChannels >= 2 { return .headphones }
        if let speakers = device.speakerLayoutChannels, speakers >= 3, speakers <= device.outputChannels { return .speakers(speakers) }
        if device.outputChannels >= 6 { return .outputs }
        return nil
    }

    /// Whether the Spatialize stereo switch does anything on `device` with this Spatial Audio mode: the settings show it
    /// only then.
    public static func canSpatializeStereo(on device: DeviceCapabilities, spatial: SpatialMode) -> Bool {
        stereoUpmixTarget(device: device, spatial: spatial) != nil
    }

    /// Spatialize stereo: a stereo or mono source upmixed to 5.1, for Spatial Audio on headphones, the outputs of a
    /// multichannel device in standard order (6 or more, no speaker setup), or a speaker setup of 3 or more. nil where it
    /// doesn't apply (more than two channels, an output with nowhere to put them), and the plan is the usual one.
    static func upmixPlan(source: SourceFormat, device: DeviceCapabilities, policy: RatePolicy, spatial: SpatialMode,
                          dsdToPCMForRoom: Bool, dsdToPCMForTransitions: Bool) -> OutputPlan? {
        guard source.channels >= 1, source.channels <= 2 else { return nil }
        guard let target = stereoUpmixTarget(device: device, spatial: spatial) else { return nil }
        // The rate is chosen for the channels the device receives (HDMI carries 8 channels at fewer rates than 2); DSD is
        // converted to PCM, which can be upmixed.
        var sized = source
        switch target {
        case .headphones: break
        case .speakers(let n): sized.channels = n
        case .outputs: sized.channels = StereoUpmixer.outputChannels
        }
        var plan = basePlan(source: sized, device: device, policy: policy, dsdToPCMForRoom: dsdToPCMForRoom || source.encoding == .dsd,
                            dsdToPCMForTransitions: dsdToPCMForTransitions)
        guard plan.mode == .pcm else { return nil }
        if source.encoding == .dsd, !dsdToPCMForRoom, !dsdToPCMForTransitions {
            plan.reason = "Spatialize stereo is on; \(source.dsdName ?? "DSD") converted to PCM so it can be upmixed"
        }
        plan.upmix = true
        let name = source.channels == 1 ? "Mono" : "Stereo"
        switch target {
        case .headphones:
            plan.channels = StereoUpmixer.outputChannels
            plan.spatialBed = kAudioChannelLayoutTag_MPEG_5_1_A
            plan.deviceChannelCount = 2
            plan.spatial = spatial
            plan.reason = "\(name) upmixed to 5.1 and rendered with Spatial Audio (\(spatial == .headTracked ? "head tracked" : "fixed")). " + plan.reason
        case .speakers(let n):
            plan.channels = n
            plan.reason = "\(name) upmixed to 5.1, placed on the \(ChannelLayouts.name(channels: n)) speaker setup. " + plan.reason
        case .outputs:
            plan.channels = StereoUpmixer.outputChannels
            plan.routeLabels = StereoUpmixer.outputLabels
            plan.reason = "\(name) upmixed to 5.1 on outputs 1–6 (L R C LFE Ls Rs). " + plan.reason
        }
        return plan
    }

    /// `dsdToPCMForRoom`: room correction is on for this output, so DSD is converted to PCM (which it can correct)
    /// instead of going out natively as DoP. `dsdToPCMForTransitions`: the same, so songs can blend (transitions on,
    /// "transitions first").
    static func basePlan(source: SourceFormat, device rawDevice: DeviceCapabilities, policy: RatePolicy, dsdToPCMForRoom: Bool = false,
                         dsdToPCMForTransitions: Bool = false) -> OutputPlan {
        let channels = max(1, min(source.channels, max(rawDevice.outputChannels, 1)))
        // Ignore rates whose only formats carry fewer channels than we need (e.g. AirPods' 24 kHz mono hands-free
        // mode). A mono song counts as stereo on a device that has stereo: a call mode's mono rate would switch
        // Bluetooth headphones to their call codec for it.
        var device = rawDevice
        if !rawDevice.physicalFormats.isEmpty {
            let needed = max(channels, min(2, rawDevice.physicalFormats.map(\.channels).max() ?? channels))
            let usable = rawDevice.sampleRates.filter { rate in
                rawDevice.physicalFormats.contains { $0.supports(rate: rate) && $0.channels >= needed }
            }
            if !usable.isEmpty { device.sampleRates = usable }
        }

        // DSD: native DoP when the user has confirmed the DAC understands it and the carrier rate exists.
        if source.encoding == .dsd {
            let carrier = dopCarrierRate(source.sampleRate)
            let dopDepth = dopCarrierDepth(device, carrier: carrier, channels: channels)
            if !dsdToPCMForRoom, !dsdToPCMForTransitions, channels == source.channels, device.supportsDoP, device.supports(rate: carrier), dopDepth >= 24 {
                return OutputPlan(mode: .dop, deviceSampleRate: carrier, decodedSampleRate: carrier,
                                  physicalBitDepth: dopDepth, channels: channels,
                                  dsdConvertedToPCM: false,
                                  reason: "\(source.dsdName ?? "DSD") sent natively as DoP at \(SampleRate.format(carrier)) kHz")
            }
            let pcmRate = dsdToPCMRate(source.sampleRate)
            let rate = chooseRate(for: pcmRate, device: device, policy: policy)
            let why = dsdToPCMForRoom
                ? "Room correction is on; \(source.dsdName ?? "DSD") converted to PCM so it can be corrected"
                : dsdToPCMForTransitions
                ? "Transitions come first; \(source.dsdName ?? "DSD") converted to PCM so songs can blend"
                : device.supportsDoP && device.supports(rate: carrier) && channels == source.channels
                ? "DoP needs a 24-bit integer format at \(SampleRate.format(carrier)) kHz, which this device doesn't offer; converted to PCM"
                : device.supportsDoP
                ? "DoP needs \(SampleRate.format(carrier)) kHz, which this device can't do; converted to PCM"
                : "Device is PCM-only (DoP off); DSD converted to PCM"
            var plan = OutputPlan(mode: .pcm, deviceSampleRate: rate, decodedSampleRate: pcmRate,
                                  physicalBitDepth: device.bestIntegerBitDepth(at: rate), channels: channels,
                                  dsdConvertedToPCM: true, reason: why)
            plan.dopAvailable = !dsdToPCMForRoom && !dsdToPCMForTransitions && !device.supportsDoP
                && channels == source.channels && device.supports(rate: carrier) && dopDepth >= 24
            return plan
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

    /// The bit depth DoP's words would reach the DAC in at `carrier` for `channels` channels; 0 where they wouldn't arrive
    /// intact. DoP words are 24-bit integers: they need an integer format of at least 24 bits at the carrier rate for every
    /// channel, in one stream, or across the streams the channels are spread over in order (an 8-channel DAC as four
    /// stereo streams), each of those taking one. A device that lists no formats is left to the output's read-back check.
    static func dopCarrierDepth(_ device: DeviceCapabilities, carrier: Double, channels: Int) -> Int {
        if device.physicalFormats.isEmpty { return device.bestIntegerBitDepth(at: carrier) }
        func carries(_ f: PhysicalFormat) -> Bool { f.isInteger && f.bitDepth >= 24 && f.supports(rate: carrier) }
        if let depth = device.physicalFormats.filter({ carries($0) && $0.channels >= channels }).map(\.bitDepth).max() { return depth }
        guard let streams = device.streamFormats, streams.count > 1 else { return 0 }
        var covered = 0, depth = Int.max
        for stream in streams where covered < channels {
            let usable = stream.filter(carries)
            guard let widest = usable.map(\.channels).max() else { return 0 }
            covered += widest
            depth = min(depth, usable.filter { $0.channels == widest }.map(\.bitDepth).max() ?? 0)
        }
        return covered >= channels ? depth : 0
    }

    /// Picks the device rate for a PCM stream at `rate`.
    ///
    /// Order of preference when the exact rate is unavailable:
    ///  1. the smallest integer multiple of the source rate (same family: 44.1 → 88.2)
    ///  2. the smallest rate above the source
    ///  3. the largest integer divisor of the source (384 → 192), unless it would give up more than half the
    ///     device's top rate: 176.4 kHz on a 96 kHz-max DAC goes to 96, not 44.1, which would cut everything
    ///     above 22 kHz
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
        let highest = rates.max()!
        if let divisor = rates.last(where: { SampleRate.isIntegerMultiple(rate, of: $0) }), divisor * 2 >= highest { return divisor }
        return highest
    }

    /// "Match 16-bit sources": a 16-bit file goes to a DAC that offers a real 16-bit mode at its rate as 16-bit,
    /// instead of zero-padded to 24 or 32 bits. `eligible` is the engine's part (the setting is on, the output is held
    /// exclusively and isn't the built-in one, and no digital volume, equalizer or ReplayGain changes the samples);
    /// the rest is the plan's: integer 16-bit PCM at its own rate and channel count, no Spatial Audio or downmix.
    /// DSD, DoP and bitstream are never affected. Anything else keeps `plan` as it is.
    public static func matchSixteenBit(_ plan: OutputPlan, source: SourceFormat, device: DeviceCapabilities, eligible: Bool) -> OutputPlan {
        guard eligible, plan.mode == .pcm, source.encoding == .pcm, source.bitDepth == 16, !plan.dsdConvertedToPCM, !plan.resamples,
              plan.spatial == .off, plan.channels == source.channels, plan.deviceChannels == source.channels else { return plan }
        var plan = plan
        if device.offersInteger(bits: 16, at: plan.deviceSampleRate, channels: plan.channels) {
            // A 16-bit word needs no integer mode: Float32 carries every 16-bit sample exactly.
            plan.integerSamples = false
            plan.physicalBitDepth = 16
            plan.sixteenBit = .requested
        } else {
            plan.sixteenBit = .noMode
        }
        return plan
    }
}
