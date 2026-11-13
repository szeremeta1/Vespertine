//
// Vespertine: a Bluetooth headset in call mode is reported, with the app holding its microphone. On 2026-11-13 Alex's AirPods
// Max spent eight minutes in call mode (24 kHz mono, no Spatial Audio) because System Settings' Sound pane metered their
// microphone, while Vespertine said "Spatial Audio on" and "24 kHz · IDLE". The processes below are the ones Core Audio
// reported on his Mac then.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

private let airPodsOutput = "70-F9-4A-BF-8C-C7:output"
private let vespertinePID: Int32 = 29289

private func airPods(rate: Double, channels: Int = 2, transport: Transport = .bluetooth) -> OutputDevice {
    OutputDevice(id: 7101, uid: airPodsOutput, name: "Alex’s AirPods Max", manufacturer: "Apple Inc.", modelUID: nil, transport: transport,
                 nominalSampleRate: rate,
                 capabilities: DeviceCapabilities(sampleRates: [24_000, 44_100, 48_000], physicalFormats: [], outputChannels: channels, supportsDoP: false),
                 hasHardwareVolume: true, isDefault: true)
}

private let soundPane = AudioInputProcess(pid: 19073, bundleID: "com.apple.Sound-Settings.extension", name: "Sound",
                                          inputDeviceUIDs: ["70-F9-4A-BF-8C-C7:input"])
private let teamsOnSamson = AudioInputProcess(pid: 4100, bundleID: "com.microsoft.teams2", name: "Microsoft Teams",
                                              inputDeviceUIDs: ["AppleUSBAudioEngine:Samson Technologies:Samson Q2U Microphone:2142100:2"])
private let speech = AudioInputProcess(pid: 1144, bundleID: nil, name: "corespeechd", inputDeviceUIDs: ["70-F9-4A-BF-8C-C7:input"])
private let otherHeadset = AudioInputProcess(pid: 5000, bundleID: "us.zoom.xos", name: "zoom.us", inputDeviceUIDs: ["04-2E-C1-67-71-EF:input"])

@Suite("Bluetooth call mode")
struct BluetoothCallModeTests {
    @Test("A Bluetooth output below 32 kHz is in call mode; A2DP rates, other transports and unknown rates are not")
    func detected() {
        #expect(airPods(rate: 24_000, channels: 1).isInCallMode)
        #expect(airPods(rate: 16_000, channels: 1, transport: .bluetoothLE).isInCallMode)
        // AirPods Max's HFP is stereo-capable: the rate decides, not the channel count.
        #expect(airPods(rate: 24_000, channels: 2).isInCallMode)
        #expect(!airPods(rate: 48_000).isInCallMode)
        #expect(!airPods(rate: 44_100).isInCallMode)
        #expect(!airPods(rate: 0).isInCallMode)
        #expect(!airPods(rate: 24_000, transport: .usb).isInCallMode)
        #expect(!airPods(rate: 24_000, transport: .builtIn).isInCallMode)
    }

    @Test("The headset's microphone is found by the Bluetooth address both its UIDs share")
    func sameHeadset() {
        #expect(MicrophoneUsers.sameHeadset("70-F9-4A-BF-8C-C7:input", airPodsOutput))
        #expect(!MicrophoneUsers.sameHeadset("04-2E-C1-67-71-EF:input", airPodsOutput))
        #expect(!MicrophoneUsers.sameHeadset("AppleUSBAudioEngine:Samson Technologies:Samson Q2U Microphone:2142100:2", airPodsOutput))
        // A UID without the address form only matches itself.
        #expect(MicrophoneUsers.sameHeadset("headset", "headset"))
        #expect(!MicrophoneUsers.sameHeadset("", ""))
    }

