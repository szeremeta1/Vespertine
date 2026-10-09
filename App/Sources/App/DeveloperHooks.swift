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

/// The launch arguments (`-Key value`) and nothing else. QA hooks read only these: UserDefaults also answers from
/// the app's saved settings, so a value left there by `defaults write` would apply at every launch, unseen (a test
/// library in place of the real one, or no software updates). Conversions follow UserDefaults (`YES`, `true`, `1`).
nonisolated struct LaunchArguments: Sendable {
    private let values: [String: String]

    init() {
        values = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            .compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
    }

    func object(forKey key: String) -> String? { values[key] }
    func string(forKey key: String) -> String? { values[key] }
    func bool(forKey key: String) -> Bool { values[key].map { ($0 as NSString).boolValue } ?? false }
    func integer(forKey key: String) -> Int { values[key].map { ($0 as NSString).integerValue } ?? 0 }
    func double(forKey key: String) -> Double { values[key].map { ($0 as NSString).doubleValue } ?? 0 }
}

@MainActor
enum DeveloperHooks {
    static func run(_ model: AppModel, openWindow: OpenWindowAction?) async {
        let d = LaunchArguments()
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
                || d.string(forKey: "VespertineOpenSheet") != nil || d.string(forKey: "VespertineFilter") != nil
                || d.string(forKey: "VespertineOpenArtist") != nil || d.string(forKey: "VespertineOpenGenre") != nil
                || d.string(forKey: "VespertinePlaySong") != nil else { return }

        // Wait (bounded) for the library to contain the requested album.
        let wanted = play ?? open
        for _ in 0..<120 {
            // (a page by name needs the playlists and sources read too, which come with the first albums)
            if wanted == nil ? !model.library.albums.isEmpty : model.library.albums.contains(where: { $0.title == wanted }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let sidebar = d.string(forKey: "VespertineSidebar") {
            switch sidebar {
            case "artists": model.sidebar = .artists
            case "songs": model.sidebar = .songs
            case "genres": model.sidebar = .genres
            case "recent": model.sidebar = .recentlyAdded
            case "favorites": model.sidebar = .favorites
            default:
                if let p = model.library.playlists.first(where: { $0.name == sidebar }), let id = p.id { model.sidebar = .playlist(id) }
                else if let s = model.library.sources.first(where: { $0.displayName == sidebar }), let id = s.id { model.sidebar = .source(id) }
            }
        }
        if d.object(forKey: "VespertineShowInspector") != nil { model.showInspector = d.bool(forKey: "VespertineShowInspector") }
        if let open, let album = model.library.albums.first(where: { $0.title == open }) {
            model.openAlbum(album.key)
        }
        // Filters and pages of one artist or genre: -VespertineFilter "genre=Jazz|Blues;decade=1970;sampleRate=96000;flags=bits24"
        // applies to the page on screen (after -VespertineSidebar), before -VespertineOpenArtist/-OpenGenre carry it on.
        if let spec = d.string(forKey: "VespertineFilter") { model.setFilter(filter(spec), for: model.visibleScope) }
        if let chips = d.string(forKey: "VespertineFormatFilter") {
            for chip in chips.split(separator: ",").compactMap({ QuickChip(rawValue: String($0)) }) {
                model.updateFilter(model.visibleScope) { if !chip.isOn($0) { chip.toggle(&$0) } }
            }
        }
        if let genre = d.string(forKey: "VespertineGenreFilter") { model.updateFilter(model.visibleScope) { $0[.genre].insert(Genres.key(genre)) } }
        if let artist = d.string(forKey: "VespertineOpenArtist") {
            model.path.append(.artist(model.library.artists.first { $0.name.localizedCaseInsensitiveCompare(artist) == .orderedSame }?.name ?? artist))
        }
        if let genre = d.string(forKey: "VespertineOpenGenre") { model.path.append(.genre(Genres.key(genre))) }
        if let facet = d.string(forKey: "VespertineOpenFilters") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.filterPanelRequest = FilterPanelRequest(scope: model.visibleScope, facet: Facet(rawValue: facet))
            }
        }
        // `-VespertineShuffle YES`: shuffle the page on screen and list what's queued (use a silent output).
        if d.bool(forKey: "VespertineShuffle") {
            setvbuf(stdout, nil, _IOLBF, 0)
            for _ in 0..<120 where model.library.albums.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            let scope = model.visibleScope
            let started = Date()
            model.play(scope, shuffled: true)
            print("[qa] shuffle \(scope): \(model.player.queue.count) queued in \(String(format: "%.2f", Date().timeIntervalSince(started))) s, shuffle \(model.player.shuffle)")
            for entry in model.player.queue.prefix(12) {
                let t = entry.track
                print("[qa]   \(t.displayAlbumArtist) — \(t.displayAlbum) — \(t.title) · \(t.formatSummary) · \(t.genre ?? "-") · \(t.year.map(String.init) ?? "-")")
            }
            if d.double(forKey: "VespertinePauseAfter") > 0 {
                try? await Task.sleep(for: .seconds(d.double(forKey: "VespertinePauseAfter")))
                model.player.engine.pause()
            }
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
        // `-VespertinePlaySong "Title|Artist|DSD"`: opens and plays the album holding that song, from that song. Artist and
        // a format word (matched against the format summary, e.g. "5.1", "DSD128", "24/96") are optional and pick one
        // version where the library has several.
        if let spec = d.string(forKey: "VespertinePlaySong") {
            let parts = spec.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let matches = { (t: Track) -> Bool in
                t.title.localizedCaseInsensitiveCompare(parts[0]) == .orderedSame
                    && (parts.count < 2 || parts[1].isEmpty || t.displayAlbumArtist.localizedCaseInsensitiveContains(parts[1]))
                    && (parts.count < 3 || t.formatSummary.localizedCaseInsensitiveContains(parts[2]))
            }
            if let song = model.library.allTracks().first(where: matches) {
                let tracks = model.library.tracks(albumKey: song.albumKey)
                model.openAlbum(song.albumKey)
                model.player.play(tracks, startAt: tracks.firstIndex { $0.id == song.id } ?? 0)
                print("[qa] play song: \(song.displayAlbumArtist) — \(song.displayAlbum) — \(song.title) · \(song.formatSummary)")
                if d.double(forKey: "VespertinePauseAfter") > 0 {
                    try? await Task.sleep(for: .seconds(d.double(forKey: "VespertinePauseAfter")))
                    model.player.engine.pause()
                }
            } else {
                print("[qa] play song: no match for \(spec)")
            }
        }
        if let select = d.string(forKey: "VespertineSelectTracks"), let album = model.library.albums.first(where: { $0.title == (open ?? play) }) {
            // "1,3,4" = track numbers within the album
            let numbers = Set(select.split(separator: ",").compactMap { Int($0) })
            let tracks = model.library.tracks(albumKey: album.key).filter { select == "all" || numbers.contains($0.trackNumber ?? -1) }
            model.selectedTrackIDs = Set(tracks.compactMap(\.id))
        }
        // `-VespertineSelectSong "<title>"`: select songs by title (shows their details or analysis without playing).
        if let title = d.string(forKey: "VespertineSelectSong") {
            model.selectedTrackIDs = Set(model.library.allTracks().filter { $0.title == title }.compactMap(\.id))
        }
        if let tab = d.string(forKey: "VespertineInspectorTab") {
            model.inspectorTab = InspectorTab.allCases.first { $0.rawValue.lowercased().hasPrefix(tab.lowercased()) } ?? .nowPlaying
        }
        if let query = d.string(forKey: "VespertineSearch") { model.searchText = query }
        // `-VespertineCycleDevices "FiiO|AirPods" -VespertineCycleEvery 6 -VespertineCycleCount 8`: switch outputs the way
        // the picker does, on a timer, to reproduce switching problems (see the org.szeremeta.vespertine.player log).
        if let names = d.string(forKey: "VespertineCycleDevices")?.split(separator: "|").map(String.init), !names.isEmpty {
            let every = max(1, d.double(forKey: "VespertineCycleEvery") == 0 ? 6 : d.double(forKey: "VespertineCycleEvery"))
            let count = d.integer(forKey: "VespertineCycleCount") == 0 ? 8 : d.integer(forKey: "VespertineCycleCount")
            Task {
                for i in 0..<max(0, count) {
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

    /// "genre=Jazz|Blues;decade=1970;sampleRate=96000;format=flac|dsd;flags=bits24,favorite" → a filter.
    static func filter(_ spec: String) -> LibraryFilter {
        var f = LibraryFilter()
        for part in spec.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let values = pair[1].split(separator: "|").map(String.init)
            if pair[0] == "flags" {
                f.flags = Set(pair[1].split(separator: ",").compactMap { FilterFlag(rawValue: String($0)) })
            } else if let facet = Facet(rawValue: pair[0]) {
                f[facet] = Set(values.map { facet == .genre ? Genres.key($0) : facet == .artist ? $0.lowercased() : $0 })
            }
        }
        return f
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
        if LaunchArguments().bool(forKey: "VespertineQuitAfterSnapshot") { NSApp.terminate(nil) }
    }
}
