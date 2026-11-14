//
// Vespertine: the bytes of an AirPlay 1 session. RTP audio (payload type 96, 352 frames a packet), sync packets on the
// control port mapping RTP time to this Mac's clock, timing replies (an NTP-like exchange the receiver starts), and
// retransmission. Layouts as OwnTone (raop.c, rtp_common.c), libraop (raop_client.c) send them and shairport-sync
// (rtp.c) reads them.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// This Mac's clock as NTP time (32.32 fixed point). Monotonic (mach continuous time), so sleep or a clock change can't make
/// it jump; the offset only makes the values look like NTP dates.
public enum NTPClock {
    /// Seconds from 1900 to the moment the process first asked.
    private static let base: (ntpSeconds: Double, uptime: UInt64) = {
        (Date().timeIntervalSince1970 + 2_208_988_800, nanosecondsNow())
    }()

    public static func nanosecondsNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// The NTP time for a `nanosecondsNow()` reading.
    public static func ntp(nanoseconds: UInt64) -> UInt64 {
        let b = base
        let elapsed = nanoseconds >= b.uptime ? Double(nanoseconds - b.uptime) / 1e9 : -Double(b.uptime - nanoseconds) / 1e9
        let seconds = b.ntpSeconds + elapsed
        let whole = floor(seconds)
        return (UInt64(whole) << 32) | UInt64((seconds - whole) * 4_294_967_296)
    }

    public static func now() -> UInt64 { ntp(nanoseconds: nanosecondsNow()) }
}

public enum RAOPTiming {
    /// Frames in each audio packet.
    public static let framesPerPacket = 352
    public static let sampleRate = 44_100
    /// What the receiver plays behind real time, in frames (2 s, as iTunes): sync packets say 77 175 and receivers add the
    /// 11 025 they always add.
    public static let latencyFrames: UInt32 = 88_200
    static let syncLatencyFrames: UInt32 = 77_175
}

public enum RAOPPacket {
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xffff_ffff)) }
    static func read16(_ d: Data, _ at: Int) -> UInt16 { let i = d.startIndex + at; return UInt16(d[i]) << 8 | UInt16(d[i + 1]) }
    static func read32(_ d: Data, _ at: Int) -> UInt32 { UInt32(read16(d, at)) << 16 | UInt32(read16(d, at + 2)) }
    static func read64(_ d: Data, _ at: Int) -> UInt64 { UInt64(read32(d, at)) << 32 | UInt64(read32(d, at + 4)) }

    /// An audio packet: RTP header (marker on the first after RECORD or FLUSH) and one ALAC packet.
    public static func audio(seq: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data, first: Bool) -> Data {
        var d = Data([0x80, first ? 0xE0 : 0x60])
        d += be16(seq) + be32(timestamp) + be32(ssrc)
        d += payload
        return d
    }

    /// The parts of an audio packet (as the receiver reads it); nil when it isn't one.
    public static func parseAudio(_ d: Data) -> (seq: UInt16, timestamp: UInt32, payload: Data)? {
        guard d.count >= 12, d[d.startIndex] == 0x80, d[d.startIndex + 1] & 0x7f == 0x60 else { return nil }
        let base = Data(d)
        return (read16(base, 2), read32(base, 4), base.subdata(in: 12..<base.count))
    }

    /// A sync packet: at NTP time `ntp`, frame `rtpNow − latency` is heard; `rtpNow` is the frame being sent now.
    public static func sync(rtpNow: UInt32, ntp: UInt64, first: Bool) -> Data {
        var d = Data([first ? 0x90 : 0x80, 0xD4, 0x00, 0x07])
        d += be32(rtpNow &- RAOPTiming.syncLatencyFrames) + be64(ntp) + be32(rtpNow)
        return d
    }

    public static func parseSync(_ d: Data) -> (rtpLessLatency: UInt32, ntp: UInt64, rtp: UInt32)? {
        let b = Data(d)
        guard b.count >= 20, b[1] == 0xD4 else { return nil }
        return (read32(b, 4), read64(b, 8), read32(b, 16))
    }

    /// A timing request (the receiver's): its transmit time is at bytes 24…31.
    public static func timingRequest(transmit: UInt64) -> Data {
        Data([0x80, 0xD2, 0x00, 0x07, 0, 0, 0, 0]) + Data(repeating: 0, count: 16) + be64(transmit)
    }

    /// The answer to a timing request: its transmit time as reference, then when it came and when this goes.
    public static func timingReply(request: Data, receive: UInt64, transmit: UInt64) -> Data? {
        let r = Data(request)
        guard r.count >= 32, r[0] == 0x80, r[1] == 0xD2 else { return nil }
        var d = Data([0x80, 0xD3, r[2], r[3], 0, 0, 0, 0])
        d += r.subdata(in: 24..<32)
        d += be64(receive) + be64(transmit)
        return d
    }

    public static func parseTimingReply(_ d: Data) -> (reference: UInt64, receive: UInt64, transmit: UInt64)? {
        let b = Data(d)
        guard b.count >= 32, b[1] == 0xD3 else { return nil }
        return (read64(b, 8), read64(b, 16), read64(b, 24))
    }

    /// A receiver's request for lost packets: `count` packets from `seq`.
    public static func resendRequest(seq: UInt16, count: UInt16) -> Data {
        Data([0x80, 0xD5, 0x00, 0x01]) + be16(seq) + be16(count)
    }

    public static func parseResendRequest(_ d: Data) -> (seq: UInt16, count: UInt16)? {
        let b = Data(d)
        guard b.count >= 8, b[0] == 0x80, b[1] == 0xD5 else { return nil }
        return (read16(b, 4), read16(b, 6))
    }

    /// A packet sent again, on the control port: a 4-byte header, then the audio packet as it was.
    public static func resend(_ audio: Data) -> Data { Data([0x80, 0xD6, 0x00, 0x01]) + audio }
}

