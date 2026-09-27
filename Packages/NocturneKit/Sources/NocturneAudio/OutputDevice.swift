//
// Nocturne — output devices as seen by the Core Audio HAL.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum Transport: String, Sendable, Codable {
    case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort, airPlay, thunderbolt, pci, fireWire, aggregate, virtual, unknown

    init(_ raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .usb: "USB"
        case .bluetooth, .bluetoothLE: "Bluetooth"
        case .hdmi: "HDMI"
        case .displayPort: "DisplayPort"
        case .airPlay: "AirPlay"
        case .thunderbolt: "Thunderbolt"
        case .pci: "PCI"
        case .fireWire: "FireWire"
        case .aggregate: "Aggregate"
        case .virtual: "Virtual"
        case .unknown: "Other"
        }
    }
}

/// A snapshot of one output device.
public struct OutputDevice: Identifiable, Sendable, Hashable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let modelUID: String?
    public let transport: Transport
    public let nominalSampleRate: Double
    public let capabilities: DeviceCapabilities
    public let hasHardwareVolume: Bool
    public let isDefault: Bool

    public var profile: DeviceProfile { DeviceProfile.detect(self) }

    /// "44.1–384 kHz · 16/24/32-bit"
    public var rangeSummary: String {
        guard let lo = capabilities.sampleRates.first, let hi = capabilities.sampleRates.last else { return "—" }
        var depths = Set(capabilities.physicalFormats.filter(\.isInteger).map(\.bitDepth)).sorted()
        if depths.isEmpty { depths = Set(capabilities.physicalFormats.map(\.bitDepth)).sorted() }
        let rates = lo == hi ? "\(SampleRate.format(lo)) kHz" : "\(SampleRate.format(lo))–\(SampleRate.format(hi)) kHz"
        return depths.isEmpty ? rates : rates + " · " + depths.map(String.init).joined(separator: "/") + "-bit"
    }
}

enum DeviceQuery {
    static let standardRates: [Double] = [
        8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000,
        176_400, 192_000, 352_800, 384_000, 705_600, 768_000,
    ]

    static func allDeviceIDs() -> [AudioObjectID] {
        (try? HAL.getArray(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        let id = try? HAL.get(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID(0))
        return id.flatMap { $0 == 0 ? nil : $0 }
    }

    static func outputStreams(_ device: AudioObjectID) -> [AudioStreamID] {
        (try? HAL.getArray(device, .output(kAudioDevicePropertyStreams), of: AudioStreamID.self)) ?? []
    }

    static func outputChannelCount(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress.output(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func physicalFormats(_ stream: AudioStreamID) -> [AudioStreamRangedDescription] {
        (try? HAL.getArray(stream, .global(kAudioStreamPropertyAvailablePhysicalFormats), of: AudioStreamRangedDescription.self)) ?? []
    }

    static func nominalRates(_ device: AudioObjectID) -> [Double] {
        let ranges = (try? HAL.getArray(device, .global(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)) ?? []
        var rates = Set<Double>()
        for range in ranges {
            if abs(range.mMaximum - range.mMinimum) < 0.5 {
                rates.insert(range.mMinimum)
            } else {
                standardRates.filter { $0 >= range.mMinimum - 0.5 && $0 <= range.mMaximum + 0.5 }.forEach { rates.insert($0) }
            }
        }
        return rates.sorted()
    }

    static func capabilities(_ device: AudioObjectID, supportsDoP: Bool) -> DeviceCapabilities {
        var formats: [PhysicalFormat] = []
        for stream in outputStreams(device) {
            for ranged in physicalFormats(stream) where ranged.mFormat.mFormatID == kAudioFormatLinearPCM {
                let f = ranged.mFormat
                formats.append(PhysicalFormat(
                    minRate: ranged.mSampleRateRange.mMinimum,
                    maxRate: ranged.mSampleRateRange.mMaximum,
                    bitDepth: Int(f.mBitsPerChannel),
                    isInteger: f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                    isMixable: f.mFormatFlags & kAudioFormatFlagIsNonMixable == 0,
                    channels: Int(f.mChannelsPerFrame)))
            }
        }
        return DeviceCapabilities(sampleRates: nominalRates(device), physicalFormats: Array(Set(formats)),
                                  outputChannels: outputChannelCount(device), supportsDoP: supportsDoP)
    }

    static func volumeElements(_ device: AudioObjectID) -> [UInt32] {
        let main = AudioObjectPropertyAddress.output(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
        if HAL.has(device, main), HAL.isSettable(device, main) { return [kAudioObjectPropertyElementMain] }
        let channels = (1...2).map { UInt32($0) }.filter {
            let a = AudioObjectPropertyAddress.output(kAudioDevicePropertyVolumeScalar, element: $0)
            return HAL.has(device, a) && HAL.isSettable(device, a)
        }
        return channels
    }

    static func snapshot(_ id: AudioObjectID, defaultID: AudioObjectID?, dopEnabledUIDs: Set<String>) -> OutputDevice? {
        guard outputChannelCount(id) > 0 else { return nil }
        let uid = HAL.getString(id, .global(kAudioDevicePropertyDeviceUID)) ?? "\(id)"
        let transport = Transport((try? HAL.get(id, .global(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0)
        return OutputDevice(
            id: id,
            uid: uid,
            name: HAL.getString(id, .global(kAudioObjectPropertyName)) ?? "Unknown Device",
            manufacturer: HAL.getString(id, .global(kAudioObjectPropertyManufacturer)) ?? "",
            modelUID: HAL.getString(id, .global(kAudioDevicePropertyModelUID)),
            transport: transport,
            nominalSampleRate: (try? HAL.get(id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0,
            capabilities: capabilities(id, supportsDoP: dopEnabledUIDs.contains(uid)),
            hasHardwareVolume: !volumeElements(id).isEmpty,
            isDefault: id == defaultID)
    }

    static func outputDevices(dopEnabledUIDs: Set<String>) -> [OutputDevice] {
        let def = defaultOutputDeviceID()
        return allDeviceIDs().compactMap { snapshot($0, defaultID: def, dopEnabledUIDs: dopEnabledUIDs) }
            .filter { $0.transport != .aggregate || !$0.name.hasPrefix("CADefaultDeviceAggregate") }
    }
}
