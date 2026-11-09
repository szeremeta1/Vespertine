//
// Vespertine: Dolby files join the library with their real format.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Dolby files in the library")
struct DolbyScanTests {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("VespertineAudioTests/Fixtures")

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

    @Test("A DTS CD shows no bitrate: the file's 1411k belongs to the PCM carrier")
    func dtsCDHasNoCarrierBitrate() throws {
        let track = try MetadataReader.read(url: fixtures.appendingPathComponent("dts-cd-tones.wav"), artwork: nil)
        #expect(track.codec == "DTS" && track.bitrate == nil)
        #expect(track.formatSummary == "DTS · 44.1 kHz · 5.1")
    }
}

@Suite("Dolby AC-4 files in the library")
struct DolbyAC4ScanTests {
    private let stub = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("VespertineAudioTests/Fixtures/dolby-ac4-ims-stub.mp4")

    @Test("An AC-4 MP4 is lossy Dolby AC-4, not a lossless 16/48 'MP4'")
    func readsAsAC4() throws {
        let track = try MetadataReader.read(url: stub, artwork: nil)
        #expect(track.codec == "Dolby AC-4")
        #expect(!track.isLossless)
        #expect(track.bitDepth == nil)
        #expect(track.sampleRate == 48_000)
        #expect(track.channels == 2)
        #expect(track.title == "Stub" && track.artist == "Nocturne Test" && track.album == "Fixtures")
        #expect(!track.formatSummary.contains("16"), "\(track.formatSummary)")
        #expect(!track.isHiRes)
    }

    @Test("Rows saved with the old fallback label are read again, so they pick up the real format")
    func oldFallbackRowsAreReread() {
        #expect(LibraryScanner.isFallbackLabel("MP4"))
        #expect(!LibraryScanner.isFallbackLabel("Dolby AC-4"))
        #expect(!LibraryScanner.isFallbackLabel("ALAC"))
    }
}
