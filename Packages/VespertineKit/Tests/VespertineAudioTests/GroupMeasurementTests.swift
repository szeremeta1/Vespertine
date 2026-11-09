//
// Vespertine: speaker groups: the measurement wizard on a group. The group is measured as the layout and channel map its drawing
// makes (a quad is a quad), the timing references come from a speaker on the clock leader (the one DAC that is never resampled),
// and the group plays for 15 s before the first sweep so the followers' drift correction has settled.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group measurement")
struct GroupMeasurementTests {
    private func setup(_ group: SpeakerGroup) throws -> GroupMeasurement.Setup {
        switch GroupMeasurement.setup(for: group) {
        case .success(let setup): return setup
        case .failure(let problem): throw problem
        }
    }

    @Test("The quad is measured as a quad on the group's own outputs, saved against the group's output UID")
    func quad() throws {
        let group = GroupFixtures.quad()
        let s = try setup(group)
        let fit = try #require(RoomLayout.layout(for: group))
        #expect(s.layout == .quad && s.layout == fit.layout)
        #expect(s.channelMap == fit.channelMap)
        #expect(s.deviceUID == group.outputUID)
        #expect(s.outputsNeeded == 4)
        #expect(s.speakers == [.left, .right, .leftSurround, .rightSurround], "in output order")
    }

    @Test("The timing references come from the clock leader: its first speaker, the left when it has it")
    func referenceOnLeader() throws {
        let group = GroupFixtures.quad()
        #expect(try setup(group).referenceSpeaker == .left)
        var follower = group
        follower.clockLeaderUID = GroupFixtures.fiio
        #expect(try setup(follower).referenceSpeaker == .leftSurround, "the FiiO is the leader here, so its first speaker keeps the time")
    }

    @Test("The group plays 15 s before the first sweep: what the hardware session found the follower needs")
    func settle() {
        #expect(GroupMeasurement.settleSeconds == 15)
    }

    @Test("Nothing to measure: no speaker on an output, or none on the leader, is said in words")
    func problems() {
        var empty = GroupFixtures.quad()
        empty.speakers = []
        #expect(GroupMeasurement.setup(for: empty) == .failure(.noSpeakers))
        var offLeader = GroupFixtures.quad()
        offLeader.speakers.removeAll { $0.deviceUID == GroupFixtures.fosi }
        #expect(GroupMeasurement.setup(for: offLeader) == .failure(.noSpeakerOnLeader))
        #expect(GroupMeasurement.Problem.noSpeakers.description.contains("Put the speakers"))
        #expect(GroupMeasurement.Problem.noSpeakerOnLeader.description.contains("clock leader"))
    }

    @Test("A whole run on the group, against a scripted room: every sweep is timed against the leader's speaker, and the profile fits the group")
    func wholeRun() async throws {
        let group = GroupFixtures.quad()
        let s = try setup(group)
        var settings = RoomMeasurementSettings(inputDevice: 91, outputDevice: 72)
        settings.sampleRate = 48_000
        settings.sweepSeconds = 1.5
        settings.positions = 1
        settings.minimumPeakToNoiseDB = 20
        settings.routeMinimumPeakToNoiseDB = 10
        settings.referenceSpeaker = s.referenceSpeaker
        var room = TestRoom()
        room.gain = [0: 0.05, 1: 0.04, 2: 0.045, 3: 0.035]
        room.delay = [0: 0.0081, 1: 0.0094, 2: 0.0120, 3: 0.0107]
        let scripted = room
        let capturer = ScriptedCapturer { r, _ in scripted.record(r) }
        let session = RoomSession(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000), deviceUID: s.deviceUID, layout: s.layout,
                                  channelMap: s.channelMap, mic: RoomMic(serial: "7001", orientation: .upward, calibrationSHA256: nil), target: .flat)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("group-measurement-\(UUID().uuidString)")
        let controller = RoomMeasurementController(settings: settings, session: session, capturer: capturer, folder: folder)
        let end = await controller.run()
        #expect(end == .completed, "\(end)")
        let sweeps = capturer.requests.filter { $0.layout.sweep.duration == settings.sweepSeconds }
        #expect(sweeps.count == 4)
        #expect(sweeps.allSatisfy { $0.referenceChannel == nil ? $0.outputChannel == 0 : $0.referenceChannel == 0 },
                "all four are timed by output 0, the leader's left; the left itself plays its own references")
        let result = try RoomMeasurementResult.make(recordings: controller.acceptedRecordings, session: controller.session, calibration: nil,
                                                    name: "Downstairs quad", micSerial: "7001")
        #expect(result.profile.applies(to: group))
        #expect(result.profile.alignment != nil, "timed against one speaker, so the delays between speakers mean something")
        // The nearest speaker waits for the farthest: output 2 (12 ms) is the latest, so the left (8.1 ms) waits about 3.9 ms.
        let waits = result.profile.alignment(for: .left).delayMs
        #expect(abs(waits - 3.9) < 0.3, "\(waits)")
        // How the group's aggregate clocked its DACs is kept with the profile, read from the output the sweeps played on.
        let clock = GroupClockContext(sampleRate: 48_000, members: [.init(uid: GroupFixtures.fosi, driftCorrected: false, driftQuality: 0),
                                                                    .init(uid: GroupFixtures.fiio, driftCorrected: true, driftQuality: 127)])
        var asked: (UInt32, Double)?
        let kept = try RoomMeasurementResult.make(recordings: controller.acceptedRecordings, session: controller.session, calibration: nil,
                                                  name: "Downstairs quad", micSerial: "7001", groupClock: { output, rate in asked = (output, rate); return clock })
        #expect(kept.profile.groupClock == clock)
        #expect(asked?.0 == 72 && asked?.1 == 48_000)
    }
}
