//
// Vespertine — multichannel layouts and Spatial Audio rendering for headphones (AirPods, Beats, …).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Multichannel music (5.1, 7.1, …) is rendered with Apple's own spatial renderer (AUSpatialMixer,
// "use output type" algorithm, personalized HRTF when the listener has set one up) into binaural
// stereo. The mixer runs on the I/O thread, slice by slice, so head tracking reacts within one
// device buffer even though decoding runs seconds ahead.
//

import AudioToolbox
import AVFAudio
import CVespertineRT
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

    /// A layout of exactly these speakers, in this order.
    public static func layout(labels: [AudioChannelLabel]) -> AVAudioChannelLayout? {
        guard !labels.isEmpty else { return nil }
        let size = MemoryLayout<AudioChannelLayout>.size + (labels.count - 1) * MemoryLayout<AudioChannelDescription>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        let layout = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mChannelBitmap = []
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        let descriptions = (raw + MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!).assumingMemoryBound(to: AudioChannelDescription.self)
        for (i, label) in labels.enumerated() {
            descriptions[i] = AudioChannelDescription(mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0))
        }
        return AVAudioChannelLayout(layout: layout)
    }

    /// Layouts Apple's spatial mixer takes for a bed: it refuses channel-by-channel descriptions, so a source's
    /// speakers are placed on the smallest of these that holds them all. Each was checked against the mixer
    /// (SpatialTests.bedsAccepted).
    static let spatialBeds: [(tag: AudioChannelLayoutTag, labels: [AudioChannelLabel])] = {
        let tags: [AudioChannelLayoutTag] = [
            0x0071_0003, 0x0083_0003, 0x0085_0003,              // L R C · L R Cs · L R LFE
            0x006C_0004, 0x00B9_0004, 0x0073_0004,              // L R Ls Rs · L R Rls Rrs · L R C Cs
            0x0088_0004, 0x0086_0004,                           // L R C LFE · L R LFE Cs
            0x0075_0005, 0x00BA_0005, 0x0087_0005, 0x0089_0005, // L R C Ls Rs · L R C Rls Rrs · L R LFE Ls Rs · L R C LFE Cs
            0x0079_0006, 0x00BB_0006, 0x00C6_0006,              // 5.1 · 5.1 with rear pair · L R Ls Rs Cs C
            0x00AC_0006, 0x00AA_0006, 0x00AB_0006,              // C Cs L R Rls Rrs · Lc Rc L R Ls Rs · C L R Rls Rrs Top
            0x007D_0007, 0x008C_0007, 0x0094_0007,              // 6.1 · 7.0 · 7.0 front (Lc Rc)
            0x00AD_0007, 0x00AE_0007, 0x009E_0007, 0x009F_0007, // Lc Rc L R Ls Rs LFE · C L R Rls Rrs Top LFE · 5.1 + Top · 5.1 + Vhc
            0x0080_0008, 0x007E_0008, 0x00A2_0008, 0x00A3_0008, // 7.1 · 7.1 wide (Lc Rc) · 5.1 + Lsd Rsd · 5.1 + Lw Rw
            0x00CD_0008, 0x00C2_0008, 0x00A5_0008, 0x00A6_0008, // 5.1.2 · 5.1 + Ltm Rtm · 6.1 + Top · 6.1 + Vhc
            0x0090_0008, 0x0070_0008, 0x006F_0008,              // octagonal · cube · L R Ls Rs C Cs Lw Rw
            0x00B2_0008, 0x00B3_0008, 0x00B4_0009, 0x00B5_0009, // Lc Rc L R Ls Rs Rls Rrs · Lc C Rc L R Ls Cs Rs (+ LFE)
            0x00C3_000A, 0x00C4_000A,                           // 5.1.4 · 7.1.2
            0x00C0_000C, 0x00CB_000E, 0x00C1_0010,              // 7.1.4 · 7.1.6 · 9.1.6
            0x0091_0010, 0x0092_0015, 0x00CC_0018,              // 16- and 21-channel sets · 22.2
        ]
        return tags.compactMap { tag in AVAudioChannelLayout(layoutTag: tag).map { (tag, $0.channelLabels) } }
    }()

    /// The bed for Spatial Audio: the smallest layout the mixer takes that has a speaker for every channel
    /// (the very same layout when it is one), else the one that has the most. nil for stereo.
    public static func spatialBed(for labels: [AudioChannelLabel]) -> (tag: AudioChannelLayoutTag, channels: Int)? {
        guard labels.count > 2 else { return nil }
        let wanted = normalizedSurrounds(labels)
        // Fewest channels without a place, then fewest placed only nearby, then the smallest bed.
        func rank(_ bed: (tag: AudioChannelLayoutTag, labels: [AudioChannelLabel])) -> (Int, Int, Int, Int) {
            guard let router = BedRouter(source: wanted, bed: bed.labels) else { return (.max, .max, .max, .max) }
            return (router.dropped, router.approximated, bed.labels.count, bed.labels == labels ? 0 : 1)
        }
        return spatialBeds.min { rank($0) < rank($1) }.map { ($0.tag, $0.labels.count) }
    }

    /// The speakers of an unlabeled multichannel stream, taken to be in the standard order for its channel count.
    public static func standardLabels(channels: Int) -> [AudioChannelLabel]? {
        guard channels > 2, standardTag(channels: channels) != nil else { return nil }
        return layout(channels: channels)?.channelLabels
    }

    /// One convention for the surround pairs. WAVE speaker masks call the back pair Ls/Rs and the side pair
    /// Lsd/Rsd; MPEG layouts (and every bed) call the side (or only) pair Ls/Rs and the back pair Rls/Rrs.
    static func normalizedSurrounds(_ labels: [AudioChannelLabel]) -> [AudioChannelLabel] {
        var result = labels
        for (surround, direct, rear) in [(kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft),
                                         (kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight)] {
            guard labels.contains(direct), !labels.contains(rear) else { continue }
            result = result.map { $0 == surround ? rear : $0 == direct ? surround : $0 }
        }
        return result
    }

    /// Core Audio names some speakers twice (the older "vertical height" and "top back" labels and the newer
    /// ones for the same places): one name for each place.
    static func canonical(_ label: AudioChannelLabel) -> AudioChannelLabel {
        switch label {
        case kAudioChannelLabel_LeftTopFront: kAudioChannelLabel_VerticalHeightLeft
        case kAudioChannelLabel_RightTopFront: kAudioChannelLabel_VerticalHeightRight
        case kAudioChannelLabel_CenterTopFront: kAudioChannelLabel_VerticalHeightCenter
        case kAudioChannelLabel_TopBackLeft: kAudioChannelLabel_LeftTopRear
        case kAudioChannelLabel_TopBackRight: kAudioChannelLabel_RightTopRear
        case kAudioChannelLabel_TopBackCenter: kAudioChannelLabel_CenterTopRear
        case kAudioChannelLabel_CenterTopMiddle: kAudioChannelLabel_TopCenterSurround
        case kAudioChannelLabel_Mono: kAudioChannelLabel_Center
        default: label
        }
    }

    /// Where a speaker goes when the bed doesn't have it: the nearest places, in order of preference, each a
    /// single speaker or a pair it sits between.
    static func nearest(_ label: AudioChannelLabel) -> [[AudioChannelLabel]] {
        switch canonical(label) {
        case kAudioChannelLabel_LeftSurroundDirect: [[kAudioChannelLabel_LeftSurround], [kAudioChannelLabel_RearSurroundLeft]]
        case kAudioChannelLabel_RightSurroundDirect: [[kAudioChannelLabel_RightSurround], [kAudioChannelLabel_RearSurroundRight]]
        case kAudioChannelLabel_LeftSurround: [[kAudioChannelLabel_LeftSurroundDirect], [kAudioChannelLabel_RearSurroundLeft]]
        case kAudioChannelLabel_RightSurround: [[kAudioChannelLabel_RightSurroundDirect], [kAudioChannelLabel_RearSurroundRight]]
        case kAudioChannelLabel_RearSurroundLeft: [[kAudioChannelLabel_LeftSurround], [kAudioChannelLabel_LeftSurroundDirect]]
        case kAudioChannelLabel_RearSurroundRight: [[kAudioChannelLabel_RightSurround], [kAudioChannelLabel_RightSurroundDirect]]
        case kAudioChannelLabel_CenterSurround:
            [[kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight], [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]]
        case kAudioChannelLabel_LeftCenter: [[kAudioChannelLabel_Left, kAudioChannelLabel_Center], [kAudioChannelLabel_Left]]
        case kAudioChannelLabel_RightCenter: [[kAudioChannelLabel_Right, kAudioChannelLabel_Center], [kAudioChannelLabel_Right]]
        case kAudioChannelLabel_LeftWide: [[kAudioChannelLabel_Left]]
        case kAudioChannelLabel_RightWide: [[kAudioChannelLabel_Right]]
        case kAudioChannelLabel_Center: [[kAudioChannelLabel_Left, kAudioChannelLabel_Right]]
        case kAudioChannelLabel_LFE2, kAudioChannelLabel_LFE3: [[kAudioChannelLabel_LFEScreen]]
        case kAudioChannelLabel_VerticalHeightLeft: [[kAudioChannelLabel_LeftTopMiddle], [kAudioChannelLabel_Left]]
        case kAudioChannelLabel_VerticalHeightRight: [[kAudioChannelLabel_RightTopMiddle], [kAudioChannelLabel_Right]]
        case kAudioChannelLabel_VerticalHeightCenter:
            [[kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight], [kAudioChannelLabel_Center]]
        case kAudioChannelLabel_LeftTopMiddle: [[kAudioChannelLabel_VerticalHeightLeft], [kAudioChannelLabel_LeftTopRear], [kAudioChannelLabel_LeftSurroundDirect], [kAudioChannelLabel_LeftSurround]]
        case kAudioChannelLabel_RightTopMiddle: [[kAudioChannelLabel_VerticalHeightRight], [kAudioChannelLabel_RightTopRear], [kAudioChannelLabel_RightSurroundDirect], [kAudioChannelLabel_RightSurround]]
        case kAudioChannelLabel_LeftTopRear: [[kAudioChannelLabel_LeftTopMiddle], [kAudioChannelLabel_RearSurroundLeft], [kAudioChannelLabel_LeftSurround]]
        case kAudioChannelLabel_RightTopRear: [[kAudioChannelLabel_RightTopMiddle], [kAudioChannelLabel_RearSurroundRight], [kAudioChannelLabel_RightSurround]]
        case kAudioChannelLabel_CenterTopRear:
            [[kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear], [kAudioChannelLabel_CenterSurround]]
        case kAudioChannelLabel_TopCenterSurround:
            [[kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_RightTopMiddle],
             [kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear]]
        default: []
        }
    }

    /// The speaker of each channel when a multichannel layout names them all (nil for stereo, unlabeled
    /// or discrete channels, and for a speaker named twice).
    public static func speakerLabels(_ layout: AVAudioChannelLayout?) -> [AudioChannelLabel]? {
        guard let layout, layout.channelCount > 2, layout.hasSpeakerPositions else { return nil }
        let labels = layout.channelLabels
        return Set(labels).count == labels.count ? labels : nil
    }

    static let lfeLabels: Set<AudioChannelLabel> = [kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2, kAudioChannelLabel_LFE3]
    static let heightLabels: Set<AudioChannelLabel> = [
        kAudioChannelLabel_TopCenterSurround, kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightCenter,
        kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_TopBackCenter, kAudioChannelLabel_TopBackRight,
        kAudioChannelLabel_LeftTopFront, kAudioChannelLabel_CenterTopFront, kAudioChannelLabel_RightTopFront,
        kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_CenterTopMiddle, kAudioChannelLabel_RightTopMiddle,
        kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_CenterTopRear, kAudioChannelLabel_RightTopRear,
    ]

    /// "Quad", "5.1", "3.1", "7.1.4", … from the speakers themselves; by channel count when they aren't known.
    public static func name(labels: [AudioChannelLabel]?, channels: Int) -> String {
        guard let labels, labels.count == channels, channels > 2 else { return name(channels: channels) }
        let set = Set(labels)
        if set == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
            || set == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]
            || set == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect] {
            return "Quad"
        }
        let lfe = labels.filter(lfeLabels.contains).count, height = labels.filter(heightLabels.contains).count
        let base = "\(channels - lfe - height).\(lfe)"
        return height > 0 ? base + ".\(height)" : base
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
                                          inputLayout.layout, UInt32(inputLayout.byteSize))
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

