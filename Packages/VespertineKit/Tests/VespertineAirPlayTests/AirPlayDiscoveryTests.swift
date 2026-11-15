//
// Vespertine: finding AirPlay receivers, and the switch that keeps it all off by default.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAirPlay

/// Stands in for Bonjour: counts starts and stops, and reports what a test tells it to.
final class FakeBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([BonjourResult]) -> Void)?
    private var _starts = 0, _stops = 0
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var isBrowsing: Bool { lock.withLock { handler != nil } }

    func start(onChange: @escaping @Sendable ([BonjourResult]) -> Void) { lock.withLock { _starts += 1; handler = onChange } }
    func stop() { lock.withLock { _stops += 1; handler = nil } }
    func report(_ results: [BonjourResult]) { lock.withLock { handler }?(results) }
}

@Suite("AirPlay discovery", .serialized)
struct AirPlayDiscoveryTests {
    static let moode = BonjourResult(service: BonjourService(name: "B827EB000001@moOde", type: "_raop._tcp"), txt: RAOPRecordTests.shairport)
    static let moodeAP2 = BonjourResult(service: BonjourService(name: "moOde", type: "_airplay._tcp"), txt: ["deviceid": "B8:27:EB:00:00:01", "model": "Shairport Sync"])
    static let homepod = BonjourResult(service: BonjourService(name: "Kitchen", type: "_airplay._tcp"), txt: ["deviceid": "AA:00:00:00:00:02"])
    static let mac = BonjourResult(service: BonjourService(name: "AA00000000FF@Studio Mac", type: "_raop._tcp"), txt: ["et": "0,3,5"])

    @Test("Both service types of one device become one entry; AirPlay 2-only devices are listed; this Mac isn't")
    func merge() {
        let list = AirPlayDiscovery.merge([Self.moode, Self.moodeAP2, Self.homepod, Self.mac], excluding: "Studio Mac")
        #expect(list.map(\.name) == ["Kitchen", "moOde"])
        let moode = list[1]
        #expect(moode.raop != nil && moode.airplay != nil)
        #expect(moode.service?.type == "_raop._tcp")
        #expect(moode.isSupported)
        #expect(!list[0].isSupported)
    }

    @Test("Off by default: nothing is browsed until the service is enabled")
    func offByDefault() async {
        let browser = FakeBrowser()
        let service = AirPlayService(discovery: AirPlayDiscovery(browser: browser, excludedName: nil))
        #expect(!service.isEnabled)
        #expect(!service.discovery.isRunning)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(browser.starts == 0)
    }

    @Test("On browses and lists; off stops browsing and empties the list; a quick on-off-on ends on")
    func onOff() async {
        let browser = FakeBrowser()
        let service = AirPlayService(discovery: AirPlayDiscovery(browser: browser, excludedName: nil))
        let seen = Locked([String]())
        service.discovery.onChange = { list in seen.withLock { $0 = list.map(\.name) } }
        await service.setEnabled(true)
        #expect(browser.isBrowsing)
        browser.report([Self.moode])
        #expect(service.discovery.devices.map(\.name) == ["moOde"])
        #expect(seen.withLock { $0 } == ["moOde"])
        #expect(service.discovery.hasAnswered)
        await service.setEnabled(false)
        #expect(!browser.isBrowsing)
        #expect(service.discovery.devices.isEmpty)
        browser.report([Self.moode])   // late answer from a stopped browser
        #expect(service.discovery.devices.isEmpty)
        service.want(true); service.want(false); service.want(true)
        await service.settled()
        #expect(browser.isBrowsing)
        #expect(service.discovery.isRunning)
        await service.setEnabled(false)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
