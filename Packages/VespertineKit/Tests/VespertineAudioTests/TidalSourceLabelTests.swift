//
// Vespertine: the signal path's source line for a TIDAL stream.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("TIDAL source label")
struct TidalSourceLabelTests {
    private let tidal = URL(string: "tidal://track/7")!

    @Test("A TIDAL item reads TIDAL · <codec> <bits>/<rate>, with (DASH) for a segmented stream")
    func labels() {
        let hiRes = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 192_000, bitDepth: 24, channels: 2)
        #expect(SignalPath.remoteSourceLabel(url: tidal, source: hiRes, isDASH: true) == "TIDAL · FLAC 24/192 (DASH)")
        let cd = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2)
        #expect(SignalPath.remoteSourceLabel(url: tidal, source: cd, isDASH: false) == "TIDAL · FLAC 16/44.1")
        #expect(SignalPath.remoteSourceLabel(url: tidal, source: cd, isDASH: nil) == "TIDAL · FLAC 16/44.1")
        let aac = SourceFormat(encoding: .lossy, codec: "AAC", sampleRate: 44_100, bitDepth: nil, channels: 2)
        #expect(SignalPath.remoteSourceLabel(url: tidal, source: aac, isDASH: false) == "TIDAL · AAC 44.1")
    }

    @Test("A file or a share item has no such label")
    func others() {
        let format = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2)
        #expect(SignalPath.remoteSourceLabel(url: URL(fileURLWithPath: "/a.flac"), source: format, isDASH: nil) == nil)
    }
}
