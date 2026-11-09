//
// Vespertine — speaker groups: when a group's signal path stays bit-perfect. A song that only the leader plays can be, and a
// delay in whole frames (room correction's timing alone) only shifts the samples; a level, a band, a filter or a follower in
// use cannot. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group bit-perfect")
struct GroupBitPerfectTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid"

    private func group(stereo: StereoPolicy = .frontOnly) -> SpeakerGroup {
        SpeakerGroup(name: "Downstairs quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: fosi,
                     speakers: [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: fosi, channel: 0, position: Point2D(x: -1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .frontRight, deviceUID: fosi, channel: 1, position: Point2D(x: 1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .sideLeft, deviceUID: fiio, channel: 0, position: Point2D(x: -2, y: 0)),
                                SpeakerGroup.Speaker(role: .sideRight, deviceUID: fiio, channel: 1, position: Point2D(x: 2, y: 0))],
                     stereoPolicy: stereo)
    }

    private func applied(known: Bool = true, exclusive: Bool = true, rate: Double = 96_000) -> AppliedFormat {
        let g = group()
        let plan = (try? GroupAggregate.plan(for: g, clockDomain: { _ in 0 }))!
        func read(_ uid: String) -> GroupMemberSession.Member {
            GroupMemberSession.Member(uid: uid, deviceID: 1, rateBefore: 48_000, rate: rate, streamRates: [rate], exclusive: exclusive,
                                      physicalBitDepth: 32, physicalIsInteger: true, physicalFormatKnown: known)
        }
        var format = AppliedFormat(sampleRate: rate, physicalBitDepth: 32, physicalIsInteger: true, virtualChannels: 4, exclusive: exclusive,
                                   bufferFrames: 512, streamCount: 2)
        format.members = GroupApplied.members(group: g, plan: plan, readback: [read(fosi), read(fiio)])
        return format
    }

    private func source(channels: Int, rate: Double = 96_000, bits: Int = 24) -> SourceFormat {
        SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: rate, bitDepth: bits, channels: channels)
    }

    private func room(delayMs: Double = 0, levelDB: Double = 0, preampDB: Double = 0, bands: [EQBand] = [], impulse: RoomImpulse? = nil,
                      channels: Int = 4) -> RoomCorrectionPlayback {
        RoomCorrectionPlayback(profileID: UUID(), name: "Timing", preampDB: preampDB,
                               channels: (0..<channels).map { RoomChannelPlayback(delayMs: $0 == 0 ? delayMs : 0, levelDB: levelDB, bands: bands, impulse: impulse) })
    }

    // MARK: Timing alone

    @Test("A room correction that only delays changes the timing, nothing else; a level, preamp, band or filter changes the samples")
    func timingOnly() {
        #expect(room(delayMs: 12.95).changesOnlyTiming(channels: 0..<4))
        #expect(room().changesOnlyTiming(channels: 0..<4))
        #expect(!room(delayMs: 3, levelDB: -1).changesOnlyTiming(channels: 0..<4))
        #expect(!room(delayMs: 3, preampDB: -2).changesOnlyTiming(channels: 0..<4))
        #expect(!room(bands: [EQBand(kind: .peak, frequency: 100, gainDB: -3, q: 1)]).changesOnlyTiming(channels: 0..<4))
        #expect(!room(impulse: RoomImpulse(file: "x.wav", name: "x", sampleRate: 48_000, frames: 64)).changesOnlyTiming(channels: 0..<4))
    }

    @Test("Only the channels the song plays count: a filter on a channel it doesn't use leaves the timing alone")
    func onlyUsedChannels() {
        var r = room(delayMs: 5)
        r.channels[3] = RoomChannelPlayback(levelDB: -6)
        #expect(r.changesOnlyTiming(channels: 0..<2))
        #expect(!r.changesOnlyTiming(channels: 0..<4))
    }

    // MARK: The stage

    @Test("The stage of the chain: nothing, whole-frame delays, then room correction, equalizer and gain by how much they change")
    func stage() {
        func stage(room: RoomCorrectionPlayback? = nil, eq: Bool = false, volume: Double? = nil, replayGain: Double? = nil) -> GroupSignalPath.Stage {
            GroupSignalPath.stage(room: room, usedChannels: 2, equalizer: eq, digitalVolumeDB: volume, replayGainDB: replayGain)
        }
        #expect(stage() == .none)
        #expect(stage(room: room()) == .none, "a flat profile changes nothing")
        #expect(stage(room: room(delayMs: 4)) == .integerDelay)
        #expect(stage(room: room(delayMs: 4, levelDB: -2)) == .roomCorrection)
        #expect(stage(room: room(delayMs: 4), eq: true) == .equalizer)
        #expect(stage(room: room(delayMs: 4, levelDB: -2), eq: true) == .roomCorrection)
        #expect(stage(volume: -6) == .gain && stage(replayGain: -3) == .gain)
        #expect(stage(volume: 0, replayGain: 0) == .none)
        #expect(stage(room: room(delayMs: 4), volume: -6) == .gain, "the gain changes the samples; the delay alone doesn't")
    }

    // MARK: The members of a song

    @Test("A stereo song on a quad group plays on the leader's pair only; the follower is in the group but not used")
    func stereoLeaderOnly() {
        let path = GroupSignalPath.make(group: group(), applied: applied(), source: source(channels: 2), plan: plan(channels: 2), stage: .none)
        #expect(path.members.map(\.speakers) == [[.frontLeft, .frontRight], []])
        #expect(path.usedMembers.map(\.deviceUID) == [fosi])
        #expect(path.isBitPerfect)
        #expect(path.badges == ["BIT-PERFECT", "SPEAKER GROUP"])
    }

    @Test("A quad song uses the follower too, which is resampled: not bit-perfect")
    func quadUsesFollower() {
        let path = GroupSignalPath.make(group: group(), applied: applied(), source: source(channels: 4), plan: plan(channels: 4), stage: .none)
        #expect(path.usedMembers.count == 2 && !path.isBitPerfect)
        #expect(path.statusLine == "RESAMPLED")
    }

    @Test("Whole-frame delays keep the leader's path bit-perfect; a level trim doesn't")
    func integerDelayStays() {
        let delayed = GroupSignalPath.make(group: group(), applied: applied(), source: source(channels: 2), plan: plan(channels: 2), stage: .integerDelay)
        #expect(delayed.isBitPerfect)
        let trimmed = GroupSignalPath.make(group: group(), applied: applied(), source: source(channels: 2), plan: plan(channels: 2), stage: .roomCorrection)
        #expect(!trimmed.isBitPerfect && trimmed.statusLine == "ROOM CORRECTION")
    }

    @Test("A song at another rate than the members, an unconfirmed format or a shared member is not bit-perfect")
    func honest() {
        #expect(!GroupSignalPath.make(group: group(), applied: applied(), source: source(channels: 2, rate: 44_100), plan: plan(channels: 2), stage: .none).isBitPerfect)
        #expect(!GroupSignalPath.make(group: group(), applied: applied(known: false), source: source(channels: 2), plan: plan(channels: 2), stage: .none).isBitPerfect)
    }

    @Test("A group whose speakers aren't assigned still counts the channels in order: the first ones are used")
    func unassigned() {
        var bare = group()
        bare.speakers = []
        let path = GroupSignalPath.make(group: bare, applied: applied(), source: source(channels: 2), plan: plan(channels: 2), stage: .none)
        #expect(path.usedMembers.map(\.deviceUID) == [fosi])
    }

    // MARK: In the engine's signal path

    @Test("The engine's signal path takes the group's answer, delay-only room correction included, and says ROOM CORRECTION when it's more")
    func inSignalPath() {
        func signalPath(_ stage: GroupSignalPath.Stage, channels: Int = 2, roomName: String? = "Timing") -> SignalPath {
            let src = source(channels: channels)
            let groupPath = GroupSignalPath.make(group: group(), applied: applied(), source: src, plan: plan(channels: channels), stage: stage)
            var path = SignalPath(source: src, decoderName: "test", plan: plan(channels: channels), applied: applied(), deviceName: "Downstairs quad",
                                  deviceUID: group().outputUID, deviceProfile: groupPath.deviceProfile, volume: .fixed, roomCorrection: roomName)
            path.group = groupPath
            return path
        }
        let delayed = signalPath(.integerDelay)
        #expect(delayed.isBitPerfect && delayed.statusLine == "BIT-PERFECT", "\(delayed.statusLine)")
        let room = signalPath(.roomCorrection)
        #expect(!room.isBitPerfect && room.statusLine == "ROOM CORRECTION")
        let quad = signalPath(.none, channels: 4, roomName: nil)
        #expect(!quad.isBitPerfect && quad.statusLine == "RESAMPLED")
        #expect(quad.group?.resampledMemberNames == ["FiiO K11"])
        var shared = signalPath(.none, roomName: nil)
        shared.applied.exclusive = false
        shared.otherAppsPlaying = true
        #expect(!shared.isBitPerfect)
        var damaged = signalPath(.none, roomName: nil)
        damaged.concealedFrames = 10
        #expect(!damaged.isBitPerfect)
    }

    @Test("A single device's signal path is unchanged: room correction of any kind still means ROOM CORRECTION")
    func singleDeviceUnchanged() {
        let src = source(channels: 2, rate: 48_000)
        let p = FormatPlanner.plan(source: src, device: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false))
        let a = AppliedFormat(sampleRate: 48_000, physicalBitDepth: 32, physicalIsInteger: false, virtualChannels: 2, exclusive: true, bufferFrames: 512)
        let path = SignalPath(source: src, decoderName: "test", plan: p, applied: a, deviceName: "T", deviceUID: "T",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: .fixed, roomCorrection: "Timing")
        #expect(!path.isBitPerfect && path.statusLine == "ROOM CORRECTION")
    }

    private func plan(channels: Int) -> OutputPlan {
        FormatPlanner.plan(source: source(channels: channels),
                           device: DeviceCapabilities(sampleRates: [96_000], physicalFormats: [], outputChannels: 4, supportsDoP: false))
    }
}
