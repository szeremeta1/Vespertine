//
// Vespertine: the known-DAC list (matching, the bundled file) and its optional signed online update.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
@testable import VespertineAudio

private func uid(_ vendor: String, _ product: String, serial: String = "0000000", port: Int = 1) -> String {
    "AppleUSBAudioEngine:\(vendor):\(product):\(serial):\(port)"
}

private func listJSON(revision: Int, dacs: [String] = [], makers: [String] = [], revoked: [String] = [], schema: Int = 1) -> Data {
    let r = revoked.map { "\"\($0)\"" }.joined(separator: ",")
    return Data("""
    {"schema":\(schema),"revision":\(revision),"dacs":[\(dacs.joined(separator: ","))],"makers":[\(makers.joined(separator: ","))],"revoked":[\(r)]}
    """.utf8)
}

private func dacJSON(id: String, vendor: String = "Acme", product: String, vid: String? = nil, pid: String? = nil,
                     source: String = "https://example.com/spec") -> String {
    var fields = ["\"id\":\"\(id)\"", "\"name\":\"\(product)\"", "\"evidence\":\"manufacturer\"", "\"source\":\"\(source)\""]
    if vid == nil { fields += ["\"uidVendor\":\"\(vendor)\"", "\"uidProduct\":\"\(product)\""] }
    if let vid, let pid { fields += ["\"usbVendorID\":\"\(vid)\"", "\"usbProductID\":\"\(pid)\""] }
    return "{" + fields.joined(separator: ",") + "}"
}

@Suite("DoP known-DAC list: matching")
struct DoPDACListMatchingTests {
    let list = try! DoPDACList.decode(listJSON(revision: 1, dacs: [
        dacJSON(id: "acme-one", product: "Acme One"),
        dacJSON(id: "by-id", product: "By ID", vid: "152a", pid: "889b"),
    ], makers: [
        #"{"id":"acme","name":"Acme Audio","usbVendorID":"1234","uidVendors":["Acme"],"source":"https://example.com/acme"}"#,
    ]))

    @Test("The unit serial and the USB port in the UID are ignored")
    func serialIgnored() {
        for (serial, port) in [("0000000", 1), ("ZZ99", 2), ("14100000", 7)] {
            #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("Acme", "Acme One", serial: serial, port: port))) != nil)
        }
    }

    @Test("A serial that spells another model's name doesn't match it")
    func serialIsNotAName() {
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("Acme", "Acme Two", serial: "Acme One"))) == nil)
    }

    @Test("Vendor and model both have to match, ignoring case")
    func vendorAndModel() {
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("ACME", "acme one"))) != nil)
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("Other", "Acme One"))) == nil)
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("Acme", "Acme One Plus"))) == nil)
    }

    @Test("USB vendor and product ID match by themselves, and both are needed")
    func vidPid() {
        let name = uid("Whatever", "Renamed")
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: name, usbVendorID: 0x152a, usbProductID: 0x889b))?.id == "by-id")
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: name, usbVendorID: 0x152a, usbProductID: 0x0001)) == nil)
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: name, usbVendorID: 0x152a, usbProductID: nil)) == nil)
    }

    @Test("A UID that isn't a USB audio engine's matches nothing by name")
    func notUSBUID() {
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: "BuiltInSpeakerDevice")) == nil)
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: "Acme:Acme One:1")) == nil)
    }

    @Test("A maker matches by USB vendor ID or by the vendor name in the UID")
    func makers() {
        #expect(list.maker(for: DoPDeviceIdentity(uid: uid("Acme", "Unlisted DAC")))?.name == "Acme Audio")
        #expect(list.maker(for: DoPDeviceIdentity(uid: uid("x", "y"), usbVendorID: 0x1234, usbProductID: 1))?.name == "Acme Audio")
        #expect(list.maker(for: DoPDeviceIdentity(uid: uid("Other", "DAC"))) == nil)
    }

    @Test("Entries without a source, or with nothing to match on, are dropped")
    func invalidEntriesDropped() throws {
        let noSource = #"{"id":"a","name":"A","uidVendor":"V","uidProduct":"P","evidence":"manufacturer","source":""}"#
        let noKey = #"{"id":"b","name":"B","evidence":"manufacturer","source":"https://example.com"}"#
        let notHTTPS = #"{"id":"c","name":"C","uidVendor":"V","uidProduct":"P","evidence":"manufacturer","source":"file:///etc/passwd"}"#
        let ok = dacJSON(id: "d", product: "D")
        let decoded = try DoPDACList.decode(listJSON(revision: 1, dacs: [noSource, noKey, notHTTPS, ok]))
        #expect(decoded.dacs.map(\.id) == ["d"])
    }

    @Test("A schema this build doesn't know is refused")
    func newerSchema() {
        #expect(throws: (any Error).self) { try DoPDACList.decode(listJSON(revision: 1, schema: 99)) }
    }
}

