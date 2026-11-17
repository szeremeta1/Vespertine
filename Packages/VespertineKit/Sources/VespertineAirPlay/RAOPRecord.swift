//
// Vespertine: what an AirPlay receiver says about itself on Bonjour. `_raop._tcp` (AirPlay 1) names the service
// `<MAC>@<name>` and lists, in its TXT record, the encryptions (`et`), codecs (`cn`), format (`sr`, `ss`, `ch`), transports
// (`tp`) and metadata (`md`) it takes; `_airplay._tcp` (AirPlay 2 and video) adds `deviceid`, `model` and `features`.
// Vespertine sends ALAC 16/44.1 over RAOP, unencrypted (after `/auth-setup` for MFi receivers) or with RSA/AES; anything
// else is listed as not supported yet.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A `_raop._tcp` service.
public struct RAOPRecord: Sendable, Hashable {
    /// The device id: the MAC before the `@`, upper-case hex without separators.
    public var deviceID: String
    public var name: String
    /// `et`: 0 none, 1 RSA (AirPort Express), 3 FairPlay, 4 MFi-SAP, 5 FairPlay SAPv2.5.
    public var encryptions: Set<Int>
    /// `cn`: 0 PCM, 1 ALAC, 2 AAC, 3 AAC-ELD. nil: not stated (older receivers take PCM and ALAC).
    public var codecs: Set<Int>?
    public var sampleRate: Int?
    public var sampleSize: Int?
    public var channels: Int?
    /// `tp`: "UDP", "TCP,UDP".
    public var transports: Set<String>?
    /// `md`: 0 text, 1 artwork, 2 progress.
    public var metadata: Set<Int>
    public var model: String?
    public var version: String?
    public var needsPassword: Bool
    /// `pk`: the device's public key (AirPlay 2 pairing; not used in phase 1).
    public var hasPublicKey: Bool
    /// `sv`: the receiver applies volume in software.
    public var softwareVolume: Bool?

    /// nil when the name isn't `<hex>@<name>`.
    public static func parse(serviceName: String, txt: [String: String]) -> RAOPRecord? {
        guard let at = serviceName.firstIndex(of: "@") else { return nil }
        let mac = serviceName[..<at].uppercased().filter { $0 != ":" && $0 != "-" }
        let name = String(serviceName[serviceName.index(after: at)...])
        guard !mac.isEmpty, mac.allSatisfy(\.isHexDigit), !name.isEmpty else { return nil }
        let t = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        return RAOPRecord(deviceID: mac, name: name,
                          encryptions: Set(ints(t["et"]) ?? [0]), codecs: ints(t["cn"]).map(Set.init),
                          sampleRate: t["sr"].flatMap { Int($0) }, sampleSize: t["ss"].flatMap { Int($0) }, channels: t["ch"].flatMap { Int($0) },
                          transports: t["tp"].map { Set($0.uppercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) },
                          metadata: Set(ints(t["md"]) ?? []), model: t["am"], version: t["vs"] ?? t["vn"],
                          needsPassword: t["pw"].map(truthy) ?? false, hasPublicKey: t["pk"].map { !$0.isEmpty } ?? false,
                          softwareVolume: t["sv"].map(truthy))
    }

    static func ints(_ value: String?) -> [Int]? {
        guard let value else { return nil }
        let list = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return list.isEmpty ? nil : list
    }

    static func truthy(_ value: String) -> Bool { ["true", "1", "yes"].contains(value.lowercased()) }
}

/// An `_airplay._tcp` service (only what matters for listing it).
public struct AirPlayRecord: Sendable, Hashable {
    public var deviceID: String
    public var name: String
    public var model: String?
    /// `features`: what the receiver can do, one bit each ("0x4A7FCA00,0xBC354BD0": the low 32 bits, then the high).
    /// nil: not stated, or not readable.
    public var features: UInt64?
    /// `flags`: how the receiver is set just now, one bit each ("0x4"). nil: not stated.
    public var flags: UInt64?

    public init(deviceID: String, name: String, model: String? = nil, features: UInt64? = nil, flags: UInt64? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.features = features
        self.flags = flags
    }

    public static func parse(serviceName: String, txt: [String: String]) -> AirPlayRecord? {
        let t = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let id = t["deviceid"]?.uppercased().filter({ $0.isHexDigit }), !id.isEmpty else { return nil }
        return AirPlayRecord(deviceID: id, name: serviceName, model: t["model"], features: t["features"].flatMap(bits), flags: t["flags"].flatMap(bits))
    }

    /// "0x1,0x2" as one number: the first part is the low 32 bits, the second (when there is one) the high.
    static func bits(_ text: String) -> UInt64? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { part -> UInt64? in
            let digits = part.trimmingCharacters(in: .whitespaces).lowercased()
            return UInt64(digits.hasPrefix("0x") ? String(digits.dropFirst(2)) : digits, radix: 16)
        }
        guard let low = parts.first ?? nil, parts.count <= 2 else { return nil }
        guard parts.count == 2 else { return low }
        guard let high = parts[1], low <= UInt64(UInt32.max), high <= UInt64(UInt32.max) else { return nil }
        return high << 32 | low
    }

    /// The receiver plays audio sent by AirPlay (`features` bit 9).
    public var playsAudio: Bool { has(9) }
    /// It can be paired with the way AirPlay 2 senders do (any of `features` bits 38, 43, 46, 48).
    public var pairs: Bool { has(38) || has(43) || has(46) || has(48) }
    /// It is set to ask for the PIN on its screen: each time (`flags` 0x8) or once (0x200).
    public var asksForPIN: Bool { (flags ?? 0) & 0x208 != 0 }
    /// It is set to ask for a password (`flags` 0x80).
    public var asksForPassword: Bool { (flags ?? 0) & 0x80 != 0 }

    private func has(_ bit: UInt64) -> Bool { (features ?? 0) >> bit & 1 == 1 }
}

