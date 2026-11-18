//
// Vespertine: one AirPlay 1 session with a receiver. RTSP sets it up (OPTIONS, ANNOUNCE with the SDP, SETUP for the UDP
// ports, RECORD), then audio goes as RTP packets of 352 ALAC frames on a timeline that continues across songs; FLUSH stops
// what the receiver holds (pause, seek), SET_PARAMETER carries volume, titles and progress, TEARDOWN ends it. The control
// port carries sync packets (which frame is heard when, by this Mac's clock) and the receiver's requests for lost packets;
// the timing port answers its clock questions. OPTIONS every 25 s keeps an idle session open.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Network
import os
import Security
import VespertineAudio

/// What a sender sends an MFi receiver before a session (`POST /auth-setup`): that the audio will come unencrypted, and a
/// Curve25519 public key made for this one request. The receiver answers with its own key, its MFi certificate and a
/// signature; a sender has no use for them (it isn't checking that the receiver is licensed), only for the 200.
public enum MFiAuthSetup {
    /// "The audio is not encrypted."
    public static let unencrypted: UInt8 = 0x01

    public static func body(publicKey: Data = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation) -> Data {
        Data([unencrypted]) + publicKey
    }
}

/// How a session gets past a receiver that must be paired with (HomePod, Apple TV, and others that speak only AirPlay 2).
enum AirPlay2Pairing: Sendable {
    /// The receiver doesn't ask for it: plain AirPlay 1.
    case none
    /// It lets anyone on the network play: paired afresh, with no PIN, every session. `secret`: SRP's private number
    /// (random unless a test gives one).
    case withoutPIN(secret: Data? = nil)
    /// It was paired with once, with the PIN on its screen: this Mac and the receiver as kept from then.
    case paired(PairingIdentity, PairedReceiver)
}

