//
// Vespertine: one AirPlay 1 session with a receiver. RTSP sets it up (OPTIONS, ANNOUNCE with the SDP, SETUP for the UDP
// ports, RECORD), then audio goes as RTP packets of 352 ALAC frames on a timeline that continues across songs; FLUSH stops
// what the receiver holds (pause, seek), SET_PARAMETER carries volume, titles and progress, TEARDOWN ends it. The control
// port carries sync packets (which frame is heard when, by this Mac's clock) and the receiver's requests for lost packets;
// the timing port answers its clock questions. OPTIONS every 25 s keeps an idle session open.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import os
import Security
import VespertineAudio

public final class RAOPSession: @unchecked Sendable {
    public let name: String
    private let endpoint: NWEndpoint
    private let encryption: RAOPEncryption
    private let rsaKey: SecKey?
    private let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "airplay")

    private var rtsp: RTSPConnection?
    private var audio: UDPSocket?
    private var control: UDPSocket?
    private var timing: UDPSocket?
    private var keepAlive: Task<Void, Never>?

    private struct State {
        var connected = false
        var host = ""
        var ports = RAOPTransport(server: 0, control: 0, timing: nil)
        var session: String?
        var cseq = 1
        var seq = UInt16.random(in: 0...UInt16.max)
        var head = UInt32.random(in: 0...(UInt32.max / 2))
        var first = true
        var anchor: (rtp: UInt32, nanos: UInt64)?
        var backlog: [UInt16: Data] = [:]
        var resent = 0
    }
    private let state = Locked(State())
    private let encoder: ALACEncoder?
    private let aesKey = AESCBC.randomBytes(16)
    private let aesIV = AESCBC.randomBytes(16)
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

    /// `rsaKey`: the key the AES key is wrapped with (the AirPort Express key unless a test gives its own).
    public init(name: String, endpoint: NWEndpoint, encryption: RAOPEncryption, rsaKey: SecKey? = nil) {
        self.name = name
        self.endpoint = endpoint
        self.encryption = encryption
        self.rsaKey = rsaKey ?? (encryption == .rsa ? try? RSAWrap.airPortExpressKey() : nil)
        // Apple's encoder if its configuration is the SDP's; the verbatim frame otherwise (lossless either way).
        encoder = try? ALACEncoder()
    }

    deinit {
        keepAlive?.cancel()
        [audio, control, timing].forEach { $0?.close() }
    }

    public var isConnected: Bool { state.withLock { $0.connected } }
    public var usesAppleEncoder: Bool { encoder != nil }
    /// Packets sent again on the receiver's request.
    public var resentPackets: Int { state.withLock { $0.resent } }

    // MARK: RTSP

    private var url: String { "rtsp://\(localAddress)/\(sessionID)" }
    private var localAddress = "0.0.0.0"

    private func request(_ method: String, url: String? = nil, headers extra: [(String, String)] = [], body: Data = Data()) async throws -> RTSPMessage {
        guard let rtsp else { throw RAOPError.closed }
        let (cseq, session) = state.withLock { s -> (Int, String?) in defer { s.cseq += 1 }; return (s.cseq, s.session) }
        var headers: [(String, String)] = [("CSeq", String(cseq)), ("User-Agent", "Vespertine/1 AirPlay/366.0"),
                                           ("Client-Instance", clientInstance), ("DACP-ID", clientInstance), ("Active-Remote", activeRemote)]
        if let session { headers.append(("Session", session)) }
        headers += extra
        let response = try await rtsp.send(.request(method, url ?? self.url, headers: headers, body: body))
        guard response.status == 200 else { throw RAOPError.refused(method, response.status) }
        return response
    }

    /// OPTIONS, ANNOUNCE, SETUP and RECORD; then the receiver takes audio. `volumeDB`: sent right after (nil: left alone).
    public func connect(volumeDB: Double?) async throws {
        let rtsp = RTSPConnection(endpoint: endpoint)
        self.rtsp = rtsp
        do {
            try await rtsp.connect()
            let host = await rtsp.remoteAddress
            localAddress = await rtsp.localAddress
            guard !host.isEmpty, !host.contains(":") else { throw RAOPError.unreachable }
            state.withLock { $0.host = host }
            _ = try await request("OPTIONS", url: "*")
            var rsa: Data?
            var extra: [(String, String)] = [("Content-Type", "application/sdp")]
            if encryption == .rsa {
                guard let rsaKey else { throw RAOPError.badResponse("RSA") }
                rsa = try RSAWrap.encrypt(aesKey, key: rsaKey)
                extra.append(("Apple-Challenge", SDP.base64NoPadding(AESCBC.randomBytes(16))))
            }
            let sdp = SDP.announce(sessionID: sessionID, local: localAddress, remote: host, rsaAESKey: rsa, aesIV: rsa == nil ? nil : aesIV)
            _ = try await request("ANNOUNCE", headers: extra, body: Data(sdp.utf8))
            // The timing port is open before SETUP (Apple TVs ask the time at once).
            let timing = try UDPSocket(), control = try UDPSocket(), audio = try UDPSocket()
            self.timing = timing
            self.control = control
            self.audio = audio
            timing.startReceiving(name: "Vespertine AirPlay timing") { [weak self] data, from, port in self?.answerTiming(data, from: from, port: port) }
            control.startReceiving(name: "Vespertine AirPlay control") { [weak self] data, _, _ in self?.answerControl(data) }
            let setup = try await request("SETUP", headers: [("Transport", RAOPTransport.request(control: control.port, timing: timing.port))])
            guard let transport = setup["Transport"].flatMap(RAOPTransport.parse) else { throw RAOPError.badResponse("SETUP") }
            state.withLock { $0.ports = transport; $0.session = setup["Session"].map { String($0.split(separator: ";")[0]) } }
            let (seq, head) = state.withLock { ($0.seq, $0.head) }
            _ = try await request("RECORD", headers: [("Range", "npt=0-"), ("RTP-Info", "seq=\(seq);rtptime=\(head)")])
            state.withLock { $0.connected = true; $0.first = true; $0.anchor = nil }
            if let volumeDB { try? await setVolume(volumeDB) }
            startKeepAlive()
        } catch {
            await close()
            throw error
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
        _ = try await request("FLUSH", headers: [("RTP-Info", "seq=\(seq);rtptime=\(head)")])
    }

    public func teardown() async {
        if isConnected { _ = try? await request("TEARDOWN") }
        await close()
    }

    private func close() async {
        keepAlive?.cancel()
        keepAlive = nil
        state.withLock { $0.connected = false }
        [audio, control, timing].forEach { $0?.close() }
        await rtsp?.close()
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled, let self else { return }
                do { _ = try await self.request("OPTIONS", url: "*") } catch {
                    guard !Task.isCancelled, self.isConnected else { return }
                    self.log.error("AirPlay \(self.name, privacy: .public) keep-alive failed: \(String(describing: error), privacy: .public)")
                    self.state.withLock { $0.connected = false }
                    self.onLost?()
                    return
                }
            }
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
            let elapsed = nanoseconds >= anchor.nanos ? nanoseconds - anchor.nanos : 0
            return anchor.rtp &+ UInt32(truncatingIfNeeded: elapsed * UInt64(RAOPTiming.sampleRate) / 1_000_000_000)
        }
    }

    /// Sends 352 interleaved stereo frames. The first packet after RECORD or FLUSH anchors the clock at `startNanos`
    /// (when its first frame counts as sent) and goes with a first sync packet.
    @discardableResult
    public func send(_ samples: [Int16], startNanos: UInt64 = NTPClock.nanosecondsNow()) -> Bool {
        var payload: Data
        if let encoder, let encoded = try? encoder.encode(samples) { payload = encoded } else { payload = ALACVerbatim.encode(samples) }
        if encryption == .rsa { try? AESCBC.apply(&payload, key: aesKey, iv: aesIV, encrypt: true) }
        let (packet, first, host, port) = state.withLock { s -> (Data, Bool, String, UInt16) in
            let first = s.first
            if first { s.anchor = (s.head, startNanos) }
            let packet = RAOPPacket.audio(seq: s.seq, timestamp: s.head, ssrc: ssrc, payload: payload, first: first)
            s.backlog[s.seq] = packet
            s.backlog[s.seq &- UInt16(Self.backlogPackets)] = nil
            s.seq &+= 1
            s.head &+= UInt32(RAOPTiming.framesPerPacket)
            s.first = false
            return (packet, first, s.host, s.ports.server)
        }
        if first { sendSync(first: true) }
        return audio?.send(packet, to: host, port: port) ?? false
    }

    /// A sync packet (about once a second while playing).
    public func sendSync(first: Bool = false) {
        let nanos = NTPClock.nanosecondsNow()
        guard let rtp = clockTimestamp(nanoseconds: nanos) else { return }
        let (host, port) = state.withLock { ($0.host, $0.ports.control) }
        control?.send(RAOPPacket.sync(rtpNow: rtp, ntp: NTPClock.ntp(nanoseconds: nanos), first: first), to: host, port: port)
    }

    private func answerTiming(_ data: Data, from: String, port: UInt16) {
        let receive = NTPClock.now()
        guard let reply = RAOPPacket.timingReply(request: data, receive: receive, transmit: NTPClock.now()) else { return }
        timing?.send(reply, to: from, port: port)
    }

    private func answerControl(_ data: Data) {
        guard let (seq, count) = RAOPPacket.parseResendRequest(data) else { return }
        let (packets, host, port) = state.withLock { s -> ([Data], String, UInt16) in
            let list = (0..<min(count, UInt16(Self.backlogPackets))).compactMap { s.backlog[seq &+ $0] }
            s.resent += list.count
            return (list, s.host, s.ports.control)
        }
        for p in packets { control?.send(RAOPPacket.resend(p), to: host, port: port) }
    }
}
