//
// Vespertine: what an AirPlay receiver says about itself on Bonjour. `_raop._tcp` (AirPlay 1) names the service
// `<MAC>@<name>` and lists, in its TXT record, the encryptions (`et`), codecs (`cn`), format (`sr`, `ss`, `ch`), transports
// (`tp`) and metadata (`md`) it takes; `_airplay._tcp` (AirPlay 2 and video) adds `deviceid`, `model` and `features`.
// Phase 1 sends ALAC 16/44.1 over RAOP, unencrypted or with RSA/AES; anything else is listed as not supported yet.
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

    public static func parse(serviceName: String, txt: [String: String]) -> AirPlayRecord? {
        let t = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let id = t["deviceid"]?.uppercased().filter({ $0.isHexDigit }), !id.isEmpty else { return nil }
        return AirPlayRecord(deviceID: id, name: serviceName, model: t["model"])
    }
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
    /// Where to connect when not through Bonjour (tests, a known address).
    public var host: String?
    public var port: UInt16?

    public var uid: String { Self.uidPrefix + deviceID }
    public var id: String { uid }
    public var model: String? { raop?.model ?? airplay?.model }

    public static func isAirPlayUID(_ uid: String?) -> Bool { uid?.hasPrefix(uidPrefix) == true }

    public init(deviceID: String, name: String, raop: RAOPRecord?, airplay: AirPlayRecord? = nil, service: BonjourService? = nil,
                host: String? = nil, port: UInt16? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.raop = raop
        self.airplay = airplay
        self.service = service
        self.host = host
        self.port = port
    }

    public var isSupported: Bool { if case .supported = support { true } else { false } }

    public var support: Support {
        guard let raop else { return .unsupported(Self.airPlay2Only) }
        if raop.needsPassword {
            return .unsupported(String(localized: "Needs a password — not supported yet", comment: "Output list: an AirPlay receiver protected by a password (Vespertine can't send to it yet)."))
        }
        let encryption: RAOPEncryption
        if raop.encryptions.contains(0) { encryption = .none } else if raop.encryptions.contains(1) { encryption = .rsa } else {
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
