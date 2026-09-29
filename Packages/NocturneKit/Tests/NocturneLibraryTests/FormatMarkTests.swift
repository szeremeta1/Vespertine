//
// Nocturne — format badges.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import NocturneLibrary

@Suite struct FormatMarkTests {
    private func mark(_ codec: String, lossless: Bool = true, dsd: Bool = false, rate: Double = 48_000, bits: Int? = 24) -> String? {
        FormatMark.of(codec: codec, lossless: lossless, dsd: dsd, sampleRate: rate, bitDepth: bits)?.text
    }

    @Test func surroundFormatsByName() {
        #expect(mark("Dolby Atmos", lossless: false) == "DOLBY ATMOS")
        #expect(mark("Dolby Atmos (TrueHD)") == "DOLBY ATMOS")
        #expect(FormatMark.of(codec: "Dolby Atmos (TrueHD)", lossless: true, dsd: false, sampleRate: 48_000, bitDepth: 24)?.carrier == "TrueHD bed · lossless")
        #expect(mark("Dolby TrueHD") == "DOLBY TRUEHD")
        #expect(mark("Dolby Digital Plus", lossless: false) == "DOLBY DIGITAL PLUS")
        #expect(mark("Dolby Digital", lossless: false) == "DOLBY DIGITAL")
        #expect(mark("DTS-HD Master Audio") == "DTS-HD MASTER AUDIO")
        #expect(mark("DTS", lossless: false) == "DTS DIGITAL SURROUND")
        #expect(mark("DTS:X") == "DTS:X")
    }

    @Test func audiophileFormats() {
        #expect(mark("DSF", dsd: true, rate: 11_289_600, bits: nil) == "DSD 256")
        #expect(mark("FLAC", rate: 96_000) == "HI-RES LOSSLESS")
        #expect(mark("FLAC", rate: 44_100, bits: 16) == "LOSSLESS")
        #expect(mark("MP3", lossless: false, rate: 44_100, bits: nil) == nil)
    }

    @Test func albumsInferLossyFromSummary() {
        func album(_ codec: String, _ summary: String, hiRes: Bool = false) -> Album {
            Album(key: "k", title: "t", artist: "a", year: nil, genre: nil, trackCount: 1, duration: 1, artworkKey: nil,
                  formatSummary: summary, codec: codec, maxBitDepth: 16, maxSampleRate: 44_100, isHiRes: hiRes,
                  isDSD: false, addedAt: .now, totalSize: 1, sourcePath: nil)
        }
        #expect(album("AAC", "AAC · 256k").formatMark == nil)
        #expect(album("FLAC", "FLAC · 16/44.1").formatMark?.text == "LOSSLESS")
        #expect(album("Dolby Digital", "Dolby Digital · 448k · 5.1").formatMark?.text == "DOLBY DIGITAL")
    }
}

@Suite struct UntaggedFallbackTests {
    @Test func albumFromFolderSkippingDiscFolders() {
        #expect(MetadataReader.albumFolder(of: URL(fileURLWithPath: "/m/Dire Straits/Brothers in Arms (DTS)/01.dts")) == "Brothers in Arms (DTS)")
        #expect(MetadataReader.albumFolder(of: URL(fileURLWithPath: "/m/Pink Floyd/The Wall/CD 2/01.dts")) == "The Wall")
        #expect(MetadataReader.albumFolder(of: URL(fileURLWithPath: "/m/Pink Floyd/WYWH (1975) [SACD]/Multichannel 5.1/01.dts")) == "WYWH (1975) [SACD]")
        for layer in ["Stereo", "Multichannel", "SACD Stereo", "Surround 5.1", "5.1", "Multi-channel 5.1"] { #expect(ArtworkStore.isDiscFolder(layer), "\(layer)") }
        for other in ["Stereo Mixes", "Greatest Hits", "1975", "Live"] { #expect(!ArtworkStore.isDiscFolder(other), "\(other)") }
    }
}
