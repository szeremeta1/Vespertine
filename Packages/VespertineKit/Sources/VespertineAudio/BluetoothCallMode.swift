//
// Vespertine: a Bluetooth headset in call mode, and who put it there.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// While any app has a Bluetooth headset's microphone open, macOS keeps the whole headset in its hands-free call mode: 24 kHz
// (or lower), usually mono, no Spatial Audio, whatever plays on it and whoever plays it. AirPods Max on their USB-C cable
// too: their microphone is still a Bluetooth one, so macOS moves the output back to Bluetooth for the call. Vespertine can't
// and doesn't change that (asking the link for another rate is refused), but it can say so, and say which app it is: on
// 2026-11-13 it was System Settings' Sound pane, whose input meter follows the default input onto the AirPods' microphone
// as soon as they connect, while Vespertine went on showing "Spatial Audio on" and "24 kHz · IDLE".
//

import CoreAudio
import Darwin
import Foundation

/// A process Core Audio reports as running input (recording) right now.
public struct AudioInputProcess: Sendable, Hashable {
    public var pid: Int32
    public var bundleID: String?
    /// The app's name (`NSRunningApplication`) or, for a daemon or extension, its executable's name.
    public var name: String?
    /// UIDs of the input devices it is recording from.
    public var inputDeviceUIDs: [String]

    public init(pid: Int32, bundleID: String?, name: String?, inputDeviceUIDs: [String]) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.inputDeviceUIDs = inputDeviceUIDs
    }
}

