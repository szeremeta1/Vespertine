//
// Vespertine: launch-argument hooks for reproducible visual QA and screenshots.
// None of these run unless the argument is passed, e.g.:
//   Vespertine.app/Contents/MacOS/Vespertine -VespertineDataDirectory /tmp/lib -VespertineAddSource ~/Demo \
//       -VespertineOpenAlbum "Horizon Line" -VespertinePlayAlbum "Horizon Line" -VespertinePlayTrack 2 -VespertinePauseAfter 4
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import VespertineAudio
import VespertineLibrary
import VespertineOpenSubsonic
import VespertineStreaming
import VespertineUPnP
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
        // `-VespertineEQPreset <ParametricEQ.txt>`: imports an AutoEQ / Equalizer APO file and turns it on for the
        // chosen output, as Import… and the output's switch in the Equalizer window do.
        if let path = d.string(forKey: "VespertineEQPreset") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                var preset = try EQPreset.parse(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent)
                if let i = model.settings.eqPresets.firstIndex(where: { $0.name == preset.name }) {   // imported before: refresh it
                    preset.id = model.settings.eqPresets[i].id
                    model.settings.eqPresets[i] = preset
                } else {
                    model.settings.eqPresets.append(preset)
                }
                if let uid = model.settings.selectedDeviceUID { model.settings.setEQPreset(preset.id, for: uid) }
                model.syncEngine()
                print("[qa] equalizer: \(preset.name), \(preset.bands.count) bands, on \(model.settings.selectedDeviceUID ?? "no output")")
            } catch {
                print("[qa] equalizer import failed: \(error.localizedDescription)")
            }
        }
        // `-VespertineRoomProfile <file>`: imports a room correction (room-profile.json, Equalizer APO text, or an
        // impulse response) for the output in use and turns it on, as Import in the Room Correction window does.
        if let path = d.string(forKey: "VespertineRoomProfile"), let device = model.activeDevice {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let name = url.deletingPathExtension().lastPathComponent
            do {
                var profile: RoomProfile
                switch url.pathExtension.lowercased() {
                case "json": profile = try RoomProfileArchive.decode(try Data(contentsOf: url))
                case "txt": profile = try RoomAPO.profile(try String(contentsOf: url, encoding: .utf8), name: name, deviceUID: device.uid)
                default: profile = try RoomImpulseImport.profile(files: [url], name: name, deviceUID: device.uid)
                }
                profile.deviceUID = device.uid
                profile = model.settings.saveRoomProfile(profile)
                model.settings.setRoomProfile(profile.id, for: device.uid)
                model.syncEngine()
                print("[qa] room correction: \(profile.name), \(profile.layout.speakers.count) speakers")
            } catch {
                print("[qa] room correction import failed: \(error.localizedDescription)")
            }
        }
        // `-VespertineOpenWindow equalizer|mini|room-correction`: opens one of the app's other windows.
        // `-VespertineOpenSheet room-measure`: opens the measurement wizard at its first step, without starting it.
        // `-VespertineOpenSheet transitions`: the note shown the first time transitions are turned on (nothing is changed).
        if let id = d.string(forKey: "VespertineOpenWindow") { openWindow?(id: id) }
        if d.string(forKey: "VespertineOpenSheet")?.hasPrefix("loopback") == true { model.showLoopbackTest = true }   // loopback-run also starts it
        if d.string(forKey: "VespertineOpenSheet") == "transitions", model.settings.transitionsFeature { model.transitionsNote.show(in: .main) }
        // `-VespertineWindowSize 1440x900`: sizes the main window (in points), so every screenshot has one framing
        // whatever frame the window last saved.
        if let size = d.string(forKey: "VespertineWindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.filter({ $0.isVisible && $0.styleMask.contains(.titled) })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                    let visible = window.screen?.visibleFrame ?? window.frame
                    window.setFrame(NSRect(x: visible.minX + 40, y: visible.maxY - size[1] - 20, width: size[0], height: size[1]), display: true)
                }
            }
        }
        // `-VespertineVizScript "play,open,wait:3,probe,close,wait:1,next,wait:2,open,wait:1,probe,shot:reopened"`: drives the
        // visualizer window the way a person does (open it, close it, skip, open it again) and says what the analysis sees
        // after each step. `play` waits for a song playing; `probe` prints the feed's frames, the tap's position and the
        // loudness; `shot:<name>` prints the window's number for an outside `screencapture -l`.
        if let script = d.string(forKey: "VespertineVizScript") {
            Task { await runVisualizerScript(script, model: model, openWindow: openWindow) }
        }
        // `-VespertineQuitAfter 60`: quits after that many seconds (timed runs, such as the visualizer's measurements).
        if d.double(forKey: "VespertineQuitAfter") > 0 {
            Task {
                try? await Task.sleep(for: .seconds(d.double(forKey: "VespertineQuitAfter")))
                NSApp.terminate(nil)
            }
        }
        // QA ONLY: `-VespertineQAEnableTransitions <dir>` opens Settings, flips the Transitions toggle's model call, and
        // reports and shoots every window before and after.
        if let path = d.string(forKey: "VespertineQAEnableTransitions") {
            Task { @MainActor in
                @MainActor func note(_ line: String) {
                    print(line); fflush(stdout)
                }
                @MainActor func report(_ tag: String) {
                    for w in NSApp.windows where w.frame.width > 100 {
                        note("[qa-win] \(tag) title='\(w.title)' id=\(w.identifier?.rawValue ?? "-") visible=\(w.isVisible) key=\(w.isKeyWindow) main=\(w.isMainWindow) mini=\(w.isMiniaturized) sheet=\(w.attachedSheet != nil) order=\(NSApp.orderedWindows.firstIndex(of: w) ?? -1)")
                    }
                }
                @MainActor func shoot(_ tag: String) {
                    let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.frame.width > 200 {
                        guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(tag)-\(i)-\(w.title.isEmpty ? "sheet" : w.title).png"))
                    }
                }
                try? await Task.sleep(for: .seconds(3))
                // The app menu's own Settings item, as a click on it does.
                if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }), let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
                try? await Task.sleep(for: .seconds(2))
                report("before"); shoot("before")
                model.setTransitionsFeature(true)
                note("[qa-win] flag note main=\(model.transitionsNote.isShown(in: .main)) settings=\(model.transitionsNote.isShown(in: .settings))")
                try? await Task.sleep(for: .seconds(2))
                report("after"); shoot("after")
                NSApp.terminate(nil)
            }
        }
        // `-VespertineStreamingDemo http://127.0.0.1:4533`: turns Music Servers on and signs in to a test server at that address
        // (user "listener"), with the sign-in held in memory only. `-VespertineStreamingDemoName "Home Server"` names it.
        if let address = d.string(forKey: "VespertineStreamingDemo") {
            let id = OpenSubsonicProvider.providerID
            model.streaming.setOn(true, id)
            let failure = await model.streaming.signIn(id, source: model.streaming.accounts(id).first,
                                                       name: d.string(forKey: "VespertineStreamingDemoName") ?? "Home Server",
                                                       request: ProviderSignIn(server: address, user: "listener", secret: .password("demo")))
            print("[qa] streaming demo: \(failure ?? "signed in")")
        }
        // `-VespertineSpeakerGroupsDemo quad|5.1|7.1.4`: on a test library only (`-VespertineDataDirectory`), turns Speaker Groups on
        // and saves a group of pretend DACs laid out that way, so its screens can be looked at with no DAC attached and nothing
        // played. `-VespertineSpeakerGroupsFill YES` has it fill the room, in a listening area. `-VespertineEditSpeakerGroup YES`
        // shows its editor and `-VespertineSpeakerGroupsSettings YES` the two Settings › Playback sections about groups, each in a
        // window of its own (in Settings they are far down a list, where a snapshot doesn't reach). `-VespertineRoomView
        // top|back|side` and `-VespertineRoomSelect FL` choose the room's view and a speaker there.
        if let layout = d.string(forKey: "VespertineSpeakerGroupsDemo"), d.string(forKey: "VespertineDataDirectory") != nil {
            model.setSpeakerGroupsFeature(true)
            var group = demoSpeakerGroup(layout, fillsRoom: d.bool(forKey: "VespertineSpeakerGroupsFill"))
            // `-VespertineSpeakerGroupsPreset surround714` (a `GroupPresets.Preset`): lays it out with that preset instead, on as many
            // pretend DACs as it takes.
            if let preset = d.string(forKey: "VespertineSpeakerGroupsPreset").flatMap(GroupPresets.Preset.init(rawValue:)) {
                let names = ["Fosi Audio ZD3", "FiiO K11", "Topping E30 II", "SMSL SU-1", "Schiit Modi", "iFi Zen DAC", "Cambridge DacMagic", "Topping D10s"]
                group.members = (0..<(preset.speakerCount + 1) / 2).map { SpeakerGroup.Member(deviceUID: "demo-dac-\($0)", name: names[$0 % names.count], channelCount: 2) }
                group = GroupPresets.apply(preset, to: group) ?? group
            }
            model.speakerGroups?.upsert(group)
            if let part = d.string(forKey: "VespertineEditSpeakerGroup"), part == "lower" || part == "policies", let groups = model.speakerGroups {
                // `-VespertineEditSpeakerGroup lower|policies`: the editor's sections below the room (outputs and channels, or volume and
                // policies), which a snapshot of the editor doesn't reach.
                showForQA(titled: "Speaker Group Editor", width: 820, height: 940, model: model) {
                    SpeakerGroupEditorLowerHalf(groups: groups, group: group, policies: part == "policies")
                }
            } else if d.bool(forKey: "VespertineEditSpeakerGroup"), let groups = model.speakerGroups {
                showForQA(titled: "Speaker Group Editor", width: 820, height: 940, model: model) { SpeakerGroupEditor(groups: groups, group: group) }
            }
            // `-VespertineSystemOutputPreview notInstalled|notLoaded|outdated|ready|playing|failed|approval`: draws Mac Sound Output as if
            // its driver and helper were in that state (nothing is installed or published on a test library).
            if let state = d.string(forKey: "VespertineSystemOutputPreview") {
                let driver: SystemOutputModel.DriverState = switch state {
                case "notInstalled": .notInstalled
                case "notLoaded": .notLoaded
                case "outdated": .outdated
                default: .ready
                }
                var status: SystemOutputStatus?
                if ["ready", "playing", "failed", "approval"].contains(state) {
                    model.systemOutput.setChoice(SystemOutputChoice(published: true, layout: .automatic, stereo: state == "playing" ? .upmix : .asGroup), for: group.id)
                    let row: [String: Any] = ["groupID": group.id.uuidString, "name": group.name, "state": state == "approval" ? "ready" : state, "isDefault": state == "playing",
                                              "sampleRate": 48_000, "latencyMs": 21, "message": "The FiiO K11 is not connected."]
                    let whole: [String: Any] = ["driverLoaded": true, "groups": [row], "menuBarItem": true, "updated": "2026-01-01T00:00:00Z"]
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    status = (try? JSONSerialization.data(withJSONObject: whole)).flatMap { try? decoder.decode(SystemOutputStatus.self, from: $0) }
                }
                model.systemOutput.previewForQA(driver: driver, helper: state == "approval" ? .needsApproval : (driver == .ready ? .on : .off), status: status)
            }
            if d.bool(forKey: "VespertineSpeakerGroupsSettings") {
                showForQA(titled: "Speaker Groups Settings", width: 560, height: 760, model: model) {
                    Form {
                        SpeakerGroupsSettingsSection()
                        SystemOutputSettingsSection()
                    }
                    .formStyle(.grouped)
                }
            }
            print("[qa] speaker group demo: \(group.name), \(group.speakers.count) speakers, issues \(group.issues)")
        }
        // `-VespertineOpenSettings playback|library|network|online|remote`: opens Settings on that tab.
        if let tab = d.string(forKey: "VespertineOpenSettings") {
            switch tab {
            case "library": model.settingsTab = .library
            case "network": model.settingsTab = .network
            case "online": model.settingsTab = .online
            case "remote": model.settingsTab = .remote
            default: model.settingsTab = .playback
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                // The app menu's own Settings item, as a click on it does.
                if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }), let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }
        }
        if let path = d.string(forKey: "VespertineSnapshot") {
            Task { await snapshotLoop(to: path, delay: d.double(forKey: "VespertineSnapshotDelay"), repeats: max(1, d.integer(forKey: "VespertineSnapshotCount"))) }
        }
        guard open != nil || play != nil || d.object(forKey: "VespertineInspectorTab") != nil || d.bool(forKey: "VespertineOpenMini")
                || d.string(forKey: "VespertineFormatFilter") != nil || d.string(forKey: "VespertineSidebar") != nil
                || d.string(forKey: "VespertineOpenSheet") != nil || d.string(forKey: "VespertineFilter") != nil
                || d.string(forKey: "VespertineOpenArtist") != nil || d.string(forKey: "VespertineOpenGenre") != nil
                || d.string(forKey: "VespertinePlaySong") != nil || d.string(forKey: "VespertineShowQueue") != nil
                || d.string(forKey: "VespertineReceiverDemo") != nil else { return }

        // Wait (bounded) for the library to contain the requested album.
        let wanted = play ?? open
        for _ in 0..<120 {
            // (a page by name needs the playlists and sources read too, which come with the first albums)
            if wanted == nil ? !model.library.albums.isEmpty : model.library.albums.contains(where: { $0.title == wanted }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let sidebar = d.string(forKey: "VespertineSidebar") {
            switch sidebar {
            case "albums": model.sidebar = .albums
            case "artists": model.sidebar = .artists
            case "songs": model.sidebar = .songs
            case "genres": model.sidebar = .genres
            case "recent": model.sidebar = .recentlyAdded
            case "favorites": model.sidebar = .favorites
            default:
                // A playlist, a folder or a music server by name. A server's page and its playlists are listed a moment after the sign-in.
                for _ in 0..<40 {
                    if let id = model.library.playlists.first(where: { $0.name == sidebar })?.id { model.sidebar = .playlist(id); break }
                    if let id = (model.library.sources + model.library.streamedAccounts).first(where: { $0.displayName == sidebar })?.id {
                        model.sidebar = .source(id)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        if d.object(forKey: "VespertineShowInspector") != nil { model.showInspector = d.bool(forKey: "VespertineShowInspector") }
        // QA: -VespertineShowQueue upNext|history opens Up Next on that tab.
        if let tab = d.string(forKey: "VespertineShowQueue").flatMap(QueueTab.init(rawValue:)) { model.queueTab = tab; model.showQueue = true }
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
        // `-VespertineReceiverDemo mconnect`: shows how Receive from Other Apps looks while a control app of that name plays, without
        // a sound: the last album's first songs stand in for what the app sent, the first album's for the listener's own queue.
        if let name = d.string(forKey: "VespertineReceiverDemo"), let sent = model.library.albums.last, let own = model.library.albums.first {
            let songs = model.library.tracks(albumKey: sent.key)
            model.player.showReceiverDemo(from: ReceiverControlApp(name: name, address: "192.0.2.7"), songs: songs,
                                          kept: model.library.tracks(albumKey: own.key), artworkKey: model.artworkKey(songs.first))
            print("[qa] receiver demo: \(songs.first?.title ?? "-") from \(name)")
        }
        if d.bool(forKey: "VespertineOpenMini") { openWindow?(id: "mini") }
        if let play, let album = model.library.albums.first(where: { $0.title == play }) {
            let tracks = model.playableTracks(albumKey: album.key)
            model.player.play(tracks, startAt: d.integer(forKey: "VespertinePlayTrack"))
            if d.double(forKey: "VespertinePauseAfter") > 0 {
                try? await Task.sleep(for: .seconds(d.double(forKey: "VespertinePauseAfter")))
                model.player.engine.pause()
            }
        }
        // `-VespertinePlaySong "Title|Artist|DSD|.iso"`: opens and plays the album holding the first song whose title contains Title, from that song. Artist and
        // a format word (matched against the format summary, e.g. "5.1", "DSD128", "24/96") are optional and pick one
        // version where the library has several; a fourth part matches the file's path.
        if let spec = d.string(forKey: "VespertinePlaySong") {
            let parts = spec.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let matches = { (t: Track) -> Bool in
                t.title.localizedCaseInsensitiveContains(parts[0])
                    && (parts.count < 2 || parts[1].isEmpty || t.displayAlbumArtist.localizedCaseInsensitiveContains(parts[1]))
                    && (parts.count < 3 || parts[2].isEmpty || t.formatSummary.localizedCaseInsensitiveContains(parts[2]))
                    && (parts.count < 4 || t.filePath.localizedCaseInsensitiveContains(parts[3]))   // e.g. ".iso"
            }
            if let song = model.library.allTracks().first(where: matches) {
                // The copy of the album the song is in, so the queue goes on in that copy.
                let tracks = model.library.albumCopies(albumKey: song.albumKey).copy(of: song)?.tracks ?? [song]
                if d.string(forKey: "VespertineSidebar") == nil { model.openAlbum(song.albumKey) }   // else stay on that page
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

    private static var qaWindows: [NSWindow] = []

    /// A view of the app in a window of its own, for a snapshot. The window is kept for as long as the app runs.
    private static func showForQA(titled title: String, width: Double, height: Double, model: AppModel, @ViewBuilder content: () -> some View) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content().environment(model).preferredColorScheme(.dark)))
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        qaWindows.append(window)
    }

    /// A group of pretend two-channel DACs for `-VespertineSpeakerGroupsDemo`: a quad on two, a 5.1 on three, a 7.1.4 on six, in a
    /// 5.2 by 4.4 m room with a 2.5 m ceiling, the seat a little behind its middle.
    private static func demoSpeakerGroup(_ layout: String, fillsRoom: Bool) -> SpeakerGroup {
        // Role, degrees from straight ahead, metres from the seat across the floor, metres above the floor (nil: at the ears).
        let places: [(SpeakerRole, Double, Double, Double?)] = switch layout {
        case "7.1.4":
            [(.frontLeft, -30, 2.2, nil), (.frontRight, 30, 2.2, nil), (.center, 0, 2.1, 1.0), (.lfe, 18, 2.3, 0.2), (.sideLeft, -90, 1.9, nil),
             (.sideRight, 90, 1.9, nil), (.backLeft, -145, 1.9, nil), (.backRight, 145, 1.9, nil), (.topFrontLeft, -40, 1.5, 2.5),
             (.topFrontRight, 40, 1.5, 2.5), (.topBackLeft, -140, 1.4, 2.5), (.topBackRight, 140, 1.4, 2.5)]
        case "5.1":
            [(.frontLeft, -30, 2.2, nil), (.frontRight, 30, 2.2, nil), (.center, 0, 2.1, 1.0), (.lfe, 18, 2.3, 0.2), (.sideLeft, -110, 1.8, 1.5),
             (.sideRight, 110, 1.8, 1.5)]
        default:
            [(.frontLeft, -32, 2.2, nil), (.frontRight, 32, 2.2, nil), (.backLeft, -140, 1.8, 1.6), (.backRight, 140, 1.8, 1.6)]
        }
        let names = ["Fosi Audio ZD3", "FiiO K11", "Topping E30 II", "SMSL SU-1", "Schiit Modi", "iFi Zen DAC"]
        let members = (0..<(places.count + 1) / 2).map { SpeakerGroup.Member(deviceUID: "demo-dac-\($0)", name: names[$0 % names.count], channelCount: 2) }
        var group = SpeakerGroup(id: UUID(uuidString: "5EA4E700-0000-4000-8000-00000000D3A0")!, name: layout == "quad" || places.count == 4 ? "Living Room" : "Cinema",
                                 members: members, clockLeaderUID: members[0].deviceUID,
                                 listener: Listener(position: Point2D(x: 0, y: -0.4)), room: RoomOutline(width: 5.2, depth: 4.4, height: 2.5))
        for (index, place) in places.enumerated() {
            let bearing = place.1 * .pi / 180
            let speaker = SpeakerGroup.Speaker(role: place.0, deviceUID: members[index / 2].deviceUID, channel: index % 2,
                                               position: Point2D(x: group.listener.position.x + place.2 * sin(bearing), y: group.listener.position.y + place.2 * cos(bearing)))
            group.speakers.append(speaker)
            group = RoomCanvas.move(speaker: speaker.id, to: speaker.position, in: group)
            if let height = place.3 { group = RoomCanvas.setHeight(speaker: speaker.id, aboveFloor: height, in: group) }
        }
        if fillsRoom {
            group = GroupPolicies.setRoomRender(true, in: group)
            group = RoomCanvas.sizeListeningArea(width: 3.4, depth: 2.6, in: group)
            group = RoomCanvas.moveListeningArea(to: Point2D(x: 0, y: -0.5), in: group)
        }
        return group
    }

    /// The visualizer window, when there is one on screen.
    private static var visualizerWindow: NSWindow? { NSApp.windows.first { $0.title == "Visualizer" } }

    private static func metalView(in view: NSView?) -> VisualizerMTKView? {
        guard let view else { return nil }
        if let metal = view as? VisualizerMTKView { return metal }
        for sub in view.subviews { if let found = metalView(in: sub) { return found } }
        return nil
    }

    private static func menuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title, item.action != nil || item.hasSubmenu == false { return item }
            if let found = menuItem(titled: title, in: item.submenu) { return found }
        }
        return nil
    }

    static func runVisualizerScript(_ script: String, model: AppModel, openWindow: OpenWindowAction?) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        model.settings.visualizerEnabled = true
        var left = [Float](repeating: 0, count: 2048), right = left
        for step in script.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let name = step.split(separator: ":", maxSplits: 1).first.map(String.init) ?? step
            let arg = step.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
            switch name {
            case "play":
                for _ in 0..<240 where model.player.current == nil || !model.player.isPlaying { try? await Task.sleep(for: .milliseconds(250)) }
                print("[viz] \(step): playing \(model.player.current?.track.title ?? "nothing")")
            case "wait": try? await Task.sleep(for: .seconds(Double(arg ?? "1") ?? 1))
            case "open":
                // The Window menu's Visualizer item, as a click on it does (the hooks may not have an `openWindow`).
                if let openWindow { openWindow(id: "visualizer"); print("[viz] open requested") }
                else if let item = menuItem(titled: "Visualizer", in: NSApp.mainMenu), let menu = item.menu {
                    menu.performActionForItem(at: menu.index(of: item)); print("[viz] open requested (menu)")
                } else { print("[viz] open: no Visualizer menu item") }
            case "close":
                if let w = visualizerWindow { w.performClose(nil); print("[viz] close requested") } else { print("[viz] close: no window") }
            case "next": model.player.next(); print("[viz] next → \(model.player.current?.track.title ?? "-")")
            case "prev": model.player.previous(); print("[viz] previous → \(model.player.current?.track.title ?? "-")")
            case "probe":
                let frame = model.visualizer.feed.frame, stats = model.visualizer.feed.stats
                let read = model.player.engine.copyVisualizerTap(left: &left, right: &right)
                let window = visualizerWindow
                let metal = window.flatMap { metalView(in: $0.contentView) }
                print("[viz] view: isPaused \(metal.map { String($0.isPaused) } ?? "no view") · occlusion visible \(window.map { String($0.occlusionState.contains(.visible)) } ?? "-") · frames drawn \(metal?.drawCount ?? -1)")
                print(String(format: "[viz] probe %@: song %@ · showing %d · window %@ visible %@ · feed frames %d · frame.time %.3f · bands Σ %.3f · rms %.1f/%.1f dB · tap position %@ rate %.0f",
                             arg ?? "", model.player.current?.track.title ?? "-", model.visualizer.showing,
                             window.map { "#\($0.windowNumber)" } ?? "none", window.map { String($0.isVisible) } ?? "-", stats.frames, frame.time,
                             frame.bands.reduce(0, +), frame.rmsDB.x, frame.rmsDB.y,
                             read.map { String($0.position) } ?? "nil", read?.sampleRate ?? 0))
            case "shot":
                let window = visualizerWindow
                print("[viz] shot \(arg ?? "") window \(window.map { String($0.windowNumber) } ?? "none")")
                try? await Task.sleep(for: .seconds(1.5))   // time for an outside capture
            case "quit": NSApp.terminate(nil)
            default: print("[viz] unknown step \(step)")
            }
        }
        print("[viz] script done")
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
        guard LaunchArguments().bool(forKey: "VespertineQuitAfterSnapshot") else { return }
        // A window with a sheet up (the loopback test's) holds the quit off, so the sheets close first. Should the
        // app still be here a moment later, a QA run ends anyway.
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
        try? await Task.sleep(for: .seconds(3))
        exit(0)
    }
}

/// QA only (`-VespertineEditSpeakerGroup lower|policies`): the speaker group editor's sections under the room, as the editor shows them.
private struct SpeakerGroupEditorLowerHalf: View {
    let groups: SpeakerGroupsModel
    @State var group: SpeakerGroup
    var policies = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if policies {
                    MemberVolumeView(group: group)
                    SpeakerPoliciesView(group: $group)
                } else {
                    GroupOutputsView(group: $group)
                    ChannelMapGrid(group: $group)
                }
            }
            .padding(20)
        }
        .onChange(of: group) { _, new in groups.upsert(new) }
    }
}
