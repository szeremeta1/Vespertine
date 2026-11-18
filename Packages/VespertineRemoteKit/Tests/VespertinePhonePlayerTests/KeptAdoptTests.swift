//
// Vespertine: what was kept from one library by itself is taken in when libraries are joined as one.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

@MainActor struct KeptAdoptTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kept-\(UUID())", isDirectory: true) }

    private func bytes(_ id: Int64) -> Data { Data((0..<3500).map { UInt8(truncatingIfNeeded: $0 &+ Int(id)) }) }

    private func song(_ id: Int64) -> TrackSummary {
        TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: 200, trackNumber: Int(id), discNumber: 1,
                     format: "WAV 24/44.1", artworkKey: "art", favorite: false)
    }

    /// A store with one album kept whole, as the keeper leaves it.
    private func kept(_ ids: [Int64]) throws -> KeptStore {
        let store = try KeptStore(directory: folder())
        store.put(KeptList(id: "album:a", kind: .album, reference: "a", title: "Album", subtitle: "Artist", artworkKey: "art", tracks: ids.map(song), smaller: false))
        for id in ids {
            let data = bytes(id)
            try data.write(to: store.partFile(for: id))
            let format = StreamFormat(codec: "WAV", container: "wav", sampleRate: 44_100, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true)
            try store.arrived(id, descriptor: StreamDescriptor(stream: 1, kind: .original, byteSize: Int64(data.count), format: format, frames: nil,
                                                               tag: "tag-\(id)", chunkSize: 1000, reduced: nil))
        }
        return store
    }

    @Test func whatWasKeptFromOneLibraryIsTakenInWhenLibrariesAreJoined() throws {
        // Kept from a Mac and from a share, each by itself, with the same song numbers.
        let fromMac = try kept([1, 2]), fromShare = try kept([1])
        let joined = try KeptStore(directory: folder())
        joined.adopt(fromMac.directory, slot: 1)
        joined.adopt(fromShare.directory, slot: 2)
        #expect(joined.lists.map(\.id) == ["album:1~a", "album:2~a"])
        #expect(joined.lists[0].reference == "1~a" && joined.lists[0].artworkKey == "1~art")
        let macSong = try #require(JoinedID.join(2, slot: 1)), shareSong = try #require(JoinedID.join(1, slot: 2))
        #expect(joined.lists[0].tracks.map(\.id) == [JoinedID.join(1, slot: 1), macSong])
        #expect(joined.lists[0].tracks[0].albumKey == "1~a")
        // The files came along: nothing is fetched again, and the two libraries' song 1 are two files.
        let macFile = try #require(joined.kept(macSong)).file, shareFile = try #require(joined.kept(shareSong)).file
        #expect(try Data(contentsOf: macFile) == bytes(2))
        #expect(try Data(contentsOf: shareFile) == bytes(1))
        #expect(joined.progress(of: "album:1~a").isComplete && joined.progress(of: "album:2~a").isComplete)
        #expect(joined.missing.isEmpty && joined.bytes == 10_500)
        #expect(!FileManager.default.fileExists(atPath: fromMac.directory.path) && !FileManager.default.fileExists(atPath: fromShare.directory.path))
        // Still there the next time the app opens.
        let again = try KeptStore(directory: joined.directory)
        #expect(again.lists.count == 2 && again.kept(macSong) != nil && again.kept(shareSong) != nil)
        // A folder with nothing kept in it is nothing to take in.
        joined.adopt(folder(), slot: 3)
        #expect(joined.lists.count == 2)
    }

    @Test func aKeptPlaylistKeepsItsNumberAndItsSongsSayWhichLibraryTheyAreFrom() throws {
        let alone = try KeptStore(directory: folder())
        alone.put(KeptList(id: KeptList.playlistID(7), kind: .playlist, reference: "7", title: "Evening", subtitle: "", artworkKey: nil, tracks: [song(4)], smaller: false))
        let joined = try KeptStore(directory: folder())
        joined.adopt(alone.directory, slot: 1)
        #expect(joined.lists.map(\.id) == ["playlist:7"] && joined.lists[0].reference == "7")
        #expect(joined.lists[0].tracks.map(\.id) == [JoinedID.join(4, slot: 1)])
        #expect(joined.missing.count == 1)
    }
}
