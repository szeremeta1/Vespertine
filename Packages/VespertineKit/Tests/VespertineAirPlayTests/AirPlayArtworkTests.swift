//
// Vespertine: the cover goes to receivers that show one (`md` lists 1): the song's picture as it is, word that there is
// none for a song without, and nothing at all to a receiver that doesn't ask for pictures.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing
import VespertineAudio
import VespertineUPnP
@testable import VespertineAirPlay

private let jpegCover = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
private let pngCover = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 64)

@Suite("AirPlay artwork", .serialized, .timeLimit(.minutes(2))) @MainActor
struct AirPlayArtworkTests {
    func playback(_ receiver: FakeRAOPReceiver, md: String) -> (AirPlayPlayback, EventLog) {
        let record = RAOPRecord.parse(serviceName: "B827EB000002@Fake", txt: ["et": "0", "md": md, "cn": "1"])!
        let device = AirPlayDevice(deviceID: "B827EB000002", name: "Fake", raop: record, host: "127.0.0.1", port: receiver.port)
        let p = AirPlayPlayback(device: device, endpoint: endpoint(receiver), encryption: .none, rsaKey: nil)
        let log = EventLog()
        p.eventHandler = { event in log.events.append(event) }
        return (p, log)
    }

    func wait(_ condition: @MainActor () -> Bool) async { await untilTrue(condition) }

    func pictures(_ receiver: FakeRAOPReceiver) -> [RTSPMessage] {
        receiver.requests.filter { $0.method == "SET_PARAMETER" && ($0["Content-Type"] ?? "").hasPrefix("image/") }
    }

    @Test("JPEG and PNG are named by their first bytes; anything else, nothing, or a file too large is no picture")
    func contentType() {
        #expect(AirPlayArtwork.contentType(of: jpegCover) == "image/jpeg")
        #expect(AirPlayArtwork.contentType(of: pngCover) == "image/png")
        #expect(AirPlayArtwork.contentType(of: Data("GIF89a".utf8)) == nil)
        #expect(AirPlayArtwork.contentType(of: Data()) == nil)
        #expect(AirPlayArtwork.contentType(of: Data([0xFF, 0xD8, 0xFF]) + Data(count: AirPlayArtwork.maximumBytes)) == nil)
    }

    @Test("A receiver that shows covers gets the song's picture, byte for byte, at the song's first frame")
    func sent() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 0.6, seed: 11)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = playback(receiver, md: "0,1,2")
        defer { p.shutdown() }
        p.metadataProvider = { _ in RendererTrackInfo(title: "Song", artist: "Artist", album: "Album", duration: 0.6, artworkKey: "cover-1") }
        p.artworkProvider = { key in key == "cover-1" ? jpegCover : nil }
        p.play(PlayableItem(url: url), at: 0)
        await wait { log.ended }
        let sent = pictures(receiver)
        #expect(sent.count == 1)
        #expect(sent.first?["Content-Type"] == "image/jpeg")
        #expect(sent.first?.body == jpegCover)
        #expect(sent.first?["RTP-Info"]?.hasPrefix("rtptime=") == true)
        // The titles still go, and to the same frame.
        let titles = receiver.requests.first { $0["Content-Type"] == "application/x-dmap-tagged" }
        #expect(titles?["RTP-Info"] == sent.first?["RTP-Info"])
    }

    @Test("A song without a cover, or with one receivers don't take, tells the receiver there is none")
    func none() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 0.6, seed: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = playback(receiver, md: "0,1,2")
        defer { p.shutdown() }
        p.metadataProvider = { _ in RendererTrackInfo(title: "Song", artworkKey: "cover-2") }
        p.artworkProvider = { _ in Data("GIF89a not for receivers".utf8) }
        p.play(PlayableItem(url: url), at: 0)
        await wait { log.ended }
        let sent = pictures(receiver)
        #expect(sent.count == 1)
        #expect(sent.first?["Content-Type"] == "image/none")
        #expect(sent.first?.body.isEmpty == true)
    }

    @Test("A receiver that doesn't list pictures is sent none, and the cover is never read")
    func notAsked() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 0.6, seed: 13)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = playback(receiver, md: "0,2")
        defer { p.shutdown() }
        let asked = Locked(0)
        p.metadataProvider = { _ in RendererTrackInfo(title: "Song", artworkKey: "cover-3") }
        p.artworkProvider = { _ in asked.withLock { $0 += 1 }; return jpegCover }
        p.play(PlayableItem(url: url), at: 0)
        await wait { log.ended }
        #expect(pictures(receiver).isEmpty)
        #expect(asked.withLock { $0 } == 0)
        #expect(receiver.requests.contains { $0["Content-Type"] == "application/x-dmap-tagged" })
    }
}
