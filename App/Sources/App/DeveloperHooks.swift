//
// Vespertine — launch-argument hooks for reproducible visual QA and screenshots.
// None of these run unless the argument is passed, e.g.:
//   Vespertine.app/Contents/MacOS/Vespertine -VespertineDataDirectory /tmp/lib -VespertineAddSource ~/Demo \
//       -VespertineOpenAlbum "Horizon Line" -VespertinePlayAlbum "Horizon Line" -VespertinePlayTrack 2 -VespertinePauseAfter 4
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import VespertineAudio
import VespertineLibrary
import SwiftUI

@MainActor
enum DeveloperHooks {
    static func run(_ model: AppModel, openWindow: OpenWindowAction?) async {
        let d = UserDefaults.standard
        let open = d.string(forKey: "VespertineOpenAlbum")
        let play = d.string(forKey: "VespertinePlayAlbum")
        if let address = d.string(forKey: "VespertineAddShare") {
            // Adds a network share using the keychain's saved password (never one passed on the command line).
            Task {
                guard let share = NetworkShare(string: address) else { print("[qa] add share: invalid address"); return }
                do {
                    try await model.shares.add(share, password: nil, remember: false, name: d.string(forKey: "VespertineShareName"), writable: false)
                    print("[qa] add share: ok")
                } catch {
                    print("[qa] add share failed: \(error.localizedDescription)")
                }
            }
        }
        if d.bool(forKey: "VespertineOpenSettings") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        if let path = d.string(forKey: "VespertineSnapshot") {
            Task { await snapshotLoop(to: path, delay: d.double(forKey: "VespertineSnapshotDelay"), repeats: max(1, d.integer(forKey: "VespertineSnapshotCount"))) }
        }
        guard open != nil || play != nil || d.object(forKey: "VespertineInspectorTab") != nil || d.bool(forKey: "VespertineOpenMini")
                || d.string(forKey: "VespertineFormatFilter") != nil || d.string(forKey: "VespertineSidebar") != nil
                || d.string(forKey: "VespertineOpenSheet") != nil else { return }

        // Wait (bounded) for the library to contain the requested album.
        let wanted = play ?? open
        for _ in 0..<120 {
            if wanted == nil || model.library.albums.contains(where: { $0.title == wanted }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let sidebar = d.string(forKey: "VespertineSidebar") {
            switch sidebar {
            case "artists": model.sidebar = .artists
            case "songs": model.sidebar = .songs
            case "genres": model.sidebar = .genres
            case "recent": model.sidebar = .recentlyAdded
            case "favorites": model.sidebar = .favorites
            default: if let p = model.library.playlists.first(where: { $0.name == sidebar }), let id = p.id { model.sidebar = .playlist(id) }
            }
        }
        if d.object(forKey: "VespertineShowInspector") != nil { model.showInspector = d.bool(forKey: "VespertineShowInspector") }
        if let open, let album = model.library.albums.first(where: { $0.title == open }) {
            model.openAlbum(album.key)
        }
        if d.bool(forKey: "VespertineOpenMini") { openWindow?(id: "mini") }
        if let play, let album = model.library.albums.first(where: { $0.title == play }) {
            let tracks = model.library.tracks(albumKey: album.key)
            model.player.play(tracks, startAt: d.integer(forKey: "VespertinePlayTrack"))
            if d.double(forKey: "VespertinePauseAfter") > 0 {
                try? await Task.sleep(for: .seconds(d.double(forKey: "VespertinePauseAfter")))
                model.player.engine.pause()
            }
        }
        if let select = d.string(forKey: "VespertineSelectTracks"), let album = model.library.albums.first(where: { $0.title == (open ?? play) }) {
            // "1,3,4" = track numbers within the album
            let numbers = Set(select.split(separator: ",").compactMap { Int($0) })
            let tracks = model.library.tracks(albumKey: album.key).filter { select == "all" || numbers.contains($0.trackNumber ?? -1) }
            model.selectedTrackIDs = Set(tracks.compactMap(\.id))
        }
        if let tab = d.string(forKey: "VespertineInspectorTab") {
            model.inspectorTab = InspectorTab.allCases.first { $0.rawValue.lowercased().hasPrefix(tab.lowercased()) } ?? .nowPlaying
        }
        if let query = d.string(forKey: "VespertineSearch") { model.searchText = query }
        if let genre = d.string(forKey: "VespertineGenreFilter") { model.library.genreFilter = Genres.key(genre) }
        // `-VespertineCycleDevices "FiiO|AirPods" -VespertineCycleEvery 6 -VespertineCycleCount 8`: switch outputs the way
        // the picker does, on a timer, to reproduce switching problems (see the org.szeremeta.vespertine.player log).
        if let cycle = d.string(forKey: "VespertineCycleDevices") {
            let names = cycle.split(separator: "|").map(String.init)
            let every = max(1, d.double(forKey: "VespertineCycleEvery") == 0 ? 6 : d.double(forKey: "VespertineCycleEvery"))
            let count = d.integer(forKey: "VespertineCycleCount") == 0 ? 8 : d.integer(forKey: "VespertineCycleCount")
            Task {
                for i in 0..<count {
                    try? await Task.sleep(for: .seconds(every))
                    let name = names[i % names.count]
                    let device = model.devices.devices.first { $0.name.localizedCaseInsensitiveContains(name) }
                    print("[qa] switch \(i + 1): \(name) → \(device?.name ?? "not listed") at \(Date())")
                    if let device { model.selectDevice(device.uid) }
                }
            }
        }
        // `-VespertineSkipBurst 8 -VespertineSkipEvery 0.15 -VespertineSkipAfter 4`: press Next quickly, the way you
        // skip through a shuffle, then report what plays (queue, engine and signal path should agree on the last one).
        if d.integer(forKey: "VespertineSkipBurst") > 0 {
            let count = d.integer(forKey: "VespertineSkipBurst")
            let every = d.double(forKey: "VespertineSkipEvery") == 0 ? 0.15 : d.double(forKey: "VespertineSkipEvery")
            let after = d.double(forKey: "VespertineSkipAfter") == 0 ? 4 : d.double(forKey: "VespertineSkipAfter")
            setvbuf(stdout, nil, _IOLBF, 0)   // lines reach a log file even if the run is killed
            Task {
                let player = model.player
                try? await Task.sleep(for: .seconds(after))
                let start = Date()
                for i in 0..<count {
                    player.next()
                    print("[qa] skip \(i + 1) at \(String(format: "%.2f", Date().timeIntervalSince(start))) s → \(player.current?.track.title ?? "-")")
                    try? await Task.sleep(for: .seconds(every))
                }
                for _ in 0..<24 {
                    try? await Task.sleep(for: .milliseconds(500))
                    let rate = player.signalPath.map { SampleRate.format($0.source.sampleRate) } ?? "-"
                    let playing = player.engine.snapshot.item.flatMap { item in player.queue.first { $0.id == item.id } }?.track.title ?? "-"
                    print("[qa] \(String(format: "%5.1f", Date().timeIntervalSince(start))) s: queue \(player.current?.track.title ?? "-") · engine \(playing) · path \(rate) kHz · \(player.state)")
                }
                player.stop()
                print("[qa] skip burst done")
            }
        }
        if let format = d.string(forKey: "VespertineFormatFilter"), let filter = FormatFilter(rawValue: format) { model.library.formatFilter = filter }
        switch d.string(forKey: "VespertineOpenSheet") {
        case "findMusic": model.showFindMusic = true
        case "enrich": model.enrichAlbumKeys = []
        case "connectServer": model.showConnectServer = true
        case "spatialExport":
            if let album = model.library.albums.first(where: { $0.title == (open ?? play) }) {
                model.spatialExportTracks = model.library.tracks(albumKey: album.key)
            }
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
        if UserDefaults.standard.bool(forKey: "VespertineQuitAfterSnapshot") { NSApp.terminate(nil) }
    }
}
