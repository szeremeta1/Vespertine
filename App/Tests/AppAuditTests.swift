import AVFAudio
import Foundation
import VespertineAudio
import VespertineLibrary
import VespertineVisualizer
import Testing
@testable import Vespertine

/// A suite named by absolute path keeps its plist in `dir`. Named suites leak into `defaults domains`:
/// cfprefsd rewrites an empty ~/Library/Preferences/<suite>.plist seconds after `removePersistentDomain`.
private func scratchDefaults(in dir: URL) throws -> (defaults: UserDefaults, suite: String) {
    let suite = dir.appendingPathComponent("defaults.plist").path
    return (try #require(UserDefaults(suiteName: suite)), suite)
}

@Suite("App audit", .serialized) @MainActor
struct AppAuditTests {
    @Test func malformedRatePreferencesFallBack() {
        for code in ["fixed:nan", "fixed:inf", "fixed:-1", "fixed:1e200", "fixed:0", "garbage"] {
            #expect(RateChoice(code: code) == .match)
        }
        #expect(RateChoice(code: "fixed:96000") == .fixed(96000))
    }
    @Test("Match 16-bit sources is off until turned on, and reaches the engine")
    func matchSixteenBitSetting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-16bit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.matchSixteenBit && !settings.engineSettings().matchSixteenBit)
        settings.matchSixteenBit = true
        #expect(settings.engineSettings().matchSixteenBit)
        #expect(AppSettings(defaults: defaults, dataDirectory: root).matchSixteenBit)
    }
    @Test("The visualizer is off until turned on; its style, options and window come back after a relaunch")
    func visualizerSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-visualizer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.visualizerEnabled)
        #expect(settings.visualizer == VisualizerSettings())
        #expect(settings.visualizerWindow == nil)
        settings.visualizerEnabled = true
        settings.visualizer.style = .vinyl
        settings.visualizer.theme = .ember
        settings.visualizer.tonearm = false
        let window = VisualizerWindowState(frame: CGRect(x: 1600, y: 100, width: 1920, height: 1080), displayID: 5,
                                           displayName: "Studio Display", fullScreen: true)
        settings.visualizerWindow = window
        let again = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(again.visualizerEnabled)
        #expect(again.visualizer.style == .vinyl && again.visualizer.theme == .ember && !again.visualizer.tonearm)
        #expect(again.visualizerWindow == window)
    }
    @Test("Volume keys reach the exclusively held device only once turned on")
    func relayVolumeKeysSetting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-relay-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.relayVolumeKeys)
        #expect(settings.systemOutputFollowsPlayback)
        settings.relayVolumeKeys = true
        #expect(AppSettings(defaults: defaults, dataDirectory: root).relayVolumeKeys)
    }
    @Test("The AirPods Max reference presets are offered, but play only once chosen")
    func airPodsMaxReferenceEQIsOptIn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-eq-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let uid = "AirPods-Max-USB"

        for preset in AirPodsMaxEQProfiles.all { #expect(settings.eqPresets.contains { $0.id == preset.id }) }
        // Nothing chosen: no output plays an equalizer, AirPods Max included (48 kHz stays bit-perfect).
        #expect(settings.eqAssignments.isEmpty)
        #expect(settings.eqPreset(for: uid) == nil && settings.engineSettings().equalizers.isEmpty)
        #expect(AppSettings(defaults: defaults, dataDirectory: root).engineSettings().equalizers.isEmpty)

        settings.setEQPreset(AirPodsMaxEQProfiles.firstGeneration.id, for: uid)
        #expect(settings.eqPreset(for: uid)?.id == AirPodsMaxEQProfiles.firstGeneration.id)
        #expect(settings.engineSettings().equalizers[uid]?.id == AirPodsMaxEQProfiles.firstGeneration.id)
    }
    @Test("Choosing Off for an output is kept as a choice and carried to its new UID")
    func equalizerOffIsRemembered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-eq-off-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let uid = "AirPods-Max-USB"
        settings.setEQPreset(AirPodsMaxEQProfiles.secondGeneration.id, for: uid)
        settings.setEQPreset(nil, for: uid)

        let reloaded = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(reloaded.eqAssignments[uid] != nil)
        #expect(reloaded.eqPreset(for: uid) == nil && reloaded.engineSettings().equalizers.isEmpty)
        reloaded.moveDeviceSettings(from: uid, to: "AirPods-Max-USB-2")
        #expect(reloaded.eqAssignments["AirPods-Max-USB-2"] == reloaded.eqAssignments[uid])
        #expect(reloaded.engineSettings().equalizers.isEmpty)
    }
    @Test("A deleted reference preset stays deleted")
    func deletedReferencePresetStaysDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-eq-delete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        // Upgrading with presets of one's own: the reference presets are added once, after them.
        let own = EQPreset(name: "Mine", bands: [EQBand()])
        defaults.set(try JSONEncoder().encode([own]), forKey: "eqPresets")
        let first = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(first.eqPresets.map(\.id) == [own.id] + AirPodsMaxEQProfiles.all.map(\.id))
        #expect(AppSettings(defaults: defaults, dataDirectory: root).eqPresets.map(\.id) == first.eqPresets.map(\.id))

        first.eqPresets.removeAll { $0.id == AirPodsMaxEQProfiles.firstGeneration.id }
        let reloaded = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(reloaded.eqPresets.map(\.id) == [own.id, AirPodsMaxEQProfiles.secondGeneration.id])
        #expect(reloaded.engineSettings().equalizers.isEmpty)
    }
    @Test("Volume control in Vespertine is chosen per output, with a level of its own")
    func appVolumePerOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-volume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.usesAppVolume("HDMI") && settings.engineSettings().deviceDigitalVolumes.isEmpty)
        #expect(settings.engineSettings().digitalVolumeDB == nil)

        settings.setUsesAppVolume(true, for: "HDMI")
        #expect(settings.engineSettings().deviceDigitalVolumes == ["HDMI": 0])            // 100%: untouched
        settings.setAppVolumeLevel(0.25, for: "HDMI")
        #expect(settings.engineSettings().deviceDigitalVolumes == ["HDMI": -30])

        // The Settings default covers outputs without a choice of their own; one turned off here stays off.
        settings.allowDigitalVolume = true
        settings.setUsesAppVolume(false, for: "Line out")
        let engine = settings.engineSettings()
        #expect(engine.digitalVolumeDB == 0)
        #expect(engine.deviceDigitalVolumes == ["HDMI": -30, "Line out": nil])

        let reloaded = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(reloaded.usesAppVolume("HDMI") && reloaded.appVolumeLevel(for: "HDMI") == 0.25 && !reloaded.usesAppVolume("Line out"))
    }
    @Test func queueClearingAndReorderingSurviveShuffle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let b = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 480))
            b.frameLength = 480
            for c in 0..<2 { for i in 0..<480 { b.floatChannelData![c][i] = 0 } }
            try f.write(from: b)
        }
        let original = try MetadataReader.read(url: url, artwork: nil)
        // Nonexistent paths exercise queue logic without playing anything on the user's DAC.
        try FileManager.default.removeItem(at: url)
        let tracks = (0..<4).map { i in var t = original; t.id = Int64(i+1); t.title = "Track \(i)"; return t }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("database"))
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root.appendingPathComponent("database"))
        let player = PlayerController(library: library, settings: settings, shares: shares)
        player.play(tracks)
        player.clearUpcoming()
        player.shuffle = true; player.shuffle = false
        #expect(player.queue.map(\.track.title) == ["Track 0"])
        player.play(tracks)
        player.moveUpcoming(from: IndexSet(integer: 0), to: 3)
        let reordered = player.queue.map(\.id)
        player.shuffle = true; player.shuffle = false
        #expect(player.queue.map(\.id) == reordered)
        settings.replayGain = .track
        player.refreshReplayGain()
        #expect(player.queue.map(\.id) == reordered)
        let duplicateRows = [TrackRow(track: tracks[0], index: 0), TrackRow(track: tracks[0], index: 1)]
        #expect(duplicateRows[0].id != duplicateRows[1].id)
        player.stop()
    }

    /// Up Next as in Apple Music: songs you add go to Playing Next, ahead of the rest of what was playing, in the order
    /// added; shuffle leaves them where they are; drags, removals and Play Next work by entry, not by place.
    @Test func playingNextComesBeforeTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav")
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let b = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 480))
            b.frameLength = 480
            for c in 0..<2 { for i in 0..<480 { b.floatChannelData![c][i] = 0 } }
            try f.write(from: b)
        }
        let original = try MetadataReader.read(url: url, artwork: nil)
        // Nonexistent paths exercise queue logic without playing anything on the user's DAC.
        try FileManager.default.removeItem(at: url)
        func song(_ i: Int, _ title: String) -> Track {
            var t = original; t.id = Int64(i); t.title = title; t.location = "/nowhere/\(title).wav"; t.filePath = t.location; return t
        }
        let album = (1...4).map { song($0, "A\($0)") }
        let x = song(10, "X"), y = song(11, "Y"), z = song(12, "Z")
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("database"))
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root.appendingPathComponent("database"))
        let player = PlayerController(library: library, settings: settings, shares: shares)
        defer { player.stop() }
        func titles(_ entries: some Sequence<QueueEntry>) -> [String] { entries.map(\.track.title) }

        player.play(album)
        player.addToQueue([x])
        player.addToQueue([y])
        player.playNext([z])
        #expect(titles(player.playingNext) == ["Z", "X", "Y"])
        #expect(titles(player.continuing) == ["A2", "A3", "A4"])

        // Shuffling mixes the album only; turning it off puts the album back in order, after Playing Next.
        player.shuffle = true
        #expect(titles(player.playingNext) == ["Z", "X", "Y"])
        #expect(Set(titles(player.continuing)) == ["A2", "A3", "A4"])
        player.shuffle = false
        #expect(titles(player.upcoming) == ["Z", "X", "Y", "A2", "A3", "A4"])

        // Moved out of Playing Next it plays with the rest; Play Next brings songs back to the front.
        let xID = try #require(player.playingNext.first { $0.track.title == "X" }?.id)
        player.moveUpcoming([xID], before: nil, playingNext: false)
        #expect(titles(player.playingNext) == ["Z", "Y"])
        #expect(titles(player.continuing) == ["A2", "A3", "A4", "X"])
        let a3 = try #require(player.continuing.first { $0.track.title == "A3" }?.id)
        player.playNext(entries: [xID, a3])
        #expect(titles(player.playingNext) == ["A3", "X", "Z", "Y"])

        // Removing works by entry: unknown and already removed entries change nothing, the song playing stays.
        let current = try #require(player.current?.id)
        player.removeFromQueue([a3, UUID(), current])
        player.removeFromQueue([a3])
        #expect(player.current?.id == current)
        #expect(titles(player.upcoming) == ["X", "Z", "Y", "A2", "A4"])
        player.clearPlayingNext()
        #expect(titles(player.upcoming) == ["A2", "A4"])
        player.clearUpcoming()
        #expect(player.upcoming.isEmpty && player.current?.id == current)
    }
    @Test func launchArgumentsIgnoreOtherDefaultsDomains() {
        // A value UserDefaults knows from elsewhere (registered here: in memory, never saved, like one left in the
        // app's settings) is not a launch argument, so no QA hook acts on it.
        let key = "VespertineAuditProbe-\(UUID().uuidString)"
        UserDefaults.standard.register(defaults: [key: "YES"])
        #expect(UserDefaults.standard.bool(forKey: key))
        #expect(LaunchArguments().string(forKey: key) == nil)
        #expect(!LaunchArguments().bool(forKey: key))
    }
    @Test func recoveryDirectoryOverridesLaunchArgument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = try scratchDefaults(in: root)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/bad/library", forKey: "VespertineDataDirectory")
        let chosen = URL(fileURLWithPath: "/chosen/library")
        #expect(AppSettings(defaults: defaults, dataDirectory: chosen).dataDirectory == chosen)
    }
    @Test func corruptDatabaseProducesRecoverableError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("This is not SQLite".utf8)
        let url = root.appendingPathComponent("Library.sqlite")
        try data.write(to: url)
        #expect(throws: (any Error).self) { try LibraryStore(dataDirectory: root) }
        #expect(try Data(contentsOf: url) == data)
    }

    /// A playlist can hold a song twice: when the list changes, the entry that was selected stays selected, not every
    /// copy of the song (or Remove from Playlist would take both).
    @Test func selectionFollowsTheEntryNotEveryCopy() {
        let before: [(row: Int64, song: Int64?)] = [(0, 7), (1, 8), (2, 7), (3, 9)]
        let entries = TrackTable.entries([2], in: before)               // the second copy of song 7
        #expect(entries == [7: [1]])
        let after: [(row: Int64, song: Int64?)] = [(0, 5), (1, 7), (2, 8), (3, 7), (4, 9)] // a song added above
        #expect(TrackTable.rows(for: entries, in: after) == [3])
        #expect(TrackTable.rows(for: TrackTable.entries([2, 3], in: after), in: before) == [1, 2])
    }
}
