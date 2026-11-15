//
// Vespertine: "Receive from Other Apps", end to end on 127.0.0.1: a control point finds the receiver, reads what it is, sends a song
// and drives it, and the real engine plays it. Each step is judged by what the receiver or the engine says happened (an event,
// an answer), never by how long it took.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation
import Testing
@testable import VespertineAudio
@testable import VespertineUPnP

/// A UDP socket on 127.0.0.1 that keeps every datagram sent to it (the receiver's announcements, in the tests).
private final class UDPInbox: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var datagrams: [String] = []
    private var closed = false

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard fd >= 0, bound == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        self.fd = fd
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [self] in listen() }
        thread.start()
    }

    private func listen() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ closed }) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { lock.withLock { datagrams.append(String(decoding: buffer[0..<n], as: UTF8.self)) } }
        }
        Darwin.close(fd)
    }

    var received: [String] { lock.withLock { datagrams } }
    func close() { lock.withLock { closed = true } }
}

@Suite("Receive from Other Apps: the receiver, end to end", .serialized)
struct ReceiverEndToEndTests {
    @Test("A control point finds it, reads what it is, sends a FLAC and plays, pauses, seeks and stops it; every step is evented")
    func discoverDescribePlay() async throws {
        let scene = try await ReceiverScene()
        let samples = TestSong.noise(frames: TestSong.rate * 6, seed: 11)
        let flac = try TestSong.flac(fromWAV: TestSong.wav(samples), in: scene.player.directory)
        scene.host.add("/music/one.flac", .init(data: flac, type: "audio/flac"))

        // Discovery: a search for media renderers is answered with where the description is.
        let searcher = SSDPSearcher(host: "127.0.0.1", port: await scene.receiver.searchPort)
        let found = Locked<SSDPResponse?>(nil)
        let answered = await ReceiverPatience.until {
            let replies = await searcher.search(targets: [ReceiverDescription.deviceType], mx: 1, wait: 0.5)
            found.withLock { $0 = replies.first }
            return !replies.isEmpty
        }
        try #require(answered, "the search was answered")
        let reply = try #require(found.withLock { $0 })
        #expect(reply.udn == scene.udn)
        #expect(reply.st == ReceiverDescription.deviceType)

        // Description: the app's own renderer client reads it as a gapless UPnP AV renderer that takes FLAC.
        let device = try await RendererDevice.load(location: reply.location)
        #expect(device.name == "Vespertine on test-mac")
        #expect(device.kind == .av(gapless: true))
        #expect(device.capabilities.entries.contains { $0.mime == "audio/flac" })
        let transport = try device.makeTransport()

        // Eventing: the first event is the whole state.
        let subscribed = try await scene.listener.subscribe(.avTransport, receiverPort: await scene.port, path: "/avt")
        #expect(subscribed.status == 200 && subscribed.sid?.hasPrefix("uuid:") == true)
        #expect(await scene.listener.heard("TransportState", "NO_MEDIA_PRESENT"))

        // Set the song and play it.
        let address = scene.host.url("/music/one.flac")
        let metadata = TestSong.didl(title: "First Song", url: address, mime: "audio/flac")
        try await transport.load(current: RendererTrack(uri: address, metadata: metadata), next: nil)
        #expect(await scene.listener.heard("TransportState", "PLAYING"), "playing was evented: \(scene.listener.values(of: "TransportState")), \(scene.player.state.withLock { $0.failures })")
        #expect(scene.listener.latest("AVTransportURI") == address.absoluteString)
        let snapshot = await scene.receiver.snapshot
        let track = try #require(snapshot.current)
        #expect(track.info.title == "First Song" && track.info.artist == "Test Artist" && track.info.album == "Test Album")

        // The bytes: what is in the playback cache is the FLAC, byte for byte.
        let entry = try scene.player.cache.entry(key: ReceiverStreams.cacheKey(track.id), url: ReceiverStreams.itemURL(track.id))
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.url.pathExtension == "flac")
        #expect(try entry.read(at: 0, count: flac.count) == flac)
        // Once the fade-in a song starts with is over, the path says how it plays from then on.
        #expect(await ReceiverPatience.until { scene.player.engine.snapshot.signalPath?.faderRamping == false })
        let remotePath = try #require(scene.player.engine.snapshot.signalPath)

        // What control apps ask while it plays.
        let info = try await scene.call(.avTransport, "GetPositionInfo", [("InstanceID", "0")])
        #expect(info["TrackURI"] == address.absoluteString && info["Track"] == "1" && info["TrackDuration"] == "0:00:06")
        #expect(ReceivedMetadata.parseOrNil(info["TrackMetaData"])?.title == "First Song")
        let media = try await scene.call(.avTransport, "GetMediaInfo", [("InstanceID", "0")])
        #expect(media["CurrentURI"] == address.absoluteString && media["NrTracks"] == "1" && media["PlayMedium"] == "NETWORK")

        // Pause, play again, seek.
        try await transport.pause()
        #expect(await scene.listener.heard("TransportState", "PAUSED_PLAYBACK"))
        #expect(await ReceiverPatience.until { scene.player.engine.snapshot.state == .paused })
        try await transport.play()
        #expect(await ReceiverPatience.until { scene.listener.values(of: "TransportState").suffix(1) == ["PLAYING"] })
        try await transport.seek(to: 4)
        #expect(await ReceiverPatience.until { scene.player.engine.snapshot.position >= 4 }, "the seek landed: \(scene.player.engine.snapshot.position)")
        let status = try await transport.status()
        #expect(status.state == .playing && status.position >= 4 && status.currentURI == address)

