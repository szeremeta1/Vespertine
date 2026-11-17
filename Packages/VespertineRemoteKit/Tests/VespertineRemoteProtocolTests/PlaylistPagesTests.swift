//
// Vespertine: a playlist's songs come a page at a time, from a newer Mac, or whole from an older one.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol

private func song(_ id: Int64) -> TrackSummary {
    TrackSummary(id: id, title: "Song \(id)", artist: "A", album: "B", albumKey: "b", duration: 180, trackNumber: nil, discNumber: nil,
                 format: "FLAC", artworkKey: nil, favorite: false)
}

@MainActor
struct PlaylistPagesTests {
    @Test func aLongPlaylistComesInPagesAndWhole() async {
        let all = (1...1_234).map { song(Int64($0)) }
        var asked: [RemoteCommand] = []
        var seen: [Int] = []
        let reply = await PlaylistPages.load(id: 7, pageSize: 500, ask: { command in
            asked.append(command)
            guard case .playlistTracks(7, let offset?, let limit?) = command else { return .failed(reason: "not a page") }
            return .songs(items: Array(all[min(offset, all.count)..<min(offset + limit, all.count)]), total: all.count)
        }, received: { songs, total in
            #expect(total == 1_234)
            seen.append(songs.count)
        })
        #expect(reply == .tracks(items: all))
        #expect(seen == [500, 1_000, 1_234])
        #expect(asked == [.playlistTracks(id: 7, offset: 0, limit: 500), .playlistTracks(id: 7, offset: 500, limit: 500),
                          .playlistTracks(id: 7, offset: 1_000, limit: 500)])
    }

    @Test func anOlderMacAnswersWithEverySong() async {
        let all = (1...3).map { song(Int64($0)) }
        var count = 0
        let reply = await PlaylistPages.load(id: 7, ask: { _ in count += 1; return .tracks(items: all) })
        #expect(reply == .tracks(items: all) && count == 1)
    }

    @Test func anEmptyPlaylistAndAFailureSaySo() async {
        #expect(await PlaylistPages.load(id: 7, ask: { _ in .songs(items: [], total: 0) }) == .tracks(items: []))
        #expect(await PlaylistPages.load(id: 7, ask: { _ in .failed(reason: "gone") }) == .failed(reason: "gone"))
        // A playlist that shrank while being read ends rather than asking forever.
        var count = 0
        let reply = await PlaylistPages.load(id: 7, pageSize: 2, ask: { _ in
            count += 1
            return count == 1 ? .songs(items: [song(1), song(2)], total: 10) : .songs(items: [], total: 2)
        })
        #expect(reply == .tracks(items: [song(1), song(2)]) && count == 2)
    }
}
