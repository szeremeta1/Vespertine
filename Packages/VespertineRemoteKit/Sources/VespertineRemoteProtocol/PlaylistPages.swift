//
// Vespertine: a playlist's songs, asked of the Mac a page at a time, so a playlist of any length fits in the replies (one
// reply holding every song of a very long playlist would be over `RemoteProtocol.maximumMessageSize` and end the connection).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public enum PlaylistPages {
    /// Songs per page: about 200 kB of reply.
    public static let pageSize = 500

    /// Reads every song of playlist `id` through `ask`, page by page. `received` gets the songs read so far after each page,
    /// and the playlist's total, so a screen can show the first page at once. An older Mac answers the first request with
    /// every song (`.tracks`), which is then the whole list. Answers `.tracks` with the songs, or the Mac's `.failed`.
    @MainActor
    public static func load(id: Int64, pageSize: Int = PlaylistPages.pageSize,
                            ask: @MainActor (RemoteCommand) async -> RemoteReply,
                            received: @MainActor ([TrackSummary], Int) -> Void = { _, _ in }) async -> RemoteReply {
        var songs: [TrackSummary] = []
        while true {
            switch await ask(.playlistTracks(id: id, offset: songs.count, limit: pageSize)) {
            case .tracks(let items):
                // An older Mac: the whole playlist in one answer.
                received(items, items.count)
                return .tracks(items: items)
            case .songs(let items, let total):
                songs += items
                received(songs, max(total, songs.count))
                // An empty page ends it too, so a playlist that shrank while being read can't loop.
                if items.isEmpty || songs.count >= total { return .tracks(items: songs) }
                // Part of a playlist is never passed off as all of it.
                if Task.isCancelled { return .failed(reason: "") }
            case .failed(let reason):
                return .failed(reason: reason)
            default:
                return .failed(reason: "")
            }
        }
    }
}
