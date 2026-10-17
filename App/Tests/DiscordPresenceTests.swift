import Darwin
import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// A stand-in for the Discord app: listens on a discord-ipc socket and answers as Discord does.
private nonisolated final class FakeDiscord: @unchecked Sendable {
    enum Answer { case ready, invalidClientID }

    let directory: String
    var path: String { directory + "/discord-ipc-0" }
    private let listener: Int32
    private let answer: Answer
    private let state = Locked<(frames: [DiscordIPC.Frame], clients: [Int32], connections: Int)>(([], [], 0))

    init(answer: Answer = .ready) throws {
        // Unix socket paths are limited to 104 bytes, so not the (long) per-user temporary directory.
        directory = "/tmp/vt-discord-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        self.answer = answer
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array((directory + "/discord-ipc-0").utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw DiscordIPC.Failure.socket(errno) }
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    var frames: [DiscordIPC.Frame] { state.withLock { $0.frames } }
    var connections: Int { state.withLock { $0.connections } }
    var activityCommands: [[String: Any]] {
        frames.compactMap { $0.json }.filter { $0["cmd"] as? String == "SET_ACTIVITY" }
    }

    /// Drops every connection, as Discord quitting does (and keeps listening, as a restarted Discord would).
    func dropClients() {
        for fd in state.withLock({ s in defer { s.clients = [] }; return s.clients }) { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    func stop() {
        dropClients()
        close(listener)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            state.withLock { $0.clients.append(fd); $0.connections += 1 }
            Thread { [self] in serve(fd) }.start()
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            guard let frames = try? DiscordIPC.decode(&buffer) else { return }
            for frame in frames {
                state.withLock { $0.frames.append(frame) }
                let json = frame.json ?? [:]
                switch frame.opcode {
                case DiscordIPC.Opcode.handshake.rawValue:
                    switch answer {
                    case .ready:
                        reply(fd, .frame, ["cmd": "DISPATCH", "evt": "READY", "data": ["v": 1, "user": ["username": "alex", "global_name": "Alex"]]])
                    case .invalidClientID:
                        reply(fd, .close, ["code": 4000, "message": "Invalid Client ID"])
                    }
                case DiscordIPC.Opcode.frame.rawValue:
                    let args = json["args"] as? [String: Any]
                    reply(fd, .frame, ["cmd": "SET_ACTIVITY", "nonce": json["nonce"] ?? "", "evt": NSNull(), "data": args?["activity"] ?? NSNull()])
                default: break
                }
            }
        }
    }

    private func reply(_ fd: Int32, _ opcode: DiscordIPC.Opcode, _ json: [String: Any]) {
        let data = DiscordIPC.encode(opcode, try! JSONSerialization.data(withJSONObject: json))
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    }
}

/// Waits (up to five seconds) for `condition`.
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

private func song(_ title: String = "So What", startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> DiscordNowPlaying {
    DiscordNowPlaying(title: title, artist: "Miles Davis", album: "Kind of Blue", format: "24/192 FLAC", bitPerfect: true,
                      startedAt: startedAt, duration: 562.5, artwork: nil)
}

@Suite("Discord status") @MainActor
struct DiscordPresenceTests {
    @Test("Frames are a little-endian opcode and length, then the JSON; partial frames wait for the rest")
    func framing() throws {
        let payload = Data(#"{"v":1,"client_id":"42"}"#.utf8)
        let encoded = DiscordIPC.encode(.handshake, payload)
        #expect([UInt8](encoded.prefix(8)) == [0, 0, 0, 0, UInt8(payload.count), 0, 0, 0])
        var buffer = encoded + DiscordIPC.encode(.ping, Data("x".utf8))
        let tail = buffer.suffix(3)
        buffer.removeLast(3)
        var frames = try DiscordIPC.decode(&buffer)
        #expect(frames == [DiscordIPC.Frame(opcode: 0, payload: payload)])
        buffer.append(tail)
        frames = try DiscordIPC.decode(&buffer)
        #expect(frames == [DiscordIPC.Frame(opcode: 3, payload: Data("x".utf8))] && buffer.isEmpty)
        var garbage = Data([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: DiscordIPC.Failure.malformed) { try DiscordIPC.decode(&garbage) }
    }

    @Test("Discord's socket is looked for in the temporary directory, discord-ipc-0 to 9")
    func socketPaths() {
        let paths = DiscordIPC.socketPaths(environment: ["TMPDIR": "/var/folders/xy/T/"])
        #expect(paths.first == "/var/folders/xy/T/discord-ipc-0")
        #expect(paths.contains("/var/folders/xy/T/discord-ipc-9") && paths.contains("/tmp/discord-ipc-0"))
        #expect(Set(paths).count == paths.count)
    }

    @Test("The format line says what's playing the way listeners say it")
    func formatLines() {
        func line(_ codec: String, _ encoding: SourceFormat.Encoding, _ rate: Double, _ bits: Int?, channels: Int = 2,
                  kbps: Double? = nil, device: String? = nil) -> String {
            DiscordStatus.formatLine(codec: codec, encoding: encoding, sampleRate: rate, bitDepth: bits, channels: channels,
                                     kbps: kbps, deviceFormat: device)
        }
        #expect(line("FLAC", .pcm, 192_000, 24) == "24/192 FLAC")
        #expect(line("FLAC", .pcm, 48_000, 24) == "24/48 FLAC")
        #expect(line("ALAC", .pcm, 44_100, 16) == "16/44.1 ALAC")
        #expect(line("DSF", .dsd, 5_644_800, 1) == "DSD128")
        #expect(line("DSDIFF", .dsd, 2_822_400, 1, channels: 6) == "DSD64 · 5.1")
        #expect(line("MP3", .lossy, 44_100, nil, kbps: 320) == "320 kbps MP3")
        #expect(line("AAC", .lossy, 44_100, nil) == "AAC")
        #expect(line("WAV", .pcm, 96_000, nil) == "96 kHz WAV")
        #expect(line("Dolby TrueHD", .pcm, 48_000, 24, channels: 8) == "Dolby TrueHD · 7.1")
        #expect(line("FLAC", .pcm, 192_000, 24, device: "24/96") == "24/192 FLAC → 24/96")
    }

    @Test("Text fits Discord's limits: 2 to 128 characters, cut with an ellipsis")
    func textLimits() {
        #expect(DiscordStatus.fit("X").utf16.count == 2 && DiscordStatus.fit("X").hasPrefix("X"))
        #expect(DiscordStatus.fit("  Blue in Green ") == "Blue in Green")
        let long = String(repeating: "Ä", count: 200)
        let cut = DiscordStatus.fit(long)
        #expect(cut.utf16.count <= 128 && cut.hasSuffix("…"))
        // Emoji are two UTF-16 units: never split in half.
        let emoji = DiscordStatus.fit(String(repeating: "🎷", count: 100))
        #expect(emoji.utf16.count <= 128 && emoji.unicodeScalars.allSatisfy { $0.properties.isEmoji || $0 == "…" })
        #expect(DiscordStatus.fit("Get Vespertine, the best free player", max: 32).utf16.count <= 32)
    }

    @Test("The activity is a Listening status with a progress bar, the album and format, and the cover")
    func activity() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let withCover = DiscordStatus.activity(for: song(startedAt: start), artworkURL: "https://example.org/cover.jpg")
        #expect(withCover.type == 2 && withCover.statusDisplayType == 2)
        #expect(withCover.details == "So What" && withCover.state == "Miles Davis")
        #expect(withCover.timestamps == .init(start: 1_800_000_000_000, end: 1_800_000_562_500))
        #expect(withCover.assets?.largeImage == "https://example.org/cover.jpg")
        #expect(withCover.assets?.largeText == "Kind of Blue · 24/192 FLAC")
        #expect(withCover.assets?.smallImage == DiscordStatus.appIconURL)
        #expect(withCover.buttons?.first?.url == "https://vespertineapp.com")

        let noCover = DiscordStatus.activity(for: song(), artworkURL: nil)
        #expect(noCover.assets?.largeImage == DiscordStatus.appIconURL && noCover.assets?.smallImage == nil)

        // Discord's own key names, and nothing it would refuse (nil fields are left out).
        let json = try #require(try JSONSerialization.jsonObject(with: #require(noCover.encoded())) as? [String: Any])
        #expect(Set(json.keys) == ["type", "status_display_type", "details", "state", "timestamps", "assets", "buttons"])
        let assets = try #require(json["assets"] as? [String: Any])
        #expect(Set(assets.keys) == ["large_image", "large_text"])
    }

    @Test("Only a real change reaches Discord: a seek or resume moves the start, polling jitter doesn't")
    func sameStatus() {
        let a = song()
        var b = a
        b.startedAt = a.startedAt.addingTimeInterval(0.3)
        #expect(a.isSame(as: b))
        b.startedAt = a.startedAt.addingTimeInterval(-30)
        #expect(!a.isSame(as: b))
        var c = a
        c.format = "24/192 FLAC → 24/96"
        #expect(!a.isSame(as: c))
    }

    @Test("Covers from Apple's catalog only for a clear match of album and artist")
    func appleMatches() throws {
        func results(_ items: [[String: String]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["resultCount": items.count, "results": items])
        }
        let data = try results([
            ["collectionName": "Kind of Blue (Legacy Edition)", "artistName": "Miles Davis", "artworkUrl100": "https://is1.mzstatic.com/a/100x100bb.jpg"],
            ["collectionName": "Kind of Blue", "artistName": "Miles Davis Tribute Band", "artworkUrl100": "https://is1.mzstatic.com/b/100x100bb.jpg"],
            ["collectionName": "Kind of Blue", "artistName": "Miles Davis", "artworkUrl100": "https://is1.mzstatic.com/c/100x100bb.jpg"],
        ])
        #expect(DiscordArtworkFinder.bestAppleMatch(data, artist: "Miles Davis", album: "Kind of Blue", title: "So What")
                == "https://is1.mzstatic.com/c/600x600bb.jpg")
        let wrong = try results([["collectionName": "Kind of Blue", "artistName": "Somebody Else", "artworkUrl100": "https://is1.mzstatic.com/d/100x100bb.jpg"]])
        #expect(DiscordArtworkFinder.bestAppleMatch(wrong, artist: "Miles Davis", album: "Kind of Blue", title: "So What") == nil)
        let other = try results([["collectionName": "Bitches Brew", "artistName": "Miles Davis", "artworkUrl100": "https://is1.mzstatic.com/e/100x100bb.jpg"]])
        #expect(DiscordArtworkFinder.bestAppleMatch(other, artist: "Miles Davis", album: "Kind of Blue", title: "So What") == nil)
        #expect(DiscordArtworkFinder.normalized("Édith Piaf & Friends [Remastered]") == "edithpiafandfriends")
        #expect(DiscordArtworkFinder.bestAppleMatch(Data("nonsense".utf8), artist: "A", album: "B", title: "C") == nil)
    }

    @Test("Against a stand-in Discord: handshake, status, clearing it, and Discord restarting")
    func talksToDiscord() async throws {
        let discord = try FakeDiscord()
        defer { discord.stop() }
        let states = Locked<[DiscordConnectionState]>([])
        let client = DiscordRPCClient(applicationID: "1234567890", minimumInterval: 0, retryInterval: 0.2,
                                      socketPaths: { [path = discord.path] in [path] },
                                      onState: { state in states.withLock { $0.append(state) } })
        defer { client.shutdown(wait: true) }

        client.setActivity(DiscordStatus.activity(for: song(), artworkURL: nil).encoded())
        #expect(await eventually { discord.activityCommands.count == 1 })
        let handshake = try #require(discord.frames.first?.json)
        #expect(discord.frames.first?.opcode == 0 && handshake["client_id"] as? String == "1234567890" && handshake["v"] as? Int == 1)
        let args = try #require(discord.activityCommands.first?["args"] as? [String: Any])
        #expect(args["pid"] as? Int == Int(getpid()))
        let activity = try #require(args["activity"] as? [String: Any])
        #expect(activity["details"] as? String == "So What" && activity["type"] as? Int == 2)
        #expect(await eventually { states.withLock { $0.last } == .connected(user: "Alex") })

        // The same status again isn't sent again.
        client.setActivity(DiscordStatus.activity(for: song(), artworkURL: nil).encoded())
        // Paused: the status is cleared (SET_ACTIVITY without an activity).
        client.setActivity(nil)
        #expect(await eventually { discord.activityCommands.count == 2 })
        let cleared = try #require(discord.activityCommands.last?["args"] as? [String: Any])
        #expect(cleared["activity"] == nil)

        // Discord quits and comes back: the next song still shows, over a new connection.
        discord.dropClients()
        client.setActivity(DiscordStatus.activity(for: song("Freddie Freeloader"), artworkURL: nil).encoded())
        #expect(await eventually {
            (discord.activityCommands.last?["args"] as? [String: Any]).flatMap { $0["activity"] as? [String: Any] }?["details"] as? String
                == "Freddie Freeloader"
        })
        #expect(discord.connections == 2)
    }

    @Test("Discord not open, or refusing the application: said so, and nothing breaks")
    func discordMissingOrRefusing() async throws {
        let states = Locked<[DiscordConnectionState]>([])
        let missing = DiscordRPCClient(applicationID: "1", retryInterval: 0.2, socketPaths: { ["/tmp/vt-no-discord-here/discord-ipc-0"] },
                                       onState: { state in states.withLock { $0.append(state) } })
        missing.setActivity(DiscordStatus.activity(for: song(), artworkURL: nil).encoded())
        #expect(await eventually { states.withLock { $0.last } == .waitingForDiscord })
        missing.shutdown(wait: true)
        #expect(states.withLock { $0.last } == .idle)

        let discord = try FakeDiscord(answer: .invalidClientID)
        defer { discord.stop() }
        let refused = Locked<[DiscordConnectionState]>([])
        let client = DiscordRPCClient(applicationID: "1", retryInterval: 30, socketPaths: { [path = discord.path] in [path] },
                                      onState: { state in refused.withLock { $0.append(state) } })
        defer { client.shutdown(wait: true) }
        client.setActivity(DiscordStatus.activity(for: song(), artworkURL: nil).encoded())
        #expect(await eventually { refused.withLock { $0.last } == .refused("Invalid Client ID") })
        #expect(discord.activityCommands.isEmpty)
    }

    @Test("The setting is off until turned on, and covers are on with it")
    func setting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-discord-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = root.appendingPathComponent("defaults.plist").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.discordPresence && settings.discordArtwork)
        settings.discordPresence = true
        #expect(AppSettings(defaults: defaults, dataDirectory: root).discordPresence)
    }
}
