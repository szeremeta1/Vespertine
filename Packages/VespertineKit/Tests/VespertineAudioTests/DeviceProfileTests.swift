//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Testing
@testable import VespertineAudio

private func builtIn(_ name: String, uid: String) -> OutputDevice {
    OutputDevice(id: 0, uid: uid, name: name, manufacturer: "Apple Inc.", modelUID: nil, transport: .builtIn, nominalSampleRate: 48_000,
                 capabilities: DeviceCapabilities(sampleRates: [44_100, 48_000, 88_200, 96_000], physicalFormats: [], outputChannels: 2,
                                                  supportsDoP: false),
                 hasHardwareVolume: true, isDefault: true)
}

@Suite("Device profiles")
struct DeviceProfileTests {
    @Test("The Mac's own speakers are never bit-perfect, whatever language macOS names them in", arguments: [
        "MacBook Pro Speakers", "Haut-parleurs MacBook Pro", "MacBook Pro-Lautsprecher", "MacBook Proのスピーカー", "Altavoces del Mac mini",
    ])
    func speakersInEveryLanguage(name: String) {
        let profile = DeviceProfile.detect(builtIn(name, uid: "BuiltInSpeakerDevice"))
        #expect(profile.kind == .speakers)
        #expect(!profile.canBeBitPerfect)
    }

    @Test("The built-in headphone output stays a bit-perfect candidate, whatever language macOS names it in", arguments: [
        "External Headphones", "Écouteurs externes", "Externe Kopfhörer", "外部ヘッドフォン",
    ])
    func headphonesInEveryLanguage(name: String) {
        let profile = DeviceProfile.detect(builtIn(name, uid: "BuiltInHeadphoneOutputDevice"))
        #expect(profile.kind == .builtIn)
        #expect(profile.canBeBitPerfect)
    }

    @Test("One built-in output for both (Intel Macs): its data source decides, not its name")
    func dataSourceDecides() {
        var speakers = builtIn("Sortie intégrée", uid: "AppleHDAEngineOutput:1B,0,1,1:0")
        speakers.builtInDataSource = DeviceProfile.internalSpeakerSource
        #expect(DeviceProfile.detect(speakers).kind == .speakers)
        var headphones = builtIn("Sortie intégrée", uid: "AppleHDAEngineOutput:1B,0,1,1:0")
        headphones.builtInDataSource = DeviceProfile.headphonesSource
        #expect(DeviceProfile.detect(headphones).kind == .builtIn)
        #expect(DeviceProfile.detect(headphones).canBeBitPerfect)
    }
}
