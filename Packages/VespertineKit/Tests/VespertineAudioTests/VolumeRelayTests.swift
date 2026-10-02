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
/// the keys and Control Center do, then puts every volume, mute, the alert volume and the sound output back.
@Suite("Volume relay", .serialized)
struct VolumeRelayTests {
    static let devices = ProcessInfo.processInfo.environment["VESPERTINE_RELAY_DEVICES"]
    static let volume = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    static let mute = AudioObjectPropertyAddress.output(kAudioDevicePropertyMute)

    private func level(_ d: AudioObjectID) -> Float32 { (try? HAL.get(d, Self.volume, initial: Float32(-1))) ?? -1 }
    private func muted(_ d: AudioObjectID) -> UInt32 { (try? HAL.get(d, Self.mute, initial: UInt32(9))) ?? 9 }
    private func settle() { Thread.sleep(forTimeInterval: 0.4) }
    private func putBackAlerts(_ alert: Int?) {
        if let alert, let now = AlertVolume.get() { AlertVolume.set(alert, ifStill: now) }
    }

    @Test("Keys and Control Center reach the held device; the stand-in gets its own volume back",
          .enabled(if: devices != nil))
    func relay() throws {
        let names = try #require(Self.devices).split(separator: "|").map(String.init)
        let all = OutputDevices.list()
        let held = try #require(all.first { $0.name.contains(names[0]) }).id
        let standIn = try #require(all.first { $0.name.contains(names[1]) }).id
        let originalOutput = try #require(DeviceControl.systemOutputDevice())
        let (heldVolume, heldMute, standInVolume, standInMute) = (level(held), muted(held), level(standIn), muted(standIn))
        let alert = AlertVolume.get()
        let relay = VolumeRelay()
        defer {
            relay.stop()
            try? HAL.set(held, Self.volume, heldVolume); try? HAL.set(held, Self.mute, heldMute)
            try? HAL.set(standIn, Self.volume, standInVolume); try? HAL.set(standIn, Self.mute, standInMute)
            putBackAlerts(alert)
            DeviceControl.setSystemOutputDevice(originalOutput)
            DeviceControl.releaseHog(held)
        }

        DeviceControl.setSystemOutputDevice(standIn)
        try HAL.set(held, Self.volume, Float32(0.40))
        #expect(DeviceControl.acquireHog(held))
        relay.follow(held)
        settle()
        #expect(abs(level(standIn) - 0.40) < 0.01, "the stand-in shows the held device's level")
        #expect(RelayChanges.load()?.standIn == HAL.getString(standIn, .global(kAudioDevicePropertyDeviceUID)),
                "what the relay changed is kept for a launch after a crash")
        // Where alerts play from the stand-in (Play sound effects through: the selected output), a louder stand-in
        // lowers the alert volume and a quieter one raises it.
        let effects = try? HAL.get(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDefaultSystemOutputDevice),
                                   initial: AudioObjectID(0))
        if effects == standIn, let alert, (2...99).contains(alert), abs(standInVolume - 0.40) > 0.1, let now = AlertVolume.get() {
            #expect(standInVolume < 0.40 ? now < alert : now > alert, "alert volume \(alert) → \(now)")
        }

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

        // A quick turn of a crown or knob on the held device: no step may be pulled back to an older level by the
        // stand-in's echo (on the AirPods Max nearly every step was), and both end where the turn stopped.
        let steps = (1...16).map { 0.55 + Float32($0) * 0.01 }
        let seen = Seen()
        var address = Self.volume
        let watch = DispatchQueue(label: "test")
        let block: AudioObjectPropertyListenerBlock = { _, _ in seen.add((try? HAL.get(held, Self.volume, initial: Float32(-1))) ?? -1) }
        AudioObjectAddPropertyListenerBlock(held, &address, watch, block)
        for step in steps {
            try HAL.set(held, Self.volume, step)
            Thread.sleep(forTimeInterval: 0.03)
        }
        settle(); settle()
        AudioObjectRemovePropertyListenerBlock(held, &address, watch, block)
        let values = seen.values
        let pulledBack = zip(values, values.dropFirst()).filter { $1 < $0 - 0.005 }
        #expect(pulledBack.isEmpty, "steps pulled back: \(pulledBack) in \(values)")
        #expect(abs(level(held) - 0.71) < 0.01)
        #expect(abs(level(standIn) - 0.71) < 0.01)

        DeviceControl.releaseHog(held)                      // pause long enough, or a shared device
        settle()
        #expect(abs(level(standIn) - standInVolume) < 0.01, "the stand-in gets its own volume back")
        #expect(AlertVolume.get() == alert, "and the alert volume its own value")
        #expect(RelayChanges.load() == nil)
        try HAL.set(standIn, Self.volume, Float32(0.10))
        settle()
        #expect(abs(level(held) - 0.71) < 0.01, "no relay without the hold")
        relay.stop()
    }

    /// Hardware test, silent: VESPERTINE_RELAY_DEVICES as above (only the stand-in is used). Leaves what a relay leaves
    /// when Vespertine crashes, then launches the way the app does.
    @Test("After a crash, the next launch puts back what the relay left, unless it was changed since",
          .enabled(if: devices != nil))
    func afterCrash() throws {
        let name = try #require(Self.devices).split(separator: "|").map(String.init)[1]
        let standIn = try #require(OutputDevices.list().first { $0.name.contains(name) }).id
        let uid = try #require(HAL.getString(standIn, .global(kAudioDevicePropertyDeviceUID)))
        let (volume, mute) = (level(standIn), muted(standIn))
        let alert = try #require(AlertVolume.get())
        defer {
            try? HAL.set(standIn, Self.volume, volume); try? HAL.set(standIn, Self.mute, mute)
            putBackAlerts(alert)
            RelayChanges.store(nil)
        }

        let lowered = alert == 37 ? 38 : 37
        try HAL.set(standIn, Self.volume, Float32(0.80))
        AlertVolume.set(lowered, ifStill: alert)
        RelayChanges.store(RelayChanges(standIn: uid, volume: 0.30, mute: mute, relayedVolume: 0.80, relayedMute: mute,
                                        alert: alert, alertSet: lowered))
        DeviceRestore.afterCrash()
        #expect(abs(level(standIn) - 0.30) < 0.01)
        #expect(AlertVolume.get() == alert)
        #expect(RelayChanges.load() == nil)

        try HAL.set(standIn, Self.volume, Float32(0.55))   // a key pressed after the crash
        RelayChanges.store(RelayChanges(standIn: uid, volume: 0.30, mute: mute, relayedVolume: 0.80, relayedMute: mute))
        DeviceRestore.afterCrash()
        #expect(abs(level(standIn) - 0.55) < 0.01, "a level set since is kept")
    }
}

