//
// Vespertine — the Controls menu's Volume Up, Volume Down and Mute: which volume they move for the current output, and by how much.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Volume up, down and mute")
struct VolumeControlsTests {
    private func output(_ uid: String, hardwareVolume: Bool) -> OutputDevice {
        OutputDevice(id: 5, uid: uid, name: uid, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: 48_000,
                     capabilities: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false),
                     hasHardwareVolume: hardwareVolume, isDefault: false)
    }

    // MARK: Which volume

    @Test("A device with a hardware volume Core Audio exposes moves that; the bar shows the same")
    func hardwareRoute() {
        let dac = output("dac", hardwareVolume: true)
        #expect(VolumeControls.route(for: dac, usesAppVolume: false, hardwareLevelKnown: true) == .hardware)
        #expect(VolumeControls.route(for: dac, usesAppVolume: true, hardwareLevelKnown: true) == .hardware)
    }

    @Test("An output without one moves Vespertine's own volume when it uses it, else it is fixed")
    func softwareOrFixed() {
        let hdmi = output("hdmi", hardwareVolume: false)
        #expect(VolumeControls.route(for: hdmi, usesAppVolume: true, hardwareLevelKnown: false) == .software)
        #expect(VolumeControls.route(for: hdmi, usesAppVolume: false, hardwareLevelKnown: false) == .fixed)
        // A DAC that claims hardware volume but whose level can't be read is not driven blind.
        let odd = output("odd", hardwareVolume: true)
        #expect(VolumeControls.route(for: odd, usesAppVolume: false, hardwareLevelKnown: false) == .fixed)
        #expect(VolumeControls.route(for: odd, usesAppVolume: true, hardwareLevelKnown: false) == .software)
    }

    @Test("A speaker group has no hardware volume of its own: software when it is chosen, else fixed")
    func groupRoute() {
        let group = GroupOutput.presented(GroupFixtures.quad(), members: [])
        #expect(VolumeControls.route(for: group, usesAppVolume: true, hardwareLevelKnown: false) == .software)
        #expect(VolumeControls.route(for: group, usesAppVolume: false, hardwareLevelKnown: false) == .fixed)
    }

    @Test("With no output there is nothing to move")
    func noOutput() {
        #expect(VolumeControls.route(for: nil, usesAppVolume: true, hardwareLevelKnown: true) == .fixed)
    }

    // MARK: Steps

    @Test("Up and down move one sixteenth, on the sixteenths, and stop at the ends")
    func steps() {
        #expect(VolumeControls.apply(.up, to: .init(level: 0.5)).level == 0.5625)
        #expect(VolumeControls.apply(.down, to: .init(level: 0.5)).level == 0.4375)
        // Off the grid, a step goes to the next line in its direction.
        #expect(VolumeControls.apply(.up, to: .init(level: 0.43)).level == 0.4375)
        #expect(VolumeControls.apply(.down, to: .init(level: 0.43)).level == 0.375)
        #expect(VolumeControls.apply(.up, to: .init(level: 1)).level == 1)
        #expect(VolumeControls.apply(.down, to: .init(level: 0)).level == 0)
        #expect(VolumeControls.apply(.up, to: .init(level: 0.97)).level == 1)
        #expect(VolumeControls.apply(.down, to: .init(level: 0.03)).level == 0)
        var level = 0.0
        for _ in 0..<16 { level = VolumeControls.apply(.up, to: .init(level: level)).level }
        #expect(level == 1)
    }

    @Test("A level that is not a number is treated as silent, never passed on")
    func notANumber() {
        #expect(VolumeControls.apply(.up, to: .init(level: .nan)).level == 0.0625)
        #expect(VolumeControls.apply(.down, to: .init(level: .infinity)).level.isFinite)
    }

    // MARK: Mute

    @Test("Mute drops to zero and remembers the level; mute again brings it back")
    func muteAndBack() {
        let muted = VolumeControls.apply(.mute, to: .init(level: 0.6))
        #expect(muted.level == 0 && muted.restoreLevel == 0.6)
        let back = VolumeControls.apply(.mute, to: muted)
        #expect(back.level == 0.6 && back.restoreLevel == nil)
    }

    @Test("Volume Up while muted brings the old level back; Volume Down stays muted")
    func whileMuted() {
        let muted = VolumeControls.apply(.mute, to: .init(level: 0.6))
        let up = VolumeControls.apply(.up, to: muted)
        #expect(up.level == 0.6 && up.restoreLevel == nil)
        let down = VolumeControls.apply(.down, to: muted)
        #expect(down == muted)
    }

    @Test("Mute at zero with nothing remembered goes to a comfortable middle, not to silence again")
    func muteFromZero() {
        let result = VolumeControls.apply(.mute, to: .init(level: 0))
        #expect(result.level == VolumeControls.unmuteFallback && result.restoreLevel == nil)
        #expect(VolumeControls.unmuteFallback > 0 && VolumeControls.unmuteFallback < 1)
    }

    @Test("A level that was moved by hand after muting is not overwritten by the old one")
    func movedAfterMute() {
        // The remembered level only counts while the level is still zero.
        let state = VolumeControls.State(level: 0.3, restoreLevel: 0.9)
        #expect(VolumeControls.apply(.mute, to: state).restoreLevel == 0.3)
        #expect(VolumeControls.apply(.up, to: state).level == 0.3125)
    }
}
