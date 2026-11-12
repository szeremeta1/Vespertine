//
// Vespertine: Mac Sound Output (beta): talking to Vespertine's audio driver (Driver/VespertineSound) through Core Audio. The
// driver is a plug-in of the Mac's audio server; it publishes what it is told through one property on its plug-in object and
// takes an output away again when nobody refreshes it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum SystemOutputDriverError: Error, Equatable, LocalizedError {
    case notInstalled
    case refused(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "Vespertine's audio driver is not installed.")
        case .refused(let status): String(localized: "The audio driver did not take the outputs (\(Int(status))).")
        }
    }
}

public enum SystemOutputDriver {
    /// Where the driver is installed: the folder the Mac's audio server loads plug-ins from.
    public static let installDirectory = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
    public static let bundleName = "VespertineSound.driver"
    public static var installedURL: URL { installDirectory.appendingPathComponent(bundleName, isDirectory: true) }

    /// The driver's plug-in object, when the audio server has loaded it.
    public static func plugIn() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress.global(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var qualifier = SystemOutput.driverBundleID as CFString
        var plugIn = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &plugIn)
        }
        return status == noErr && plugIn != 0 && plugIn != AudioObjectID(kAudioObjectUnknown) ? plugIn : nil
    }

    /// The driver is loaded (installed, and the audio server started since it was).
    public static var isLoaded: Bool { plugIn() != nil }

    /// A driver bundle's build number (CFBundleVersion), nil when there is none at `url`. Read from its Info.plist directly, so a
    /// driver replaced while the app runs reads as the new one (Bundle caches).
    public static func buildNumber(at url: URL = installedURL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleVersion"] as? String
    }

    /// The driver inside Vespertine.app (Contents/Library/Audio), what installing copies.
    public static func bundledURL(in app: URL = Bundle.main.bundleURL) -> URL {
        app.appendingPathComponent("Contents/Library/Audio", isDirectory: true).appendingPathComponent(bundleName, isDirectory: true)
    }

    /// Publishes exactly `configuration` (`SystemOutput.driverConfiguration`): outputs not in it go away, the rest are
    /// refreshed. An empty list takes every output away.
    public static func publish(_ configuration: [[String: Any]]) throws {
        guard let plugIn = plugIn() else { throw SystemOutputDriverError.notInstalled }
        var address = AudioObjectPropertyAddress.global(SystemOutput.configurationSelector)
        var list = configuration as CFArray
        let status = withUnsafeMutablePointer(to: &list) {
            AudioObjectSetPropertyData(plugIn, &address, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0)
        }
        guard status == noErr else { throw SystemOutputDriverError.refused(status) }
    }

    /// The device with `uid` (a published output or its capture side), if the driver shows it now.
    public static func device(uid: String) -> AudioObjectID? { GroupAggregateDevice.deviceID(uid: uid) }

    /// Some app plays to (or records from) the device: Core Audio runs it for someone.
    public static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        ((try? HAL.get(device, .global(kAudioDevicePropertyDeviceIsRunningSomewhere), initial: UInt32(0))) ?? 0) != 0
    }

    public static func nominalRate(_ device: AudioObjectID) -> Double {
        (try? HAL.get(device, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
    }

    public static func setNominalRate(_ rate: Double, on device: AudioObjectID) {
        try? HAL.set(device, .global(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    /// The device is the Mac's chosen output (what the volume keys and the Sound menu act on).
    public static func isDefaultOutput(_ device: AudioObjectID) -> Bool { DeviceQuery.defaultOutputDeviceID() == device }
}
