//
// Vespertine — Dolby AC-4 files are named for what they are, not "not recognized".
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Dolby AC-4")
struct DolbyAC4Tests {
    /// An MP4 with an 'ac-4' track (immersive stereo, as Dolby's 2024 Atmos Music stereo masters are): a real container, frames that
    /// aren't decodable (scripts/make-ac4-fixture.py).
    private var stub: URL { Bundle.module.url(forResource: "dolby-ac4-ims-stub.mp4", withExtension: nil, subdirectory: "Fixtures")! }

    @Test("Opening it says it is Dolby AC-4 and that this Mac can't decode it")
    func openingNamesTheCodec() throws {
        let failure = #expect(throws: (any Error).self) { try SourceOpener.probe(stub) }
        let message = failure?.localizedDescription ?? ""
        #expect(message.contains("Dolby AC-4"), "\(message)")
        #expect(!message.contains("not recognized"), "\(message)")
    }

    @Test("Its format is reported as lossy Dolby AC-4, 48 kHz stereo, with no bit depth")
    func formatIsHonest() throws {
        let format = try #require(SourceInspector.undecodableFormat(stub))
        #expect(format.codec == "Dolby AC-4")
        #expect(format.encoding == .lossy)
        #expect(format.sampleRate == 48_000)
        #expect(format.channels == 2)
        #expect(format.bitDepth == nil)
    }

    @Test("Ordinary files are not mistaken for it", arguments: ["dolby-digital-plus-tones.m4a", "dolby-digital-tones.ac3", "dts-tones.mka"])
    func otherFilesAreNotAC4(name: String) throws {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        #expect(SourceInspector.undecodableFormat(url) == nil)
    }
}