        // Stop.
        try await transport.stop()
        #expect(await ReceiverPatience.until { scene.listener.values(of: "TransportState").suffix(1) == ["STOPPED"] })
        #expect(await ReceiverPatience.until { scene.player.engine.snapshot.state == .stopped })

        // The signal path: the same song as a file on this Mac goes through the engine the same way.
        let local = scene.player.directory.appendingPathComponent("local.flac")
        try flac.write(to: local)
        let item = PlayableItem(url: local)
        scene.player.engine.play(item)
        #expect(await ReceiverPatience.until { scene.player.state.withLock { $0.started.contains(item.id) } })
        #expect(await ReceiverPatience.until { scene.player.engine.snapshot.signalPath?.faderRamping == false })
        #expect(scene.player.engine.snapshot.signalPath == remotePath)
        scene.player.engine.stop()
        await scene.close()
    }

    @Test("Two songs sent as current and next join with no frame added or lost")
    func gapless() async throws {
        let scene = try await ReceiverScene()
        let first = TestSong.noise(frames: TestSong.rate * 2, seed: 101), second = TestSong.noise(frames: TestSong.rate * 2, seed: 202)
        scene.host.add("/a.wav", .init(data: TestSong.wav(first), type: "audio/wav"))
        scene.host.add("/b.wav", .init(data: TestSong.wav(second), type: "audio/wav"))
        _ = try await scene.listener.subscribe(.avTransport, receiverPort: await scene.port, path: "/avt")
        let a = scene.host.url("/a.wav"), b = scene.host.url("/b.wav")
        let device = try await RendererDevice.load(location: try #require(await scene.receiver.location(host: "127.0.0.1")))
        let transport = try device.makeTransport()
        try await transport.load(current: RendererTrack(uri: a, metadata: TestSong.didl(title: "A", url: a, mime: "audio/wav")),
                                 next: RendererTrack(uri: b, metadata: TestSong.didl(title: "B", url: b, mime: "audio/wav")))
        // The receiver moves on by itself and says so; then the second song ends.
        #expect(await scene.listener.heard("CurrentTrackURI", b.absoluteString), "moved on to the next song: \(scene.listener.values(of: "CurrentTrackURI"))")
        #expect(await ReceiverPatience.until { scene.listener.values(of: "TransportState").suffix(1) == ["STOPPED"] })
        #expect(scene.listener.latest("NextAVTransportURI") == "")
        #expect(scene.player.state.withLock { $0.started.count } == 2)
        // The output is drained before it is compared: the last buffers leave after the engine has said the queue ended.
        let expected = TestSong.floats(first + second)
        #expect(await ReceiverPatience.until(giveUpAfter: 30) { scene.player.heard.count >= expected.count })
        let heard = scene.player.heard
        #expect(heard.count == expected.count, "frames out: \(heard.count / 2), frames in: \(expected.count / 2)")
        if heard.count == expected.count {
            let different = zip(heard, expected).enumerated().filter { $0.element.0 != $0.element.1 }
            #expect(different.isEmpty, "\(different.count) samples differ, the first at \(different.first?.offset ?? -1)")
        }
        await scene.close()
    }

    @Test("Next and Previous: the next song is skipped to, and Previous starts the song again")
    func nextAndPrevious() async throws {
        let scene = try await ReceiverScene()
        scene.host.add("/a.wav", .init(data: TestSong.wav(TestSong.noise(frames: TestSong.rate * 8, seed: 1)), type: "audio/wav"))
        scene.host.add("/b.wav", .init(data: TestSong.wav(TestSong.noise(frames: TestSong.rate * 8, seed: 2)), type: "audio/wav"))
        _ = try await scene.listener.subscribe(.avTransport, receiverPort: await scene.port, path: "/avt")
        let a = scene.host.url("/a.wav").absoluteString, b = scene.host.url("/b.wav").absoluteString
        #expect(await scene.setURI(a) == nil)
        #expect(await scene.fault(.avTransport, "Next", [("InstanceID", "0")])?.code == 711, "nothing to skip to yet")
        #expect(await scene.fault(.avTransport, "SetNextAVTransportURI", [("InstanceID", "0"), ("NextURI", b), ("NextURIMetaData", "")]) == nil)
        _ = try await scene.call(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
        #expect(await scene.listener.heard("TransportState", "PLAYING"))
        #expect(try await scene.call(.avTransport, "GetCurrentTransportActions", [("InstanceID", "0")])["Actions"]?.contains("Next") == true)
        _ = try await scene.call(.avTransport, "Next", [("InstanceID", "0")])
        #expect(await scene.listener.heard("CurrentTrackURI", b))
        #expect(await ReceiverPatience.until { scene.player.state.withLock { $0.started.count } == 2 })
        #expect(await ReceiverPatience.until { scene.player.engine.snapshot.position > 0.3 })
        _ = try await scene.call(.avTransport, "Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", "0:00:05")])
        #expect(await ReceiverPatience.until { scene.player.engine.snapshot.position >= 5 })
        _ = try await scene.call(.avTransport, "Previous", [("InstanceID", "0")])
        #expect(await ReceiverPatience.until { scene.player.engine.snapshot.position < 4 })
        #expect(await scene.fault(.avTransport, "Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", "0:10:00")])?.code == 711)
        #expect(await scene.fault(.avTransport, "Seek", [("InstanceID", "0"), ("Unit", "X_FRAME"), ("Target", "1")])?.code == 710)
        await scene.close()
    }

    @Test("Volume is fixed unless the listener lets control apps set it")
    func volume() async throws {
        let scene = try await ReceiverScene()
        _ = try await scene.listener.subscribe(.renderingControl, receiverPort: await scene.port, path: "/rcs")
        #expect(await scene.listener.heard("Volume", "100", path: "/rcs"))
        let arguments = [("InstanceID", "0"), ("Channel", "Master")]
        #expect(try await scene.call(.renderingControl, "GetVolume", arguments)["CurrentVolume"] == "100")
        _ = try await scene.call(.renderingControl, "SetVolume", arguments + [("DesiredVolume", "30")])
        _ = try await scene.call(.renderingControl, "SetMute", arguments + [("DesiredMute", "1")])
        #expect(try await scene.call(.renderingControl, "GetVolume", arguments)["CurrentVolume"] == "100")
        #expect(try await scene.call(.renderingControl, "GetMute", arguments)["CurrentMute"] == "0")
        #expect(scene.player.state.withLock { $0.volumesSet.isEmpty && !$0.muted && $0.volume == 0.8 }, "the listener's volume was left alone")

        await scene.receiver.setAllowsVolume(true)
        #expect(await scene.listener.heard("Volume", "80", path: "/rcs"), "the listener's own volume is shown once control apps may set it")
        _ = try await scene.call(.renderingControl, "SetVolume", arguments + [("DesiredVolume", "30")])
        #expect(scene.player.state.withLock { $0.volumesSet } == [0.3])
        #expect(try await scene.call(.renderingControl, "GetVolume", arguments)["CurrentVolume"] == "30")
        #expect(await scene.listener.heard("Volume", "30", path: "/rcs"))
        // The listener turns it up in the app: control apps hear of it.
        scene.receiver.playerEvent(.volume(level: 0.55, muted: false))
        #expect(await scene.listener.heard("Volume", "55", path: "/rcs"))
        #expect(await scene.fault(.renderingControl, "SetVolume", arguments + [("DesiredVolume", "101")])?.code == 402)
        #expect(await scene.fault(.renderingControl, "GetVolume", [("InstanceID", "3"), ("Channel", "Master")])?.code == 702)
        await scene.close()
    }

    @Test("The listener's own play ends the control app's session, and the control app is told")
    func tookOver() async throws {
        let scene = try await ReceiverScene()
        scene.host.add("/a.wav", .init(data: TestSong.wav(TestSong.noise(frames: TestSong.rate * 8, seed: 5)), type: "audio/wav"))
        _ = try await scene.listener.subscribe(.avTransport, receiverPort: await scene.port, path: "/avt")
        #expect(await scene.setURI(scene.host.url("/a.wav").absoluteString) == nil)
        _ = try await scene.call(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
        #expect(await scene.listener.heard("TransportState", "PLAYING"))
        scene.receiver.playerEvent(.paused)
        #expect(await scene.listener.heard("TransportState", "PAUSED_PLAYBACK"), "a pause in the app is evented")
        scene.receiver.playerEvent(.resumed)
        #expect(await ReceiverPatience.until { scene.listener.values(of: "TransportState").suffix(1) == ["PLAYING"] })
        scene.receiver.playerEvent(.tookOver)
        #expect(await ReceiverPatience.until { scene.listener.values(of: "TransportState").suffix(1) == ["STOPPED"] })
        #expect(await scene.fault(.avTransport, "Pause", [("InstanceID", "0")])?.code == 701, "nothing of the control app's is playing")
        await scene.close()
    }
}

