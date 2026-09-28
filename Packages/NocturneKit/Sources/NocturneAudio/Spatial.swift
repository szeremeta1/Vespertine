//
// Nocturne — multichannel layouts and Spatial Audio rendering for headphones (AirPods, Beats, …).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Multichannel music (5.1, 7.1, …) is rendered with Apple's own spatial renderer (AUSpatialMixer,
// "use output type" algorithm, personalized HRTF when the listener has set one up) into binaural
// stereo. The mixer runs on the I/O thread, slice by slice, so head tracking reacts within one
// device buffer even though decoding runs seconds ahead.
//

import AudioToolbox
import AVFAudio
import CNocturneRT
import Foundation

/// How multichannel music is delivered to a device.
public enum SpatialMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Standard downmix to the device's channels (or every channel on multichannel outputs).
    case off
    /// Virtual speakers fixed in front of you.
    case fixed
    /// Virtual speakers stay put as you turn your head (needs head-tracking AirPods or Beats).
    case headTracked

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off: "Off"
        case .fixed: "Fixed"
        case .headTracked: "Head Tracked"
        }
    }
}

public enum ChannelLayouts {
    /// The layout files of this channel count use when they don't say (WAV/FLAC/SMPTE order).
    public static func standardTag(channels: Int) -> AudioChannelLayoutTag? {
        switch channels {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        case 3: kAudioChannelLayoutTag_MPEG_3_0_A      // L R C
        case 4: kAudioChannelLayoutTag_Quadraphonic    // L R Ls Rs
        case 5: kAudioChannelLayoutTag_MPEG_5_0_A      // L R C Ls Rs
        case 6: kAudioChannelLayoutTag_MPEG_5_1_A      // L R C LFE Ls Rs
        case 7: kAudioChannelLayoutTag_MPEG_6_1_A      // L R C LFE Ls Rs Cs
        case 8: kAudioChannelLayoutTag_MPEG_7_1_C      // L R C LFE Ls Rs Rls Rrs
        default: nil
        }
    }

    /// The format's own layout, else the standard one for its channel count, else discrete channels.
    public static func layout(for format: AVAudioFormat) -> AVAudioChannelLayout? {
        if let own = format.channelLayout { return own }
        return layout(channels: Int(format.channelCount))
    }

    public static func layout(channels: Int) -> AVAudioChannelLayout? {
        guard channels > 0 else { return nil }
        let tag = standardTag(channels: channels) ?? (kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))
        return AVAudioChannelLayout(layoutTag: tag)
    }

    /// "5.1", "7.1", "Stereo", …
    public static func name(channels: Int) -> String {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 3: "3.0"
        case 4: "Quad"
        case 5: "5.0"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }
}

public enum SpatialError: LocalizedError {
    case unavailable(OSStatus, String)
    public var errorDescription: String? {
        switch self { case .unavailable(let s, let what): "Spatial Audio isn't available (\(what): \(s))." }
    }
}

/// Apple's spatial mixer configured for a multichannel bed and headphones, plus the real-time bridge.
public final class SpatialRenderer: @unchecked Sendable {
    public let inputChannels: Int
    public let sampleRate: Double
    public let mode: SpatialMode
    let unit: AudioUnit
    let bridge: OpaquePointer

    public init(inputLayout: AVAudioChannelLayout, channels: Int, sampleRate: Double, maxFrames: UInt32, mode: SpatialMode) throws {
        precondition(mode != .off)
        inputChannels = channels
        self.sampleRate = sampleRate
        self.mode = mode
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_SpatialMixer,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw SpatialError.unavailable(-1, "no spatial mixer") }
        var instance: AudioUnit?
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let unit = instance else { throw SpatialError.unavailable(status, "create") }
        self.unit = unit

        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T, _ what: String) throws {
            var v = value
            let s = AudioUnitSetProperty(unit, property, scope, element, &v, UInt32(MemoryLayout<T>.size))
            guard s == noErr else { throw SpatialError.unavailable(s, what) }
        }
        do {
            try set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, UInt32(1), "inputs")
            try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maxFrames, "slice size")
            var input = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, input, "input format")
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0,
                                          inputLayout.layout, UInt32(MemoryLayout<AudioChannelLayout>.size))
            guard status == noErr else { throw SpatialError.unavailable(status, "input layout") }
            input.mChannelsPerFrame = 2
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, input, "output format")
            try set(kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, 0, UInt32(3) /* kSpatialMixerSourceMode_AmbienceBed */, "bed mode")
            try set(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, 0, UInt32(7) /* kSpatializationAlgorithm_UseOutputType */, "algorithm")
            try set(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, UInt32(1) /* kSpatialMixerOutputType_Headphones */, "output type")
            // Personalized Spatial Audio when the listener has a profile; the default HRTF otherwise.
            try? set(kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global, 0, AUSpatialMixerPersonalizedHRTFMode.auto.rawValue, "personalized HRTF")
            try set(kAudioUnitProperty_SpatialMixerEnableHeadTracking, kAudioUnitScope_Global, 0, UInt32(mode == .headTracked ? 1 : 0), "head tracking")
            status = AudioUnitInitialize(unit)
            guard status == noErr else { throw SpatialError.unavailable(status, "initialize") }
            guard let bridge = nrt_spatial_create(unit, UInt32(channels), maxFrames) else { throw SpatialError.unavailable(-1, "bridge") }
            self.bridge = bridge
            status = nrt_spatial_install(bridge)
            guard status == noErr else { nrt_spatial_destroy(bridge); throw SpatialError.unavailable(status, "input callback") }
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        nrt_spatial_destroy(bridge)
    }

    /// Whether the listener's personalized spatial audio profile is in use.
    public var usesPersonalizedHRTF: Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let s = AudioUnitGetProperty(unit, kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF, kAudioUnitScope_Global, 0, &value, &size)
        return s == noErr && value != 0
    }

    /// Attaches the renderer to a playback context; call while the device is stopped.
    func attach(to context: OpaquePointer) -> Bool {
        nrt_context_set_processor(context, nrt_spatial_process, UnsafeMutableRawPointer(bridge), 2)
    }

    /// Renders interleaved multichannel frames to interleaved binaural stereo (exports, tests).
    public func render(interleaved input: [Float], frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames * 2)
        input.withUnsafeBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { out in
                nrt_spatial_process(UnsafeMutableRawPointer(bridge), inp.baseAddress!, UInt32(inputChannels),
                                    out.baseAddress!, 2, UInt32(frames))
            }
        }
        return output
    }
}

