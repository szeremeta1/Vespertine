//
// Vespertine — playlists to and from other players: M3U files both ways, and a library exported from Apple Music.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import UniformTypeIdentifiers
import VespertineLibrary

extension AppModel {
    func exportPlaylist(_ playlist: Playlist) {
        let tracks = library.tracks(in: playlist)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(playlist.name).m3u8"
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
        panel.message = String(localized: "Other players open this as a playlist of the same files.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try M3U.text(tracks).write(to: url, atomically: true, encoding: .utf8) }
        catch { playlistReport = String(localized: "Couldn't save the playlist: \(error.localizedDescription)") }
    }

    func importPlaylistFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "Choose M3U or M3U8 playlists. Songs already in your library are added; nothing new is scanned.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task {
            let result = await library.importPlaylistFiles(urls)
            playlistReport = Self.report(result)
        }
    }

    func importAppleMusicLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml, .propertyList]
        panel.message = String(localized: "In Music, choose File \u{203A} Library \u{203A} Export Library\u{2026}, then pick the file it saved.",
                               comment: "File, Library and Export Library… are menu items of Apple's Music app: use the names Music shows in this language.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let result = await library.importAppleMusicLibrary(url) else { return }
            playlistReport = Self.report(result)
        }
    }

    private static func report(_ r: PlaylistImportResult) -> String {
        var lines: [String] = []
        if r.playlists > 0 || r.favorites == 0 && r.playCounts == 0 {
            lines.append(String(localized: "Added \(r.playlists) playlists with \(r.songs) songs."))
        }
        if r.favorites > 0 { lines.append(String(localized: "Marked \(r.favorites) loved songs as favorites.")) }
        if r.playCounts > 0 { lines.append(String(localized: "Brought over play counts for \(r.playCounts) songs.")) }
        if r.unmatched > 0 {
            lines.append(String(localized: "\(r.unmatched) entries weren't found in your library. Add the folders those songs are in, then import again."))
        }
        return lines.joined(separator: " ")
    }
}