extension ReceivedMetadata {
    static func parseOrNil(_ text: String?) -> ReceivedMetadata? { text.flatMap { try? parse($0) } }
}

@Suite("Receive from Other Apps: what the receiver refuses", .serialized)
struct ReceiverRefusalTests {
    private static func said(_ refusal: StreamRefusal) -> String { refusal.localizedDescription }

    @Test("A file: address, and any address that isn't http or https, is refused in plain words")
    func notHTTP() async throws {
        let scene = try await ReceiverScene()
        for address in ["file:///etc/passwd", "rtsp://192.0.2.7/stream", "smb://192.0.2.7/share/a.flac", "vespertine-receiver://track/1"] {
            let fault = await scene.setURI(address)
            #expect(fault?.code == 716 && fault?.description == Self.said(.notHTTP), "\(address): \(String(describing: fault))")
        }
        #expect(await scene.setURI("not a url at all")?.code == 402)
        #expect(await scene.receiver.snapshot.current == nil)
        #expect(await scene.receiver.snapshot.state == .noMedia)
        #expect(scene.refusals.withLock { $0.count } == 4, "the listener is told of each refusal")
        #expect(scene.host.paths.isEmpty, "nothing was fetched")
        await scene.close()
    }

    @Test("An address on this Mac itself or a link-local one is refused, and so is a redirect to one")
    func forbiddenAddresses() async throws {
        // As the app runs it: nothing may point the receiver at this Mac.
        let strict = try await ReceiverScene(fromLoopback: false)
        strict.host.add("/a.wav", .init(data: TestSong.wav(TestSong.noise(frames: 4800, seed: 3)), type: "audio/wav"))
        for address in [strict.host.url("/a.wav").absoluteString, "http://localhost:\(strict.host.port)/a.wav", "http://[::1]:\(strict.host.port)/a.wav",
                        "http://169.254.169.254/latest/meta-data/", "http://[fe80::1]/a.wav", "http://0.0.0.0/a.wav"] {
            let fault = await strict.setURI(address)
            #expect(fault?.code == 716 && fault?.description == Self.said(.forbiddenAddress), "\(address): \(String(describing: fault))")
        }
        #expect(strict.host.paths.isEmpty, "none of them was asked for a byte")
        await strict.close()

        // A redirect is judged like the address itself (the tests' host is on 127.0.0.1, so here only link-local is forbidden).
        let scene = try await ReceiverScene()
        scene.host.redirect("/moved", to: "http://169.254.10.10/a.wav")
        let fault = await scene.setURI(scene.host.url("/moved").absoluteString)
        #expect(fault?.code == 716 && fault?.description == Self.said(.forbiddenRedirect), "\(String(describing: fault))")
        #expect(throws: StreamRefusal.forbiddenRedirect) { try StreamAddressPolicy.fromTheNetwork.check(URL(string: "http://127.0.0.1:8080/a.flac")!, redirect: true) }
        #expect(throws: StreamRefusal.forbiddenRedirect) { try StreamAddressPolicy.fromTheNetwork.check(URL(string: "http://[::ffff:127.0.0.1]/a.flac")!, redirect: true) }
        #expect(throws: StreamRefusal.notHTTP) { try StreamAddressPolicy.fromTheNetwork.check(URL(string: "file:///tmp/a.flac")!, redirect: true) }
        // A redirect to somewhere allowed is followed.
        scene.host.add("/a.wav", .init(data: TestSong.wav(TestSong.noise(frames: 4800, seed: 3)), type: "audio/wav"))
        scene.host.redirect("/fine", to: scene.host.url("/a.wav").absoluteString)
        #expect(await scene.setURI(scene.host.url("/fine").absoluteString) == nil)
        await scene.close()
    }

