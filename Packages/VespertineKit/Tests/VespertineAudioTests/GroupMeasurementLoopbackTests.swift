//
// Vespertine — speaker groups: the measurement's output on a real group of two virtual devices. The aggregate keeps running on
// silence between captures (so a capture's player starting and stopping does not stop it), a capture's tone arrives on the one
// channel it was sent to, and releasing leaves no aggregate and no hold.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --no-parallel --filter GroupMeasurementLoopback
// Needs "Vespertine Loopback" and "BlackHole 2ch" (or VESPERTINE_GROUP_FOLLOWER), unused by other processes.
//

import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group measurement loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupMeasurementLoopbackTests {
    static let rate = 48_000.0

    private func devices() throws -> [OutputDevice] {
        let all = OutputDevices.list()
        let leader = try #require(all.first { $0.name == "Vespertine Loopback" && $0.transport == .virtual }, "no Vespertine Loopback")
        let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"
        let follower = try #require(all.first { $0.name == followerName && $0.transport == .virtual }, "no \(followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        try #require(AVAudioApplication.shared.recordPermission != .denied, "audio input access denied")
        return [leader, follower]
    }

    private func nominal(_ device: OutputDevice) -> Double {
        (try? HAL.get(device.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
    }

    @Test("Held on silence, a capture's tone arrives on its channel alone, the aggregate keeps running between captures, and release leaves nothing")
    func holdAndPlay() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let before = Set(DeviceQuery.allDeviceIDs())
        let group = SpeakerGroup(name: "Vespertine test group", members: members.map { .init(deviceUID: $0.uid, name: $0.name, channelCount: 2) },
                                 clockLeaderUID: members[0].uid)
        let output = try GroupMeasurementOutput.open(group: group, devices: members, rate: Self.rate)
        let aggregateUID = output.uid
        #expect(output.channels == 4 && !output.isRunning)
        try output.startHold()
        usleep(300_000)
        #expect(output.isHolding && output.isRunning)

        let recorder = try LoopbackRecorder(device: members[0].id, rate: Self.rate, maxChannels: 2)
        try recorder.start()
        defer { recorder.restore() }
        // 0.5 s of 1 kHz on the leader's second channel (aggregate channel 1).
        let tone = (0..<Int(Self.rate / 2)).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / Self.rate)) }
        let player = try RoomStimulusPlayer(device: output.deviceID, stimulus: RoomStimulus(tracks: [.init(channel: 1, samples: tone)]), rate: Self.rate)
        try player.start()
        usleep(900_000)
        recorder.drain()
        player.stop()
        usleep(200_000)
        #expect(output.isRunning, "the player stopped; the hold did not")
        recorder.stop()

        func rms(_ x: [Float]) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))) }
        let left = rms(recorder.samples[0]), right = rms(recorder.samples[1])
        #expect(right > 0.05, "the tone arrived on the right channel: \(right)")
        #expect(left < 0.001, "and not on the left: \(left)")

        output.release()
        #expect(GroupAggregateDevice.deviceID(uid: aggregateUID) == nil)
        for d in members { #expect(DeviceControl.hogOwner(d.id) == -1) }
        #expect(Set(DeviceQuery.allDeviceIDs()) == before)
    }
}
