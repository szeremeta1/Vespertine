//
// Nocturne — launch-argument hooks for reproducible visual QA and screenshots.
// None of these run unless the argument is passed, e.g.:
//   Nocturne.app/Contents/MacOS/Nocturne -NocturneDataDirectory /tmp/lib -NocturneAddSource ~/Demo \
//       -NocturneOpenAlbum "Horizon Line" -NocturnePlayAlbum "Horizon Line" -NocturnePlayTrack 2 -NocturnePauseAfter 4
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import NocturneLibrary
import SwiftUI

@MainActor
enum DeveloperHooks {
    static func run(_ model: AppModel, openWindow: OpenWindowAction?) async {
        let d = UserDefaults.standard
        let open = d.string(forKey: "NocturneOpenAlbum")
        let play = d.string(forKey: "NocturnePlayAlbum")
        if let address = d.string(forKey: "NocturneAddShare") {
            // Adds a network share using the keychain's saved password (never one passed on the command line).
            Task {
                guard let share = NetworkShare(string: address) else { print("[qa] add share: invalid address"); return }
                do {
                    try await model.shares.add(share, password: nil, remember: false, name: d.string(forKey: "NocturneShareName"), writable: false)
                    print("[qa] add share: ok")
                } catch {
                    print("[qa] add share failed: \(error.localizedDescription)")
                }
            }
        }
        if d.bool(forKey: "NocturneOpenSettings") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        if let path = d.string(forKey: "NocturneSnapshot") {
            Task { await snapshotLoop(to: path, delay: d.double(forKey: "NocturneSnapshotDelay"), repeats: max(1, d.integer(forKey: "NocturneSnapshotCount"))) }
        }
        guard open != nil || play != nil || d.object(forKey: "NocturneInspectorTab") != nil || d.bool(forKey: "NocturneOpenMini")
                || d.string(forKey: "NocturneOpenSheet") != nil else { return }

        // Wait (bounded) for the library to contain the requested album.
        let wanted = play ?? open
        for _ in 0..<120 {
            if wanted == nil || model.library.albums.contains(where: { $0.title == wanted }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let sidebar = d.string(forKey: "NocturneSidebar") {
            switch sidebar {
            case "artists": model.sidebar = .artists
            case "songs": model.sidebar = .songs
            case "recent": model.sidebar = .recentlyAdded
            default: if let p = model.library.playlists.first(where: { $0.name == sidebar }), let id = p.id { model.sidebar = .playlist(id) }
            }
        }
        if d.object(forKey: "NocturneShowInspector") != nil { model.showInspector = d.bool(forKey: "NocturneShowInspector") }
        if let open, let album = model.library.albums.first(where: { $0.title == open }) {
            model.openAlbum(album.key)
        }
        if d.bool(forKey: "NocturneOpenMini") { openWindow?(id: "mini") }
        if let play, let album = model.library.albums.first(where: { $0.title == play }) {
            let tracks = model.library.tracks(albumKey: album.key)
            model.player.play(tracks, startAt: d.integer(forKey: "NocturnePlayTrack"))
            if d.double(forKey: "NocturnePauseAfter") > 0 {
                try? await Task.sleep(for: .seconds(d.double(forKey: "NocturnePauseAfter")))
                model.player.engine.pause()
            }
        }
        if let select = d.string(forKey: "NocturneSelectTracks"), let album = model.library.albums.first(where: { $0.title == (open ?? play) }) {
            // "1,3,4" = track numbers within the album
            let numbers = Set(select.split(separator: ",").compactMap { Int($0) })
            let tracks = model.library.tracks(albumKey: album.key).filter { select == "all" || numbers.contains($0.trackNumber ?? -1) }
            model.selectedTrackIDs = Set(tracks.compactMap(\.id))
        }
        if let tab = d.string(forKey: "NocturneInspectorTab") {
            model.inspectorTab = InspectorTab.allCases.first { $0.rawValue.lowercased().hasPrefix(tab.lowercased()) } ?? .nowPlaying
        }
        if let query = d.string(forKey: "NocturneSearch") { model.searchText = query }
        switch d.string(forKey: "NocturneOpenSheet") {
        case "findMusic": model.showFindMusic = true
        case "enrich": model.enrichAlbumKeys = []
        case "connectServer": model.showConnectServer = true
        default: break
        }
    }

    /// Renders every visible window (including its title bar) to `<dir>/<n>-<title>.png`.
    /// Works while the screen is locked because it draws the view hierarchy itself.
    static func snapshotLoop(to directory: String, delay: Double, repeats: Int) async {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in 1...repeats {
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 4))
            for window in NSApp.windows where window.isVisible && window.frame.width > 200 {
                guard let view = window.contentView?.superview ?? window.contentView else { continue }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = window.title.isEmpty ? "window" : window.title.replacingOccurrences(of: "/", with: "-")
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(n)-\(name).png"))
            }
        }
        print("[qa] snapshot done")
        if UserDefaults.standard.bool(forKey: "NocturneQuitAfterSnapshot") { NSApp.terminate(nil) }
    }
}