    @Test("A SOAP call past the size limit is answered 413; one with a document type is answered 400; neither reaches a parser")
    func oversizedAndHostileSOAP() async throws {
        let scene = try await ReceiverScene()
        let port = await scene.port
        func post(_ body: Data) -> String? {
            var head = "POST \(ReceiverService.avTransport.controlPath) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/xml\r\n"
            head += "SOAPACTION: \"\(ReceiverService.avTransport.type)#SetAVTransportURI\"\r\nContent-Length: \(body.count)\r\n\r\n"
            return rawExchange(port: port, send: Data(head.utf8) + body)?.response
        }
        let padding = String(repeating: "A", count: UPnPReceiver.maximumSOAP)
        let big = SOAP.envelope(serviceType: ReceiverService.avTransport.type, action: "SetAVTransportURI",
                                arguments: [("InstanceID", "0"), ("CurrentURI", "http://192.0.2.7/a.flac"), ("CurrentURIMetaData", padding)])
        #expect(post(big)?.hasPrefix("HTTP/1.1 413") == true)
        let hostile = Data("<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY a \"aaaa\">]><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:SetAVTransportURI xmlns:u=\"\(ReceiverService.avTransport.type)\"><InstanceID>0</InstanceID><CurrentURI>&a;</CurrentURI></u:SetAVTransportURI></s:Body></s:Envelope>".utf8)
        #expect(post(hostile)?.hasPrefix("HTTP/1.1 400") == true)
        #expect(post(Data("this is not xml".utf8))?.hasPrefix("HTTP/1.1 400") == true)
        #expect(await scene.receiver.snapshot.current == nil)
        // An action of another service, or one that doesn't exist.
        #expect(await scene.fault(.avTransport, "NoSuchAction", [("InstanceID", "0")])?.code == 401)
        #expect(await scene.fault(.avTransport, "Play", [("InstanceID", "7"), ("Speed", "1")])?.code == 718)
        #expect(await scene.fault(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])?.code == 702, "nothing to play")
        await scene.close()
    }

    @Test("A malformed description of the song is refused; none at all is fine")
    func malformedDIDL() async throws {
        let scene = try await ReceiverScene()
        scene.host.add("/a.wav", .init(data: TestSong.wav(TestSong.noise(frames: 4800, seed: 3)), type: "audio/wav"))
        let address = scene.host.url("/a.wav").absoluteString
        for metadata in ["<DIDL-Lite><item><dc:title>Broken", "<html><body>hello</body></html>", "<!DOCTYPE d [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><DIDL-Lite/>",
                         "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"></DIDL-Lite>", String(repeating: "x", count: ReceivedMetadata.maximumLength + 1)] {
            let fault = await scene.setURI(address, metadata: metadata)
            #expect(fault?.code == 402, "\(metadata.prefix(40)): \(String(describing: fault))")
        }
        #expect(scene.host.paths.isEmpty, "the song isn't fetched when its description is refused")
        #expect(await scene.setURI(address, metadata: "") == nil)
        #expect(await scene.setURI(address, metadata: "NOT_IMPLEMENTED") == nil)
        #expect(await scene.receiver.snapshot.current?.info.title == "a")
        await scene.close()
    }

