//
// Vespertine: an AirPlay 1 receiver on 127.0.0.1 for the tests: RTSP on a TCP port, UDP audio, control and timing ports.
// It records every request, asks the sender for the time (as shairport-sync does before it trusts sync packets), unwraps
// the AES key with the test's private key, decrypts and decodes the ALAC it gets, and can lose packets on purpose to ask
// for them again.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation
import CryptoKit
import Security
@testable import VespertineAirPlay

final class FakeRAOPReceiver: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var _requests: [RTSPMessage] = []
    private var _packets: [UInt32: [Int32]] = [:]
    private var _firstTimestamp: UInt32?
    private var _syncs: [Data] = []
    private var _timingReplies: [Data] = []
    private var _markers = 0
    private var _resent = 0
    private var stopped = false
    private var sockets: [UDPSocket] = []
    /// The RTSP connections being served. A descriptor is in this ledger exactly as long as it is this receiver's: the thread
    /// that serves it closes it through the ledger, which forgets it under the same lock. A closed descriptor's number is at
    /// once free to be another socket's, of any test running in this process, and must never be touched again.
    private let clientSockets = FakeRAOPSockets()
    /// The event connections accepted (AirPlay 2): nobody reads them, so `stop` closes them.
    private var eventSockets: [Int32] = []
    /// Signalled by each accepting thread when it has closed its listener.
    private let accepting = DispatchSemaphore(value: 0)
    private var decoder: ALACDecoder?
    private var aesKey: Data?
    private var aesIV: Data?
    private var clientControl: UInt16 = 0
    private var clientTiming: UInt16 = 0

    /// The private key for `et=1` sessions (the sender is given its public key).
    let privateKey: SecKey?
    /// Sequence numbers lost the first time they come (asked for again on the control port).
    var drop: Set<UInt16> {
        get { lock.withLock { _drop } }
        set { lock.withLock { _drop = newValue } }
    }
    private var _drop: Set<UInt16> = []
    /// Answer with this status to these methods.
    var refuse: [String: Int] {
        get { lock.withLock { _refuse } }
        set { lock.withLock { _refuse = newValue } }
    }
    private var _refuse: [String: Int] = [:]
    /// The SETUP answer's Session header ("" for an empty one); nil: the usual.
    var sessionHeader: String? {
        get { lock.withLock { _sessionHeader } }
        set { lock.withLock { _sessionHeader = newValue } }
    }
    private var _sessionHeader: String?
    /// Answer these methods with another request's CSeq.
    var wrongCSeq: Set<String> {
        get { lock.withLock { _wrongCSeq } }
        set { lock.withLock { _wrongCSeq = newValue } }
    }
    private var _wrongCSeq: Set<String> = []
    /// Wait this long before answering these methods (a receiver that is slow to set up).
    var stall: [String: TimeInterval] {
        get { lock.withLock { _stall } }
        set { lock.withLock { _stall = newValue } }
    }
    private var _stall: [String: TimeInterval] = [:]
    /// A receiver with a password: every request without its digest gets 401 and a challenge. `capitalDigits`: it takes
    /// the digest only with capital hex digits (as iTunes sends it).
    var password: String? {
        get { lock.withLock { _password } }
        set { lock.withLock { _password = newValue } }
    }
    private var _password: String?
    var capitalDigits: Bool {
        get { lock.withLock { _capitalDigits } }
        set { lock.withLock { _capitalDigits = newValue } }
    }
    private var _capitalDigits = false
    /// The challenge's nonce changes after this many accepted requests (a receiver whose nonces go stale); 0: never.
    var nonceLife = 0
    private var nonceCount = 1
    private var nonceUses = 0
    /// An MFi receiver: every request but OPTIONS is refused (403) until the sender has done `POST /auth-setup`.
    var requiresAuthSetup: Bool {
        get { lock.withLock { _requiresAuthSetup } }
        set { lock.withLock { _requiresAuthSetup = newValue } }
    }
    private var _requiresAuthSetup = false
    private var introduced = false

    /// A receiver that must be paired with (HomePod, Apple TV): it answers pairing's POSTs, seals the connection once
    /// pairing is done, and until then refuses everything else (470).
    var pairing: FakePairing? {
        get { lock.withLock { _pairing } }
        set { lock.withLock { _pairing = newValue } }
    }
    private var _pairing: FakePairing?
    /// AirPlay 2: what the two SETUP requests said (the session's, then the stream's), as property lists.
    var setups: [[String: Any]] { lock.withLock { _setups } }
    private var _setups: [[String: Any]] = []
    /// AirPlay 2: how many times the event connection was opened.
    var eventConnections: Int { lock.withLock { _eventConnections } }
    private var _eventConnections = 0
    private var eventPortsOpened: [UInt16] = []
    /// AirPlay 2: the key the audio packets are sealed with (the stream SETUP's), and how many packets didn't open.
    private var audioKey: SymmetricKey?
    var unopened: Int { lock.withLock { _unopened } }
    private var _unopened = 0
    /// AirPlay 2: what GET /info is answered with, to anyone, paired or not (nil: no such answer, as before).
    var info: [String: Any]? {
        get { lock.withLock { _info } }
        set { lock.withLock { _info = newValue } }
    }
    private var _info: [String: Any]?
    /// AirPlay 2: stream formats (their `audioFormat` bits) refused with 415 though listed.
    var refusedFormats: Set<Int> {
        get { lock.withLock { _refusedFormats } }
        set { lock.withLock { _refusedFormats = newValue } }
    }
    private var _refusedFormats: Set<Int> = []
    /// AirPlay 2: the format of the stream that was set up.
    var streamFormat: AirPlayFormat? { lock.withLock { _streamFormat } }
    private var _streamFormat: AirPlayFormat?
    /// AirPlay 2: answer the first SETUP without an event port.
    var withholdEventPort = false
    /// AirPlay 2, a buffered stream: the clocks the sender named (SETPEERS), what each SETRATEANCHORTIME and
    /// FLUSHBUFFERED said, how many times the block connection was opened, and the blocks that came (their numbers).
    var peers: [String] { lock.withLock { _peers } }
    private var _peers: [String] = []
    var anchors: [[String: Any]] { lock.withLock { _anchors } }
    private var _anchors: [[String: Any]] = []
    var bufferedFlushes: [[String: Any]] { lock.withLock { _bufferedFlushes } }
    private var _bufferedFlushes: [[String: Any]] = []
    var blockConnections: Int { lock.withLock { _blockConnections } }
    private var _blockConnections = 0
    var blockSequences: [UInt32] { lock.withLock { _blockSequences } }
    private var _blockSequences: [UInt32] = []
    /// Bytes on the block connection that were not blocks, or blocks of a kind this receiver doesn't know.
    var badBlocks: Int { lock.withLock { _badBlocks } }
    private var _badBlocks = 0
    /// How many bytes of blocks the buffered stream's answer says this receiver holds.
    static let bufferSize = 8 * 1024 * 1024

    /// For each request in `requests`, whether it came sealed.
    var sealed: [Bool] { lock.withLock { _sealed } }
    private var _sealed: [Bool] = []
    /// Keys the connection changes to once the answer under way has gone out.
    private var nextKeys: PairingChannelKeys?
    /// Spoil the next sealed answer (a frame that won't open).
    var spoilNextAnswer: Bool {
        get { lock.withLock { _spoil } }
        set { lock.withLock { _spoil = newValue } }
    }
    private var _spoil = false

    /// The RTP times of the packets that came with the marker (the first of each stream after RECORD or FLUSH).
    var markerTimestamps: [UInt32] { lock.withLock { _markerTimestamps } }
    private var _markerTimestamps: [UInt32] = []

    /// The RTP time of the first audio packet received.
    var firstTimestamp: UInt32? { lock.withLock { _firstTimestamp } }

    /// Lose this many packets (whatever their numbers) after this many have come.
    var loseAfter: (count: Int, lose: Int)?

    init(privateKey: SecKey? = nil) throws {
        self.privateKey = privateKey
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        listener = fd
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    func stop() {
        // Only descriptors still in the ledger are shut down, so each is still this receiver's (see `clientSockets`).
        let (first, socks, events) = lock.withLock { () -> (Bool, [UDPSocket], [UInt16]) in
            guard !stopped else { return (false, [], []) }
            stopped = true
            clientSockets.stop()
            for c in eventSockets { close(c) }
            eventSockets = []
            return (true, sockets, eventPortsOpened)
        }
        guard first else { return }
        // A listener is closed by the thread that accepts on it, and by no one else: closed from here, its number could be
        // another test's listener by the time that thread calls accept again, and it would take that test's connections.
        // The thread is woken by a connection, sees that the receiver has stopped and closes the listener.
        for wake in [port] + events {
            if Self.knock(wake) { _ = accepting.wait(timeout: .now() + 30) }
        }
        socks.forEach { $0.close() }
    }

    /// Connects to `port` on this Mac and hangs up; false if nothing listens there.
    private static func knock(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    /// Accepts on `listener` until the receiver is stopped, then closes it. `take` is given each connection, under the lock.
    private static func accept(on listener: Int32, for receiver: FakeRAOPReceiver, take: (FakeRAOPReceiver, Int32) -> Void) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0, errno == EINTR || errno == ECONNABORTED { continue }
            let goesOn = receiver.lock.withLock { () -> Bool in
                guard client >= 0, !receiver.stopped else { return false }
                take(receiver, client)
                return true
            }
            if !goesOn {
                if client >= 0 { close(client) }
                close(listener)
                receiver.accepting.signal()
                return
            }
        }
    }

    var requests: [RTSPMessage] { lock.withLock { _requests } }
    var methods: [String] { requests.compactMap(\.method) }
    var syncs: [Data] { lock.withLock { _syncs } }
    var timingReplies: [Data] { lock.withLock { _timingReplies } }
    var markers: Int { lock.withLock { _markers } }
    var resent: Int { lock.withLock { _resent } }
    var packetCount: Int { lock.withLock { _packets.count } }
    /// Every frame received, in RTP order (a 16-bit stream's).
    var samples: [Int16] { deepSamples.map { Int16(truncatingIfNeeded: $0) } }

    /// Every frame received, in RTP order, each sample a value of the stream's depth.
    var deepSamples: [Int32] {
        lock.withLock {
            guard let first = _firstTimestamp else { return [] }
            return _packets.sorted { ($0.key &- first) < ($1.key &- first) }.flatMap(\.value)
        }
    }

    /// Frames from the packets at or after `timestamp`, in order.
    func samples(from timestamp: UInt32) -> [Int16] {
        lock.withLock {
            guard let first = _firstTimestamp else { return [] }
            return _packets.filter { ($0.key &- first) >= (timestamp &- first) }.sorted { ($0.key &- first) < ($1.key &- first) }.flatMap(\.value)
                .map { Int16(truncatingIfNeeded: $0) }
        }
    }

    /// Forgets the audio received so far (a test that looks at what came after a flush).
    func clearAudio() { lock.withLock { _packets = [:]; _firstTimestamp = nil } }

    func waitFor(_ condition: () -> Bool, seconds: Double = 5) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: RTSP

    private func acceptLoop() {
        Self.accept(on: listener, for: self) { receiver, client in
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Never refused here: this runs under the lock with the receiver not yet stopped.
            guard receiver.clientSockets.insert(client) else { return }
            let thread = Thread { receiver.serve(client) }
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var parser = RTSPParser()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var channel: PairingChannel?
        // Forgotten and closed in one step: `stop` shuts down only what the ledger still holds.
        defer { clientSockets.close(fd) }
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            var data = Data(buffer[0..<n])
            if channel != nil {
                guard let plain = try? channel?.open(data) else { return }
                data = plain
            }
            parser.append(data)
            while let request = try? parser.next() {
                let response = handle(request, sealed: channel != nil)
                var bytes = response.encoded()
                if channel != nil {
                    guard var out = try? channel?.seal(bytes) else { return }
                    if lock.withLock({ defer { _spoil = false }; return _spoil }) { out[out.count - 1] ^= 1 }
                    bytes = out
                }
                _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if let keys = lock.withLock({ defer { nextKeys = nil }; return nextKeys }) { channel = PairingChannel(keys: keys) }
            }
        }
    }

    private func handle(_ request: RTSPMessage, sealed: Bool = false) -> RTSPMessage {
        lock.withLock { _requests.append(request); _sealed.append(sealed) }
        var cseq = request["CSeq"] ?? "0"
        if wrongCSeq.contains(request.method ?? "") { cseq = String((Int(cseq) ?? 0) + 7) }
        var headers: [(String, String)] = [("CSeq", cseq), ("Server", "AirTunes/366.0")]
        if let wait = stall[request.method ?? ""] { Thread.sleep(forTimeInterval: wait) }
        if let status = refuse[request.method ?? ""] { return .response(status, "Refused", headers: headers) }
        // As an Apple TV does: a sender that names something other than AirPlay first is refused whatever it asks.
        if let sender = request["User-Agent"], !sender.hasPrefix("AirPlay/") { return .response(403, "Forbidden", headers: headers) }
        if let password {
            let (nonce, capitals) = lock.withLock { () -> (String, Bool) in
                if nonceLife > 0, nonceUses >= nonceLife { nonceCount += 1; nonceUses = 0 }
                return ("nonce-\(nonceCount)", _capitalDigits)
            }
            let challenge = RTSPDigest.Challenge(realm: "raop", nonce: nonce)
            let given = request["Authorization"].map { RTSPDigest.parameters(String($0.dropFirst("Digest".count))) } ?? [:]
            let wanted = RTSPDigest.response(challenge, password: password, method: request.method ?? "", uri: request.url ?? "", uppercase: capitals)
            guard given["username"] == RTSPDigest.username, given["nonce"] == nonce, given["uri"] == request.url, given["response"] == wanted else {
                return .response(401, "Unauthorized", headers: headers + [("WWW-Authenticate", "Digest realm=\"raop\", nonce=\"\(nonce)\"")])
            }
            lock.withLock { nonceUses += 1 }
        }
        if request.method == "GET", request.url == "/info", let info {
            return .response(200, "OK", headers: headers + [("Content-Type", AirPlay2Message.contentType)], body: AirPlay2Message.encode(info))
        }
        if let pairing {
            let binary = ("Content-Type", "application/octet-stream")
            switch (request.method ?? "", request.url ?? "") {
            case ("POST", "/pair-pin-start"):
                pairing.showPIN()
                return .response(200, "OK", headers: headers)
            case ("POST", "/pair-setup"), ("POST", "/pair-verify"):
                let (answer, keys) = pairing.answer(path: request.url ?? "", body: request.body)
                lock.withLock { nextKeys = keys }
                return .response(200, "OK", headers: headers + [binary], body: answer)
            default:
                if !sealed { return .response(470, "Connection Authorization Required", headers: headers) }
            }
        }
        if request.method == "POST", request.url == "/auth-setup" {
            // 0x01 (unencrypted) and a 32-byte key; the answer is the receiver's key, then a certificate and signature
            // (stand-ins here: the sender reads none of it).
            guard request.body.count == 33, request.body.first == 0x01 else { return .response(400, "Bad Request", headers: headers) }
            lock.withLock { introduced = true }
            return .response(200, "OK", headers: headers + [("Content-Type", "application/octet-stream")], body: Data(repeating: 0xA5, count: 32 + 4 + 16))
        }
        if requiresAuthSetup, request.method != "OPTIONS", !lock.withLock({ introduced }) { return .response(403, "Forbidden", headers: headers) }
        switch request.method {
        case "ANNOUNCE":
            let attributes = SDP.attributes(String(decoding: request.body, as: UTF8.self))
            let config = attributes["fmtp"].flatMap(ALACConfig.init(fmtp:)) ?? ALACConfig()
            var key: Data?
            if let wrapped = attributes["rsaaeskey"].flatMap(SDP.base64), let privateKey { key = try? RSAWrap.decrypt(wrapped, key: privateKey) }
            let iv = attributes["aesiv"].flatMap(SDP.base64)
            lock.withLock {
                decoder = try? ALACDecoder(config: config)
                aesKey = key
                aesIV = iv
            }
        case "SETUP" where request["Content-Type"] == AirPlay2Message.contentType:
            guard let said = AirPlay2Message.decode(request.body) else { return .response(400, "Bad Request", headers: headers) }
            lock.withLock { _setups.append(said) }
            let plist = ("Content-Type", AirPlay2Message.contentType)
            if let stream = (said["streams"] as? [[String: Any]])?.first, stream["type"] as? Int == AirPlay2Buffered.streamType {
                // A buffered stream: its key, and a TCP port its blocks are written to.
                let named = stream["audioFormat"] as? Int ?? 0
                guard !refusedFormats.contains(named), named == AirPlay2Message.bufferedFormat else {
                    return .response(415, "Unsupported Media Type", headers: headers)
                }
                guard let key = stream["shk"] as? Data, key.count == 32, let blocks = blockPort() else {
                    return .response(400, "Bad Request", headers: headers)
                }
                let format = AirPlay2Buffered.Kind.alac48000Deep.format
                lock.withLock {
                    audioKey = SymmetricKey(data: key)
                    _streamFormat = format
                    decoder = try? ALACDecoder(config: format.alac)
                }
                let answer: [String: Any] = ["streams": [["type": AirPlay2Buffered.streamType, "dataPort": Int(blocks), "audioBufferSize": Self.bufferSize]]]
                return .response(200, "OK", headers: headers + [plist], body: AirPlay2Message.encode(answer))
            }
            if let stream = (said["streams"] as? [[String: Any]])?.first {
                // The format it names decides how the packets decode; one this receiver is set to refuse is refused.
                let named = stream["audioFormat"] as? Int ?? AirPlay2Message.alacFormat
                guard !refusedFormats.contains(named), let format = AirPlayFormat.all.first(where: { $0.streamFormat == named }) else {
                    return .response(415, "Unsupported Media Type", headers: headers)
                }
                // The stream: its key, and where this receiver takes audio and control packets.
                guard let key = stream["shk"] as? Data, key.count == 32, let port = stream["controlPort"] as? Int,
                      let audio = try? UDPSocket(bind: "127.0.0.1"), let control = try? UDPSocket(bind: "127.0.0.1") else {
                    return .response(400, "Bad Request", headers: headers)
                }
                lock.withLock {
                    audioKey = SymmetricKey(data: key)
                    clientControl = UInt16(port)
                    _streamFormat = format
                    decoder = try? ALACDecoder(config: format.alac)
                    sockets += [audio, control]
                    controlSocket = control
                }
                audio.startReceiving(name: "fake audio") { [weak self] data, _, _ in self?.audio(data, resent: false) }
                control.startReceiving(name: "fake control") { [weak self] data, _, _ in self?.control(data) }
                let answer: [String: Any] = ["streams": [["type": 96, "dataPort": Int(audio.port), "controlPort": Int(control.port)]]]
                return .response(200, "OK", headers: headers + [plist], body: AirPlay2Message.encode(answer))
            }
            // A session timed by the sender's PTP clock has no port to ask the time of: answered with the event port and
            // this receiver's own name as a clock.
            if said["timingProtocol"] as? String == "PTP" {
                guard said["timingPeerInfo"] is [String: Any], let events = eventPort() else { return .response(400, "Bad Request", headers: headers) }
                let peer: [String: Any] = ["Addresses": ["127.0.0.1"], "ID": "127.0.0.1"]
                let answer: [String: Any] = ["eventPort": Int(events), "timingPort": 0, "timingPeerInfo": peer]
                return .response(200, "OK", headers: headers + [plist], body: AirPlay2Message.encode(answer))
            }
            // The session: where to ask the time, answered with the event port (a listener that counts who connects).
            guard let port = said["timingPort"] as? Int, let timing = try? UDPSocket(bind: "127.0.0.1"), let events = eventPort() else {
                return .response(400, "Bad Request", headers: headers)
            }
            timing.startReceiving(name: "fake timing") { [weak self] data, _, _ in self?.lock.withLock { self?._timingReplies.append(data) } }
            lock.withLock { clientTiming = UInt16(port); sockets.append(timing); timingSocket = timing }
            let answer: [String: Any] = withholdEventPort ? ["timingPort": Int(timing.port)] : ["eventPort": Int(events), "timingPort": Int(timing.port)]
            return .response(200, "OK", headers: headers + [plist], body: AirPlay2Message.encode(answer))
        case "SETUP":
            guard let transport = request["Transport"], let audio = try? UDPSocket(bind: "127.0.0.1"), let control = try? UDPSocket(bind: "127.0.0.1"),
                  let timing = try? UDPSocket(bind: "127.0.0.1") else { return .response(500, "Error", headers: headers) }
            for part in transport.split(separator: ";") {
                let kv = part.split(separator: "=")
                if kv.count == 2, kv[0] == "control_port" { lock.withLock { clientControl = UInt16(kv[1]) ?? 0 } }
                if kv.count == 2, kv[0] == "timing_port" { lock.withLock { clientTiming = UInt16(kv[1]) ?? 0 } }
            }
            audio.startReceiving(name: "fake audio") { [weak self] data, _, _ in self?.audio(data, resent: false) }
            control.startReceiving(name: "fake control") { [weak self] data, _, _ in self?.control(data) }
            timing.startReceiving(name: "fake timing") { [weak self] data, _, _ in self?.lock.withLock { self?._timingReplies.append(data) } }
            lock.withLock { sockets += [audio, control, timing]; controlSocket = control; timingSocket = timing }
            headers += [("Transport", "RTP/AVP/UDP;unicast;mode=record;server_port=\(audio.port);control_port=\(control.port);timing_port=\(timing.port)"),
                        ("Session", sessionHeader ?? "DEADBEEF"), ("Audio-Jack-Status", "connected; type=analog")]
        case "RECORD":
            headers.append(("Audio-Latency", "11025"))
            // Asks the sender for the time, as a receiver does before it uses sync packets.
            let (timing, port) = lock.withLock { (timingSocket, clientTiming) }
            timing?.send(RAOPPacket.timingRequest(transmit: NTPClock.now()), to: "127.0.0.1", port: port)
        case "SETPEERS":
            let list = (try? PropertyListSerialization.propertyList(from: request.body, format: nil)) as? [String]
            guard let list else { return .response(400, "Bad Request", headers: headers) }
            lock.withLock { _peers = list }
        case "SETRATEANCHORTIME":
            guard let said = AirPlay2Message.decode(request.body) else { return .response(400, "Bad Request", headers: headers) }
            lock.withLock { _anchors.append(said) }
        case "FLUSHBUFFERED":
            guard let said = AirPlay2Message.decode(request.body) else { return .response(400, "Bad Request", headers: headers) }
            lock.withLock { _bufferedFlushes.append(said) }
        case "OPTIONS":
            headers.append(("Public", "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER"))
        default: break
        }
        return .response(200, "OK", headers: headers)
    }

    /// Opens the event listener (once) and gives its port.
    private func eventPort() -> UInt16? {
        listenerPort { receiver, client in
            receiver._eventConnections += 1
            receiver.eventSockets.append(client)
        }
    }

    /// Opens the listener a buffered stream's blocks are written to and gives its port. Each connection is served by a
    /// thread of its own, and is in the ledger of connections exactly as an RTSP one is.
    private func blockPort() -> UInt16? {
        listenerPort { receiver, client in
            guard receiver.clientSockets.insert(client) else { return }
            receiver._blockConnections += 1
            let thread = Thread { receiver.serveBlocks(client) }
            thread.start()
        }
    }

    /// A TCP listener on a free port, accepted on by a thread of its own until the receiver stops. `take` is given each
    /// connection, under the lock.
    private func listenerPort(take: @escaping (FakeRAOPReceiver, Int32) -> Void) -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = UInt16(bigEndian: addr.sin_port)
        // Stopped meanwhile: no thread is started for a listener nobody would wake.
        guard lock.withLock({ () -> Bool in
            guard !stopped else { return false }
            eventPortsOpened.append(port)
            return true
        }) else { close(fd); return nil }
        let thread = Thread { [self] in
            Self.accept(on: fd, for: self, take: take)
        }
        thread.start()
        return port
    }

    /// Reads a buffered stream's connection: whole blocks are opened with the stream's key and decoded; the rest waits
    /// for more bytes.
    private func serveBlocks(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var arrived = Data()
        // Forgotten and closed in one step, as an RTSP connection is.
        defer { clientSockets.close(fd) }
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            arrived.append(contentsOf: buffer[0..<n])
            guard let cut = AirPlay2Buffered.split(arrived) else {
                lock.withLock { _badBlocks += 1 }
                return
            }
            arrived = Data(arrived.dropFirst(cut.used))
            for block in cut.blocks { takeBlock(block) }
        }
    }

    private func takeBlock(_ data: Data) {
        let (key, decoder) = lock.withLock { (audioKey, self.decoder) }
        guard let key, let opened = AirPlay2Buffered.open(data, key: key) else { lock.withLock { _unopened += 1 }; return }
        guard opened.kind == AirPlay2Buffered.Kind.alac48000Deep.rawValue else { lock.withLock { _badBlocks += 1 }; return }
        let samples = decodeLock.withLock { try? decoder?.decode(samples: opened.payload) }
        lock.withLock {
            _blockSequences.append(opened.sequence)
            guard let samples else { return }
            if _firstTimestamp == nil { _firstTimestamp = opened.timestamp }
            _packets[opened.timestamp] = samples
        }
    }

    private var controlSocket: UDPSocket?
    private var timingSocket: UDPSocket?
    private var received = 0
    private let decodeLock = NSLock()

    // MARK: UDP

    private func audio(_ data: Data, resent: Bool) {
        // AirPlay 2: sealed with the stream's key; a packet that doesn't open is counted and dropped.
        let sealedWith = lock.withLock { audioKey }
        let packet: (seq: UInt16, timestamp: UInt32, payload: Data)
        if let sealedWith {
            guard let opened = AirPlay2Audio.open(data, key: sealedWith) else { lock.withLock { _unopened += 1 }; return }
            packet = (opened.seq, opened.timestamp, opened.payload)
        } else {
            guard let plain = RAOPPacket.parseAudio(data) else { return }
            packet = plain
        }
        // A packet's marker is counted in the same moment its audio is kept (below), never before: a test that waits for the
        // marker and then reads the audio must find it. Only a packet lost on purpose, whose audio is not kept, counts here.
        let marked = !resent && data[data.startIndex + 1] == 0xE0
        let lost = lock.withLock { () -> Bool in
            if !resent { received += 1 }
            var lost = false
            if !resent, _drop.contains(packet.seq) { _drop.remove(packet.seq); lost = true }
            else if !resent, let l = loseAfter, received > l.count, received <= l.count + l.lose { lost = true }
            if lost, marked { _markers += 1; _markerTimestamps.append(packet.timestamp) }
            return lost
        }
        if lost {
            let (control, port) = lock.withLock { (controlSocket, clientControl) }
            control?.send(RAOPPacket.resendRequest(seq: packet.seq, count: 1), to: "127.0.0.1", port: port)
            return
        }
        var payload = packet.payload
        let (key, iv, decoder) = lock.withLock { (aesKey, aesIV, self.decoder) }
        if let key, let iv { try? AESCBC.apply(&payload, key: key, iv: iv, encrypt: false) }
        // The audio and control threads both decode: one at a time.
        let samples = decodeLock.withLock { try? decoder?.decode(samples: payload) }
        lock.withLock {
            if marked { _markers += 1; _markerTimestamps.append(packet.timestamp) }
            guard let samples else { return }
            if _firstTimestamp == nil { _firstTimestamp = packet.timestamp }
            if resent { _resent += 1 }
            _packets[packet.timestamp] = samples
        }
    }

    private func control(_ data: Data) {
        guard data.count >= 4 else { return }
        if data[data.startIndex + 1] == 0xD4 { lock.withLock { _syncs.append(data) } }
        if data[data.startIndex + 1] == 0xD6 { audio(Data(data.dropFirst(4)), resent: true) }
    }
}
