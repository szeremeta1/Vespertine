//
// Vespertine: multichannel layouts and Spatial Audio rendering for headphones (AirPods, Beats, …).
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
// Speaker layouts, Spatial Audio beds and their routing live in VespertineChannels (the iPhone player uses them too).
@_exported import VespertineChannels

public enum SpatialError: LocalizedError {
    case unavailable(OSStatus, String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let s, let what):
            String(localized: "Spatial Audio isn't available (\(what): \(Int(s))).", comment: "A technical step of Apple's spatial mixer, then its error code.")
        }
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