    @Test("Video, a playlist of segments, a copy-protected stream, a stream without ranges and a missing one are each refused with its reason")
    func undecodable() async throws {
        let scene = try await ReceiverScene()
        scene.host.add("/film.mp4", .init(data: Data(repeating: 7, count: 4096), type: "video/mp4"))
        scene.host.add("/unknown", .init(data: Data(repeating: 9, count: 4096), type: "application/octet-stream"))
        scene.host.add("/live.m3u8", .init(data: Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:6,\nsegment0.ts\n".utf8), type: "application/vnd.apple.mpegurl"))
        var protected = Data([0, 0, 0, 0x1c]) + Data("ftypM4A ".utf8) + Data(repeating: 0, count: 64)
        protected += Data("moovtrakmdiaminfstblstsd".utf8) + Data("enca".utf8) + Data(repeating: 0, count: 256)
        scene.host.add("/drm.m4a", .init(data: protected, type: "audio/mp4"))
        scene.host.add("/whole.wav", .init(data: TestSong.wav(TestSong.noise(frames: TestSong.rate * 2, seed: 4)), type: "audio/wav", ranges: false))
        let cases: [(String, Int, StreamRefusal)] = [
            ("/film.mp4", 714, .notDecodable("video/mp4")), ("/unknown", 714, .notDecodable("application/octet-stream")),
            ("/live.m3u8", 714, .segmented), ("/drm.m4a", 704, .protected), ("/whole.wav", 704, .noRanges), ("/missing.flac", 716, .status(404)),
        ]
        for (path, code, refusal) in cases {
            let fault = await scene.setURI(scene.host.url(path).absoluteString)
            #expect(fault?.code == code && fault?.description == Self.said(refusal), "\(path): \(String(describing: fault))")
        }
        // Nothing listens on port 1: the address doesn't answer.
        let dead = await scene.setURI("http://127.0.0.1:1/a.flac")
        #expect(dead?.code == 716 && dead?.description.isEmpty == false)
        #expect(scene.refusals.withLock { $0.count } == cases.count + 1)
        #expect(await scene.receiver.snapshot.current == nil)
        await scene.close()
    }

    @Test("A song whose bytes are not what its name says fails when it is played, and the control app is told why")
    func notWhatItSays() async throws {
        let scene = try await ReceiverScene()
        scene.host.add("/noise.flac", .init(data: Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }), type: "application/octet-stream"))
        _ = try await scene.listener.subscribe(.avTransport, receiverPort: await scene.port, path: "/avt")
        #expect(await scene.setURI(scene.host.url("/noise.flac").absoluteString) == nil, "its name says FLAC, so the decoders are asked")
        _ = try await scene.call(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
        #expect(await scene.listener.heard("TransportStatus", "ERROR_OCCURRED"))
        #expect(try await scene.call(.avTransport, "GetTransportInfo", [("InstanceID", "0")])["CurrentTransportState"] == "STOPPED")
        #expect(await scene.receiver.snapshot.lastError?.isEmpty == false)
        #expect(scene.refusals.withLock { $0.count } == 1)
        await scene.close()
    }

    @Test("A stream that stops answering in the middle of a song is given up after the share's silence limit, with the receiver's own words")
    func stopsAnsweringMidSong() async throws {
        // One second of silence is the limit here (two minutes in the app): the copy's own clock decides, not this test's.
        let scene = try await ReceiverScene(noProgressLimit: 1)
        // Big enough to start playing on its first megabytes while the rest is still to come.
        let wav = TestSong.wav(TestSong.noise(frames: TestSong.rate * 26, seed: 9))
        try #require(Int64(wav.count) >= NetworkStart.smallestEarlyFile)
        scene.host.add("/long.wav", .init(data: wav, type: "audio/wav"))
        scene.host.goQuiet("/long.wav", from: 8 << 20)
        _ = try await scene.listener.subscribe(.avTransport, receiverPort: await scene.port, path: "/avt")
        #expect(await scene.setURI(scene.host.url("/long.wav").absoluteString) == nil)
        _ = try await scene.call(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
        #expect(await scene.listener.heard("TransportState", "PLAYING"), "it starts on what has arrived: \(scene.player.state.withLock { $0.failures })")
        #expect(scene.host.reachedQuiet("/long.wav") || scene.player.engine.snapshot.state == .playing)
        let told = await scene.listener.heard("TransportStatus", "ERROR_OCCURRED")
        let engine = scene.player.engine.snapshot
        #expect(told, "the silence was reported: engine \(engine.state) at \(engine.position), error \(String(describing: engine.lastError)), player \(scene.player.state.withLock { ($0.failures, $0.ended, $0.started.count) }), quiet reached \(scene.host.reachedQuiet("/long.wav")), asked \(scene.host.paths.count)")
        #expect(await scene.receiver.snapshot.lastError == ReceiverStreams.notAnswering)
        #expect(await scene.receiver.snapshot.state == .stopped)
        #expect(scene.refusals.withLock { $0 } == [ReceiverStreams.notAnswering])
        await scene.close()
    }
}

@Suite("Receive from Other Apps: off is off", .serialized)
struct ReceiverOffTests {
    @Test("Until it is started the receiver has no port and no socket; stopped, it closes both and says goodbye")
    func startAndStop() async throws {
        let inbox = try UDPInbox()
        defer { inbox.close() }
        let player = try EnginePlayer()
        let udn = "uuid:\(UUID().uuidString.lowercased())"
        var configuration = UPnPReceiver.Configuration(udn: udn, name: "Vespertine on test-mac", version: "1.1.0")
        configuration.listenOn = ("127.0.0.1", 0)
        configuration.announceTo = ("127.0.0.1", inbox.port)
        configuration.responseDelay = { _ in 0 }
        let receiver = UPnPReceiver(configuration, player: player)
        let before = await (receiver.port, receiver.searchPort, receiver.isRunning)
        #expect(before == (0, 0, false))
        #expect(!NetworkPlaybackCache.hasRemoteReader(scheme: "x-\(ReceiverStreams.scheme)"))
        #expect(inbox.received.isEmpty, "nothing is announced before it is started")

        try await receiver.start()
        let port = await receiver.port, searchPort = await receiver.searchPort
        #expect(port != 0 && searchPort != 0)
        #expect(NetworkPlaybackCache.hasRemoteReader(scheme: ReceiverStreams.scheme))
        #expect(await ReceiverPatience.until { inbox.received.contains { $0.contains("NTS: ssdp:alive") && $0.contains("NT: \(ReceiverDescription.deviceType)") } })
        let alive = try #require(inbox.received.first { $0.contains("NT: \(ReceiverDescription.deviceType)") })
        #expect(alive.contains("LOCATION: http://127.0.0.1:\(port)\(ReceiverDescription.descriptionPath)") && alive.contains("USN: \(udn)::"))
        let description = try #require(rawExchange(port: port, send: Data("GET \(ReceiverDescription.descriptionPath) HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        #expect(description.response.hasPrefix("HTTP/1.1 200") && description.response.contains("<friendlyName>Vespertine on test-mac</friendlyName>"))

        await receiver.stop()
        let after = await (receiver.port, receiver.searchPort, receiver.isRunning)
        #expect(after == (0, 0, false))
        #expect(await ReceiverPatience.until { inbox.received.contains { $0.contains("NTS: ssdp:byebye") && $0.contains("NT: \(ReceiverDescription.deviceType)") } },
                "it said goodbye")
        // The listener closes on its own queue: the port is gone once a connection to it is refused.
        #expect(await ReceiverPatience.until { rawExchange(port: port, send: Data("GET \(ReceiverDescription.descriptionPath) HTTP/1.1\r\nHost: x\r\n\r\n".utf8), timeout: 1) == nil },
                "the port is closed")
        let replies = await SSDPSearcher(host: "127.0.0.1", port: searchPort).search(targets: ["ssdp:all"], mx: 1, wait: 0.3)
        #expect(replies.isEmpty, "searches are no longer answered")
        // On again: it comes back, on ports of its own.
        try await receiver.start()
        #expect(await receiver.port != 0)
        await receiver.stop()
    }

