//
// Vespertine: Phase 0 speaker-group probe: the few Core Audio property reads and writes the probe tools need.
// (VespertineAudio keeps its own helpers internal; the probe only uses its public API, so this is a small copy.)
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

enum ProbeHAL {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var a = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type) -> [T] {
        var a = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer.bindMemory(to: T.self, capacity: count), count: count))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
                                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> OSStatus {
        var a = address(selector, scope: scope)
        var v = value
        return AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var a = address(selector)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &a, &settable) == noErr && settable.boolValue
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var a = address(selector)
        return AudioObjectHasProperty(object, &a)
    }

    static func outputStreams(_ device: AudioObjectID) -> [AudioStreamID] {
        getArray(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self)
    }

    static func nominalRate(_ device: AudioObjectID) -> Double {
        get(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
    }

    /// Sets the device's nominal rate and waits (bounded) until it reads back. Returns the rate read back.
    @discardableResult
    static func setNominalRate(_ rate: Double, on device: AudioObjectID, timeout: Double = 3) -> Double {
        if abs(nominalRate(device) - rate) < 0.5 { return nominalRate(device) }
        set(device, kAudioDevicePropertyNominalSampleRate, Float64(rate))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if abs(nominalRate(device) - rate) < 0.5 { usleep(60_000); break }   // let the change finish (the wedge lesson, AGENTS.md)
            usleep(10_000)
        }
        return nominalRate(device)
    }

    static func hogOwner(_ device: AudioObjectID) -> pid_t {
        get(device, kAudioDevicePropertyHogMode, initial: pid_t(-1)) ?? -1
    }

    /// Takes the device's hog mode for this process. True when this process owns it afterwards.
    static func acquireHog(_ device: AudioObjectID) -> Bool {
        let me = getpid()
        if hogOwner(device) == me { return true }
        if hogOwner(device) != -1 { return false }
        set(device, kAudioDevicePropertyHogMode, me)
        return hogOwner(device) == me
    }

    static func releaseHog(_ device: AudioObjectID) {
        guard hogOwner(device) == getpid() else { return }
        set(device, kAudioDevicePropertyHogMode, pid_t(-1))
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioObjectID.self)
    }

    static func deviceID(uid: String) -> AudioObjectID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func inputChannelCount(_ device: AudioObjectID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