    @Test("Only the apps recording from this headset's microphone are named, never Vespertine itself, each once")
    func holders() {
        let me = AudioInputProcess(pid: vespertinePID, bundleID: "org.szeremeta.Vespertine", name: "Vespertine", inputDeviceUIDs: ["70-F9-4A-BF-8C-C7:input"])
        let twice = AudioInputProcess(pid: 19074, bundleID: "com.apple.Sound-Settings.extension", name: "Sound", inputDeviceUIDs: ["70-F9-4A-BF-8C-C7:input"])
        let names = MicrophoneUsers.holders(ofOutputUID: airPodsOutput, among: [teamsOnSamson, soundPane, me, otherHeadset, speech, twice],
                                            excludingPID: vespertinePID)
        #expect(names == ["System Settings", "Siri"])
    }

    @Test("System Settings' panes and the speech daemon get the names people know")
    func names() {
        #expect(MicrophoneUsers.displayName(soundPane) == "System Settings")
        #expect(MicrophoneUsers.displayName(AudioInputProcess(pid: 1, bundleID: "com.apple.systempreferences", name: "System Settings", inputDeviceUIDs: [])) == "System Settings")
        #expect(MicrophoneUsers.displayName(speech) == "Siri")
        #expect(MicrophoneUsers.displayName(teamsOnSamson) == "Microsoft Teams")
        #expect(MicrophoneUsers.displayName(AudioInputProcess(pid: 77, bundleID: nil, name: nil, inputDeviceUIDs: [])) == "an app (pid 77)")
    }

    @Test("Call mode names the device, its rate and who has the microphone")
    func callModeOf() throws {
        let mode = try #require(BluetoothCallMode.of(airPods(rate: 24_000, channels: 1), processes: [soundPane, teamsOnSamson], excludingPID: vespertinePID))
        #expect(mode == BluetoothCallMode(deviceName: "Alex’s AirPods Max", sampleRate: 24_000, microphoneUsers: ["System Settings"]))
        #expect(BluetoothCallMode.of(airPods(rate: 48_000), processes: [soundPane], excludingPID: vespertinePID) == nil)
        #expect(BluetoothCallMode.of(airPods(rate: 24_000, transport: .usb), processes: [soundPane], excludingPID: vespertinePID) == nil)
    }

    @Test("The explanation says what macOS did, who caused it and what to do, without blaming the music")
    func explanation() {
        let held = BluetoothCallMode(deviceName: "Alex’s AirPods Max", sampleRate: 24_000, microphoneUsers: ["System Settings"]).explanation
        #expect(held.contains("Alex’s AirPods Max"))
        #expect(held.contains("call mode"))
        #expect(held.contains("System Settings"))
        #expect(held.contains("24"))
        #expect(held.contains("Spatial Audio"))
        let unknown = BluetoothCallMode(deviceName: "Alex’s AirPods Max", sampleRate: 24_000, microphoneUsers: []).explanation
        #expect(unknown.contains("an app"))
        #expect(unknown.contains("call mode"))
        let two = BluetoothCallMode(deviceName: "AirPods", sampleRate: 16_000, microphoneUsers: ["System Settings", "Siri"]).explanation
        #expect(two.contains("System Settings") && two.contains("Siri"))
    }

    @Test("The output chip says call mode, not IDLE, and says macOS plays while its renderer does")
    func chip() {
        let callMode = airPods(rate: 24_000, channels: 1), a2dp = airPods(rate: 48_000)
        #expect(DeviceChipState.of(callMode, systemRendering: true, standingIn: false) == .callMode)
        #expect(DeviceChipState.of(callMode, systemRendering: false, standingIn: true) == .callMode)
        #expect(DeviceChipState.of(a2dp, systemRendering: true, standingIn: false) == .systemRenders)
        #expect(DeviceChipState.of(a2dp, systemRendering: false, standingIn: true) == .standingIn)
        #expect(DeviceChipState.of(a2dp, systemRendering: false, standingIn: false) == .idle)
    }

    @Test("Reading Core Audio's process list works on this Mac and never lists Vespertine's own test process as a holder")
    func liveListReads() {
        let names = MicrophoneUsers.holders(ofOutputUID: airPodsOutput, among: MicrophoneUsers.running(), excludingPID: getpid())
        #expect(names.allSatisfy { !$0.isEmpty })
    }
}