    @Test("Control is taken only from the Mac's own subnets, or from any private address when the listener allows that")
    func ownSubnets() {
        let networks = [LocalNetwork(interface: "en0", address: [192, 0, 2, 10], mask: [255, 255, 255, 0]),
                        LocalNetwork(interface: "lo0", address: [127, 0, 0, 1], mask: [255, 0, 0, 0], isLoopback: true)]
        #expect(LocalNetworks.isOnOwnSubnet("192.0.2.77", networks: networks))
        #expect(LocalNetworks.isOnOwnSubnet("::ffff:192.0.2.77", networks: networks))
        #expect(LocalNetworks.isOnOwnSubnet("127.0.0.1", networks: networks))
        #expect(!LocalNetworks.isOnOwnSubnet("192.0.3.77", networks: networks))
        #expect(!LocalNetworks.isOnOwnSubnet("198.51.100.7", networks: networks))
        #expect(!LocalNetworks.isOnOwnSubnet(nil, networks: networks))
        #expect(!LocalNetworks.isOnOwnSubnet("not an address", networks: networks))
        #expect(LocalNetworks.isPrivate("10.1.2.3") && LocalNetworks.isPrivate("172.20.0.9") && LocalNetworks.isPrivate("192.168.4.4") && LocalNetworks.isPrivate("100.100.1.1"))
        #expect(LocalNetworks.isPrivate("fd00::1") && LocalNetworks.isPrivate("fe80::1%en0") && LocalNetworks.isPrivate("::1"))
        #expect(!LocalNetworks.isPrivate("198.51.100.7") && !LocalNetworks.isPrivate("2001:db8::1") && !LocalNetworks.isPrivate("172.32.0.1"))
    }