/// The receiver's volume: −30…0 dB for the slider's 0…1 (linear in dB, as OwnTone and libraop), −144 for silence.
public enum RAOPVolume {
    public static func decibels(level: Double) -> Double {
        let l = min(max(level, 0), 1)
        return l <= 0 ? -144 : -30 + 30 * l
    }

    /// The SET_PARAMETER body, with a dot whatever the locale.
    public static func parameter(decibels: Double) -> String {
        String(format: "volume: %.6f\r\n", locale: Locale(identifier: "en_US_POSIX"), decibels)
    }
}

/// DMAP (DAAP) tagged metadata for the receiver's display: a `mlit` item with title, artist and album.
public enum DMAP {
    static func tag(_ code: String, _ value: Data) -> Data {
        Data(code.utf8) + RAOPPacket.be32(UInt32(value.count)) + value
    }

    public static func item(title: String, artist: String?, album: String?) -> Data {
        var inner = tag("minm", Data(title.utf8))
        if let artist, !artist.isEmpty { inner += tag("asar", Data(artist.utf8)) }
        if let album, !album.isEmpty { inner += tag("asal", Data(album.utf8)) }
        return tag("mlit", inner)
    }

    /// The tags in a DMAP container (for tests and the fake receiver).
    public static func parse(_ data: Data) -> [String: Data] {
        var out: [String: Data] = [:]
        var i = data.startIndex
        let d = Data(data)
        i = 0
        while i + 8 <= d.count {
            let code = String(decoding: d.subdata(in: i..<(i + 4)), as: UTF8.self)
            let length = Int(RAOPPacket.read32(d, i + 4))
            guard i + 8 + length <= d.count else { break }
            let value = d.subdata(in: (i + 8)..<(i + 8 + length))
            if code == "mlit" { out.merge(parse(value)) { a, _ in a } } else { out[code] = value }
            i += 8 + length
        }
        return out
    }
}

/// The SDP an ANNOUNCE carries: ALAC 352 frames, 16-bit, 44.1 kHz stereo; the RSA-wrapped AES key and IV when encrypted.
public enum SDP {
    public static let fmtp = "352 0 16 40 10 14 2 255 0 0 44100"

    public static func announce(sessionID: UInt32, local: String, remote: String, rsaAESKey: Data? = nil, aesIV: Data? = nil) -> String {
        var s = "v=0\r\n"
        s += "o=iTunes \(sessionID) 0 IN IP4 \(local)\r\n"
        s += "s=iTunes\r\n"
        s += "c=IN IP4 \(remote)\r\n"
        s += "t=0 0\r\n"
        s += "m=audio 0 RTP/AVP 96\r\n"
        s += "a=rtpmap:96 AppleLossless\r\n"
        s += "a=fmtp:96 \(fmtp)\r\n"
        if let rsaAESKey, let aesIV {
            s += "a=rsaaeskey:\(base64NoPadding(rsaAESKey))\r\n"
            s += "a=aesiv:\(base64NoPadding(aesIV))\r\n"
        }
        return s
    }

    public static func base64NoPadding(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "=", with: "") }

    /// Decodes base64 with or without its padding.
    public static func base64(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// `a=` attributes of an SDP, by name (the fake receiver reads `fmtp`, `rsaaeskey`, `aesiv`).
    public static func attributes(_ sdp: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in sdp.components(separatedBy: "\r\n") where line.hasPrefix("a=") {
            let body = line.dropFirst(2)
            guard let colon = body.firstIndex(of: ":") else { continue }
            var value = String(body[body.index(after: colon)...])
            let name = String(body[..<colon])
            if name == "fmtp" || name == "rtpmap", let space = value.firstIndex(of: " ") { value = String(value[value.index(after: space)...]) }
            out[name] = value
        }
        return out
    }
}