// MARK: - Speaker labels

extension AVAudioChannelLayout {
    /// Speaker label of each channel, in order (expanding a layout tag when needed).
    public var channelLabels: [AudioChannelLabel] {
        let n = Int(channelCount)
        var result: [AudioChannelLabel] = []
        if layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            result = Self.labels(in: layout)
        } else {
            var tag = layoutTag
            var size: UInt32 = 0
            if AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &size) == noErr,
               size >= UInt32(MemoryLayout<AudioChannelLayout>.size) {
                let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
                defer { raw.deallocate() }
                if AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &size, raw) == noErr {
                    result = Self.labels(in: raw.assumingMemoryBound(to: AudioChannelLayout.self))
                }
            }
        }
        if result.count < n { result += Array(repeating: kAudioChannelLabel_Unknown, count: n - result.count) }
        return Array(result.prefix(n))
    }

    /// Reads the variable-length description array in place (copying `pointee` keeps only the first).
    static func labels(in layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        let base = UnsafeRawPointer(layout) + MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let d = base.assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { d[$0].mChannelLabel }
    }

    /// True when channels carry real speaker positions (not just "channel 1, 2, …").
    public var hasSpeakerPositions: Bool {
        let labels = channelLabels
        let positional = labels.filter { $0 != kAudioChannelLabel_Unknown && $0 != kAudioChannelLabel_Unused
            && !($0 >= kAudioChannelLabel_Discrete && $0 <= kAudioChannelLabel_Discrete_65535) }
        return channelCount >= 2 && positional.count == labels.count
    }

    /// "L R C LFE Ls Rs"
    public var shortNames: [String] { channelLabels.map(ChannelLayouts.shortName) }
}

extension ChannelLayouts {
    public static func shortName(_ label: AudioChannelLabel) -> String {
        switch label {
        case kAudioChannelLabel_Left: "L"
        case kAudioChannelLabel_Right: "R"
        case kAudioChannelLabel_Center: "C"
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: "LFE"
        case kAudioChannelLabel_LeftSurround: "Ls"
        case kAudioChannelLabel_RightSurround: "Rs"
        case kAudioChannelLabel_LeftSurroundDirect: "Lsd"
        case kAudioChannelLabel_RightSurroundDirect: "Rsd"
        case kAudioChannelLabel_CenterSurround: "Cs"
        case kAudioChannelLabel_RearSurroundLeft: "Lrs"
        case kAudioChannelLabel_RearSurroundRight: "Rrs"
        case kAudioChannelLabel_LeftCenter: "Lc"
        case kAudioChannelLabel_RightCenter: "Rc"
        case kAudioChannelLabel_LeftWide: "Lw"
        case kAudioChannelLabel_RightWide: "Rw"
        case kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_LeftTopFront: "Ltf"
        case kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_RightTopFront: "Rtf"
        case kAudioChannelLabel_VerticalHeightCenter, kAudioChannelLabel_CenterTopFront: "Ctf"
        case kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTopRear: "Ltr"
        case kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTopRear: "Rtr"
        case kAudioChannelLabel_TopCenterSurround: "Top"
        case kAudioChannelLabel_Mono: "M"
        default:
            label >= kAudioChannelLabel_Discrete_0 && label <= kAudioChannelLabel_Discrete_65535 ? "\(label - kAudioChannelLabel_Discrete_0 + 1)" : "·"
        }
    }
}
