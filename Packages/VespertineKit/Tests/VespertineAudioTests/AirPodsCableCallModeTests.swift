//
// Vespertine: AirPods Max with the USB-C cable in are only on the cable while macOS sends the audio down it. When an app opens
// their microphone, macOS moves the audio back to Bluetooth in call mode (24 kHz, mono) with the cable still in, on the same
// Core Audio device (the 2026-11-13 laptop logs: `HFP Shim Configured … 24000 Channels 1` at 16:51:43.618, 34 s after the cable
// went in). Vespertine judged "on the cable" by the cable's USB interface being attached, so it called that call-mode link
// "USB-C · LOSSLESS", held it and asked it for 48 kHz: the request macOS refuses while the microphone is open (1.1.1's '!dat').
// The link's own state decides: a call-mode rate, or Bluetooth's latency (7680 frames; 480 on the cable), means Bluetooth.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// AirPods Max as macOS lists them: one Bluetooth device whether the audio runs over the radio or the cable.
private func airPodsMax(rate: Double, channels: Int = 2, latency: Int? = nil, cable: Bool) -> OutputDevice {
    var device = OutputDevice(id: 7101, uid: "70-F9-4A-BF-8C-C7:output", name: "Alex’s AirPods Max", manufacturer: "Apple Inc.",
                              modelUID: nil, transport: .bluetooth, nominalSampleRate: rate,
                              capabilities: DeviceCapabilities(sampleRates: [24_000, 44_100, 48_000], physicalFormats: [],
                                                               outputChannels: channels, supportsDoP: false),
                              hasHardwareVolume: true, isDefault: true)
    device.outputLatencyFrames = latency
    device.airPodsMaxCableAttached = cable
    return device
}

@Suite("AirPods Max: cable in, call mode")
struct AirPodsCableCallModeTests {
    @Test("Cable in and the audio on it (48 kHz, USB latency): lossless over USB-C, as before")
    func onTheCable() {
        for latency in [480, nil] as [Int?] {
            let device = airPodsMax(rate: 48_000, latency: latency, cable: true)
            #expect(device.profile.kind == .airPodsMaxUSB)
            #expect(!device.isBluetoothLink)
        }
    }

    @Test("Cable in but a microphone open: the 24 kHz mono call mode is Bluetooth, not USB-C lossless")
    func callModeWithTheCableIn() {
        let device = airPodsMax(rate: 24_000, channels: 1, latency: 7_680, cable: true)
        #expect(device.profile.kind == .airPodsMaxBluetooth)
        #expect(device.isBluetoothLink)
        #expect(device.isInCallMode)
        // Never held, never asked for another rate: the plan uses the rate the link is at.
        #expect(device.alwaysShared)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 24_000, decodedSampleRate: 96_000, physicalBitDepth: 24, channels: 1,
                              dsdConvertedToPCM: false, reason: "")
        #expect(!PlaybackEngine.takesDevice(device, plan: plan, exclusiveSetting: true))
        #expect(device.planningCapabilities.sampleRates == [24_000])
    }

    @Test("Cable in but the audio still on the radio (A2DP 48 kHz at Bluetooth's latency): Bluetooth")
    func radioWithTheCableIn() {
        let device = airPodsMax(rate: 48_000, latency: 7_680, cable: true)
        #expect(device.profile.kind == .airPodsMaxBluetooth)
        #expect(device.isBluetoothLink)
    }

    @Test("The signal path of a call-mode link with the cable in says call mode, and never bit-perfect")
    func signalPathSaysCallMode() {
        let device = airPodsMax(rate: 24_000, channels: 1, latency: 7_680, cable: true)
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2)
        let plan = FormatPlanner.plan(source: source, device: device.planningCapabilities)
        let path = SignalPath(source: source, decoderName: "test", plan: plan,
                              applied: AppliedFormat(sampleRate: 24_000, physicalBitDepth: 16, physicalIsInteger: true, virtualChannels: 1,
                                                     exclusive: false, bufferFrames: 512),
                              deviceName: device.name, deviceUID: device.uid, deviceProfile: device.profile, volume: .hardware)
        #expect(path.isBluetoothCallMode)
        #expect(path.bluetoothNote != nil)
        #expect(!path.isBitPerfect)
    }

    @Test("No cable: Bluetooth, whatever the rate")
    func noCable() {
        #expect(airPodsMax(rate: 48_000, latency: 480, cable: false).profile.kind == .airPodsMaxBluetooth)
        #expect(airPodsMax(rate: 24_000, channels: 1, cable: false).profile.kind == .airPodsMaxBluetooth)
    }
}
