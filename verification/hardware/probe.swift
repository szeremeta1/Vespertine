// Vespertine verification: prints what Core Audio reports for every output device, for LOOPBACK.md steps P1 and R2.
// SPDX-License-Identifier: GPL-3.0-or-later
//
//   swift verification/hardware/probe.swift
//
// One line per device with output streams: name, UID, nominal sample rate, the first output stream's physical
// format (bits, integer or float, non-mixable), and which process holds hog mode (none, or a PID). Run it before
// starting Vespertine, while it plays, and after it quits, and compare. It only reads properties; it changes nothing.

import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out) == noErr else { return [] }
    return out
}

func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = address(selector)
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = address(selector)
    var v: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &v) == noErr, let s = v else { return "?" }
    return s.takeRetainedValue() as String
}

func describe(_ f: AudioStreamBasicDescription) -> String {
    let kind = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float"
        : f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 ? "integer" : "unsigned"
    let mixable = f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 ? ", non-mixable" : ""
    return "\(f.mBitsPerChannel)-bit \(kind), \(f.mChannelsPerFrame) ch at \(f.mSampleRate) Hz\(mixable)"
}

let system = AudioObjectID(kAudioObjectSystemObject)
let now = ISO8601DateFormatter().string(from: Date())
print("# \(now)")
for device in ids(system, kAudioHardwarePropertyDevices) {
    let streams = ids(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    guard let first = streams.first else { continue }
    let rate = value(device, kAudioDevicePropertyNominalSampleRate, Float64(0)).map { "\($0) Hz" } ?? "?"
    let physical = value(first, kAudioStreamPropertyPhysicalFormat, AudioStreamBasicDescription()).map(describe) ?? "?"
    let hog = value(device, kAudioDevicePropertyHogMode, pid_t(-1)).map { $0 == -1 ? "none" : "pid \($0)" } ?? "?"
    print("\(string(device, kAudioObjectPropertyName)) | \(string(device, kAudioDevicePropertyDeviceUID)) | nominal \(rate) | physical \(physical) | hog \(hog)")
}