public final class RAOPSession: @unchecked Sendable {
    public let name: String
    private let endpoint: NWEndpoint
    private let encryption: RAOPEncryption
    private let authSetup: Bool
    private let rsaKey: SecKey?
    private let password: String?
    private let pairing: AirPlay2Pairing
    private let sender: AirPlay2Sender
    /// AirPlay 2: what would be sent if the receiver says it takes it (nil: 16-bit at 44.1 kHz, and nothing is asked).
    private let wish: AirPlayWish?
    /// AirPlay 2: the clock a buffered stream is timed by. Given one, the session sets up a buffered stream of 24-bit
    /// ALAC at 48 kHz when the song and the receiver both call for it (and a realtime one as ever when they don't); the
    /// clock is then this session's, started by it and stopped when it closes.
    private let clock: PTPClock?
    /// Where the receiver takes the clock's messages (tests give their follower's ports).
    var clockPeerPorts: (event: UInt16, general: UInt16) = (319, 320)
    /// An AirPlay 2 session: paired first, set up with property lists, its audio sealed, kept open with /feedback.
    private var usesPairing: Bool { if case .none = pairing { false } else { true } }
    private let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "airplay")

    /// The connection, sockets and keep-alive: set by connect and close (the playback's worker), read by the pacer and the
    /// socket readers, so behind a lock.
    private struct Parts {
        var rtsp: RTSPConnection?
        var audio: UDPSocket?
        var control: UDPSocket?
        var timing: UDPSocket?
        /// AirPlay 2: the connection the receiver asks for to tell of events. Nothing it says is used, but a receiver
        /// drops a session that hasn't opened it.
        var events: NWConnection?
        /// AirPlay 2, a buffered stream: the connection its blocks are written to.
        var blocks: NWConnection?
        /// AirPlay 2: the key each audio packet is sealed with.
        var audioKey: SymmetricKey?
        /// AirPlay 2, a stream in another format than 16-bit at 44.1 kHz: Apple's encoder for it.
        var streamEncoder: ALACEncoder?
        var keepAlive: Task<Void, Never>?
        var localAddress = "0.0.0.0"
        var aesKey = Data()
        var aesIV = Data()
    }
    private let parts = Locked(Parts())
    private var rtsp: RTSPConnection? { parts.withLock { $0.rtsp } }
    private var audio: UDPSocket? { parts.withLock { $0.audio } }
    private var control: UDPSocket? { parts.withLock { $0.control } }
    private var timing: UDPSocket? { parts.withLock { $0.timing } }

    private struct State {
        var connected = false
        /// What the audio packets hold: 16-bit at 44.1 kHz unless an AirPlay 2 receiver said it takes more and took it.
        var format = AirPlayFormat.cd
        /// AirPlay 2: the audio goes as the blocks of a buffered stream, played at moments named on the session's clock.
        var buffered = false
        /// The next block's number.
        var block: UInt32 = 0
        var host = ""
        var ports = RAOPTransport(server: 0, control: 0, timing: nil)
        var session: String?
        var cseq = 1
        /// The receiver's password challenge, and which case of hex digits it took.
        var challenge: RTSPDigest.Challenge?
        var uppercaseDigest = false
        var seq = UInt16.random(in: 0...UInt16.max)
        var head = UInt32.random(in: 0...(UInt32.max / 2))
        var first = true
        var anchor: (rtp: UInt32, nanos: UInt64)?
        /// AirPlay 2: how many audio packets have been sealed (each one's nonce).
        var sealed: UInt64 = 0
        var backlog: [UInt16: Data] = [:]
        var resent = 0
        /// The receiver's clock questions: how many, and when the last one came (nanoseconds). One that has asked and then
        /// falls silent while audio is being sent has probably gone.
        var timingRequests = 0
        var lastTiming: UInt64 = 0
        var lastAudio: UInt64 = 0
    }
    private let state = Locked(State())
    private let encoder: ALACEncoder?
    private let sessionID = UInt32.random(in: 1...UInt32.max)
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private let clientInstance = String(format: "%016llX", UInt64.random(in: 1...UInt64.max))
    private let activeRemote = String(UInt32.random(in: 1...UInt32.max))

    /// The receiver went away (keep-alive failed): the playback is told once.
    public var onLost: (@Sendable () -> Void)? {
        get { hooks.withLock { $0 } }
        set { hooks.withLock { $0 = newValue } }
    }
    private let hooks = Locked<(@Sendable () -> Void)?>(nil)

    public static let backlogPackets = 1024
    public static let keepAliveInterval: Duration = .seconds(25)
    /// A receiver that was asking the time and has asked nothing for this long, while audio goes to it, is asked at once
    /// whether it is still there (it asks every few seconds while it plays).
    public static let silenceBeforeProbe: TimeInterval = 8

    /// `rsaKey`: the key the AES key is wrapped with (the AirPort Express key unless a test gives its own).
    /// `authSetup`: the receiver lists MFi authentication, so the session introduces itself with `POST /auth-setup` first.
    /// `password`: the receiver's, when it has one (asked for by its 401; never sent, only its digest).
    public convenience init(name: String, endpoint: NWEndpoint, encryption: RAOPEncryption, rsaKey: SecKey? = nil, authSetup: Bool = false,
                            password: String? = nil) {
        self.init(name: name, endpoint: endpoint, encryption: encryption, rsaKey: rsaKey, authSetup: authSetup, password: password,
                  pairing: .none, sender: AirPlay2Sender(deviceID: "", name: "", model: "", osVersion: ""))
    }

    /// `pairing`: for a receiver that must be paired with; the session is then an AirPlay 2 one, and `encryption`,
    /// `rsaKey` and `authSetup` play no part. `sender`: this Mac as such a receiver is told of it. `wish`: what to send
    /// such a receiver if it says it takes it; without one, or for one that 16-bit at 44.1 kHz serves as well, the
    /// receiver is asked nothing and gets that.
    init(name: String, endpoint: NWEndpoint, encryption: RAOPEncryption, rsaKey: SecKey? = nil, authSetup: Bool = false,
         password: String? = nil, pairing: AirPlay2Pairing, sender: AirPlay2Sender, wish: AirPlayWish? = nil, clock: PTPClock? = nil) {
        self.name = name
        self.clock = clock
        self.pairing = pairing
        self.sender = sender
        self.wish = wish
        self.password = password.flatMap { $0.isEmpty ? nil : $0 }
        self.endpoint = endpoint
        self.encryption = encryption
        self.authSetup = authSetup
        self.rsaKey = rsaKey ?? (encryption == .rsa ? try? RSAWrap.airPortExpressKey() : nil)
        // Apple's encoder if its configuration is the SDP's; the verbatim frame otherwise (lossless either way).
        encoder = try? ALACEncoder()
    }

    deinit {
        let p = parts.withLock { $0 }
        p.keepAlive?.cancel()
        [p.audio, p.control, p.timing].forEach { $0?.close() }
        p.events?.cancel()
        p.blocks?.cancel()
        clock?.stop()
        if let rtsp = p.rtsp { Task { await rtsp.close() } }
    }

    public var isConnected: Bool { state.withLock { $0.connected } }
    public var usesAppleEncoder: Bool { format == .cd ? encoder != nil : parts.withLock { $0.streamEncoder != nil } }
    /// What the audio packets hold. Settled by `connect`: 16-bit at 44.1 kHz before it, and after it unless the
    /// receiver said it takes the format wished for and then took it.
    public var format: AirPlayFormat { state.withLock { $0.format } }
    /// The audio goes as a buffered stream. Settled by `connect`.
    public var isBuffered: Bool { state.withLock { $0.buffered } }
    /// Packets sent again on the receiver's request.
    public var resentPackets: Int { state.withLock { $0.resent } }

    // MARK: RTSP

    private var url: String { "rtsp://\(parts.withLock { $0.localAddress })/\(sessionID)" }

    private func request(_ method: String, url: String? = nil, headers extra: [(String, String)] = [], body: Data = Data()) async throws -> RTSPMessage {
        guard let rtsp else { throw RAOPError.closed }
        let target = url ?? self.url
        // A receiver with a password answers 401 with a challenge: the request goes again with the password's digest,
        // then with the digits in the other case (receivers differ), then in the first case against the newest challenge
        // (one that had only gone stale), and after that the refusal stands.
        var refusals = 0
        while true {
            let (cseq, session, challenge, uppercase) = state.withLock { s -> (Int, String?, RTSPDigest.Challenge?, Bool) in
                defer { s.cseq += 1 }
                return (s.cseq, s.session, s.challenge, s.uppercaseDigest)
            }
            var headers: [(String, String)] = [("CSeq", String(cseq)), ("User-Agent", "Vespertine/1 AirPlay/366.0"),
                                               ("Client-Instance", clientInstance), ("DACP-ID", clientInstance), ("Active-Remote", activeRemote)]
            if let session { headers.append(("Session", session)) }
            if let challenge, let password {
                headers.append(("Authorization", RTSPDigest.authorization(challenge, password: password, method: method, uri: target, uppercase: uppercase)))
            }
            headers += extra
            let response = try await rtsp.send(.request(method, target, headers: headers, body: body))
            // Some receivers leave CSeq out (OwnTone notes Reflector and Airfoil); one that names another request is answering
            // something else.
            if let answered = response["CSeq"], answered != String(cseq) { throw RAOPError.badResponse("\(method) (CSeq \(answered), not \(cseq))") }
            if response.status == 401, password != nil, refusals < 3, let asked = response["WWW-Authenticate"].flatMap(RTSPDigest.Challenge.parse) {
                refusals += 1
                state.withLock { s in
                    // Refused with a digest already sent: the other case of digits, against the challenge it gives now.
                    if challenge != nil { s.uppercaseDigest.toggle() }
                    s.challenge = asked
                }
                continue
            }
            guard response.status == 200 else { throw RAOPError.refused(method, response.status) }
            return response
        }
    }

    /// OPTIONS, ANNOUNCE, SETUP and RECORD; then the receiver takes audio. `volumeDB`: sent right after (nil: left alone).
    public func connect(volumeDB: Double?) async throws {
        let rtsp = RTSPConnection(endpoint: endpoint)
        parts.withLock { $0.rtsp = rtsp }
        do {
            let aesKey = try AESCBC.randomBytes(16), aesIV = try AESCBC.randomBytes(16)
            parts.withLock { $0.aesKey = aesKey; $0.aesIV = aesIV }
            try await rtsp.connect()
            let host = await rtsp.remoteAddress
            let localAddress = await rtsp.localAddress
            parts.withLock { $0.localAddress = localAddress }
            guard !host.isEmpty, !host.contains(":") else { throw RAOPError.unreachable }
            state.withLock { $0.host = host }
            if usesPairing {
                try await setUpPaired(rtsp, host: host)
            } else {
                _ = try await request("OPTIONS", url: "*")
                if authSetup {
                    // A receiver that lists MFi and refuses this may still take the session (some list it and don't ask for
                    // it); one that needs it refuses the ANNOUNCE next, and that is the error shown. A lost connection is one.
                    do {
                        _ = try await request("POST", url: "/auth-setup", headers: [("Content-Type", "application/octet-stream")], body: MFiAuthSetup.body())
                    } catch RAOPError.refused(_, let status) {
                        log.info("AirPlay \(self.name, privacy: .public) refused auth-setup (\(status)); going on without")
                    }
                }
                var rsa: Data?
                var extra: [(String, String)] = [("Content-Type", "application/sdp")]
                if encryption == .rsa {
                    guard let rsaKey else { throw RAOPError.badResponse("RSA") }
                    rsa = try RSAWrap.encrypt(aesKey, key: rsaKey)
                    extra.append(("Apple-Challenge", SDP.base64NoPadding(try AESCBC.randomBytes(16))))
                }
                let sdp = SDP.announce(sessionID: sessionID, local: localAddress, remote: host, rsaAESKey: rsa, aesIV: rsa == nil ? nil : aesIV)
                _ = try await request("ANNOUNCE", headers: extra, body: Data(sdp.utf8))
                // The timing port is open before SETUP (Apple TVs ask the time at once).
                let timing = try UDPSocket(), control = try UDPSocket(), audio = try UDPSocket()
                parts.withLock { $0.timing = timing; $0.control = control; $0.audio = audio }
                timing.startReceiving(name: "Vespertine AirPlay timing") { [weak self] data, from, port in self?.answerTiming(data, from: from, port: port) }
                control.startReceiving(name: "Vespertine AirPlay control") { [weak self] data, from, _ in self?.answerControl(data, from: from) }
                let setup = try await request("SETUP", headers: [("Transport", RAOPTransport.request(control: control.port, timing: timing.port))])
                guard let transport = setup["Transport"].flatMap(RAOPTransport.parse) else { throw RAOPError.badResponse("SETUP") }
                // "Session: <id>[;timeout=…]"; none, or an empty one, is a receiver Vespertine can't go on with.
                guard let session = setup["Session"]?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }), !session.isEmpty else {
                    throw RAOPError.badResponse("SETUP (no session)")
                }
                state.withLock { $0.ports = transport; $0.session = session }
            }
            let (seq, head) = state.withLock { ($0.seq, $0.head) }
            _ = try await request("RECORD", headers: [("Range", "npt=0-"), ("RTP-Info", "seq=\(seq);rtptime=\(head)")])
            state.withLock { $0.connected = true; $0.first = true; $0.anchor = nil; $0.timingRequests = 0; $0.lastTiming = 0; $0.lastAudio = 0 }
            if let volumeDB { try? await setVolume(volumeDB) }
            startKeepAlive()
        } catch {
            await close()
            throw error
        }
    }

    /// AirPlay 2's way to the same place as OPTIONS, ANNOUNCE and SETUP: pairing (which seals the connection), a SETUP that
    /// introduces this Mac and is answered with the event port, the event connection, and a SETUP for the audio.
    private func setUpPaired(_ rtsp: RTSPConnection, host: String) async throws {
        // What the receiver takes is asked before pairing, in the clear, as it answers anyone; and only when there is
        // something to gain by it. No answer, or one that doesn't list the format, leaves 16-bit at 44.1 kHz.
        var format = AirPlayFormat.cd
        var buffered: AirPlay2Buffered.Kind?
        if let wish, !wish.isPlain {
            let info = try? await request("GET", url: "/info")
            let accepted = info.flatMap { AirPlay2Message.acceptedFormats(info: $0.body) } ?? []
            format = wish.format(accepted: accepted)
            // A buffered stream when there is a clock for one, the song is one its format serves, and the receiver's
            // buffered streams take it.
            let kind = AirPlay2Buffered.Kind.alac48000Deep
            if clock != nil, wish.format(accepted: [kind.format]) == kind.format, let info, AirPlay2Message.takesBuffered(info: info.body) {
                buffered = kind
            }
        }
        let exchange = PairingExchange(connection: rtsp, cseq: state.withLock { $0.cseq })
        let secret: Data
        switch pairing {
        case .none: return
        case .withoutPIN(let srp): secret = try await exchange.withoutPIN(secret: srp)
        case .paired(let identity, let receiver): secret = try await exchange.verify(identity: identity, receiver: receiver)
        }
        let next = await exchange.cseq
        state.withLock { $0.cseq = next }
        guard let audioKey = AirPlay2Audio.key(secret: secret) else { throw RAOPError.badResponse("SETUP") }
        if let buffered, let clock {
            try await setUpBuffered(host: host, key: audioKey, kind: buffered, clock: clock)
            return
        }
        let timing = try UDPSocket(), control = try UDPSocket(), audio = try UDPSocket()
        parts.withLock { $0.timing = timing; $0.control = control; $0.audio = audio; $0.audioKey = SymmetricKey(data: audioKey) }
        state.withLock { $0.sealed = 0 }
        timing.startReceiving(name: "Vespertine AirPlay timing") { [weak self] data, from, port in self?.answerTiming(data, from: from, port: port) }
        control.startReceiving(name: "Vespertine AirPlay control") { [weak self] data, from, _ in self?.answerControl(data, from: from) }
        let plist = [("Content-Type", AirPlay2Message.contentType)]
        let introduced = try await request("SETUP", headers: plist, body: AirPlay2Message.sessionSetup(sender: sender, sessionUUID: UUID(), timingPort: timing.port))
        guard let eventPort = AirPlay2Message.eventPort(in: introduced.body) else { throw RAOPError.badResponse("SETUP") }
        let events = try await Self.openEvents(host: host, port: eventPort)
        parts.withLock { $0.events = events }
        let stream: RTSPMessage
        do {
            stream = try await request("SETUP", headers: plist, body: AirPlay2Message.streamSetup(controlPort: control.port, key: audioKey,
                                                                                                 connectionID: sessionID, format: format))
        } catch RAOPError.refused(_, let status) where format != .cd {
            // It listed the format and then refused it: the stream every receiver takes.
            let refused = format
            log.info("AirPlay \(self.name, privacy: .public) refused \(refused.bitDepth)-bit at \(refused.sampleRate) Hz (\(status)); sending 16-bit at 44.1 kHz")
            format = .cd
            stream = try await request("SETUP", headers: plist, body: AirPlay2Message.streamSetup(controlPort: control.port, key: audioKey,
                                                                                                 connectionID: sessionID))
        }
        guard let ports = AirPlay2Message.streamPorts(in: stream.body) else { throw RAOPError.badResponse("SETUP") }
        let chosen = format
        // Apple's encoder for the format if it can be had; the verbatim frame otherwise (lossless either way).
        var streamEncoder: ALACEncoder?
        if chosen != .cd { streamEncoder = try? ALACEncoder(config: chosen.alac) }
        parts.withLock { $0.streamEncoder = streamEncoder }
        state.withLock { $0.ports = RAOPTransport(server: ports.data, control: ports.control, timing: nil); $0.format = chosen }
    }

    /// A buffered stream in place of the realtime one: the receiver is told of this Mac's clock, the clock starts telling
    /// it the time, and the blocks get a connection of their own. Anything refused on the way is thrown: there is no
    /// going back to a realtime stream within the session (the caller opens another, without a clock).
    private func setUpBuffered(host: String, key: Data, kind: AirPlay2Buffered.Kind, clock: PTPClock) async throws {
        let local = parts.withLock { $0.localAddress }
        parts.withLock { $0.audioKey = SymmetricKey(data: key) }
        state.withLock { $0.sealed = 0; $0.block = 0 }
        let plist = [("Content-Type", AirPlay2Message.contentType)]
        let introduced = try await request("SETUP", headers: plist, body: AirPlay2Message.bufferedSessionSetup(sender: sender, sessionUUID: UUID(), groupUUID: UUID(),
                                                                                                         addresses: [local]))
        guard let eventPort = AirPlay2Message.eventPort(in: introduced.body) else { throw RAOPError.badResponse("SETUP") }
        let events = try await Self.openEvents(host: host, port: eventPort)
        parts.withLock { $0.events = events }
        _ = try await request("SETPEERS", headers: plist, body: AirPlay2Message.peers([local, host]))
        let ports = clockPeerPorts
        clock.setPeers([PTPClock.Peer(host: host, eventPort: ports.event, generalPort: ports.general)])
        clock.start()
        let stream = try await request("SETUP", headers: plist, body: AirPlay2Message.bufferedStreamSetup(key: key, connectionID: sessionID, kind: kind))
        guard let answer = AirPlay2Message.bufferedStream(in: stream.body) else { throw RAOPError.badResponse("SETUP") }
        let blocks = try await Self.openEvents(host: host, port: answer.dataPort)
        let streamEncoder = try? ALACEncoder(config: kind.format.alac)
        parts.withLock { $0.blocks = blocks; $0.streamEncoder = streamEncoder }
        state.withLock { $0.ports = RAOPTransport(server: answer.dataPort, control: 0, timing: nil); $0.format = kind.format; $0.buffered = true }
    }

    /// SETRATEANCHORTIME: the frame the stream is anchored at sounds its latency after the moment it was anchored, on the
    /// session's clock (whose time is this Mac's uptime).
    private func sendAnchor() async {
        guard let clock, let (rtp, nanos, format) = state.withLock({ s in s.anchor.map { ($0.rtp, $0.nanos, s.format) } }) else { return }
        let lead = UInt64(format.latencyFrames) * 1_000_000_000 / UInt64(format.sampleRate)
        let body = AirPlay2Message.play(rtpTime: rtp, at: AirPlay2NetworkTime(nanoseconds: nanos &+ lead), clock: clock.identity)
        do {
            _ = try await request("SETRATEANCHORTIME", headers: [("Content-Type", AirPlay2Message.contentType)], body: body)
        } catch {
            log.error("AirPlay \(self.name, privacy: .public) was not told when to play: \(String(describing: error), privacy: .public)")
        }
    }

    /// The event connection, open and being read (what arrives is sealed, and dropped unread).
    private static func openEvents(host: String, port: UInt16) async throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw RAOPError.badResponse("SETUP") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        let queue = DispatchQueue(label: "org.szeremeta.vespertine.airplay.events")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .failed, .cancelled, .waiting:
                    if once.take() {
                        connection.cancel()
                        continuation.resume(throwing: RAOPError.unreachable)
                    }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        drain(connection)
        return connection
    }

    private static func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { _, _, complete, error in
            guard error == nil, !complete else { return }
            drain(connection)
        }
    }

    public func setVolume(_ decibels: Double) async throws {
        _ = try await request("SET_PARAMETER", headers: [("Content-Type", "text/parameters")], body: Data(RAOPVolume.parameter(decibels: decibels).utf8))
    }

    /// Title, artist and album from the frame `rtptime` on.
    public func setMetadata(title: String, artist: String?, album: String?, rtptime: UInt32) async throws {
        _ = try await request("SET_PARAMETER", headers: [("Content-Type", "application/x-dmap-tagged"), ("RTP-Info", "rtptime=\(rtptime)")],
                              body: DMAP.item(title: title, artist: artist, album: album))
    }

    /// The song's cover from the frame `rtptime` on (JPEG or PNG); nil, or a picture receivers don't take, clears the one shown.
    public func setArtwork(_ image: Data?, rtptime: UInt32) async throws {
        let type = image.flatMap(AirPlayArtwork.contentType)
        _ = try await request("SET_PARAMETER", headers: [("Content-Type", type ?? AirPlayArtwork.none), ("RTP-Info", "rtptime=\(rtptime)")],
                              body: type == nil ? Data() : image ?? Data())
    }

    /// Where the song is: its first frame, the frame heard now, its last (RTP times).
    public func setProgress(start: UInt32, current: UInt32, end: UInt32) async throws {
        _ = try await request("SET_PARAMETER", headers: [("Content-Type", "text/parameters")], body: Data("progress: \(start)/\(current)/\(end)\r\n".utf8))
    }

    /// Drops everything the receiver holds; the next packet starts afresh (with the marker and a first sync).
    public func flush() async throws {
        let (seq, head) = state.withLock { s -> (UInt16, UInt32) in
            s.first = true
            s.anchor = nil
            return (s.seq, s.head)
        }
        if let block = state.withLock({ s -> UInt32? in s.buffered ? s.block : nil }) {
            // A buffered stream: everything before the next block is dropped, and the next block is anchored anew.
            _ = try await request("FLUSHBUFFERED", headers: [("Content-Type", AirPlay2Message.contentType)],
                                  body: AirPlay2Message.flushBuffered(untilSequence: block, untilTimestamp: head))
            return
        }
        _ = try await request("FLUSH", headers: [("RTP-Info", "seq=\(seq);rtptime=\(head)")])
    }

    public func teardown() async {
        if isConnected { _ = try? await request("TEARDOWN") }
        await close()
    }

    private func close() async {
        let p = parts.withLock { p -> Parts in defer { p.keepAlive = nil }; return p }
        // Not the keep-alive's own task cancelling itself mid-close: it ends by returning.
        p.keepAlive?.cancel()
        state.withLock { $0.connected = false }
        [p.audio, p.control, p.timing].forEach { $0?.close() }
        p.events?.cancel()
        p.blocks?.cancel()
        clock?.stop()
        await p.rtsp?.close()
    }

    private func startKeepAlive() {
        parts.withLock { $0.keepAlive?.cancel() }
        let task = Task { [weak self] in
            var asked = ContinuousClock.now
            while !Task.isCancelled {
                // Looked at every two seconds; asked every `keepAliveInterval`, or at once when the receiver has gone quiet.
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                // An AirPlay 2 receiver is told every two seconds that the sender is still there (POST /feedback).
                guard self.usesPairing || ContinuousClock.now - asked >= Self.keepAliveInterval || self.hasGoneQuiet() else { continue }
                asked = .now
                do {
                    _ = try await self.usesPairing ? self.request("POST", url: "/feedback") : self.request("OPTIONS", url: "*")
                    // It answered: quiet or not, it is there (not asked again before another silence as long).
                    self.state.withLock { $0.lastTiming = NTPClock.nanosecondsNow() }
                } catch RAOPError.refused(_, _) where self.usesPairing {
                    // A receiver that has no use for /feedback and says so is still there.
                    continue
                } catch {
                    guard !Task.isCancelled, self.isConnected else { return }
                    self.log.error("AirPlay \(self.name, privacy: .public) keep-alive failed: \(String(describing: error), privacy: .public)")
                    self.state.withLock { $0.connected = false }
                    // The connection is closed (not left half-open) before the playback hears of it.
                    let p = self.parts.withLock { p -> Parts in defer { p.keepAlive = nil }; return p }
                    [p.audio, p.control, p.timing].forEach { $0?.close() }
                    p.events?.cancel()
                    p.blocks?.cancel()
                    self.clock?.stop()
                    await p.rtsp?.close()
                    self.onLost?()
                    return
                }
            }
        }
        parts.withLock { $0.keepAlive = task }
    }

    /// Audio is going out, the receiver has been asking the time, and it has stopped asking.
    func hasGoneQuiet(now: UInt64 = NTPClock.nanosecondsNow()) -> Bool {
        state.withLock { s in
            guard s.connected, s.timingRequests >= 2, now >= s.lastAudio, now - s.lastAudio < 2_000_000_000, now >= s.lastTiming else { return false }
            return Double(now - s.lastTiming) / 1e9 >= Self.silenceBeforeProbe
        }
    }

    // MARK: Audio

    /// The RTP time of the next frame to be sent.
    public var nextTimestamp: UInt32 { state.withLock { $0.head } }

    /// The RTP time this Mac's clock says is being sent now (the frame heard `latencyFrames` later); nil before the first
    /// packet after RECORD or FLUSH.
    public func clockTimestamp(nanoseconds: UInt64 = NTPClock.nanosecondsNow()) -> UInt32? {
        state.withLock { s in
            guard let anchor = s.anchor else { return nil }
            // Signed: before the anchor (the packets sent ahead of the clock) the frame being "sent now" is behind it.
            let elapsed = Int64(bitPattern: nanoseconds &- anchor.nanos)
            // In Double: an Int64 product would overflow after about 58 hours on one anchor.
            let frames = Int64((Double(elapsed) * Double(s.format.sampleRate) / 1e9).rounded(.down))
            return anchor.rtp &+ UInt32(truncatingIfNeeded: frames)
        }
    }

    /// Sends 352 interleaved stereo frames. The first packet after RECORD or FLUSH anchors the clock at `startNanos`
    /// (when its first frame counts as sent) and goes with a first sync packet.
    @discardableResult
    public func send(_ samples: [Int16], startNanos: UInt64 = NTPClock.nanosecondsNow()) -> Bool {
        send(samples: samples.map { Int32($0) }, startNanos: startNanos)
    }

    /// The same for samples of the session's `format`: each a value of its depth (what `AirPlayFrames.nextSamples` gives
    /// for that format).
    @discardableResult
    public func send(samples: [Int32], startNanos: UInt64 = NTPClock.nanosecondsNow()) -> Bool {
        let format = self.format
        let encoder = format == .cd ? self.encoder : parts.withLock { $0.streamEncoder }
        var payload: Data
        if let encoder, let encoded = try? encoder.encode(samples: samples) {
            payload = encoded
        } else {
            payload = ALACVerbatim.encode(samples: samples, bitDepth: format.bitDepth)
        }
        if encryption == .rsa, !usesPairing {
            let (key, iv) = parts.withLock { ($0.aesKey, $0.aesIV) }
            guard (try? AESCBC.apply(&payload, key: key, iv: iv, encrypt: true)) != nil else { return false }
        }
        let audioKey = parts.withLock { $0.audioKey }
        if let kind = AirPlay2Buffered.Kind(format: format), isBuffered {
            guard let audioKey, let blocks = parts.withLock({ $0.blocks }) else { return false }
            let (block, first) = state.withLock { s -> (Data, Bool) in
                let first = s.first
                if first { s.anchor = (s.head, startNanos) }
                let block = (try? AirPlay2Buffered.block(sequence: s.block, timestamp: s.head, kind: kind, payload: payload, key: audioKey, counter: s.sealed)) ?? Data()
                s.sealed += 1
                s.block = (s.block &+ 1) & AirPlay2Buffered.sequenceMask
                s.head &+= UInt32(RAOPTiming.framesPerPacket)
                s.first = false
                s.lastAudio = NTPClock.nanosecondsNow()
                return (block, first)
            }
            guard !block.isEmpty else { return false }
            blocks.send(content: block, completion: .contentProcessed { _ in })
            // The first block after RECORD or a flush says when it plays.
            if first { Task { [weak self] in await self?.sendAnchor() } }
            return true
        }
        let (packet, first, host, port) = state.withLock { s -> (Data, Bool, String, UInt16) in
            let first = s.first
            if first { s.anchor = (s.head, startNanos) }
            var packet = RAOPPacket.audio(seq: s.seq, timestamp: s.head, ssrc: ssrc, payload: payload, first: first)
            if let audioKey {
                // Sealed once: a packet the receiver asks for again goes as the same bytes.
                packet = (try? AirPlay2Audio.packet(seq: s.seq, timestamp: s.head, ssrc: ssrc, payload: payload, first: first, key: audioKey,
                                                    counter: s.sealed)) ?? Data()
                s.sealed += 1
            }
            s.backlog[s.seq] = packet
            s.backlog[s.seq &- UInt16(Self.backlogPackets)] = nil
            s.seq &+= 1
            s.head &+= UInt32(RAOPTiming.framesPerPacket)
            s.first = false
            s.lastAudio = NTPClock.nanosecondsNow()
            return (packet, first, s.host, s.ports.server)
        }
        guard !packet.isEmpty else { return false }
        if first { sendSync(first: true) }
        return audio?.send(packet, to: host, port: port) ?? false
    }

    /// A sync packet (about once a second while playing).
    public func sendSync(first: Bool = false) {
        // A buffered stream has no sync packets: its moments are named on the clock.
        guard !isBuffered else { return }
        let nanos = NTPClock.nanosecondsNow()
        guard let rtp = clockTimestamp(nanoseconds: nanos) else { return }
        let (host, port, latency) = state.withLock { ($0.host, $0.ports.control, $0.format.syncLatencyFrames) }
        control?.send(RAOPPacket.sync(rtpNow: rtp, ntp: NTPClock.ntp(nanoseconds: nanos), first: first, latency: latency), to: host, port: port)
    }

    private func answerTiming(_ data: Data, from: String, port: UInt16) {
        let receive = NTPClock.now()
        // Only the session's own receiver counts as a sign of life (these ports take datagrams from anyone on the network).
        state.withLock { s in
            guard from == s.host else { return }
            s.timingRequests += 1
            s.lastTiming = NTPClock.nanosecondsNow()
        }
        guard let reply = RAOPPacket.timingReply(request: data, receive: receive, transmit: NTPClock.now()) else { return }
        timing?.send(reply, to: from, port: port)
    }

    private func answerControl(_ data: Data, from: String) {
        // Packets are sent again only when the receiver itself asks: anyone else could have it flooded with them.
        guard from == state.withLock({ $0.host }) else { return }
        guard let (seq, count) = RAOPPacket.parseResendRequest(data) else { return }
        let (packets, host, port) = state.withLock { s -> ([Data], String, UInt16) in
            let list = (0..<min(count, UInt16(Self.backlogPackets))).compactMap { s.backlog[seq &+ $0] }
            s.resent += list.count
            return (list, s.host, s.ports.control)
        }
        for p in packets { control?.send(RAOPPacket.resend(p), to: host, port: port) }
    }
}
