//
// Nocturne — Dolby files join the library with their real format.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import NocturneLibrary

@Suite("Dolby files in the library")
struct DolbyScanTests {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("NocturneAudioTests/Fixtures")

    @Test("Dolby Digital and Dolby Digital Plus files are read", arguments: [
        ("dolby-digital-tones.ac3", "Dolby Digital"), ("dolby-digital-plus-tones.ec3", "Dolby Digital Plus"),
        ("dolby-digital-plus-tones.m4a", "Dolby Digital Plus"),
    ])
    func reads(name: String, codec: String) throws {
        let track = try MetadataReader.read(url: fixtures.appendingPathComponent(name), artwork: nil)
        #expect(track.codec == codec)
        #expect(track.channels == 6)
        #expect(!track.isLossless)
        #expect(track.sampleRate == 48_000)
        #expect(abs(track.duration - 1.5) < 0.1, "duration \(track.duration)")
    }

    @Test("DTS and TrueHD files are read, with Matroska tags", arguments: [
        ("dts-tones.dts", "DTS", false, nil as String?), ("dts-tones.mka", "DTS", false, "DTS Tones"),
        ("truehd-tones.thd", "Dolby TrueHD", true, nil), ("truehd-tones.mka", "Dolby TrueHD", true, nil),
    ])
    func readsFFmpegFormats(name: String, codec: String, lossless: Bool, title: String?) throws {
        let track = try MetadataReader.read(url: fixtures.appendingPathComponent(name), artwork: nil)
        #expect(track.codec == codec)
        #expect(track.isLossless == lossless)
        #expect(track.channels == 6)
        #expect(abs(track.duration - 1) < 0.1, "duration \(track.duration)")
        if let title { #expect(track.title == title && track.artist == "Nocturne Test" && track.album == "Fixtures") }
    }
}
