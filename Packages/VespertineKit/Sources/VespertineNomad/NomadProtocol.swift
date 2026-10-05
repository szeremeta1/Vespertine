//
// Vespertine — the Work Louder Nomad [E] vendor protocol: 64-byte HID reports carrying JSON-RPC text.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What the keyboard's vendor interface (usage page 0xFF00) speaks. Worked out from how Work Louder's own Input app
/// drives the media widget, and checked against the hardware: a request is JSON text cut into HID reports, the answer
/// comes back the same way, and the keyboard also sends unprompted notifications (`mp.fetch_data` when its media
/// screen opens or closes).
public enum NomadProtocol {
    public static let vendorID = 0x303A
    /// Nomad [E] (4097, 33428, 33429) and Nomad [E] 2 (33648 ISO, 33649 ANSI).
    public static let productIDs: Set<Int> = [4097, 33428, 33429, 33648, 33649]
    public static let usagePage = 0xFF00

    public static let reportID: UInt8 = 6
    public static let reportSize = 64
    /// Payload bytes per report: report ID, channel and length take the other three.
    public static let maxPayload = 61

    public enum Channel: UInt8, Sendable {
        case debug = 1
        case rpc = 2
    }

    /// Raw bytes per `mp.write_artwork` call; base64 of this is 4096 characters, the most the firmware takes.
    public static let artworkChunkBytes = 3072
    /// Cover art is shown at this size.
    public static let artworkSide = 80

    public enum Method {
        public static let writeInfo = "mp.write_info"
        public static let writeArtwork = "mp.write_artwork"
        public static let fetchData = "mp.fetch_data"
        public static let version = "sys.version"
    }
}

// MARK: - Reports

public enum NomadReports {
    /// Splits one message into 64-byte output reports: `[6, channel, length, payload (≤ 61 bytes)…]`.
    public static func split(_ message: String, channel: NomadProtocol.Channel = .rpc) -> [[UInt8]] {
        let bytes = Array(message.utf8)
        var reports: [[UInt8]] = []
        var offset = 0
        while offset < bytes.count {
            let n = min(NomadProtocol.maxPayload, bytes.count - offset)
            var report = [UInt8](repeating: 0, count: NomadProtocol.reportSize)
            report[0] = NomadProtocol.reportID
            report[1] = channel.rawValue
            report[2] = UInt8(n)
            report.replaceSubrange(3..<3 + n, with: bytes[offset..<offset + n])
            reports.append(report)
            offset += n
        }
        return reports
    }

    /// Reassembles input reports into the newline-terminated lines the keyboard sends on each channel.
    public struct LineDecoder: Sendable {
        private var buffers: [UInt8: [UInt8]] = [:]

        public init() {}

        public struct Line: Sendable, Equatable {
            public var channel: UInt8
            public var text: String
        }

        /// `report` as the OS hands it over: with the report ID first when the interface numbers its reports (it does),
        /// or without it. Both forms are accepted so a different OS release can't shift every field by one.
        public mutating func feed(_ report: [UInt8]) -> [Line] {
            guard let body = Self.body(of: report) else { return [] }
            let channel = body[0], length = min(Int(body[1]), body.count - 2)
            guard length > 0 else { return [] }
            var buffer = buffers[channel, default: []]
            buffer.append(contentsOf: body[2..<2 + length])
            var lines: [Line] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let raw = buffer[..<newline]
                buffer.removeSubrange(...newline)
                let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(Line(channel: channel, text: text)) }
            }
            // A runaway buffer (no newline for a long time) is noise; start over rather than grow without bound.
            buffers[channel] = buffer.count > 16_384 ? [] : buffer
            return lines
        }

        /// The bytes from the channel on (indexed from 0), or nil if this isn't one of ours.
        private static func body(of report: [UInt8]) -> [UInt8]? {
            if report.count >= 3, report[0] == NomadProtocol.reportID, report[1] <= 2 { return Array(report.dropFirst()) }
            if report.count >= 2, report[0] <= 2 { return report }
            return nil
        }
    }
}

// MARK: - JSON-RPC

public enum NomadRPC {
    /// One request as the firmware wants it: keys in this order, every non-ASCII character as `\uXXXX`.
    public static func request(method: String, params: [(String, JSONValue)]?, id: Int) -> String {
        var s = "{\"method\":\(JSONValue.string(method).encoded)"
        if let params {
            s += ",\"params\":{" + params.map { "\(JSONValue.string($0.0).encoded):\($0.1.encoded)" }.joined(separator: ",") + "}"
        } else {
            s += ",\"params\":null"
        }
        s += ",\"id\":\(id)}"
        return s
    }

    public enum Message: Sendable, Equatable {
        case response(id: Int, error: String?)
        case notification(method: String, shouldFetch: Bool?)
    }

    /// Understands what the keyboard sends: a result or error for an id, or a notification (no id, with a method).
    /// Keys may be abbreviated (`i`, `m`, `p`) as the firmware does on long messages.
    public static func parse(_ line: String) -> Message? {
        guard let start = line.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line[start...].utf8)) as? [String: Any] else { return nil }
        let id = (object["id"] ?? object["i"]) as? Int
        let method = (object["method"] ?? object["m"]) as? String
        if id == nil, let method {
            let params = (object["params"] ?? object["p"]) as? [String: Any]
            return .notification(method: method, shouldFetch: params?["should_fetch"] as? Bool)
        }
        guard let id else { return nil }
        var error: String?
        if let e = object["error"] as? [String: Any] { error = (e["message"] as? String) ?? "error" }
        else if object["error"] != nil { error = "error" }
        return .response(id: id, error: error)
    }
}

public enum JSONValue: Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    var encoded: String {
        switch self {
        case .int(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s):
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where scalar.value < 0x20 || scalar.value > 0x7E:
                    for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }
    }
}
