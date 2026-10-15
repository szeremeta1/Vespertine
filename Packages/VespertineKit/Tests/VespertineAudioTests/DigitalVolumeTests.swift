//
// Vespertine — which outputs get digital volume: an output's own choice first, then the default, never one with
// hardware volume.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

private func output(_ uid: String, hardwareVolume: Bool = false) -> OutputDevice {
    OutputDevice(id: 0, uid: uid, name: uid, manufacturer: "", modelUID: nil, transport: .hdmi, nominalSampleRate: 48_000,
                 capabilities: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false),
                 hasHardwareVolume: hardwareVolume, isDefault: false)
}

@Suite("Digital volume per output")
struct DigitalVolumeTests {
    @Test("An output's own choice wins over the default, and hardware volume wins over both")
    func perOutput() {
        var s = EngineSettings()
        s.preferHardwareVolume = true
        #expect(s.digitalVolume(for: output("HDMI")) == nil)

        s.deviceDigitalVolumes = ["HDMI": -12]
        #expect(s.digitalVolume(for: output("HDMI")) == -12)
        #expect(s.digitalVolume(for: output("DAC")) == nil)
        #expect(s.digitalVolume(for: output("HDMI", hardwareVolume: true)) == nil)

        s.digitalVolumeDB = -6
        s.deviceDigitalVolumes.updateValue(nil, forKey: "Line out")
        #expect(s.digitalVolume(for: output("DAC")) == -6)
        #expect(s.digitalVolume(for: output("Line out")) == nil)
        #expect(s.digitalVolume(for: output("HDMI")) == -12)
        #expect(s.digitalVolume(for: nil) == -6)
    }
}
