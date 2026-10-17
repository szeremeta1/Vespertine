//
// Vespertine — Discord's local RPC: framed JSON over the Unix socket the Discord app opens for other apps on the Mac.
// No Discord SDK and no network: the Discord app itself carries the status to Discord.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation
import os

/// The wire format. Each frame is a little-endian opcode and payload length, then that many bytes of JSON.
nonisolated enum DiscordIPC {
    enum Opcode: UInt32, Sendable { case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4 }

    static let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "discord")

    struct Frame: Sendable, Equatable {
        var opcode: UInt32
        var payload: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] }
        static func == (a: Frame, b: Frame) -> Bool { a.opcode == b.opcode && a.payload == b.payload }
    }

    enum Failure: Error, Equatable {
        case noSocket
        case socket(Int32)
        case closed(code: Int?, message: String?)
        case malformed
        case timedOut
    }

    /// Larger than any reply Discord sends; a header claiming more is a stream out of step, not a frame.
    static let maxPayload = 1 << 20

    static func encode(_ opcode: Opcode, _ payload: Data) -> Data {
        var data = Data(capacity: 8 + payload.count)
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Takes every complete frame off the front of `buffer`, leaving a partial one there.
    static func decode(_ buffer: inout Data) throws -> [Frame] {
        var frames: [Frame] = []
        while buffer.count >= 8 {
            let header = [UInt8](buffer.prefix(8))
            let opcode = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
            let length = Int(UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24)
            guard length <= maxPayload else { throw Failure.malformed }
            guard buffer.count >= 8 + length else { break }
            let start = buffer.startIndex
            frames.append(Frame(opcode: opcode, payload: Data(buffer[(start + 8)..<(start + 8 + length)])))
            buffer = Data(buffer.dropFirst(8 + length))
        }
        return frames
    }

    /// Where Discord (or Discord PTB, Canary, or a client like Vesktop) listens: discord-ipc-0…9 in the temporary
    /// directory. Discord takes the first free number, so the first one that answers is the one to use.
    static func socketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var directories: [String] = []
        for key in ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"] {
            if let dir = environment[key], !dir.isEmpty { directories.append(dir) }
        }
        directories.append(NSTemporaryDirectory())
        directories.append("/tmp")
        var seen = Set<String>()
        let unique = directories.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }.filter { seen.insert($0).inserted }
        return unique.flatMap { dir in (0...9).map { "\(dir)/discord-ipc-\($0)" } }
    }
}

/// One connection to the Discord app. Not thread-safe: `DiscordRPCClient` uses it from its own queue only.
nonisolated final class DiscordIPCConnection {
    private var fd: Int32
    private var buffer = Data()

    /// Connects to the first socket in `paths` that accepts.
    init(paths: [String]) throws {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw DiscordIPC.Failure.socket(errno) }
            var on: Int32 = 1
            // A write after Discord quit must fail with EPIPE, not kill Vespertine with SIGPIPE.
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); continue }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if connected == 0 {
                self.fd = fd
                return
            }
            // A socket file left behind by a Discord that crashed: try the next one.
            Darwin.close(fd)
        }
        throw DiscordIPC.Failure.noSocket
    }

    deinit { close() }

    var isOpen: Bool { fd >= 0 }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    func send(_ opcode: DiscordIPC.Opcode, _ payload: Data) throws {
        let data = DiscordIPC.encode(opcode, payload)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { let e = errno; close(); throw DiscordIPC.Failure.socket(e) }
                offset += n
            }
        }
    }

    func send(_ opcode: DiscordIPC.Opcode, json: [String: Any]) throws {
        try send(opcode, try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }

    /// Frames that arrive within `timeout` (0: only what's already there). Stops at the first complete frame when
    /// `untilFrame` is set. Answers Discord's pings itself, and throws when Discord closes the connection.
    func receive(timeout: TimeInterval, untilFrame: Bool = true) throws -> [DiscordIPC.Frame] {
        var frames: [DiscordIPC.Frame] = []
        let deadline = Date().addingTimeInterval(timeout)
        while fd >= 0 {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            guard n > 0 else { close(); throw DiscordIPC.Failure.closed(code: nil, message: nil) }
            buffer.append(contentsOf: chunk[0..<n])
            let decoded: [DiscordIPC.Frame]
            do { decoded = try DiscordIPC.decode(&buffer) } catch { close(); throw error }
            for frame in decoded {
                switch DiscordIPC.Opcode(rawValue: frame.opcode) {
                case .ping: try send(.pong, frame.payload)
                case .close:
                    close()
                    let json = frame.json
                    throw DiscordIPC.Failure.closed(code: json?["code"] as? Int, message: json?["message"] as? String)
                default: frames.append(frame)
                }
            }
            if untilFrame, !frames.isEmpty { break }
            if remaining <= 0 { break }
        }
        return frames
    }
}

/// What the Discord connection is doing, for Settings.
nonisolated enum DiscordConnectionState: Sendable, Equatable {
    /// Not connected, and not trying: nothing to show.
    case idle
    /// Discord isn't open (or not signed in yet). Vespertine keeps looking while a song plays.
    case waitingForDiscord
    /// Connected; the name of the Discord account, when Discord said.
    case connected(user: String?)
    /// Discord refused the connection or the status, with its reason.
    case refused(String)
}

