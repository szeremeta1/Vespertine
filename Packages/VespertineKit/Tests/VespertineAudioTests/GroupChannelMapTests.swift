//
// Vespertine — speaker groups: the channel map. Every channel of every output against the speaker role on it, edited one cell at a
// time, and the quiet tone that says which channel is which. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group channel map")
struct GroupChannelMapTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid"

    private func bare() -> SpeakerGroup {
        SpeakerGroup(name: "Dorm quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: fosi)
    }

    // MARK: Rows

    @Test("One row per channel of every output, in the aggregate's order, with nothing assigned in a new group")
    func rows() {
        let rows = GroupChannelMap.rows(bare())
        #expect(rows.count == 4)
        #expect(rows.map(\.aggregateChannel) == [0, 1, 2, 3])
        #expect(rows.map(\.deviceName) == ["Fosi ZD3", "Fosi ZD3", "FiiO K11", "FiiO K11"])
        #expect(rows.map(\.channelOnDevice) == [0, 1, 0, 1])
        #expect(rows.allSatisfy { $0.role == nil && !$0.inverted })
        #expect(rows.map(\.label) == ["Fosi ZD3 · channel 1", "Fosi ZD3 · channel 2", "FiiO K11 · channel 1", "FiiO K11 · channel 2"])
    }

    // MARK: Assigning

    @Test("A role put on a channel makes the speaker there; it starts where that role usually stands, 2 m from the seat")
    func assign() throws {
        let group = GroupChannelMap.assign(.frontLeft, toChannel: 0, of: fosi, in: bare())
        let speaker = try #require(group.speakers.first)
        #expect(speaker.role == .frontLeft && speaker.deviceUID == fosi && speaker.channel == 0)
        #expect(abs(SpeakerGeometryLite.distance(speaker.position) - 2) < 1e-9)
        #expect(SpeakerGeometryLite.azimuth(speaker.position).rounded() == -30)
        #expect(GroupChannelMap.rows(group).first?.role == .frontLeft)
        #expect(group.isValid, "\(group.issues)")
    }

    @Test("A role that is already on another channel moves: a role is in a group once")
    func moves() {
        var group = GroupChannelMap.assign(.frontLeft, toChannel: 0, of: fosi, in: bare())
        group = GroupChannelMap.assign(.frontLeft, toChannel: 1, of: fiio, in: group)
        #expect(group.speakers.count == 1)
        #expect(GroupChannelMap.rows(group).map(\.role) == [nil, nil, nil, .frontLeft])
        #expect(group.isValid, "\(group.issues)")
    }

    @Test("A different role on a channel that has a speaker keeps the speaker's place, trims and polarity")
    func reassign() throws {
        var group = GroupChannelMap.assign(.frontLeft, toChannel: 0, of: fosi, in: bare())
        group.speakers[0].position = Point2D(x: -1.2, y: 2)
        group.speakers[0].trimDB = -2
        group.speakers[0].delayTrimMs = 1.5
        group.speakers[0].invertPolarity = true
        let before = group.speakers[0]
        group = GroupChannelMap.assign(.center, toChannel: 0, of: fosi, in: group)
        let after = try #require(group.speakers.first)
        #expect(group.speakers.count == 1 && after.role == .center && after.id == before.id)
        #expect(after.position == before.position && after.trimDB == -2 && after.delayTrimMs == 1.5 && after.invertPolarity)
    }

    @Test("No role clears the channel")
    func clear() {
        var group = GroupChannelMap.assign(.frontLeft, toChannel: 0, of: fosi, in: bare())
        group = GroupChannelMap.assign(nil, toChannel: 0, of: fosi, in: group)
        #expect(group.speakers.isEmpty)
        #expect(GroupChannelMap.assign(nil, toChannel: 1, of: fosi, in: group) == group, "nothing there: nothing changes")
    }

    @Test("A channel the output doesn't have, or an output not in the group, changes nothing")
    func outOfRange() {
        let group = bare()
        #expect(GroupChannelMap.assign(.frontLeft, toChannel: 2, of: fosi, in: group) == group)
        #expect(GroupChannelMap.assign(.frontLeft, toChannel: 0, of: "nobody", in: group) == group)
        #expect(GroupChannelMap.assign(.frontLeft, toChannel: -1, of: fosi, in: group) == group)
    }

    @Test("The LFE has no place in the room: it goes in front of the seat, at the seat's side of the room")
    func lfePlace() throws {
        let group = GroupChannelMap.assign(.lfe, toChannel: 0, of: fosi, in: bare())
        let speaker = try #require(group.speakers.first)
        #expect(speaker.position != group.listener.position && group.isValid)
    }

    // MARK: Polarity

    @Test("Polarity is set on a channel's speaker; a channel with no speaker has none to set")
    func polarity() {
        var group = GroupChannelMap.assign(.frontLeft, toChannel: 0, of: fosi, in: bare())
        group = GroupChannelMap.setInverted(true, channel: 0, of: fosi, in: group)
        #expect(GroupChannelMap.rows(group).first?.inverted == true)
        #expect(GroupChannelMap.setInverted(true, channel: 1, of: fosi, in: group) == group)
    }

    // MARK: What is left to do

    @Test("The channels with no role, and the roles still free")
    func leftToDo() {
        var group = GroupChannelMap.assign(.frontLeft, toChannel: 0, of: fosi, in: bare())
        group = GroupChannelMap.assign(.frontRight, toChannel: 1, of: fosi, in: group)
        #expect(GroupChannelMap.unassigned(group).map(\.aggregateChannel) == [2, 3])
        #expect(!GroupChannelMap.freeRoles(group).contains(.frontLeft) && GroupChannelMap.freeRoles(group).contains(.center))
        #expect(GroupChannelMap.freeRoles(group).count == SpeakerRole.allCases.count - 2)
    }

    // MARK: Identify

    @Test("The identify tone is on the channel asked for and no other, quiet, and starts and ends at silence")
    func identifyOnOneChannel() {
        let tone = IdentifyTone.samples(channel: 2, channels: 4, rate: 48_000)
        #expect(tone.count % 4 == 0 && tone.count / 4 == Int(48_000 * IdentifyTone.seconds))
        for c in 0..<4 where c != 2 { #expect(stride(from: c, to: tone.count, by: 4).allSatisfy { tone[$0] == 0 }, "channel \(c) is silent") }
        let channel = stride(from: 2, to: tone.count, by: 4).map { tone[$0] }
        let peak = channel.map(abs).max() ?? 0
        #expect(peak > 0.005 && peak <= Float(pow(10, IdentifyTone.levelDB / 20)) * 1.0001, "peak \(peak)")
        #expect(channel.first == 0 && channel.last == 0)
    }

    @Test("It is noise with more low than high in it (pink), in bursts with gaps, the same every time")
    func identifyShape() {
        let a = IdentifyTone.samples(channel: 0, channels: 2, rate: 48_000)
        #expect(a == IdentifyTone.samples(channel: 0, channels: 2, rate: 48_000))
        let mono = stride(from: 0, to: a.count, by: 2).map { a[$0] }
        // Gaps: some stretch of a tenth of a second is silent.
        let window = 4_800
        let silentWindows = stride(from: 0, to: mono.count - window, by: window).filter { start in mono[start..<(start + window)].allSatisfy { $0 == 0 } }
        #expect(!silentWindows.isEmpty)
        // Tilt: a crude split by a one-pole low pass.
        var low: Float = 0, lowEnergy: Float = 0, highEnergy: Float = 0
        for x in mono { low += 0.05 * (x - low); lowEnergy += low * low; highEnergy += (x - low) * (x - low) }
        // White noise would have about 1.6% as much below this low pass as above it; pink has about two-thirds.
        #expect(lowEnergy / highEnergy > 0.2, "low \(lowEnergy), high \(highEnergy)")
    }

    @Test("A channel that isn't there is silence, and the tone adjusts to the rate")
    func identifyEdges() {
        #expect(IdentifyTone.samples(channel: 5, channels: 4, rate: 48_000).allSatisfy { $0 == 0 })
        #expect(IdentifyTone.samples(channel: 0, channels: 2, rate: 96_000).count == 2 * Int(96_000 * IdentifyTone.seconds))
        #expect(IdentifyTone.samples(channel: 0, channels: 0, rate: 48_000).isEmpty)
    }
}

/// The distance and azimuth of a point from the origin, facing +y, for checking where a speaker starts.
private enum SpeakerGeometryLite {
    static func distance(_ p: Point2D) -> Double { (p.x * p.x + p.y * p.y).squareRoot() }
    static func azimuth(_ p: Point2D) -> Double { atan2(p.x, p.y) * 180 / .pi }
}