    @Test("A control app on another subnet gets no answer: not to a search, not on the HTTP port")
    func otherSubnetsRefused() async throws {
        let player = try EnginePlayer()
        var configuration = UPnPReceiver.Configuration(udn: "uuid:\(UUID().uuidString.lowercased())", name: "Vespertine on test-mac", version: "1.1.0")
        configuration.listenOn = ("127.0.0.1", 0)
        configuration.responseDelay = { _ in 0 }
        // This Mac as if it were only on 192.0.2.0/24: the tests' own address, 127.0.0.1, is then a stranger's.
        configuration.networks = { [LocalNetwork(interface: "en0", address: [192, 0, 2, 10], mask: [255, 255, 255, 0])] }
        let receiver = UPnPReceiver(configuration, player: player)
        try await receiver.start()
        let port = await receiver.port
        let reply = try #require(rawExchange(port: port, send: Data("GET \(ReceiverDescription.descriptionPath) HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        #expect(reply.response.isEmpty && reply.closed, "closed before a byte was read or sent")
        let replies = await SSDPSearcher(host: "127.0.0.1", port: await receiver.searchPort).search(targets: ["ssdp:all"], mx: 1, wait: 0.5)
        #expect(replies.isEmpty)
        await receiver.stop()
    }

    @Test("Events go only to the address that subscribed; a subscription is renewed and ended by its id")
    func subscriptions() async throws {
        let scene = try await ReceiverScene()
        let port = await scene.port
        #expect(try await scene.listener.subscribe(.avTransport, receiverPort: port, path: "/avt", callback: "<http://192.0.2.9:4004/events>").status == 412)
        #expect(try await scene.listener.subscribe(.avTransport, receiverPort: port, path: "/avt", callback: "<https://127.0.0.1:4004/events>").status == 412)
        #expect(try await scene.listener.subscribe(.avTransport, receiverPort: port, path: "/avt", callback: "nonsense").status == 412)
        let made = try await scene.listener.subscribe(.connectionManager, receiverPort: port, path: "/cm")
        let sid = try #require(made.sid)
        #expect(await ReceiverPatience.until { scene.listener.events.contains { $0.path == "/cm" && $0.sid == sid && $0.sequence == 0 } }, "the first event is numbered 0")
        #expect(try await EventListener.request("SUBSCRIBE", .connectionManager, receiverPort: port, sid: sid) == 200)
        #expect(try await EventListener.request("UNSUBSCRIBE", .connectionManager, receiverPort: port, sid: sid) == 200)
        #expect(try await EventListener.request("SUBSCRIBE", .connectionManager, receiverPort: port, sid: sid) == 412)
        #expect(try await EventListener.request("UNSUBSCRIBE", .connectionManager, receiverPort: port, sid: "uuid:nobody") == 412)
        await scene.close()
    }
}

@Suite("Receive from Other Apps: what it says it is")
struct ReceiverDescriptionTests {
    @Test("The description is one the app's own renderer client reads: a MediaRenderer with the three services")
    func description() throws {
        let xml = ReceiverDescription.device(udn: "uuid:1234", name: "  Vespertine <on> test-mac & co\n", version: "1.1.0")
        let parsed = try DeviceDescription.parse(Data(xml.utf8), location: URL(string: "http://192.0.2.10:49200\(ReceiverDescription.descriptionPath)")!)
        #expect(parsed.udn == "uuid:1234" && parsed.friendlyName == "Vespertine <on> test-mac & co")
        #expect(parsed.service(.avTransport)?.controlURL.path == ReceiverService.avTransport.controlPath)
        #expect(parsed.service(.connectionManager) != nil && parsed.service(.renderingControl) != nil)
        #expect(ReceiverDescription.friendlyName("   ") == "Vespertine")
        #expect(ReceiverDescription.friendlyName(String(repeating: "n", count: 200)).count == ReceiverDescription.maximumNameLength)
        let actions = try SCPD.actions(Data(ReceiverDescription.scpd(.avTransport).utf8))
        #expect(actions.isSuperset(of: ["SetAVTransportURI", "SetNextAVTransportURI", "Play", "Pause", "Stop", "Seek", "GetPositionInfo", "GetTransportInfo", "GetMediaInfo"]))
        #expect(try SCPD.actions(Data(ReceiverDescription.scpd(.renderingControl).utf8)).isSuperset(of: ["GetVolume", "SetVolume", "GetMute", "SetMute"]))
        #expect(try SCPD.actions(Data(ReceiverDescription.scpd(.connectionManager).utf8)).contains("GetProtocolInfo"))
    }

    @Test("Every type it says it takes is one the stream reader recognises as audio")
    func sinkIsWhatTheEngineDecodes() {
        for type in ReceiverDescription.sinkMediaTypes {
            #expect(ReceiverDescription.fileExtension(forMediaType: type) != nil, "\(type) has a decoder's extension")
        }
        #expect(ReceiverDescription.sinkProtocolInfo.contains("http-get:*:audio/flac:*"))
        #expect(!ReceiverDescription.sinkProtocolInfo.contains("video/"))
        #expect(ReceiverDescription.fileExtension(forMediaType: "Audio/FLAC; charset=binary") == "flac")
        #expect(ReceiverDescription.fileExtension(forMediaType: "video/mp4") == nil)
    }