/// How a receiver that takes AirPlay 2 lets a sender in.
public enum AirPlay2Entry: Sendable, Hashable {
    /// Anyone on the network may play: paired afresh, with no PIN, every session.
    case open
    /// The PIN on its screen, once; this Mac is remembered after.
    case pin
}

public enum RAOPEncryption: String, Sendable, Hashable {
    case none
    /// RSA-wrapped AES key, AES-128-CBC audio (AirPort Express and receivers that ask for it).
    case rsa
}

/// An AirPlay receiver as an output.
public struct AirPlayDevice: Sendable, Hashable, Identifiable {
    public static let uidPrefix = "raop:"

    public enum Support: Sendable, Hashable {
        case supported(RAOPEncryption)
        /// Listed, not choosable: why.
        case unsupported(String)
    }

    public var deviceID: String
    public var name: String
    public var raop: RAOPRecord?
    public var airplay: AirPlayRecord?
    /// The `_raop._tcp` service to connect to (nil: only AirPlay 2 was seen).
    public var service: BonjourService?
    /// The `_airplay._tcp` service, where an AirPlay 2 session connects (nil: none was seen).
    public var airplayService: BonjourService?
    /// Where to connect when not through Bonjour (tests, a known address).
    public var host: String?
    public var port: UInt16?

    public var uid: String { Self.uidPrefix + deviceID }
    public var id: String { uid }
    public var model: String? { raop?.model ?? airplay?.model }

    public static func isAirPlayUID(_ uid: String?) -> Bool { uid?.hasPrefix(uidPrefix) == true }

    public init(deviceID: String, name: String, raop: RAOPRecord?, airplay: AirPlayRecord? = nil, service: BonjourService? = nil,
                airplayService: BonjourService? = nil, host: String? = nil, port: UInt16? = nil) {
        self.airplayService = airplayService
        self.deviceID = deviceID
        self.name = name
        self.raop = raop
        self.airplay = airplay
        self.service = service
        self.host = host
        self.port = port
    }

    public var isSupported: Bool { if case .supported = support { true } else { false } }

    /// The receiver says it has a password (`pw`): the listener is asked for it before the first song.
    public var needsPassword: Bool { raop?.needsPassword == true }

    /// The receiver lists MFi authentication (`et` 4: most licensed third-party speakers and AV receivers). It expects the
    /// sender's `POST /auth-setup` before anything else, and refuses what follows without it.
    public var needsAuthSetup: Bool { raop?.encryptions.contains(4) == true }

    /// How an AirPlay 2 session with this receiver would begin; nil when it doesn't say it takes one (no `_airplay._tcp`
    /// record, no audio, or no pairing an open sender can do). A receiver set to ask for a password is not one yet.
    public var airPlay2Entry: AirPlay2Entry? {
        guard let airplay, airplay.playsAudio, airplay.pairs, !airplay.asksForPassword else { return nil }
        return airplay.asksForPIN ? .pin : .open
    }

    public var support: Support {
        guard let raop else { return .unsupported(Self.airPlay2Only) }
        // MFi receivers (`et` 4) take the audio as it is once the sender has introduced itself (`needsAuthSetup`).
        let encryption: RAOPEncryption
        if raop.encryptions.contains(0) || raop.encryptions.contains(4) { encryption = .none } else if raop.encryptions.contains(1) { encryption = .rsa } else {
            return .unsupported(Self.airPlay2Only)
        }
        if let codecs = raop.codecs, !codecs.contains(1) { return .unsupported(Self.formatUnsupported) }
        if let transports = raop.transports, !transports.contains("UDP") { return .unsupported(Self.formatUnsupported) }
        if let size = raop.sampleSize, size != 16 { return .unsupported(Self.formatUnsupported) }
        if let rate = raop.sampleRate, rate != 44_100 { return .unsupported(Self.formatUnsupported) }
        if let channels = raop.channels, channels != 2 { return .unsupported(Self.formatUnsupported) }
        return .supported(encryption)
    }

    static var airPlay2Only: String {
        String(localized: "AirPlay 2 only — not supported yet", comment: "Output list: an AirPlay receiver that takes only AirPlay 2, which Vespertine can't send yet.")
    }

    static var formatUnsupported: String {
        String(localized: "Doesn't take ALAC 16-bit / 44.1 kHz — not supported", comment: "Output list: an AirPlay receiver that doesn't list the format Vespertine sends.")
    }
}

/// A Bonjour service, by name, type and domain (what NWBrowser reports and NWConnection connects to).
public struct BonjourService: Sendable, Hashable {
    public var name: String
    public var type: String
    public var domain: String

    public init(name: String, type: String, domain: String = "local.") {
        self.name = name
        self.type = type
        self.domain = domain
    }
}
