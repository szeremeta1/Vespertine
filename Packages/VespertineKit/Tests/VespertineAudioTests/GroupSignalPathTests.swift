//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

private let flac96 = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 4)

private func member(_ name: String, leader: Bool = false, resampled: Bool = false, _ speakers: [SpeakerRole],
                    rate: Double = 96_000, depth: Int = 32, integer: Bool = false, known: Bool = true,
                    exclusive: Bool = true, others: Bool = false) -> GroupSignalPath.Member {
    GroupSignalPath.Member(deviceUID: "uid-\(name)", name: name, isLeader: leader, resampled: resampled, speakers: speakers,
                           sampleRate: rate, physicalBitDepth: depth, physicalIsInteger: integer, physicalFormatKnown: known,
                           exclusive: exclusive, otherAppsPlaying: others)
}

private func quad(followerResampled: Bool = true, stage: GroupSignalPath.Stage = .none, source: SourceFormat = flac96) -> GroupSignalPath {
    GroupSignalPath(groupName: "Downstairs quad", source: source, folds: false, dsdConvertedToPCM: false, stage: stage, members: [
        member("Fosi ZD3", leader: true, [.frontLeft, .frontRight]),
        member("FiiO K11", resampled: followerResampled, [.sideLeft, .sideRight]),
    ])
}

@Suite("Speaker group signal path")
struct GroupSignalPathTests {
    @Test("A quad across two clocks is not bit-perfect: the follower is resampled, and the badge says so")
    func followerIsResampled() {
        let path = quad()
        #expect(!path.isBitPerfect)
        #expect(path.statusLine == "RESAMPLED")
        #expect(path.badges == ["RESAMPLED", "SPEAKER GROUP"])
        #expect(path.deviceProfile.kind == .speakerGroup)
        #expect(!path.deviceProfile.canBeBitPerfect)
    }

    @Test("Each DAC gets its own row: the leader's channels untouched, the follower's resampled to stay in step")
    func rows() {
        let rows = quad().rows
        #expect(rows.count == 2)
        #expect(rows[0] == "Fosi ZD3 · FL FR · clock leader · 32/96 · bit-perfect")
        #expect(rows[1] == "FiiO K11 · SL SR · follows Fosi ZD3, resampled to stay in step · 32/96")
    }

    @Test("Members that share a hardware clock need no drift correction and the group can be bit-perfect")
    func sharedClock() {
        let path = quad(followerResampled: false)
        #expect(path.isBitPerfect)
        #expect(path.statusLine == "BIT-PERFECT")
        #expect(path.badges == ["BIT-PERFECT", "SPEAKER GROUP"])
        #expect(path.deviceProfile.canBeBitPerfect)
        #expect(path.rows[1] == "FiiO K11 · SL SR · shares Fosi ZD3's clock · 32/96 · bit-perfect")
    }

    @Test("A song that only uses the leader's channels stays bit-perfect; the resampled follower is listed as unused")
    func followerUnused() {
        var path = quad()
        path.members[1].speakers = []
        path.source.channels = 2
        #expect(path.isBitPerfect)
        #expect(path.rows[1] == "FiiO K11 · not used by this song · follows Fosi ZD3, resampled to stay in step")
    }

    @Test("Integer-frame delays alone keep it bit-perfect; level, EQ and room filters do not, and are named")
    func processing() {
        #expect(quad(followerResampled: false, stage: .integerDelay).isBitPerfect)
        for (stage, badge) in [(GroupSignalPath.Stage.roomCorrection, "ROOM CORRECTION"), (.equalizer, "EQUALIZER"), (.gain, "DIGITAL GAIN")] {
            let path = quad(followerResampled: false, stage: stage)
            #expect(!path.isBitPerfect)
            #expect(path.statusLine == badge)
        }
    }

    @Test("A resampled follower is named before room correction: the first badge is the one that matters most")
    func resampledBeatsCorrection() {
        let path = quad(stage: .roomCorrection)
        #expect(path.badges == ["RESAMPLED", "ROOM CORRECTION", "SPEAKER GROUP"])
    }

    @Test("DSD played as PCM, a fold, a member format that isn't confirmed, a wrong rate or another app sharing a DAC each defeat bit-perfect")
    func defeaters() {
        var dsd = quad(followerResampled: false)
        dsd.dsdConvertedToPCM = true
        dsd.source = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 4)
        #expect(!dsd.isBitPerfect && dsd.statusLine == "Converted from DSD")

        var fold = quad(followerResampled: false)
        fold.folds = true
        #expect(!fold.isBitPerfect && fold.statusLine == "Downmixed")

        var unknown = quad(followerResampled: false)
        unknown.members[1].physicalFormatKnown = false
        #expect(!unknown.isBitPerfect && unknown.statusLine == "FORMAT UNCONFIRMED")

        var rate = quad(followerResampled: false)
        rate.members[0].sampleRate = 192_000
        #expect(!rate.isBitPerfect && rate.statusLine == "CONVERTED")

        var shared = quad(followerResampled: false)
        shared.members[0].exclusive = false
        shared.members[0].otherAppsPlaying = true
        #expect(!shared.isBitPerfect && shared.statusLine == "MIXED WITH OTHER APPS")
        shared.members[0].otherAppsPlaying = false
        #expect(shared.isBitPerfect)
    }

    @Test("A 16-bit integer device format holds a 16-bit source exactly, but not a 24-bit one (same rule as one DAC)")
    func depth() {
        var path = quad(followerResampled: false)
        for i in path.members.indices { path.members[i].physicalIsInteger = true; path.members[i].physicalBitDepth = 16 }
        #expect(!path.isBitPerfect)
        path.source.bitDepth = 16
        #expect(path.isBitPerfect)
    }

    @Test("The SignalPath badge for a group says SPEAKER GROUP, with RESAMPLED when a follower is, never BLUETOOTH")
    func signalPathBadge() {
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 96_000, decodedSampleRate: 96_000, physicalBitDepth: 32, channels: 4,
                              dsdConvertedToPCM: false, reason: "")
        let applied = AppliedFormat(sampleRate: 96_000, physicalBitDepth: 32, physicalIsInteger: false, virtualChannels: 4, exclusive: true, bufferFrames: 512)
        func line(_ path: GroupSignalPath, resampled: [String]) -> String {
            var sp = SignalPath(source: path.source, decoderName: "FLAC", plan: plan, applied: applied, deviceName: path.groupName,
                                deviceUID: "vespertine-group:x", deviceProfile: path.deviceProfile, volume: .fixed, replayGainDB: nil)
            sp.resampledMembers = resampled
            return sp.statusLine
        }
        #expect(line(quad(), resampled: ["FiiO K11"]) == "SPEAKER GROUP · RESAMPLED")
        #expect(line(quad(), resampled: []) == "SPEAKER GROUP")
        #expect(line(quad(followerResampled: false), resampled: []) == "BIT-PERFECT")
    }
}