/// Keeps Discord showing the activity it was last given: connects when there is one to show, reconnects when
/// Discord restarts, and limits how often the status changes (Discord allows five changes in 20 seconds).
/// Everything runs on one serial queue; the socket never blocks the main thread.
nonisolated final class DiscordRPCClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.discord", qos: .utility)
    private let applicationID: String
    private let socketPaths: @Sendable () -> [String]
    private let onState: @Sendable (DiscordConnectionState) -> Void
    /// The shortest time between two status changes sent to Discord.
    private let minimumInterval: TimeInterval
    private let retryInterval: TimeInterval

    // Queue-confined.
    private var connection: DiscordIPCConnection?
    /// The activity to show (encoded), or nil to show none. `wanted` is false once shut down.
    private var desired: Data?
    private var wanted = false
    /// What Discord was last told: nil when nothing (or nothing yet) is shown.
    private var shown: Data?
    private var lastSent = Date.distantPast
    private var lastAttempt = Date.distantPast
    /// The Discord account's name, from the handshake.
    private var user: String?
    private var pumpScheduled = false
    private var keepAlive: DispatchSourceTimer?
    private var state: DiscordConnectionState = .idle {
        didSet { if state != oldValue { onState(state) } }
    }

    init(applicationID: String, minimumInterval: TimeInterval = 2, retryInterval: TimeInterval = 10,
         socketPaths: @escaping @Sendable () -> [String] = { DiscordIPC.socketPaths() },
         onState: @escaping @Sendable (DiscordConnectionState) -> Void) {
        self.applicationID = applicationID
        self.minimumInterval = minimumInterval
        self.retryInterval = retryInterval
        self.socketPaths = socketPaths
        self.onState = onState
    }

    /// Shows `activity` (a JSON-encoded activity object), or clears the status with nil.
    func setActivity(_ activity: Data?) {
        queue.async { [self] in
            wanted = true
            desired = activity
            pump()
        }
    }

    /// Clears the status and disconnects (the setting was turned off). `wait`: until Discord has been told.
    func shutdown(wait: Bool = false) {
        let work: @Sendable () -> Void = { [self] in
            wanted = false
            desired = nil
            if let connection, connection.isOpen, shown != nil { try? send(activity: nil) }
            disconnect(to: .idle)
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    // MARK: Queue only

    private func pump() {
        guard wanted else { return }
        if connection?.isOpen != true {
            connection = nil
            // Nothing to show: no reason to open Discord's socket (and nothing of ours is showing there).
            guard desired != nil else { shown = nil; return }
            let wait = lastAttempt.addingTimeInterval(retryInterval).timeIntervalSinceNow
            if wait > 0 { schedulePump(after: wait); return }
            lastAttempt = .now
            guard connect() else { schedulePump(after: retryInterval); return }
        }
        guard desired != shown else { return }
        let wait = lastSent.addingTimeInterval(minimumInterval).timeIntervalSinceNow
        if wait > 0 { schedulePump(after: wait); return }
        do {
            try send(activity: desired)
        } catch {
            DiscordIPC.log.notice("Discord status not sent: \(String(describing: error), privacy: .public)")
            handle(error)
            schedulePump(after: 1)
        }
    }

    private func schedulePump(after seconds: TimeInterval) {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        queue.asyncAfter(deadline: .now() + max(0.05, seconds)) { [self] in
            pumpScheduled = false
            pump()
        }
    }

    private func connect() -> Bool {
        do {
            let connection = try DiscordIPCConnection(paths: socketPaths())
            try connection.send(.handshake, json: ["v": 1, "client_id": applicationID])
            // READY arrives once Discord accepts the application (an unknown ID gets a CLOSE instead).
            let ready = try connection.receive(timeout: 5).first { $0.json?["evt"] as? String == "READY" }
            guard let ready else { connection.close(); throw DiscordIPC.Failure.timedOut }
            let user = (ready.json?["data"] as? [String: Any])?["user"] as? [String: Any]
            let name = (user?["global_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user?["username"] as? String
            self.connection = connection
            shown = nil
            user = name
            state = .connected(user: name)
            startKeepAlive()
            DiscordIPC.log.info("Connected to Discord")
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func send(activity: Data?) throws {
        guard let connection else { throw DiscordIPC.Failure.noSocket }
        var args: [String: Any] = ["pid": Int(getpid())]
        if let activity, let object = try? JSONSerialization.jsonObject(with: activity) { args["activity"] = object }
        let nonce = UUID().uuidString
        try connection.send(.frame, json: ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce])
        lastSent = .now
        // Read the answer so replies never pile up in the socket; an ERROR names what Discord didn't accept.
        let replies = try connection.receive(timeout: 3).filter { $0.json?["nonce"] as? String == nonce }
        if let reply = replies.first?.json, reply["evt"] as? String == "ERROR" {
            let message = (reply["data"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            DiscordIPC.log.error("Discord refused the status: \(message, privacy: .public)")
            state = .refused(message)
            // Not shown, and the same activity would be refused again: wait for a different one.
            shown = activity
            return
        }
        shown = activity
        state = .connected(user: user)
    }

    private func handle(_ error: Error) {
        // 4000: invalid client ID, 4004: invalid version, and the like. Anything else: Discord isn't there (yet).
        if case .closed(let code?, let message?)? = error as? DiscordIPC.Failure, code != 1000 {
            disconnect(to: .refused(message))
        } else {
            disconnect(to: .waitingForDiscord)
        }
    }

    private func disconnect(to newState: DiscordConnectionState) {
        keepAlive?.cancel()
        keepAlive = nil
        connection?.close()
        connection = nil
        shown = nil
        state = newState
    }

    /// Reads what Discord sends between status changes: pings (answered), and the end of the connection when Discord
    /// quits, so the status is shown again as soon as it's back.
    private func startKeepAlive() {
        keepAlive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.connection else { return }
            do { _ = try connection.receive(timeout: 0, untilFrame: false) } catch {
                self.handle(error)
                self.pump()
            }
        }
        keepAlive = timer
        timer.resume()
    }
}
