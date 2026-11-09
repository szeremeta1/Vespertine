//
// Vespertine: speaker groups: the wizard's skew step, on recordings made by hand (the references on the leader's slots, the follower's chirp
// a set number of frames behind) so no device is involved.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group skew measurement (wizard)")
struct GroupSkewMeasurementTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid"
    private let rate = 48_000.0

    private func group() -> SpeakerGroup {
        SpeakerGroup(name: "Downstairs quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2), SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: fosi,
                     speakers: [SpeakerGroup.Speaker(role: .frontRight, deviceUID: fosi, channel: 1, position: Point2D(x: 1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .frontLeft, deviceUID: fosi, channel: 0, position: Point2D(x: -1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .sideRight, deviceUID: fiio, channel: 1, position: Point2D(x: 2, y: 0)),
                                SpeakerGroup.Speaker(role: .sideLeft, deviceUID: fiio, channel: 0, position: Point2D(x: -2, y: 0))])
    }

    /// The references on the leader, the follower's chirp `offset` frames behind where a leader chirp would be, and (long captures) its second
    /// chirp `slip` more frames behind.
    private func recording(_ layout: RoomCaptureLayout, span: Bool, offset: Int, slip: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: layout.recordingFrames)
        let ref = layout.reference.samples.map { Float($0 * 0.01) }
        func put(at start: Int) { for (n, v) in ref.enumerated() where start + n < out.count { out[start + n] += v } }
        let slots = GroupSkew.followerChirpFrames(layout, span: span)
        put(at: layout.firstReferenceStart + 100)
        put(at: layout.secondReferenceStart + 100)
        put(at: slots.first + 100 + offset)
        if let second = slots.second { put(at: second + 100 + offset + slip) }
        return out
    }

    @Test("The pair to time: the leader's front left (wired first or not) against the follower's first wired channel, on aggregate channels")
    func pairs() {
        let pairs = GroupSkewMeasurement.pairs(for: group())
        #expect(pairs.count == 1)
        #expect(pairs[0].followerUID == fiio && pairs[0].leaderChannel == 0 && pairs[0].followerChannel == 2)
        #expect(pairs[0].leaderSpeaker.role == .frontLeft && pairs[0].followerSpeaker.role == .sideLeft)
    }

    @Test("A follower that is not drift-corrected: five short captures, the median skew less the path difference, saved with its settings")
    func shortOnly() async throws {
        // 600 frames = 12.5 ms behind at the mic; the side-left speaker is 0.575 ms farther than the front left.
        let out = await GroupSkewMeasurement.run(group: group(), rate: rate, corrected: []) { layout, leader, follower, span in
            #expect(leader == 0 && follower == 2 && !span)
            return recording(layout, span: false, offset: 600)
        }
        #expect(out.failures.isEmpty)
        let outcome = try #require(out.outcomes.first)
        #expect(outcome.goodRuns == 5 && outcome.rateTrimPPM == nil)
        let member = outcome.group.members[1]
        #expect(abs(member.skewMs - (12.5 - 0.575)) < 0.01, "skewMs \(member.skewMs)")
        #expect(member.skewContext == SpeakerGroup.Member.SkewContext(driftCorrected: false, driftQuality: 127, sampleRate: 48_000))
        #expect(member.rateTrimPPM == 0 && outcome.group.members[0].skewMs == 0)
        #expect(outcome.notes.contains { $0.contains("not drift-corrected") })
    }

    @Test("A drift-corrected follower: the long capture gives its rate, and the short ones are taken back to where it was when the output started")
    func withRate() async throws {
        // The follower is 600 frames behind at the start and creeps 13.5 ppm = 0.648 frames/s. The wizard's aggregate has been running 20 s + 8 s
        // per capture when each starts.
        let creepPerSecond = 13.5e-6 * rate
        let clock = Locked(20.0)
        let out = await GroupSkewMeasurement.run(group: group(), rate: rate, corrected: [fiio], secondsSinceOutputStarted: { clock.value }) { layout, _, _, span in
            let elapsed = clock.value
            clock.value += span ? 70 : 8
            if span {
                let slots = GroupSkew.followerChirpFrames(layout, span: true)
                let spacing = slots.second! - slots.first
                return recording(layout, span: true, offset: Int((600 + creepPerSecond * (elapsed + 2.1)).rounded()), slip: Int((13.5e-6 * Double(spacing)).rounded()))
            }
            return recording(layout, span: false, offset: Int((600 + creepPerSecond * (elapsed + 2.1)).rounded()))
        }
        #expect(out.failures.isEmpty)
        let outcome = try #require(out.outcomes.first)
        let ppm = try #require(outcome.rateTrimPPM)
        #expect(abs(ppm - 13.5) < 0.5, "rate \(ppm)")
        // Taken back to the start: 600 frames less the path (0.575 ms = 27.6 frames) = 572.4 frames = 11.925 ms, however late the capture was.
        #expect(abs(outcome.group.members[1].skewMs - 11.925) < 0.05, "skewMs \(outcome.group.members[1].skewMs)")
        #expect(abs(outcome.group.members[1].rateTrimPPM - ppm) < 1e-9)
        #expect(outcome.group.members[1].skewContext?.driftCorrected == true)
    }

    @Test("A capture that landed on a later copy of the chirp is left out; the median of the others stands")
    func outlierLeftOut() async throws {
        let count = Locked(0)
        let out = await GroupSkewMeasurement.run(group: group(), rate: rate, corrected: []) { layout, _, _, _ in
            count.value += 1
            return recording(layout, span: false, offset: count.value == 3 ? 786 : 600)
        }
        let outcome = try #require(out.outcomes.first)
        #expect(outcome.goodRuns == 4 && abs(outcome.skewFrames - 600) < 0.1)
        #expect(outcome.notes.contains { $0.contains("later copy") })
    }

    @Test("Silence is a failure with a reason, and the group is left as it was")
    func silence() async {
        let out = await GroupSkewMeasurement.run(group: group(), rate: rate, corrected: []) { layout, _, _, _ in [Float](repeating: 0, count: layout.recordingFrames) }
        #expect(out.outcomes.isEmpty && out.failures.count == 1)
        #expect(out.failures[0].contains("FiiO K11") && out.failures[0].contains("not measured"))
    }

    @Test("A follower whose speaker is at the seat has no distance: the whole number is kept and the notes say so")
    func noDistance() async throws {
        var g = group()
        g.speakers[3].position = Point2D(x: 0, y: 0)
        let out = await GroupSkewMeasurement.run(group: g, rate: rate, corrected: []) { layout, _, _, _ in recording(layout, span: false, offset: 600) }
        let outcome = try #require(out.outcomes.first)
        #expect(abs(outcome.group.members[1].skewMs - 12.5) < 0.01)
        #expect(outcome.notes.contains { $0.contains("no distance") })
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
