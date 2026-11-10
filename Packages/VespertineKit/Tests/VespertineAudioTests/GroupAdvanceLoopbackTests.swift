//
// Vespertine: a queue played on a speaker group moves on by itself: song one ends, song two plays, with no skip. Run on the real
// engine and a real aggregate of two virtual devices (the same pair as GroupEngineLoopbackTests), with the speaker layout of a
// four-speaker group on two stereo DACs. Every queue step is counted from the engine's own `trackStarted` events, and the
// buffer underruns the engine reports are read at the end.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --filter GroupAdvanceLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes. Nothing is audible: the devices are virtual.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group advance loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupAdvanceLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"

    private func devices() throws -> [OutputDevice] {
        let all = DeviceQuery.outputDevices(dopEnabledUIDs: [])
        let leader = try #require(all.first { $0.name == Self.leaderName && $0.transport == .virtual }, "no \(Self.leaderName)")
        let follower = try #require(all.first { $0.name == Self.followerName && $0.transport == .virtual }, "no \(Self.followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        return [leader, follower]
    }

    /// Two stereo outputs carrying four speakers: front left/right on the first, back left/right on the second, the stereo song
    /// sent to every speaker (the layout of a bar and two rear speakers).
    private func quadGroup(_ members: [OutputDevice]) throws -> SpeakerGroup {
        func speaker(_ role: String, _ channel: Int, _ uid: String, _ x: Double, _ y: Double) -> [String: Any] {
            ["channel": channel, "delayTrimMs": 0, "deviceUID": uid, "id": UUID().uuidString, "invertPolarity": false,
             "position": ["x": x, "y": y], "role": role, "trimDB": 0]
        }
        let json: [String: Any] = [
            "clockLeaderUID": members[0].uid, "id": UUID().uuidString, "lfePolicy": ["toAll": ["dB": -10]],
            "listener": ["facingDegrees": 0, "position": ["x": 0.5, "y": 0]],
            "members": members.map { ["channelCount": 2, "deviceUID": $0.uid, "driftQuality": 127, "extraLatencyFrames": 0,
                                       "name": $0.name, "rateTrimPPM": 0, "skewMs": 0] as [String: Any] },
            "name": "Advance test group", "onMemberLoss": "pause", "schemaVersion": 1,
            "speakers": [speaker("FL", 0, members[0].uid, 0.03, 0.82), speaker("FR", 1, members[0].uid, 0.97, 0.82),
                         speaker("BL", 0, members[1].uid, -2, -1), speaker("BR", 1, members[1].uid, -1.1, -1)],
            "stereoPolicy": ["allSpeakers": [:] as [String: Any]],
        ]
        return try JSONDecoder().decode(SpeakerGroup.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func nominal(_ device: OutputDevice) -> Double {
        (try? HAL.get(device.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
    }

    private struct Run {
        var started: [UUID] = []
        var stateAtEnd = ""
        var underruns = 0
    }

    /// Plays `songs` in order on the group, with no input, and reports which of them started, within `seconds`.
    private func play(songs: [PlayableItem], seconds: Double, rate: Double) throws -> Run {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) where r > 0 { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let group = try quadGroup(members)
        var settings = EngineSettings()
        settings.exclusive = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_EXCLUSIVE"] == "1"
        settings.deviceUID = group.outputUID
        settings.deviceName = group.name
        settings.speakerGroups = [group]
        let engine = PlaybackEngine()
        let started = Locked<[UUID]>([])
        engine.eventHandler = { event in if case .trackStarted(let item) = event { started.withLock { $0.append(item.id) } } }
        let order = songs.map(\.id)
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        engine.nextItemProvider = { finished in order.firstIndex(of: finished.id).flatMap { $0 + 1 < order.count ? byID[order[$0 + 1]] : nil } }
        engine.update(settings: settings)
        Thread.sleep(forTimeInterval: 0.2)
        engine.play(songs[0])
        let begun = Date()
        var maxUnderruns = 0
        while Date().timeIntervalSince(begun) < seconds {
            Thread.sleep(forTimeInterval: 0.02)
            maxUnderruns = max(maxUnderruns, engine.snapshot.underruns)
            if started.withLock({ $0.count }) == songs.count, engine.snapshot.state == .stopped { break }
        }
        let run = Run(started: started.withLock { $0 }, stateAtEnd: "\(engine.snapshot.state)", underruns: max(maxUnderruns, engine.snapshot.underruns))
        engine.stopAndWait()
        return run
    }

    /// Songs far longer than the output's ring (about 22 s), as a real queue's are: the next one is lined up while the first still plays.
    @Test("Two songs on a group: the second starts by itself", arguments: [(96_000.0, 96_000.0), (96_000.0, 44_100.0), (44_100.0, 96_000.0)])
    func advances(rates: (Double, Double)) throws {
        let (r1, r2) = rates
        let a = try writeWAV("adv-a", rate: r1, bits: 24, seconds: 30) { c, i in 0.2 * Float(sin(2 * Double.pi * (440 + 110 * Double(c)) * Double(i) / r1)) }
        let b = try writeWAV("adv-b", rate: r2, bits: 24, seconds: 8) { c, i in 0.2 * Float(sin(2 * Double.pi * (660 + 110 * Double(c)) * Double(i) / r2)) }
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let first = PlayableItem(url: a), second = PlayableItem(url: b)
        let run = try play(songs: [first, second], seconds: 60, rate: r1)
        #expect(run.started == [first.id, second.id], "\(r1) -> \(r2): started \(run.started.count) of 2; ended \(run.stateAtEnd)")
        #expect(run.underruns == 0, "\(r1) -> \(r2): \(run.underruns) underruns")
    }

    /// The same on songs that come from a network share, the next one's copy slower than its own playing: the group still moves on,
    /// and the output does not run dry while the next song's copy is waited for (the first song's ring holds what is left of it).
    @Test("Two songs from a share on a group: the second starts by itself", arguments: [50.0, 0.4])
    func advancesFromShare(nextMBps: Double) async throws {
        let rig = try PlayPauseRig(seconds: 40, nextBytesPerSecond: nextMBps * 1_048_576)
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) where r > 0 { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let group = try quadGroup(members)
        let engine = PlaybackEngine()
        engine.cacheOverride = rig.cache
        var settings = EngineSettings()
        settings.exclusive = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_EXCLUSIVE"] == "1"
        settings.deviceUID = group.outputUID
        settings.deviceName = group.name
        settings.speakerGroups = [group]
        let first = rig.item(), second = rig.nextItem()
        let started = Locked<[UUID]>([])
        engine.eventHandler = { event in if case .trackStarted(let item) = event { started.withLock { $0.append(item.id) } } }
        engine.nextItemProvider = { $0.id == first.id ? second : nil }
        engine.update(settings: settings)
        try await Task.sleep(for: .milliseconds(200))
        engine.play(first)
        let begun = Date()
        var maxUnderruns = 0
        while Date().timeIntervalSince(begun) < 120 {
            try await Task.sleep(for: .milliseconds(20))
            maxUnderruns = max(maxUnderruns, engine.snapshot.underruns)
            if started.withLock({ $0.count }) == 2 { break }
        }
        let ids = started.withLock { $0 }
        let state = "\(engine.snapshot.state)"
        engine.stopAndWait()
        #expect(ids == [first.id, second.id], "next song at \(nextMBps) MB/s: started \(ids.count) of 2; ended \(state)")
        #expect(maxUnderruns == 0, "next song at \(nextMBps) MB/s: \(maxUnderruns) underruns")
    }
}
