//
// Vespertine: the Settings › Playback switch for Receive from Other Apps (beta), off by default. Off, nothing about it runs: no
// port, no announcement, nothing in the app. On, a control app's songs play in place of the listener's queue, which comes back.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
import VespertineAudio
import VespertineLibrary
import VespertineUPnP
@testable import Vespertine

@Suite("Receive from Other Apps settings switch", .serialized) @MainActor
struct ReceiverSwitchTests {
    private struct Scratch {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let settings: AppSettings
        let player: PlayerController
        let album: [Track]
    }

    /// A player with nothing behind it and an album of five songs whose files don't exist: nothing opens or plays on a real output.
    private func scratch() throws -> Scratch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-receiverswitch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"), automaticScanning: { false })
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let player = PlayerController(library: library, settings: settings, shares: shares)
        let album = (1...5).map { n -> Track in
            var track = Track.transient(location: "/nowhere/S\(n).flac", title: "S\(n)", artist: "Test Artist", album: "Test Album", duration: 180)
            track.id = Int64(n)
            track.filePath = track.location
            return track
        }
        return Scratch(root: root, defaults: defaults, suite: suite, settings: settings, player: player, album: album)
    }

    private func clean(_ scratch: Scratch) {
        scratch.player.stop()
        scratch.defaults.removePersistentDomain(forName: scratch.suite)
        try? FileManager.default.removeItem(at: scratch.root)
    }

    /// The receiver on loopback, announcing to a port of this test's instead of the network.
    private func model(_ scratch: Scratch, announceTo port: UInt16 = 9) -> ReceiverModel {
        let model = ReceiverModel(player: scratch.player, settings: scratch.settings)
        model.configure = { configuration in
            configuration.listenOn = ("127.0.0.1", 0)
            configuration.announceTo = ("127.0.0.1", port)
            configuration.streamPolicy = .listenersOwn
        }
        return model
    }

    /// Whether anything accepts a connection on `port` of this Mac.
    private func answers(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    private func report(_ event: EngineEvent, to player: PlayerController) throws {
        let handler = try #require(player.engine.eventHandler)
        handler(event)
    }

    private func sent(_ title: String) -> ReceiverTrack {
        ReceiverTrack(address: URL(string: "http://192.0.2.7/\(title).flac")!, info: RendererTrackInfo(title: title, artist: "Sent Artist", album: "Sent Album", duration: 200))
    }

    @Test("The switch says beta, and its line says what off means")
    func switchExists() {
        #expect(ReceiverSwitch.title.localizedCaseInsensitiveContains("beta"))
        #expect(ReceiverSwitch.explanation.localizedCaseInsensitiveContains("off"))
        #expect(!ReceiverSwitch.explanation.contains("\n"))
        #expect(!ReceiverSwitch.explanation.localizedCaseInsensitiveContains("renderer"))
    }

    @Test("A new install starts with it off: nothing stored, no model made, no identity made")
    func offByDefault() throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        #expect(!scratch.settings.upnpReceiverFeature)
        #expect(scratch.settings.upnpReceiverOwnNetworks, "control only from the Mac's own networks unless the listener says otherwise")
        #expect(!scratch.settings.upnpReceiverVolume, "control apps don't move the volume unless the listener says so")
        let stored = scratch.defaults.persistentDomain(forName: scratch.suite) ?? [:]
        #expect(stored.keys.allSatisfy { !$0.hasPrefix("upnpReceiver") })
        var made = false
        let model = ReceiverSwitch.apply(false, to: scratch.settings, current: nil, make: { made = true; return self.model(scratch) })
        #expect(model == nil)
        #expect(!made)
        #expect(scratch.settings.upnpReceiverID.isEmpty, "nothing is made for a feature that is off")
        #expect(scratch.player.receiverEvents == nil)
    }

    @Test("On, it opens its port and control apps can read what it is; off again, the port is closed and the model goes")
    func onThenOff() async throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        let model = try #require(ReceiverSwitch.apply(true, to: scratch.settings, current: nil, make: { self.model(scratch) }))
        #expect(scratch.settings.upnpReceiverFeature)
        #expect(scratch.settings.upnpReceiverID.hasPrefix("uuid:"))
        await model.settled()
        #expect(model.status == .running)
        let port = await model.port
        #expect(port != 0)
        #expect(answers(port))
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(ReceiverDescription.descriptionPath)")!)
        let description = String(decoding: data, as: UTF8.self)
        #expect(description.contains("MediaRenderer:1") && description.contains(scratch.settings.upnpReceiverID))

        #expect(ReceiverSwitch.apply(false, to: scratch.settings, current: model, make: { self.model(scratch) }) == nil)
        await model.settled()
        #expect(!scratch.settings.upnpReceiverFeature)
        #expect(await model.port == 0)
        // The listener's close is asked for, then done: wait for the port to stop answering, however long that takes here.
        var closed = false
        for _ in 0..<3000 where !closed {
            closed = !answers(port)
            if !closed { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(closed)
        #expect(scratch.player.receiverEvents == nil)
    }

    @Test("The name control apps see is the listener's, or the app's and the computer's when none is given")
    func name() throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        #expect(ReceiverSwitch.name(scratch.settings) == ReceiverSwitch.defaultName)
        #expect(ReceiverSwitch.defaultName.hasPrefix("Vespertine ("))
        scratch.settings.upnpReceiverName = "  Listening Room  "
        #expect(ReceiverSwitch.name(scratch.settings) == "Listening Room")
    }

    @Test("A control app's songs take the queue's place; when it stops, the listener's queue is back as it was, at its song")
    func queueSurvives() throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        let player = scratch.player
        var told: [ReceiverPlayerEvent] = []
        player.receiverEvents = { told.append($0) }
        player.repeatMode = .all
        player.play(scratch.album, startAt: 2)
        try report(.trackStarted(try #require(player.current).item), to: player)
        let before = player.queue.map(\.id)
        let wasAt = try #require(player.current?.id)

        let first = sent("Sent One"), second = sent("Sent Two")
        player.receiverPlay(first, next: second, from: ReceiverControlApp(name: "TestControl", address: "192.0.2.7"))
        #expect(player.receiverSession?.app.name == "TestControl")
        #expect(player.queue.map(\.id) == [first.id, second.id])
        #expect(player.queue.allSatisfy { $0.received })
        #expect(player.current?.track.title == "Sent One")
        #expect(player.currentLibraryTrack == nil, "a control app's song is not a song of the library")
        #expect(player.receiverSession?.queue.map(\.id) == before, "the listener's queue is kept, whole")

        // The listener adds a song meanwhile: it joins their own queue, not the control app's.
        var extra = scratch.album[0]
        extra.id = 99
        extra.title = "Added Meanwhile"
        player.playNext([extra])
        #expect(player.queue.map(\.id) == [first.id, second.id])
        #expect(player.receiverSession?.queue.count == before.count + 1)

        try report(.trackStarted(first.item), to: player)
        try report(.trackStarted(second.item), to: player)
        #expect(told.contains(.started(first.id)) && told.contains(.started(second.id)))
        #expect(player.current?.track.title == "Sent Two")

        player.receiverStop()
        #expect(player.receiverSession == nil)
        #expect(player.current?.id == wasAt, "back at the song that was playing")
        #expect(player.queue.count == before.count + 1)
        #expect(player.queue.allSatisfy { !$0.received }, "none of the control app's songs is left in the queue")
        #expect(player.upcoming.first?.track.title == "Added Meanwhile")
        #expect(player.repeatMode == .all, "repeat is the listener's, untouched")
    }

    @Test("The listener playing something of their own ends the control app's session, and the control app is told")
    func listenerTakesOver() throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        let player = scratch.player
        var told: [ReceiverPlayerEvent] = []
        player.receiverEvents = { told.append($0) }
        player.receiverPlay(sent("Sent One"), next: nil, from: ReceiverControlApp(name: "TestControl"))
        #expect(player.receiverSession != nil)
        player.play(scratch.album, startAt: 0)
        #expect(player.receiverSession == nil)
        #expect(told.last == .tookOver)
        #expect(player.queue.count == scratch.album.count && player.queue.allSatisfy { !$0.received })
        #expect(player.current?.track.title == "S1")
    }

    @Test("A control app's song that fails says why to the listener and to the control app, and looks for no file")
    func failureIsToldBothWays() throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        let player = scratch.player
        var told: [ReceiverPlayerEvent] = []
        player.receiverEvents = { told.append($0) }
        let song = sent("Sent One")
        player.receiverPlay(song, next: nil, from: ReceiverControlApp())
        try report(.failed(song.item, "The address didn’t answer."), to: player)
        #expect(player.lastError == "The address didn’t answer.")
        #expect(told.contains(.failed(song.id, "The address didn’t answer.")))
    }

    @Test("The signal path's first step and the chip name the control app, or say it is one when it gave no name")
    func whoIsSending() {
        let named = ReceiverText.pathTitle(ReceiverControlApp(name: "TestControl"))
        #expect(named.contains("TestControl") && named.localizedCaseInsensitiveContains("network"))
        #expect(!ReceiverText.pathTitle(ReceiverControlApp()).isEmpty)
        #expect(ReceiverText.chip(ReceiverControlApp(name: "TestControl")).contains("TESTCONTROL"))
    }
}