@Suite("Volume relay: alerts and crash recovery")
struct VolumeRelayAlertTests {
    @Test("The alert volume moves by the stand-in's change in amplitude")
    func compensation() {
        #expect(AlertVolume.compensated(75, before: -20, now: -20) == 75)
        #expect(AlertVolume.compensated(80, before: -20, now: 0) == 8)      // 20 dB louder: a tenth
        #expect(AlertVolume.compensated(10, before: -26, now: -20) == 5)    // 6 dB louder: half
        #expect(AlertVolume.compensated(10, before: -20, now: -26) == 20)   // quieter: raised
    }

    @Test("Never above 100, never below 1 unless alerts were off")
    func bounds() {
        #expect(AlertVolume.compensated(50, before: -10, now: -30) == 100)
        #expect(AlertVolume.compensated(75, before: -60, now: 0) == 1)
        #expect(AlertVolume.compensated(0, before: -60, now: 0) == 0)
        #expect(AlertVolume.compensated(75, before: -20, now: -.infinity) == 100)  // the stand-in silenced
        #expect(AlertVolume.compensated(75, before: -.infinity, now: -20) == 1)    // it was silent
    }

    @Test("Without a device's own curve, levels taper like a volume curve")
    func fallbackCurve() {
        #expect(AlertVolume.decibels(1) == 0)
        #expect(abs(AlertVolume.decibels(0.5) + 12.04) < 0.01)
        #expect(AlertVolume.decibels(0.25) < AlertVolume.decibels(0.5))
        #expect(AlertVolume.decibels(0).isFinite)
    }

    @Test("After a crash, only what is still as the relay left it is put back")
    func putBack() {
        let left = RelayChanges(standIn: "BuiltInSpeakerDevice", volume: 0.3, mute: 0, relayedVolume: 1, relayedMute: 0,
                                alert: 75, alertSet: 4)
        let all = left.putBack(volume: 1, mute: 0, alert: 4)
        #expect(all.volume == 0.3 && all.mute == 0 && all.alert == 75)
        #expect(left.putBack(volume: 0.996, mute: 0, alert: 4).volume == 0.3, "the device's rounding of the level")
        let keys = left.putBack(volume: 0.94, mute: 1, alert: 4)
        #expect(keys.volume == nil && keys.mute == nil && keys.alert == 75, "volume and mute changed since")
        let settings = left.putBack(volume: 1, mute: 0, alert: 50)
        #expect(settings.alert == nil && settings.volume == 0.3, "alert volume changed since")
        let gone = left.putBack(volume: nil, mute: nil, alert: nil)
        #expect(gone.volume == nil && gone.mute == nil && gone.alert == nil, "stand-in unplugged, alert volume unreadable")
        let untouched = RelayChanges(standIn: "BuiltInSpeakerDevice", volume: 0.3, mute: 0).putBack(volume: 0.3, mute: 0, alert: 75)
        #expect(untouched.volume == nil && untouched.mute == nil && untouched.alert == nil, "nothing changed, nothing to undo")
    }

    @Test("What the relay changed stays in the defaults until it is put back")
    func record() throws {
        let suite = "org.szeremeta.vespertine.tests.relay-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RelayChanges.load(from: defaults) == nil)
        let left = RelayChanges(standIn: "BuiltInSpeakerDevice", volume: 0.3, mute: 0, relayedVolume: 0.8, relayedMute: 0,
                                alert: 75, alertSet: 9)
        RelayChanges.store(left, in: defaults)
        #expect(RelayChanges.load(from: defaults) == left)
        RelayChanges.store(nil, in: defaults)
        #expect(RelayChanges.load(from: defaults) == nil)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Float32] = []
    func add(_ v: Float32) { lock.lock(); list.append(v); lock.unlock() }
    var values: [Float32] { lock.lock(); defer { lock.unlock() }; return list }
}
