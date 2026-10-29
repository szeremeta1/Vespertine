//
// Vespertine — room profiles made elsewhere: REW's Equalizer APO export (per-speaker delay, level and filters) and
// impulse responses (convolution filters), and a profile written back out as Equalizer APO text.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

private func apo(_ text: String) throws -> RoomProfile { try RoomAPO.profile(text, name: "Living room", deviceUID: "zd3") }

/// A WAV file of float samples, one array per channel, in a fresh folder that the caller removes.
private func wav(_ channels: [[Float]], rate: Double = 48_000, name: String = "filter", in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent("\(name).wav")
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                           AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 32,
                                                           AVLinearPCMIsFloatKey: true])
    let frames = channels.map(\.count).max() ?? 0
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for (c, samples) in channels.enumerated() {
        for (i, v) in samples.enumerated() { buffer.floatChannelData![c][i] = v }
    }
    try file.write(from: buffer)
    return url
}

private func freshFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("room-import-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func impulse(at index: Int, gain: Float, length: Int = 1000) -> [Float] {
    (0..<length).map { $0 == index ? gain : 0 }
}

@Suite("Room correction import")
struct RoomImportTests {
    @Test("Reads REW's Equalizer APO export: a preamp, then each speaker's delay, level and filters")
    func perSpeakerAPO() throws {
        let profile = try apo("""
        Preamp: -4 dB
        Channel: L
        Delay: 1.25 ms
        Filter 1: ON PK Fc 42 Hz Gain -9.5 dB Q 6.0
        Filter 2: ON PK Fc 87 Hz Gain -4 dB Q 3
        Channel: R
        Preamp: -1.5 dB
        Filter 1: ON PK Fc 45 Hz Gain -7 dB Q 5.2
        """)
        #expect(profile.name == "Living room" && profile.deviceUID == "zd3" && profile.layout == .stereo && profile.origin == .equalizerAPO)
        #expect(profile.filters.preampDB == -4 && profile.channelMap == .standard(.stereo))
        #expect(profile.alignment(for: .left) == RoomSpeakerAlignment(delayMs: 1.25, levelDB: 0))
        #expect(profile.alignment(for: .right) == RoomSpeakerAlignment(delayMs: 0, levelDB: -1.5))
        let left = try #require(profile.filters.channels[.left])
        #expect(left.count == 2 && left[0].frequency == 42 && left[0].gainDB == -9.5 && left[0].q == 6)
        #expect(profile.filters.channels[.right]?.count == 1)
        // It plays as written.
        let playback = RoomCorrectionPlayback(profile: profile)
        #expect(playback.channels.count == 2 && playback.channels[0].delayMs == 1.25 && playback.channels[1].levelDB == -1.5)
    }

    @Test("Filters before any Channel line correct every speaker; ALL, numbers and surround names make a 5.1 profile")
    func sharedAndScoped() throws {
        let profile = try apo("""
        Filter: ON HPQ Fc 20 Hz Q 0.7
        Channel: 1 2
        Filter: ON PK Fc 60 Hz Gain -3 dB Q 4
        Channel: C
        Filter: ON PK Fc 70 Hz Gain -2 dB Q 4
        Channel: SL SR
        Preamp: -2 dB
        Channel: ALL
        Delay: 0.5 ms
        """)
        #expect(profile.layout == .surround51 && profile.channelMap == .standard(.surround51))
        #expect(RoomLayout.surround51.speakers.map { profile.filters.channels[$0]?.count ?? 0 } == [2, 2, 2, 1, 1, 1])
        #expect(RoomLayout.surround51.speakers.allSatisfy { profile.filters.channels[$0]?.first?.kind == .highPass })
        #expect(RoomLayout.surround51.speakers.allSatisfy { profile.alignment(for: $0).delayMs == 0.5 })
        #expect(profile.alignment(for: .leftSurround).levelDB == -2 && profile.alignment(for: .center).levelDB == 0)
        #expect(RoomCorrectionPlayback(profile: profile).channels.count == 6)
    }

    @Test("A plain file with no Channel lines corrects left and right alike")
    func plainFile() throws {
        let profile = try apo("Preamp: -2 dB\nFilter 1: ON PK Fc 50 Hz Gain -6 dB Q 5")
        #expect(profile.layout == .stereo && profile.filters.preampDB == -2)
        #expect(profile.filters.channels[.left] == profile.filters.channels[.right] && profile.alignment == nil)
    }

    @Test("Refuses what it can't apply instead of playing something else")
    func refusals() {
        #expect(throws: EQImportError.noFilters) { try apo("Preamp: -2 dB") }
        #expect(throws: EQImportError.unsupportedChannel(line: 1, name: "XL")) { try apo("Channel: XL") }
        #expect(throws: EQImportError.delayInSamples(line: 1)) { try apo("Delay: 40 samples") }
        #expect(throws: EQImportError.unsupportedCommand(line: 2, command: "Copy")) { try apo("Filter: ON PK Fc 50 Hz Gain -6 dB Q 5\nCopy: L=R") }
        #expect(throws: EQImportError.graphicEQ) { try apo("GraphicEQ: 20 -1; 30 -2") }
        let many = (1...(RoomProfile.maxBands + 1)).map { "Filter \($0): ON PK Fc \(30 + $0) Hz Gain -1 dB Q 4" }.joined(separator: "\n")
        #expect(throws: EQImportError.tooManyRoomFilters(RoomProfile.maxBands + 1)) { try apo(many) }
        #expect(RoomProfile.maxBands == 24)
    }