@Suite("DoP known-DAC list: the bundled file")
struct DoPBundledListTests {
    @Test("Every bundled entry has an https source and something to match on, and ids are unique")
    func everyEntryIsCited() throws {
        let list = DoPDACList.bundled
        #expect(!list.dacs.isEmpty)
        for dac in list.dacs {
            #expect(dac.source.hasPrefix("https://"), "\(dac.id) needs a cited source")
            #expect(dac.hasMatchKey, "\(dac.id) needs a vendor+model or a USB ID")
        }
        for maker in list.makers { #expect(maker.source.hasPrefix("https://"), "\(maker.id) needs a cited source") }
        #expect(Set(list.dacs.map(\.id)).count == list.dacs.count)
        #expect(Set(list.makers.map(\.id)).count == list.makers.count)
    }

    @Test("The DACs on the old allow list, and the iBasso DC07 Pro (issue #247), are in it")
    func seeded() {
        let list = DoPDACList.bundled
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("FIIO", "FiiO K11"))) != nil)
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("XMOS", "Fosi Audio ZD3"))) != nil)
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("iBasso", "iBasso DC07 Pro", serial: "1234567"))) != nil)
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: uid("iBasso", "iBasso DC03 Pro"))) == nil)
    }

    @Test("DoPDefaults answers from the list, with the serial ignored")
    func defaultsUseList() {
        #expect(DoPDefaults.isKnownDoP(uid: uid("iBasso", "iBasso DC07 Pro", serial: "ABC", port: 3)))
        #expect(DoPDefaults.isKnownDoP(uid: uid("XMOS", "Fosi Audio ZD3", serial: "9999999", port: 3)))
        #expect(!DoPDefaults.isKnownDoP(uid: uid("XMOS", "Fosi Audio ZD2")))
    }
}

@Suite("DoP known-DAC list: online update and cache")
struct DoPDACListStoreTests {
    struct Failure: Error {}

    /// A throwaway signing key, its public half as the store takes it, and a folder for the cache.
    struct Rig {
        let key = Curve25519.Signing.PrivateKey()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dop-list-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "dop-list-\(UUID().uuidString)")!
        var publicKey: Data { key.publicKey.rawRepresentation }
        func sign(_ data: Data) -> Data { Data(try! key.signature(for: data).base64EncodedString().utf8) }

