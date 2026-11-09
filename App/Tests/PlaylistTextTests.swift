// Vespertine: tests for reading playlist files written in an older code page.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Vespertine

@Suite("Playlist file text")
struct PlaylistTextTests {
    @Test("UTF-8 playlists read as they are")
    func utf8() {
        let text = "#EXTM3U\nMusic/Café del Mar.flac\n"
        #expect(LibraryStore.playlistText(Data(text.utf8)) == text)
    }

    @Test("An old .m3u in the Windows code page keeps its accented letters and quotes")
    func windowsCodePage() {
        // "Café – “Jazz”.flac" as Windows-1252: é is E9, the dash 96, the curly quotes 93 and 94.
        let bytes: [UInt8] = Array("Music/Caf".utf8) + [0xE9, 0x20, 0x96, 0x20, 0x93] + Array("Jazz".utf8) + [0x94] + Array(".flac".utf8)
        #expect(LibraryStore.playlistText(Data(bytes)) == "Music/Café – “Jazz”.flac")
    }

    @Test("Bytes the Windows code page leaves undefined still read, as Latin-1")
    func latinOne() {
        let bytes: [UInt8] = Array("Caf".utf8) + [0xE9, 0x81]
        #expect(LibraryStore.playlistText(Data(bytes)).hasPrefix("Café"))
    }
}
