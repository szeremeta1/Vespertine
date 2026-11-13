//
// Vespertine: an AirPlay 1 receiver on 127.0.0.1 for the tests: RTSP on a TCP port, UDP audio, control and timing ports.
// It records every request, asks the sender for the time (as shairport-sync does before it trusts sync packets), unwraps
// the AES key with the test's private key, decrypts and decodes the ALAC it gets, and can lose packets on purpose to ask
// for them again.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation
import Security
@testable import VespertineAirPlay

final class FakeRAOPReceiver: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var _requests: [RTSPMessage] = []
    private var _packets: [UInt32: [Int16]] = [:]
    private var _firstTimestamp: UInt32?
    private var _syncs: [Data] = []
    private var _timingReplies: [Data] = []
    private var _markers = 0
    private var _resent = 0
    private var stopped = false
    private var sockets: [UDPSocket] = []
    private var clientSockets: [Int32] = []
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
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    func stop() {
        let (socks, clients) = lock.withLock { () -> ([UDPSocket], [Int32]) in
            stopped = true
            return (sockets, clientSockets)
        }
        shutdown(listener, SHUT_RDWR)
        close(listener)
        for c in clients { shutdown(c, SHUT_RDWR) }
        socks.forEach { $0.close() }
    }

    var requests: [RTSPMessage] { lock.withLock { _requests } }
    var methods: [String] { requests.compactMap(\.method) }
    var syncs: [Data] { lock.withLock { _syncs } }
    var timingReplies: [Data] { lock.withLock { _timingReplies } }
    var markers: Int { lock.withLock { _markers } }
    var resent: Int { lock.withLock { _resent } }
    var packetCount: Int { lock.withLock { _packets.count } }
    /// Every frame received, in RTP order.
    var samples: [Int16] {
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
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { clientSockets.append(client) }
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var parser = RTSPParser()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        defer { close(fd) }
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            parser.append(Data(buffer[0..<n]))
            while let request = try? parser.next() {
                let response = handle(request)
                let bytes = response.encoded()
                _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            }
        }
    }

    private func handle(_ request: RTSPMessage) -> RTSPMessage {
        lock.withLock { _requests.append(request) }
        var cseq = request["CSeq"] ?? "0"
        if wrongCSeq.contains(request.method ?? "") { cseq = String((Int(cseq) ?? 0) + 7) }
        var headers: [(String, String)] = [("CSeq", cseq), ("Server", "AirTunes/366.0")]
        if let status = refuse[request.method ?? ""] { return .response(status, "Refused", headers: headers) }
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
        case "OPTIONS":
            headers.append(("Public", "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER"))
        default: break
        }
        return .response(200, "OK", headers: headers)
    }

    private var controlSocket: UDPSocket?
    private var timingSocket: UDPSocket?
    private var received = 0
    private let decodeLock = NSLock()

    // MARK: UDP

    private func audio(_ data: Data, resent: Bool) {
        guard let packet = RAOPPacket.parseAudio(data) else { return }
        let lost = lock.withLock { () -> Bool in
            if !resent, data[data.startIndex + 1] == 0xE0 { _markers += 1 }
            if !resent { received += 1 }
            if !resent, _drop.contains(packet.seq) { _drop.remove(packet.seq); return true }
            if !resent, let l = loseAfter, received > l.count, received <= l.count + l.lose { return true }
            return false
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
        guard let samples = decodeLock.withLock({ try? decoder?.decode(payload) }) else { return }
        lock.withLock {
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
