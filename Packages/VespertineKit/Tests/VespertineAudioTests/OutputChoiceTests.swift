//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

private func output(_ uid: String, _ name: String, _ transport: Transport, rates: [Double] = [44_100, 48_000], depths: [Int] = [24],
                    isDefault: Bool = false, dop: Bool = false, model: String? = nil, id: UInt32 = 0) -> OutputDevice {
    let formats = depths.map { PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: $0, isInteger: true, isMixable: true, channels: 2) }
    return OutputDevice(id: id, uid: uid, name: name, manufacturer: "", modelUID: model, transport: transport, nominalSampleRate: rates[0],
                        capabilities: DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: 2, supportsDoP: dop),
                        hasHardwareVolume: true, isDefault: isDefault)
}

private let speakers = output("BuiltInSpeakerDevice", "MacBook Pro Speakers", .builtIn, rates: [44_100, 48_000, 88_200, 96_000])
private let k11 = output("AppleUSBAudioEngine:FiiO:FiiO K11:1100000:1", "FiiO K11", .usb,
                         rates: [44_100, 48_000, 96_000, 192_000, 384_000], depths: [16, 24, 32], model: "K11")
private let zoom = output("ZoomAudioDevice", "ZoomAudioDevice", .virtual, rates: [48_000], isDefault: true)
private let airPods = output("AA-BB-CC:output", "Alex's AirPods Max", .bluetooth, rates: [48_000])

@Suite("Output choice")
struct OutputChoiceTests {
    @Test("The best connected output: an external DAC over the Mac's sound output and speakers")
    func externalFirst() {
        #expect(OutputChoice.best(among: [speakers, k11, airPods])?.uid == k11.uid)
        #expect(OutputChoice.best(among: [speakers, airPods])?.uid == speakers.uid)
        let airPodsDefault = output(airPods.uid, airPods.name, .bluetooth, rates: [48_000], isDefault: true)
        #expect(OutputChoice.best(among: [speakers, airPodsDefault])?.uid == airPods.uid)
    }

    @Test("Virtual outputs are a last resort, even as the Mac's sound output")
    func virtualLast() {
        #expect(OutputChoice.best(among: [zoom, speakers])?.uid == speakers.uid)
        #expect(OutputChoice.best(among: [zoom])?.uid == zoom.uid)
        #expect(OutputChoice.best(among: []) == nil)
    }

    @Test("Each setting picks its stand-in, or none")
    func fallbacks() {
        let defaultSpeakers = output(speakers.uid, speakers.name, .builtIn, isDefault: true)
        #expect(OutputChoice.substitute(among: [defaultSpeakers, k11], fallback: .bestAvailable)?.uid == k11.uid)
        #expect(OutputChoice.substitute(among: [defaultSpeakers, k11], fallback: .systemDefault)?.uid == speakers.uid)
        #expect(OutputChoice.substitute(among: [defaultSpeakers, k11], fallback: .waitForChosen) == nil)
    }

    @Test("A DAC under a new UID (another USB port) is recognized; two identical ones are not guessed between")
    func sameOutput() {
        let remembered = OutputIdentity(k11)
        let moved = output("AppleUSBAudioEngine:FiiO:FiiO K11:2200000:1", "FiiO K11", .usb, model: "K11")
        #expect(OutputChoice.sameOutput(as: remembered, among: [speakers, moved])?.uid == moved.uid)
        #expect(OutputChoice.sameOutput(as: remembered, among: [speakers, k11, moved]) == nil)   // still there as it was
        let twin = output("AppleUSBAudioEngine:FiiO:FiiO K11:3300000:1", "FiiO K11", .usb, model: "K11")
        #expect(OutputChoice.sameOutput(as: remembered, among: [moved, twin]) == nil)
        let bluetooth = output("K11-BT", "FiiO K11", .bluetooth)
        #expect(OutputChoice.sameOutput(as: remembered, among: [bluetooth]) == nil)
    }
}
