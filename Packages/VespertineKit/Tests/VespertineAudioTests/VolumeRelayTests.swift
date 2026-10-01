//
// Vespertine — the volume relay carries the sound output's volume to a device held exclusively.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

/// Hardware test, silent: VESPERTINE_RELAY_DEVICES="<held device>|<stand-in>" (names contain these), e.g. "Speakers|Teams".
/// Holds the first device exclusively (plays nothing), makes the second the sound output, moves volume and mute the way
/// the keys and Control Center do, then puts every volume, mute and the sound output back.
@Suite("Volume relay")
struct VolumeRelayTests {
    static let devices = ProcessInfo.processInfo.environment["VESPERTINE_RELAY_DEVICES"]
    static let volume = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    static let mute = AudioObjectPropertyAddress.output(kAudioDevicePropertyMute)

    private func level(_ d: AudioObjectID) -> Float32 { (try? HAL.get(d, Self.volume, initial: Float32(-1))) ?? -1 }
    private func muted(_ d: AudioObjectID) -> UInt32 { (try? HAL.get(d, Self.mute, initial: UInt32(9))) ?? 9 }
    private func settle() { Thread.sleep(forTimeInterval: 0.4) }

    @Test("Keys and Control Center reach the held device; the stand-in gets its own volume back",
          .enabled(if: devices != nil))
    func relay() throws {
        let names = try #require(Self.devices).split(separator: "|").map(String.init)
        let all = OutputDevices.list()
        let held = try #require(all.first { $0.name.contains(names[0]) }).id
        let standIn = try #require(all.first { $0.name.contains(names[1]) }).id
        let originalOutput = try #require(DeviceControl.systemOutputDevice())
        let (heldVolume, heldMute, standInVolume, standInMute) = (level(held), muted(held), level(standIn), muted(standIn))
        defer {
            try? HAL.set(held, Self.volume, heldVolume); try? HAL.set(held, Self.mute, heldMute)
            try? HAL.set(standIn, Self.volume, standInVolume); try? HAL.set(standIn, Self.mute, standInMute)
            DeviceControl.setSystemOutputDevice(originalOutput)
            DeviceControl.releaseHog(held)
        }

        DeviceControl.setSystemOutputDevice(standIn)
        try HAL.set(held, Self.volume, Float32(0.40))
        #expect(DeviceControl.acquireHog(held))
        let relay = VolumeRelay()
        relay.follow(held)
        settle()
        #expect(abs(level(standIn) - 0.40) < 0.01, "the stand-in shows the held device's level")

        try HAL.set(standIn, Self.volume, Float32(0.25))   // a volume key / the Control Center slider
        settle()
        #expect(abs(level(held) - 0.25) < 0.01)
        try HAL.set(standIn, Self.mute, UInt32(1))          // the mute key
        settle()
        #expect(muted(held) == 1)
        try HAL.set(standIn, Self.mute, UInt32(0))
        settle()
        #expect(muted(held) == 0)

        try HAL.set(held, Self.volume, Float32(0.55))       // Vespertine's own slider, or the DAC's knob
        settle()
        #expect(abs(level(standIn) - 0.55) < 0.01)

        DeviceControl.releaseHog(held)                      // pause long enough, or a shared device
        settle()
        #expect(abs(level(standIn) - standInVolume) < 0.01, "the stand-in gets its own volume back")
        try HAL.set(standIn, Self.volume, Float32(0.10))
        settle()
        #expect(abs(level(held) - 0.55) < 0.01, "no relay without the hold")
        relay.stop()
    }
}
