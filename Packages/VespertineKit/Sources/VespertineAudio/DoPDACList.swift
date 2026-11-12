//
// Vespertine: the list of DACs known to decode DoP, and of makers known for DSD DACs.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import os

/// What identifies a connected USB DAC. The Core Audio UID of a USB DAC is
/// `AppleUSBAudioEngine:<vendor>:<product>:<serial>:<interface>`: the vendor and product are the names the DAC's own USB
/// descriptors give, the serial and interface differ per unit and port. Matching never looks at those two. The USB
/// vendor and product ID are the stronger identity where they can be read (`USBIdentity`).
public struct DoPDeviceIdentity: Sendable, Hashable {
    public var uid: String
    public var usbVendorID: UInt16?
    public var usbProductID: UInt16?

    public init(uid: String, usbVendorID: UInt16? = nil, usbProductID: UInt16? = nil) {
        self.uid = uid
        self.usbVendorID = usbVendorID
        self.usbProductID = usbProductID
    }

    private var uidParts: [Substring]? {
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        // Exactly vendor, product, serial and interface after the engine name: a name with a colon in it would make the
        // split ambiguous, so it matches nothing by name (its USB ID, if known, still can).
        return parts.count == 5 && parts[0] == "AppleUSBAudioEngine" ? parts : nil
    }

    /// The vendor name in the UID, nil for a UID that isn't a USB audio engine's.
    public var uidVendor: String? { uidParts.map { String($0[1]) } }
    /// The product name in the UID.
    public var uidProduct: String? { uidParts.map { String($0[2]) } }
}

/// A DAC confirmed to decode DoP.
public struct DoPKnownDAC: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The vendor and product as they appear in the Core Audio UID (both needed).
    public var uidVendor: String?
    public var uidProduct: String?
    /// USB vendor and product ID in hex ("152a", "889b"; both needed).
    public var usbVendorID: String?
    public var usbProductID: String?
    /// How it is known: `hardware` (the maintainer or a reporter played DSD over DoP on it), `owner-report`, or
    /// `manufacturer` (the maker's own page says DoP).
    public var evidence: String
    /// Where each claim comes from: an https link (the maker's spec page, the issue, the repository's device notes), with
    /// a few words on what it shows. JSON has no comments, so this is the comment field. No source, no entry.
    public var source: String
    public var note: String?

    var vendorProductIDs: (UInt16, UInt16)? { DoPDACList.hex(usbVendorID).flatMap { v in DoPDACList.hex(usbProductID).map { (v, $0) } } }
    var hasNamePair: Bool { !(uidVendor ?? "").isEmpty && !(uidProduct ?? "").isEmpty }
    public var hasMatchKey: Bool { hasNamePair || vendorProductIDs != nil }
    var isValid: Bool { !id.isEmpty && source.hasPrefix("https://") && hasMatchKey }
}

/// A maker whose USB DACs are known to play DSD. It is a hint, not proof: a DAC of a listed maker that isn't in the
/// DAC list is only suggested a test.
public struct DSDMaker: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var usbVendorID: String?
    /// The vendor names that appear in the Core Audio UIDs of this maker's DACs, where known.
    public var uidVendors: [String]?
    public var source: String

    var hasMatchKey: Bool { DoPDACList.hex(usbVendorID) != nil || !(uidVendors ?? []).isEmpty }
    var isValid: Bool { !id.isEmpty && source.hasPrefix("https://") && hasMatchKey }
}

public struct DoPDACList: Codable, Sendable, Hashable {
    /// The newest file format this build reads.
    public static let supportedSchema = 1

    public var schema: Int
    /// Rises with every published list; an online list is only taken if it is newer than what is already held.
    public var revision: Int
    public var dacs: [DoPKnownDAC]
    public var makers: [DSDMaker]
    /// Ids withdrawn by an online list.
    public var revoked: [String]

    public struct Invalid: Error, Equatable { public var why: String }

    public init(schema: Int = DoPDACList.supportedSchema, revision: Int, dacs: [DoPKnownDAC], makers: [DSDMaker], revoked: [String] = []) {
        self.schema = schema; self.revision = revision; self.dacs = dacs; self.makers = makers; self.revoked = revoked
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        revision = try c.decode(Int.self, forKey: .revision)
        dacs = try c.decodeIfPresent([DoPKnownDAC].self, forKey: .dacs) ?? []
        makers = try c.decodeIfPresent([DSDMaker].self, forKey: .makers) ?? []
        revoked = try c.decodeIfPresent([String].self, forKey: .revoked) ?? []
    }

    /// Reads a list file. A newer schema than this build knows is refused; entries without a source or with nothing to
    /// match on are dropped rather than trusted.
    public static func decode(_ data: Data) throws -> DoPDACList {
        var list = try JSONDecoder().decode(DoPDACList.self, from: data)
        guard list.schema <= supportedSchema else { throw Invalid(why: "schema \(list.schema)") }
        list.dacs = list.dacs.filter(\.isValid)
        list.makers = list.makers.filter(\.isValid)
        return list
    }

    static func hex(_ text: String?) -> UInt16? {
        guard var t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        if t.hasPrefix("0x") { t.removeFirst(2) }
        return UInt16(t, radix: 16)
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The listed DAC this is, by USB vendor and product ID or by the vendor and product names in its UID. The serial
    /// and interface in the UID are never read.
    public func knownDAC(for identity: DoPDeviceIdentity) -> DoPKnownDAC? {
        dacs.first { dac in
            if let ids = dac.vendorProductIDs, let v = identity.usbVendorID, let p = identity.usbProductID, ids == (v, p) { return true }
            return dac.hasNamePair && Self.same(dac.uidVendor, identity.uidVendor) && Self.same(dac.uidProduct, identity.uidProduct)
        }
    }

    /// The listed DSD maker of this device, by USB vendor ID or by the vendor name in its UID.
    public func maker(for identity: DoPDeviceIdentity) -> DSDMaker? {
        makers.first { maker in
            if let id = DoPDACList.hex(maker.usbVendorID), let v = identity.usbVendorID, id == v { return true }
            return (maker.uidVendors ?? []).contains { Self.same($0, identity.uidVendor) }
        }
    }

    /// This list with an online one on top: its entries replace same-id ones and add new ones, and its `revoked` ids
    /// are taken out. The bundled entries stay unless withdrawn.
    func merging(_ online: DoPDACList) -> DoPDACList {
        func merged<T: Identifiable>(_ base: [T], _ over: [T]) -> [T] where T.ID == String {
            var result = base.filter { b in !over.contains { $0.id == b.id } } + over
            result.removeAll { online.revoked.contains($0.id) }
            return result
        }
        return DoPDACList(schema: schema, revision: max(revision, online.revision), dacs: merged(dacs, online.dacs),
                          makers: merged(makers, online.makers), revoked: [])
    }

    /// The list that ships inside the app (`Resources/dop-dacs.json`). Empty only if the file is missing from the build,
    /// which the tests catch.
    public static let bundled: DoPDACList = {
        guard let url = Bundle.module.url(forResource: "dop-dacs", withExtension: "json"),
              let data = try? Data(contentsOf: url), let list = try? decode(data) else {
            Logger(subsystem: "org.szeremeta.vespertine.player", category: "audio").error("the bundled DoP DAC list is missing or unreadable")
            return DoPDACList(revision: 0, dacs: [], makers: [])
        }
        return list
    }()
}