    @Test("A search is an M-SEARCH with ssdp:discover; anything else on the port is not answered")
    func searchParsing() {
        let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 9\r\nST: ssdp:all\r\n\r\n"
        #expect(ReceiverAdvertiser.Search.parse(Data(search.utf8)) == .init(target: "ssdp:all", mx: 5))
        #expect(ReceiverAdvertiser.Search.parse(Data("NOTIFY * HTTP/1.1\r\nNT: upnp:rootdevice\r\n\r\n".utf8)) == nil)
        #expect(ReceiverAdvertiser.Search.parse(Data("M-SEARCH * HTTP/1.1\r\nST: ssdp:all\r\n\r\n".utf8)) == nil, "no MAN header")
        #expect(ReceiverAdvertiser.Search.parse(Data([0xff, 0xfe, 0x00])) == nil)
        #expect(ReceiverAdvertiser.Search.parse(Data(("M-SEARCH * HTTP/1.1\r\nMAN: \"ssdp:discover\"\r\nST: " + String(repeating: "x", count: 400) + "\r\n\r\n").utf8)) == nil)
    }

    @Test("The control app's name comes from its User-Agent, cleaned; a library's or a system's name is not a name")
    func controlAppName() {
        #expect(ReceiverControlApp.name(fromUserAgent: "Linux/4.9 UPnP/1.0 BubbleUPnP/3.5") == "BubbleUPnP")
        #expect(ReceiverControlApp.name(fromUserAgent: "mConnect/3.2 UPnP/1.0") == "mConnect")
        #expect(ReceiverControlApp.name(fromUserAgent: "Dalvik/2.1.0 (Linux; U; Android 14; Pixel 8)") == nil)
        #expect(ReceiverControlApp.name(fromUserAgent: "Darwin/25.0 UPnP/1.1 CFNetwork/1500") == nil)
        #expect(ReceiverControlApp.name(fromUserAgent: nil) == nil)
        #expect(ReceiverControlApp.name(fromUserAgent: "<script>alert(1)</script>/1.0") == "scriptalert")
        // Text from the network never keeps a character a format string could act on.
        #expect(ReceiverControlApp.name(fromUserAgent: "%@%n%s/1.0 Evil%d") == "ns")
        #expect(ReceiverControlApp.name(fromUserAgent: "%@/1.0 Evil%d") == "Evild")
        #expect((ReceiverControlApp.name(fromUserAgent: String(repeating: "N", count: 100) + "/1") ?? "").count == 40)
        #expect(ReceiverControlApp.name(fromUserAgent: String(repeating: "N", count: 600)) == nil)
    }

    @Test("A song's description gives its title, artist, album, art and length; fields are cut to size and art must be http")
    func metadata() throws {
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
        <item id="1" parentID="0" restricted="1"><dc:title>Night &amp; Day</dc:title><dc:creator>Someone Else</dc:creator><upnp:artist>The Artist</upnp:artist>
        <upnp:album>The Album</upnp:album><upnp:albumArtURI>http://192.0.2.7:8080/art/1.jpg</upnp:albumArtURI>
        <res protocolInfo="http-get:*:audio/x-flac:DLNA.ORG_OP=01" duration="0:03:25.500">http://192.0.2.7:8080/1.flac</res>
        <res protocolInfo="http-get:*:audio/mpeg:*">http://192.0.2.7:8080/1.mp3</res></item></DIDL-Lite>
        """
        let found = try #require(try ReceivedMetadata.parse(didl))
        #expect(found.title == "Night & Day" && found.artist == "The Artist" && found.album == "The Album")
        #expect(found.artworkURL == URL(string: "http://192.0.2.7:8080/art/1.jpg") && found.duration == 205.5 && found.mediaType == "audio/x-flac")
        let odd = "<DIDL-Lite><item><title>\(String(repeating: "t", count: 5000))</title><albumArtURI>file:///etc/passwd</albumArtURI><res duration=\"NOT_IMPLEMENTED\">x</res></item></DIDL-Lite>"
        let cut = try #require(try ReceivedMetadata.parse(odd))
        #expect(cut.title?.count == 1024 && cut.artworkURL == nil && cut.duration == nil && cut.mediaType == nil)
        #expect(try ReceivedMetadata.parse("") == nil)
        #expect(throws: ReceivedMetadata.Failure.malformed) { try ReceivedMetadata.parse("<DIDL-Lite><item/><item/></DIDL-Lite>") }
    }

    @Test("Events carry each variable once, escaped inside LastChange")
    func eventBodies() {
        let body = ReceiverEventBody.lastChange(namespace: ReceiverEventBody.avTransportNamespace,
                                                variables: [("TransportState", "PLAYING", nil), ("AVTransportURI", "http://192.0.2.7/a?b=1&c=<2>", nil)])
        let read = ReceiverEventBody.variables(inLastChange: body)
        #expect(read == ["TransportState": "PLAYING", "AVTransportURI": "http://192.0.2.7/a?b=1&c=<2>"])
        #expect(ReceiverSubscriptions.timeout("Second-99999") == 1800 && ReceiverSubscriptions.timeout("Second-5") == 60 && ReceiverSubscriptions.timeout("infinite") == 1800)
        #expect(ReceiverSubscriptions.callback("<http://192.0.2.9/a> <http://192.0.2.7:4004/b>", peer: "192.0.2.7")?.absoluteString == "http://192.0.2.7:4004/b")
        #expect(ReceiverSubscriptions.callback("<http://user@192.0.2.7:4004/b>", peer: "192.0.2.7") == nil)
        #expect(ReceiverSubscriptions.callback("<http://music.example/b>", peer: "192.0.2.7") == nil, "a name is not the subscriber's address")
    }
}