public enum MicrophoneUsers {
    /// The apps (display names, without duplicates, in Core Audio's order) recording from the microphone of the headset whose
    /// output has `outputUID`, leaving out `excludingPID` (Vespertine itself).
    public static func holders(ofOutputUID outputUID: String, among processes: [AudioInputProcess], excludingPID: Int32) -> [String] {
        var names: [String] = []
        for process in processes where process.pid != excludingPID && process.inputDeviceUIDs.contains(where: { sameHeadset($0, outputUID) }) {
            let name = displayName(process)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The headset's microphone as Core Audio names it: AirPods' output "70-F9-4A-BF-8C-C7:output" and input
    /// "70-F9-4A-BF-8C-C7:input" share the Bluetooth address before the colon.
    static func sameHeadset(_ inputUID: String, _ outputUID: String) -> Bool {
        guard !inputUID.isEmpty, !outputUID.isEmpty else { return false }
        func address(_ uid: String) -> Substring? {
            guard let colon = uid.lastIndex(of: ":") else { return nil }
            let head = uid[..<colon]
            return head.isEmpty ? nil : head
        }
        if let a = address(inputUID), let b = address(outputUID) { return a == b }
        return inputUID == outputUID
    }

    /// What to call a process in a sentence: System Settings' panes run as their own processes ("Sound"), the speech daemon
    /// behind "Hey Siri" as corespeechd.
    public static func displayName(_ process: AudioInputProcess) -> String {
        let bundle = process.bundleID?.lowercased() ?? ""
        if bundle == "com.apple.systempreferences" || (bundle.hasPrefix("com.apple.") && bundle.contains("settings.extension")) {
            return String(localized: "System Settings", comment: "The macOS app, named as the one using a headset's microphone")
        }
        if process.name == "corespeechd" || bundle == "com.apple.corespeech.corespeechd" {
            return String(localized: "Siri", comment: "Siri's listening (\"Hey Siri\"), named as what is using a headset's microphone")
        }
        if let name = process.name, !name.isEmpty { return name }
        return String(localized: "an app", comment: "An app Vespertine can't name, using a headset's microphone; its process ID follows in parentheses") + " (pid \(process.pid))"
    }

    /// The live list, read from Core Audio (macOS 14.2 and later): every process running input, with its input devices.
    public static func running() -> [AudioInputProcess] {
        let list = AudioObjectPropertyAddress.global(kAudioHardwarePropertyProcessObjectList)
        guard let objects = try? HAL.getArray(AudioObjectID(kAudioObjectSystemObject), list, of: AudioObjectID.self) else { return [] }
        return objects.compactMap { object -> AudioInputProcess? in
            let running: UInt32 = (try? HAL.get(object, .global(kAudioProcessPropertyIsRunningInput), initial: UInt32(0))) ?? 0
            guard running != 0 else { return nil }
            let pid: Int32 = (try? HAL.get(object, .global(kAudioProcessPropertyPID), initial: Int32(-1))) ?? -1
            let bundleID = HAL.getString(object, .global(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
            let devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeInput,
                                                            mElement: kAudioObjectPropertyElementMain)
            let devices = (try? HAL.getArray(object, devicesAddress, of: AudioObjectID.self)) ?? []
            let uids = devices.compactMap { HAL.getString($0, .global(kAudioDevicePropertyDeviceUID)) }
            return AudioInputProcess(pid: pid, bundleID: bundleID, name: processName(pid), inputDeviceUIDs: uids)
        }
    }

    private static func processName(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}

/// A Bluetooth output that macOS has put in call mode, and the apps holding its microphone (empty: couldn't tell).
public struct BluetoothCallMode: Sendable, Equatable {
    public var deviceName: String
    public var sampleRate: Double
    public var microphoneUsers: [String]

    public init(deviceName: String, sampleRate: Double, microphoneUsers: [String]) {
        self.deviceName = deviceName
        self.sampleRate = sampleRate
        self.microphoneUsers = microphoneUsers
    }

    /// The call mode of `device` (nil: not a Bluetooth output, or not in call mode), with the apps holding its microphone.
    public static func of(_ device: OutputDevice, processes: [AudioInputProcess], excludingPID: Int32) -> BluetoothCallMode? {
        guard device.isInCallMode else { return nil }
        return BluetoothCallMode(deviceName: device.name, sampleRate: device.nominalSampleRate,
                                 microphoneUsers: MicrophoneUsers.holders(ofOutputUID: device.uid, among: processes, excludingPID: excludingPID))
    }

    /// The same, read live from Core Audio.
    public static func current(_ device: OutputDevice) -> BluetoothCallMode? {
        guard device.isInCallMode else { return nil }
        return of(device, processes: MicrophoneUsers.running(), excludingPID: getpid())
    }

    /// What happened and what to do about it, in a sentence or two.
    public var explanation: String {
        let rate = SampleRate.format(sampleRate)
        guard !microphoneUsers.isEmpty else {
            return String(localized: "\(deviceName) is in call mode because an app is using its microphone: macOS plays everything on it at \(rate) kHz, like a phone call, without Spatial Audio. Close that app or pick another input in System Settings › Sound; full quality returns by itself.",
                          comment: "A Bluetooth headset is in its hands-free call mode and Vespertine can't tell which app has its microphone. The first %@ is the headset, the second the rate in kHz.")
        }
        let users = ListFormatter.localizedString(byJoining: microphoneUsers)
        return String(localized: "\(deviceName) is in call mode because \(users) is using its microphone: macOS plays everything on it at \(rate) kHz, like a phone call, without Spatial Audio. Close it or pick another input in System Settings › Sound; full quality returns by itself.",
                      comment: "A Bluetooth headset is in its hands-free call mode because an app has its microphone open. The first %@ is the headset, the second the app (e.g. System Settings), the third the rate in kHz.")
    }
}

extension OutputDevice {
    /// A Bluetooth output macOS has put in its hands-free call mode (below 32 kHz; A2DP music runs at 44.1 or 48 kHz). Judged by
    /// the transport, not the profile: AirPods Max on the cable go back to Bluetooth for the call.
    public var isInCallMode: Bool {
        (transport == .bluetooth || transport == .bluetoothLE) && nominalSampleRate > 0 && nominalSampleRate < 32_000
    }
}

/// What the output chip says next to the rate when Vespertine's own signal path isn't playing.
public enum DeviceChipState: Sendable, Equatable {
    case idle
    /// macOS's renderer is playing (Dolby Atmos), not Vespertine's output.
    case systemRenders
    case standingIn
    /// A Bluetooth headset in call mode: this beats the others, since it's why the sound is bad.
    case callMode

    public static func of(_ device: OutputDevice, systemRendering: Bool, standingIn: Bool) -> DeviceChipState {
        if device.isInCallMode { return .callMode }
        if standingIn { return .standingIn }
        return systemRendering ? .systemRenders : .idle
    }
}
