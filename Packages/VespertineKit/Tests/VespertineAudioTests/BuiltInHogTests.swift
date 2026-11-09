//
// Vespertine: the Mac's built-in output is never taken exclusively, even when the DoP or bitstream setting names it (its passthrough
// plan then fails honestly instead of taking the device away from the system).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

@Suite("Exclusive access by output")
struct BuiltInHogTests {
    private func device(_ transport: Transport) -> OutputDevice {
        OutputDevice(id: 0, uid: "out", name: "Output", manufacturer: "", modelUID: nil, transport: transport, nominalSampleRate: 48_000,
                     capabilities: DeviceCapabilities(sampleRates: [44_100, 48_000], physicalFormats: [], outputChannels: 2, supportsDoP: true),
                     hasHardwareVolume: true, isDefault: true)
    }

    private func plan(_ mode: OutputPlan.Mode) -> OutputPlan {
        var plan = OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000, physicalBitDepth: 24, channels: 2,
                              dsdConvertedToPCM: false, reason: "")
        plan.mode = mode
        return plan
    }

    @Test("The built-in output is never held, whatever the plan or the exclusive setting", arguments: [OutputPlan.Mode.pcm, .dop, .bitstream])
    func builtInNeverHeld(mode: OutputPlan.Mode) {
        #expect(!PlaybackEngine.takesDevice(device(.builtIn), plan: plan(mode), exclusiveSetting: true))
        #expect(!PlaybackEngine.takesDevice(device(.builtIn), plan: plan(mode), exclusiveSetting: false))
    }

    @Test("Other outputs: held when exclusive is on, and always for DoP and bitstream")
    func othersAsBefore() {
        #expect(PlaybackEngine.takesDevice(device(.usb), plan: plan(.pcm), exclusiveSetting: true))
        #expect(!PlaybackEngine.takesDevice(device(.usb), plan: plan(.pcm), exclusiveSetting: false))
        #expect(PlaybackEngine.takesDevice(device(.usb), plan: plan(.dop), exclusiveSetting: false))
        #expect(PlaybackEngine.takesDevice(device(.hdmi), plan: plan(.bitstream), exclusiveSetting: false))
    }
}