    @Test("Export reads back the same profile, measured or imported")
    func roundTrip() throws {
        let filters = RoomFilterSet(version: 1, channels: [
            .left: [EQBand(kind: .peak, frequency: 42, gainDB: -8, q: 6)],
            .right: [EQBand(kind: .peak, frequency: 55, gainDB: -5, q: 4), EQBand(kind: .lowShelf, frequency: 120, gainDB: -2, q: 0.7)],
        ], preampDB: -3)
        var profile = RoomProfile.imported(name: "x", deviceUID: "zd3", layout: .stereo, source: .measured, filters: filters)
        profile.alignment = [.left: RoomSpeakerAlignment(delayMs: 1.5, levelDB: -1)]
        let back = try RoomAPO.profile(RoomAPO.text(profile), name: "x", deviceUID: "zd3")
        #expect(back.filters.preampDB == -3 && back.layout == .stereo)
        #expect(back.alignment(for: .left) == RoomSpeakerAlignment(delayMs: 1.5, levelDB: -1) && !back.alignment(for: .right).isActive)
        #expect(back.filters.channels[.right]?.map(\.kind) == [.peak, .lowShelf])
        #expect(back.filters.channels[.right]?[0].frequency == 55 && back.filters.channels[.left]?[0].gainDB == -8)
    }

    @Test("Impulse responses: a stereo file gives each speaker its own filter, trimmed, with the same gain at every rate")
    func impulseResponses() throws {
        let folder = try freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("store", isDirectory: true)
        let url = try wav([impulse(at: 300, gain: 1), impulse(at: 300, gain: 0.5)], in: folder)
        let profile = try RoomImpulseImport.profile(files: [url], name: "IR", deviceUID: "zd3", directory: store)
        #expect(profile.origin == .impulseResponse && profile.layout == .stereo)
        let left = try #require(profile.impulses?[.left]), right = try #require(profile.impulses?[.right])
        #expect(left.frames == 301 && left.sampleRate == 48_000 && left != right)   // trailing silence trimmed
        let playback = RoomCorrectionPlayback(profile: profile, impulseDirectory: store)
        #expect(!playback.isFlat)
        let taps = try #require(playback.impulseTaps(sampleRate: 48_000, channelCount: 2))
        #expect(taps[0]?[300] == 1 && taps[1]?[300] == 0.5)
        let doubled = try #require(right.taps(at: 96_000, in: store))
        #expect(abs(doubled.reduce(0, +) - 0.5) < 0.01)   // the same gain at twice the rate
    }

    @Test("Single-channel files go to the speaker their names point to")
    func namedFiles() throws {
        let folder = try freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let right = try wav([impulse(at: 10, gain: 0.25)], name: "room_R", in: folder)
        let left = try wav([impulse(at: 10, gain: 1)], name: "room_L", in: folder)
        let profile = try RoomImpulseImport.profile(files: [right, left], name: "IR", deviceUID: "zd3", directory: folder)
        #expect(profile.impulses?[.left]?.name == "room_L" && profile.impulses?[.right]?.name == "room_R")
        #expect(RoomImpulseImport.speakerHint("Filter Left 48k") == .left && RoomImpulseImport.speakerHint("SR") == .rightSurround)
        #expect(RoomImpulseImport.speakerHint("lfe-filter") == .lfe && RoomImpulseImport.speakerHint("bass") == nil)
        // One filter alone corrects both speakers.
        let one = try RoomImpulseImport.profile(files: [left], name: "IR", deviceUID: "zd3", directory: folder)
        #expect(one.impulses?[.left] == one.impulses?[.right] && one.impulses?[.left] != nil)
    }

    @Test("An imported profile draws what its correction does: bands, level and preamp, and a measured filter's magnitude")
    func correctionCurves() throws {
        let profile = try apo("Preamp: -2 dB\nChannel: L\nFilter: ON PK Fc 100 Hz Gain -6 dB Q 4\nChannel: R\nPreamp: -1 dB")
        let curves = RoomCorrectionCurves(profile: profile)
        let i100 = try #require(RoomCorrectionCurves.frequencies.firstIndex { abs($0 - 100) < 3 })
        #expect(curves.channels.map(\.speaker) == [.left, .right])
        #expect(abs(curves.channels[0].db[i100] - (-8)) < 0.3 && abs(curves.channels[1].db[i100] - (-3)) < 1e-6)

        let folder = try freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ir = try RoomImpulseImport.profile(files: [try wav([impulse(at: 3, gain: 0.5, length: 8)], in: folder)], name: "IR",
                                               deviceUID: "zd3", directory: folder)
        let flat = RoomCorrectionCurves(profile: ir, impulseDirectory: folder)
        #expect(ir.layout == .stereo && flat.channels.count == 2)
        #expect(flat.channels.allSatisfy { $0.db.allSatisfy { abs($0 - 20 * log10(0.5)) < 0.01 } })
    }

    @Test("Files that aren't audio, or too many filters, are refused and leave nothing behind")
    func impulseRefusals() throws {
        let folder = try freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("store", isDirectory: true)
        let text = folder.appendingPathComponent("text.wav")
        try Data("Filter 1: ON PK Fc 40 Hz Gain -6 dB Q 4".utf8).write(to: text)
        #expect(throws: RoomImpulseError.unreadable) { try RoomImpulseImport.profile(files: [text], name: "x", deviceUID: "zd3", directory: store) }
        let eight = try wav((0..<8).map { _ in impulse(at: 5, gain: 1, length: 10) }, in: folder)
        #expect(throws: RoomImpulseError.tooManyChannels(8)) { try RoomImpulseImport.profile(files: [eight], name: "x", deviceUID: "zd3", directory: store) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
        #expect(left.isEmpty)
    }
}