        func store(serving: [URL: Data]? = nil, error: Bool = false, key publicKey: Data? = nil, now: @escaping @Sendable () -> Date = { Date() },
                   bundled: DoPDACList = try! DoPDACList.decode(listJSON(revision: 5, dacs: [dacJSON(id: "bundled", product: "Bundled DAC")]))) -> DoPDACListStore {
            let served = serving
            return DoPDACListStore(bundled: bundled, cacheDirectory: folder, publicKey: publicKey ?? self.publicKey,
                                   endpoints: .init(list: URL(string: "https://example.com/l.json")!, signature: URL(string: "https://example.com/l.sig")!),
                                   defaults: defaults, now: now,
                                   fetch: { url in
                                       if error { throw Failure() }
                                       guard let data = served?[url] else { throw Failure() }
                                       return data
                                   })
        }
        func served(_ list: Data, signed: Data? = nil) -> [URL: Data] {
            [URL(string: "https://example.com/l.json")!: list, URL(string: "https://example.com/l.sig")!: signed ?? sign(list)]
        }
    }

    static let online = listJSON(revision: 6, dacs: [dacJSON(id: "online", product: "Online DAC")])

    @Test("Offline: the bundled list stays, and refresh says why")
    func offlineKeepsBundled() async {
        let rig = Rig()
        let store = rig.store(error: true)
        let outcome = await store.refresh(force: true)
        #expect(outcome == .failed)
        #expect(store.list.dacs.map(\.id) == ["bundled"])
    }

    @Test("A signed, newer list is used alongside the bundled one, and cached")
    func signedNewerApplies() async {
        let rig = Rig()
        let store = rig.store(serving: rig.served(Self.online))
        #expect(await store.refresh(force: true) == .updated(revision: 6))
        #expect(Set(store.list.dacs.map(\.id)) == ["bundled", "online"])
        // A fresh store (next launch, offline) reads the cache.
        let next = rig.store(error: true)
        next.loadCache()
        #expect(Set(next.list.dacs.map(\.id)) == ["bundled", "online"])
    }

    @Test("A list with a wrong signature is ignored and not cached")
    func badSignatureRejected() async {
        let rig = Rig()
        let other = Curve25519.Signing.PrivateKey()
        let forged = Data(try! other.signature(for: Self.online).base64EncodedString().utf8)
        let store = rig.store(serving: rig.served(Self.online, signed: forged))
        #expect(await store.refresh(force: true) == .rejected)
        #expect(store.list.dacs.map(\.id) == ["bundled"])
        let next = rig.store(error: true)
        next.loadCache()
        #expect(next.list.dacs.map(\.id) == ["bundled"])
    }

    @Test("Without a pinned key nothing online is accepted")
    func noKeyNoUpdate() async {
        let rig = Rig()
        let list = rig.store(serving: rig.served(Self.online), key: Data())
        #expect(await list.refresh(force: true) == .rejected)
        #expect(list.list.dacs.map(\.id) == ["bundled"])
    }

    @Test("A list that is not newer than the bundled one is ignored")
    func olderRejected() async {
        let rig = Rig()
        let old = listJSON(revision: 5, dacs: [dacJSON(id: "online", product: "Online DAC")])
        let store = rig.store(serving: rig.served(old))
        #expect(await store.refresh(force: true) == .notNewer)
        #expect(store.list.dacs.map(\.id) == ["bundled"])
    }

    @Test("A cache edited on disk (signature no longer fits) is ignored")
    func tamperedCacheIgnored() async throws {
        let rig = Rig()
        let first = rig.store(serving: rig.served(Self.online))
        _ = await first.refresh(force: true)
        let cached = rig.folder.appendingPathComponent("dop-dacs.json")
        try Data(contentsOf: cached).replacing(Data("Online DAC".utf8), with: Data("Evil DAC!!".utf8)).write(to: cached)
        let next = rig.store(error: true)
        next.loadCache()
        #expect(next.list.dacs.map(\.id) == ["bundled"])
    }

    @Test("A corrupt or missing cache is ignored")
    func corruptCacheIgnored() throws {
        let rig = Rig()
        let empty = rig.store(error: true)
        empty.loadCache()
        #expect(empty.list.dacs.map(\.id) == ["bundled"])
        try FileManager.default.createDirectory(at: rig.folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: rig.folder.appendingPathComponent("dop-dacs.json"))
        try Data("zzz".utf8).write(to: rig.folder.appendingPathComponent("dop-dacs.json.sig"))
        let broken = rig.store(error: true)
        broken.loadCache()
        #expect(broken.list.dacs.map(\.id) == ["bundled"])
    }

    @Test("The online list can withdraw an entry, but only a signed one")
    func revoked() async {
        let rig = Rig()
        let withdraw = listJSON(revision: 6, revoked: ["bundled"])
        let store = rig.store(serving: rig.served(withdraw))
        _ = await store.refresh(force: true)
        #expect(store.list.dacs.isEmpty)
    }

    @Test("It checks at most once a day unless forced")
    func throttled() async {
        let rig = Rig()
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let store = rig.store(error: true, now: { clock.withLock { $0 } })
        #expect(await store.refresh() == .failed)
        #expect(await store.refresh() == .skipped)
        clock.withLock { $0 = $0.addingTimeInterval(25 * 3600) }
        #expect(await store.refresh() == .failed)
    }
}
