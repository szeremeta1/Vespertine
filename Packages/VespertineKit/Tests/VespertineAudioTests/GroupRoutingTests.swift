//
// Vespertine — speaker groups: a song routed onto a group by where the speakers stand (PositionRouter and the content policies),
// in place of the plain "channel i to output i" and the speaker-setup fold a single device gets.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("Group routing")
struct GroupRoutingTests {
    private static let L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center
    private static let LFE = kAudioChannelLabel_LFEScreen, Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround

    private func source(_ channels: Int, rate: Double = 48_000) -> SourceFormat {
        SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: rate, bitDepth: 24, channels: channels)
    }

    private func device(outputs: Int) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: [44_100, 48_000, 96_000], physicalFormats: [
            PhysicalFormat(minRate: 44_100, maxRate: 96_000, bitDepth: 24, isInteger: true, isMixable: true, channels: outputs)],
            outputChannels: outputs, supportsDoP: false, speakerLayoutChannels: nil)
    }

    private func quad(_ policy: StereoPolicy = .frontOnly, lfe: LFEPolicy = .drop) -> SpeakerGroup {
        var group = GroupFixtures.quad()
        group.stereoPolicy = policy
        group.lfePolicy = lfe
        return group
    }

    // MARK: What the song's channels stand for

    @Test("Mono is a centre, stereo is a left and a right, a file's own speakers are kept, the usual order fills in, and a count with no order is nil")
    func sourceLabels() {
        #expect(GroupRouting.sourceLabels(channels: 1, speakers: nil) == [Self.C])
        #expect(GroupRouting.sourceLabels(channels: 2, speakers: nil) == [Self.L, Self.R])
        #expect(GroupRouting.sourceLabels(channels: 6, speakers: [Self.L, Self.R, Self.C, Self.LFE, Self.Ls, Self.Rs]) == [Self.L, Self.R, Self.C, Self.LFE, Self.Ls, Self.Rs])
        #expect(GroupRouting.sourceLabels(channels: 6, speakers: nil) == [Self.L, Self.R, Self.C, Self.LFE, Self.Ls, Self.Rs])
        #expect(GroupRouting.sourceLabels(channels: 8, speakers: nil) == ChannelLayouts.wavOrderLabels(channels: 8))
        #expect(GroupRouting.sourceLabels(channels: 9, speakers: nil) == nil)
        #expect(GroupRouting.sourceLabels(of: source(2)) == [Self.L, Self.R])
        #expect(GroupRouting.sourceLabels(of: source(4)) == ChannelLayouts.wavOrderLabels(channels: 4) ?? nil)
    }

    // MARK: The plan

    @Test("A group's plan has one channel for every output of the group, whatever the song: stereo, mono and 5.1 on a quad all take 4")
    func planChannels() throws {
        let group = quad()
        for channels in [1, 2, 6] {
            let content = GroupRouting.content(source: source(channels), group: group)
            let base = GroupFormatRules.plan(source: source(channels), device: device(outputs: 4))
            let plan = GroupRouting.routed(base, content: content, group: group, source: source(channels))
            #expect(plan.channels == 4, "\(channels) channels")
            #expect(plan.mode == .pcm && !plan.integerSamples && plan.routeLabels == nil && plan.spatial == .off)
            #expect(plan.deviceChannels == 4)
        }
    }

    @Test("Songs of different channel counts on one group need no new session")
    func plansAreCompatible() {
        let group = quad()
        func plan(_ channels: Int) -> OutputPlan {
            GroupRouting.routed(GroupFormatRules.plan(source: source(channels), device: device(outputs: 4)),
                                content: GroupRouting.content(source: source(channels), group: group), group: group, source: source(channels))
        }
        #expect(plan(2).isDeviceCompatible(with: plan(6)))
        #expect(plan(2).isDeviceCompatible(with: plan(1)))
    }

    @Test("A song whose channels have no order (9) keeps the plan it had: nothing to route by")
    func unknownOrder() {
        let group = quad()
        let base = GroupFormatRules.plan(source: source(9), device: device(outputs: 4))
        #expect(GroupRouting.content(source: source(9), group: group) == nil)
        #expect(GroupRouting.routed(base, content: nil, group: group, source: source(9)) == base)
    }

    @Test("The plan says how the song is spread, in the words the signal path shows")
    func reason() throws {
        let group = quad()
        let two = GroupRouting.routed(GroupFormatRules.plan(source: source(2), device: device(outputs: 4)),
                                      content: GroupRouting.content(source: source(2), group: group), group: group, source: source(2))
        #expect(two.reason.contains("Downstairs quad"), "\(two.reason)")
        let six = GroupRouting.routed(GroupFormatRules.plan(source: source(6), device: device(outputs: 4)),
                                      content: GroupRouting.content(source: source(6), group: group), group: group, source: source(6))
        #expect(six.reason.contains("where the speakers stand"), "\(six.reason)")
    }

    // MARK: The signal path

    private func path(_ channels: Int, group: SpeakerGroup, stage: GroupSignalPath.Stage = .none) -> GroupSignalPath {
        let src = source(channels)
        let content = GroupRouting.content(source: src, group: group)
        let plan = GroupRouting.routed(GroupFormatRules.plan(source: src, device: device(outputs: 4)), content: content, group: group, source: src)
        let members = group.members.enumerated().map { i, m in
            MemberApplied(uid: m.deviceUID, name: m.name, resampled: m.deviceUID != group.clockLeaderUID, isLeader: m.deviceUID == group.clockLeaderUID,
                          channelOffset: i * 2, channelCount: 2, sampleRate: 48_000, physicalBitDepth: 32, physicalIsInteger: false,
                          physicalFormatKnown: true, exclusive: true)
        }
        var applied = AppliedFormat(sampleRate: 48_000, physicalBitDepth: 32, physicalIsInteger: false, virtualChannels: 4, exclusive: true, bufferFrames: 512)
        applied.members = members
        return GroupSignalPath.make(group: group, applied: applied, source: src, plan: plan, stage: stage, content: content)
    }

    @Test("Stereo on a quad, front only: the front DAC plays it, the back DAC is not used, nothing is folded, and the leader's part is bit-perfect")
    func stereoFrontOnly() throws {
        let p = path(2, group: quad(.frontOnly))
        #expect(p.members.map(\.speakers) == [[.frontLeft, .frontRight], []])
        #expect(!p.folds)
        #expect(p.isBitPerfect)
        #expect(p.router != nil)
    }

    @Test("Stereo mirrored to the back pair: the back DAC plays too, so the path is resampled and not bit-perfect")
    func stereoMirror() throws {
        let p = path(2, group: quad(.mirror(trimDB: -3)))
        #expect(p.members.map(\.speakers) == [[.frontLeft, .frontRight], [.backLeft, .backRight]])
        #expect(!p.isBitPerfect)
        #expect(p.badges.contains("RESAMPLED"))
    }

    @Test("5.1 on a quad: folded, the LFE heard nowhere, and the badge says Downmixed")
    func surroundFold() throws {
        let p = path(6, group: quad())
        #expect(p.folds)
        #expect(p.badges.contains("Downmixed"))
        #expect(!p.isBitPerfect)
        #expect(Set(p.usedMembers.map(\.name)) == ["Fosi Audio ZD3", "FiiO K11"])
    }

    @Test("A quad file on the quad: every channel on its own speaker, nothing folded")
    func quadFile() throws {
        let p = path(4, group: quad())
        #expect(!p.folds)
        #expect(p.members.map(\.speakers) == [[.frontLeft, .frontRight], [.backLeft, .backRight]])
    }

    // MARK: What reaches the ring

    private func decode(_ url: URL, group: SpeakerGroup) throws -> (samples: [Float], plan: OutputPlan, path: GroupSignalPath?) {
        let probed = try SourceOpener.probe(url)
        let content = GroupRouting.content(source: probed.format, group: group)
        let plan = GroupRouting.routed(GroupFormatRules.plan(source: probed.format, device: device(outputs: 4)), content: content, group: group, source: probed.format)
        let layout = OutputSession.routeLayout(plan: plan, speakers: nil)
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        var path = SignalPath(source: probed.format, decoderName: "test", plan: plan,
                              applied: AppliedFormat(sampleRate: plan.deviceSampleRate, physicalBitDepth: 32, physicalIsInteger: false,
                                                     virtualChannels: 4, exclusive: false, bufferFrames: 512),
                              deviceName: "test", deviceUID: group.outputUID,
                              deviceProfile: .speakerGroup(canBeBitPerfect: false), volume: .fixed)
        let groupPath = GroupSignalPath(groupName: group.name, source: probed.format, folds: false, dsdConvertedToPCM: false, stage: .none,
                                        members: [], router: content?.router)
        path.group = groupPath
        let decoding = try Decoding(item: PlayableItem(url: url), probed: probed, decoder: decoder, path: path, chunk: 4096, layout: layout)
        var out: [Float] = []
        while true {
            let chunk = decoding.convertChunk()
            if let data = chunk.data { out += UnsafeBufferPointer(start: data, count: Int(chunk.frames) * plan.channels) }
            if chunk.ended { break }
        }
        return (out, plan, path.group)
    }

    private func write(channels: Int, mask: UInt32, rate: Double = 48_000, frames: Int = 9_600, value: @escaping (Int, Int) -> Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grouproute-\(UUID()).wav")
        try ChannelID.writeWAV(to: url, channels: channels, frames: frames, rate: rate, mask: mask) { c, f in
            Int32((value(c, f) * 8_388_607).rounded())
        }
        return url
    }

    @Test("A stereo file on the quad reaches the ring four channels wide: the front pair holds the file's own samples and the back pair is silent")
    func decodeStereo() throws {
        let url = try write(channels: 2, mask: WaveMask.FL | WaveMask.FR) { c, f in 0.25 * sin(2 * .pi * Double(c + 1) * 440 * Double(f) / 48_000) }
        defer { try? FileManager.default.removeItem(at: url) }
        let (out, plan, _) = try decode(url, group: quad())
        #expect(plan.channels == 4 && out.count == 9_600 * 4)
        for f in 0..<9_600 {
            let expectL = Float((0.25 * sin(2 * .pi * 440 * Double(f) / 48_000) * 8_388_607).rounded() / 8_388_607)
            #expect(abs(out[f * 4] - expectL) < 1e-6)
            #expect(out[f * 4 + 2] == 0 && out[f * 4 + 3] == 0)
        }
    }

    @Test("A 5.1 file on the quad: the centre is shared by the fronts at 0.707, the surrounds go to the back pair, the LFE is dropped")
    func decodeSurround() throws {
        // Each channel a constant of its own, so the sums can be read straight off.
        let levels = [0.10, 0.20, 0.30, 0.40, 0.05, 0.06]
        let url = try write(channels: 6, mask: 0x3F) { c, _ in levels[c] }
        defer { try? FileManager.default.removeItem(at: url) }
        let (out, plan, _) = try decode(url, group: quad())
        #expect(plan.channels == 4)
        let mid = 4_000 * 4
        let k = 0.5.squareRoot()
        #expect(abs(Double(out[mid]) - (0.10 + k * 0.30)) < 1e-4)
        #expect(abs(Double(out[mid + 1]) - (0.20 + k * 0.30)) < 1e-4)
        #expect(abs(Double(out[mid + 2]) - 0.05) < 1e-4)
        #expect(abs(Double(out[mid + 3]) - 0.06) < 1e-4)
    }

    @Test("A mono file: shared equally by the front pair, at the ITU −3 dB each")
    func decodeMono() throws {
        let url = try write(channels: 1, mask: WaveMask.FC) { _, _ in 0.4 }
        defer { try? FileManager.default.removeItem(at: url) }
        let (out, plan, _) = try decode(url, group: quad())
        #expect(plan.channels == 4)
        let mid = 4_000 * 4
        #expect(abs(Double(out[mid]) - 0.4 * 0.5.squareRoot()) < 1e-4 && abs(Double(out[mid + 1]) - 0.4 * 0.5.squareRoot()) < 1e-4)
        #expect(out[mid + 2] == 0 && out[mid + 3] == 0)
    }
}