/// Places a source's channels on a Spatial Audio bed, each on the bed speaker of its own place (or split
/// between the two nearest), in interleaved Float32. Apple's converter can't be trusted with this: it turns
/// the whole stream silent when the bed has speakers it doesn't know how to feed (heights, 16-channel sets).
struct BedRouter {
    let sourceChannels: Int
    let bedChannels: Int
    /// Each source channel's bed speakers and gain.
    let routes: [[(bed: Int, gain: Float)]]

    init?(source: [AudioChannelLabel], bed: [AudioChannelLabel]) {
        guard !source.isEmpty, !bed.isEmpty else { return nil }
        let canonicalBed = bed.map(ChannelLayouts.canonical)
        func slots(_ labels: [AudioChannelLabel]) -> [Int]? {
            let found = labels.compactMap { l in canonicalBed.firstIndex(of: ChannelLayouts.canonical(l)) }
            return found.count == labels.count ? found : nil
        }
        var approximated = 0
        routes = ChannelLayouts.normalizedSurrounds(source).map { label in
            var place = slots([label])
            if place == nil {
                place = ChannelLayouts.nearest(label).lazy.compactMap(slots).first
                if place != nil { approximated += 1 }
            }
            let targets = place ?? []
            let gain = targets.isEmpty ? 0 : Float(1 / Double(targets.count).squareRoot())    // equal power between two
            return targets.map { ($0, gain) }
        }
        self.approximated = approximated
        sourceChannels = source.count
        bedChannels = bed.count
    }

    /// Source channels no bed speaker could take (heard nowhere).
    var dropped: Int { routes.filter(\.isEmpty).count }
    /// Source channels placed on the nearest speakers rather than their own.
    let approximated: Int

    func route(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, frames: Int) {
        output.update(repeating: 0, count: frames * bedChannels)
        for (s, targets) in routes.enumerated() {
            for (b, g) in targets {
                for f in 0..<frames { output[f * bedChannels + b] += input[f * sourceChannels + s] * g }
            }
        }
    }
}

// MARK: - Speaker labels

extension AVAudioChannelLayout {
    /// Bytes behind `layout`: the header and its channel descriptions. A tag-only layout is 12 bytes, so
    /// `MemoryLayout<AudioChannelLayout>.size` (32) reads past its end.
    public var byteSize: Int {
        MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            + Int(layout.pointee.mNumberChannelDescriptions) * MemoryLayout<AudioChannelDescription>.size
    }

    /// Speaker label of each channel, in order (expanding a layout tag when needed).
    public var channelLabels: [AudioChannelLabel] {
        let n = Int(channelCount)
        var result: [AudioChannelLabel] = []
        if layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            result = Self.labels(in: layout)
        } else if layoutTag == kAudioChannelLayoutTag_UseChannelBitmap {
            // A WAVE-style speaker bitmap (CAF, AIFF and WavPack files written by FFmpeg, …).
            var bitmap = layout.pointee.mChannelBitmap
            var size: UInt32 = 0
            if AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForBitmap, UInt32(MemoryLayout<AudioChannelBitmap>.size), &bitmap, &size) == noErr,
               size >= UInt32(MemoryLayout<AudioChannelLayout>.size) {
                let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
                defer { raw.deallocate() }
                if AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForBitmap, UInt32(MemoryLayout<AudioChannelBitmap>.size), &bitmap, &size, raw) == noErr {
                    let expanded = raw.assumingMemoryBound(to: AudioChannelLayout.self)
                    result = expanded.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions
                        ? Self.labels(in: expanded) : AVAudioChannelLayout(layout: expanded).channelLabels
                }
            }
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
        case kAudioChannelLabel_TopBackCenter, kAudioChannelLabel_CenterTopRear: "Ctr"
        case kAudioChannelLabel_LeftTopMiddle: "Lts"
        case kAudioChannelLabel_RightTopMiddle: "Rts"
        case kAudioChannelLabel_CenterTopMiddle: "Ctm"
        case kAudioChannelLabel_TopCenterSurround: "Top"
        case kAudioChannelLabel_LFE3: "LFE"
        case kAudioChannelLabel_Mono: "M"
        default:
            label >= kAudioChannelLabel_Discrete_0 && label <= kAudioChannelLabel_Discrete_65535 ? "\(label - kAudioChannelLabel_Discrete_0 + 1)" : "·"
        }
    }
}
