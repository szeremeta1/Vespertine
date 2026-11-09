//
// Vespertine: speaker groups when a DAC is plugged into another USB port. Core Audio's UID for a USB device holds the port's
// location ID, so a group's saved members stop matching. They are found again by the UID without the location, only when one
// device fits, and the saved group is rewritten. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group USB port")
struct GroupUSBPortTests {
    private let k11Old = "AppleUSBAudioEngine:FIIO:FiiO K11:140000:2"
    private let k11New = "AppleUSBAudioEngine:FIIO:FiiO K11:2144400:2"
    private let zd3Old = "AppleUSBAudioEngine:Fosi Audio:Fosi Audio ZD3:1100000:1"
    private let zd3New = "AppleUSBAudioEngine:Fosi Audio:Fosi Audio ZD3:2142200:1"

    private func device(_ uid: String, _ name: String, id: AudioObjectID, transport: Transport = .usb) -> OutputDevice {
        let caps = DeviceCapabilities(sampleRates: [44_100, 48_000],
                                      physicalFormats: [PhysicalFormat(minRate: 44_100, maxRate: 48_000, bitDepth: 32, isInteger: true, isMixable: false, channels: 2)],
                                      outputChannels: 2, supportsDoP: false)
        return OutputDevice(id: id, uid: uid, name: name, manufacturer: "", modelUID: nil, transport: transport, nominalSampleRate: 48_000,
                            capabilities: caps, hasHardwareVolume: true, isDefault: false)
    }

    private func group(_ zd3: String, _ k11: String, profile: UUID? = nil) -> SpeakerGroup {
        SpeakerGroup(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000118")!, name: "Bar 118",
                     members: [SpeakerGroup.Member(deviceUID: zd3, name: "Fosi ZD3", channelCount: 2, skewMs: 1.5),
                               SpeakerGroup.Member(deviceUID: k11, name: "FiiO K11", channelCount: 2, rateTrimPPM: 13.5)],
                     clockLeaderUID: k11,
                     speakers: [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: zd3, channel: 0, position: Point2D(x: -1, y: 2), trimDB: -1),
                                SpeakerGroup.Speaker(role: .frontRight, deviceUID: zd3, channel: 1, position: Point2D(x: 1, y: 2)),
                                SpeakerGroup.Speaker(role: .backLeft, deviceUID: k11, channel: 0, position: Point2D(x: -1, y: -2)),
                                SpeakerGroup.Speaker(role: .backRight, deviceUID: k11, channel: 1, position: Point2D(x: 1, y: -2))],
                     alignmentProfileID: profile)
    }

    // MARK: The key

    @Test("The key is the UID without its location ID: the same DAC on two ports has one key")
    func key() {
        #expect(USBDeviceUID.portIndependentKey(k11Old) == USBDeviceUID.portIndependentKey(k11New))
        #expect(USBDeviceUID.portIndependentKey(zd3Old) == USBDeviceUID.portIndependentKey(zd3New))
        #expect(USBDeviceUID.portIndependentKey(k11Old) != USBDeviceUID.portIndependentKey(zd3Old))
        #expect(USBDeviceUID.portIndependentKey(k11Old) != nil)
    }

    @Test("The interface index stays in the key: two interfaces of one DAC are two outputs")
    func keyKeepsInterface() {
        #expect(USBDeviceUID.portIndependentKey("AppleUSBAudioEngine:FIIO:FiiO K11:140000:2")
                != USBDeviceUID.portIndependentKey("AppleUSBAudioEngine:FIIO:FiiO K11:140000:3"))
    }

    @Test("UIDs that aren't a USB audio engine's, or don't have the shape, have no key")
    func noKey() {
        for uid in ["BuiltInSpeakerDevice", "fosi-uid", "AA-BB-CC-DD-EE-FF:output", "vespertine-group:0A1B2C3D-0000-4000-8000-000000000001",
                    "AppleUSBAudioEngine:FIIO:FiiO K11:2", "AppleUSBAudioEngine:FIIO:FiiO K11:SN-77:2", "AppleUSBAudioEngine:FIIO:FiiO K11::2", ""] {
            #expect(USBDeviceUID.portIndependentKey(uid) == nil, "\(uid)")
        }
    }

    // MARK: Finding the members on another port

    @Test("Replugged on other ports, both DACs are found: the group is ready")
    func replugReconnects() {
        let zd3 = device(zd3New, "Fosi ZD3", id: 10), k11 = device(k11New, "FiiO K11", id: 11)
        guard case .ready(_, let members) = GroupOutput.resolve(group(zd3Old, k11Old), among: [k11, zd3]) else {
            Issue.record("still waiting"); return
        }
        #expect(members.map(\.uid) == [zd3New, k11New], "in the group's order")
        #expect(GroupOutputRows.rows(groups: [group(zd3Old, k11Old)], devices: [zd3, k11]).first?.isReady == true)
        #expect(GroupOutput.connectedUIDs(of: [group(zd3Old, k11Old)], connected: Set([zd3, k11].map(\.uid))) == [group(zd3Old, k11Old).outputUID])
    }

    @Test("The saved group is rewritten to the new UIDs: members, speakers and the clock leader, and nothing else changes")
    func rewrite() throws {
        let original = group(zd3Old, k11Old, profile: UUID())
        let zd3 = device(zd3New, "Fosi ZD3", id: 10), k11 = device(k11New, "FiiO K11", id: 11)
        let moved = try #require(original.followingUSBPorts(among: [zd3, k11]))
        #expect(moved.members.map(\.deviceUID) == [zd3New, k11New])
        #expect(moved.speakers.map(\.deviceUID) == [zd3New, zd3New, k11New, k11New])
        #expect(moved.clockLeaderUID == k11New)
        #expect(moved.id == original.id && moved.outputUID == original.outputUID, "the same output: its settings and room profile stay bound")
        #expect(moved.alignmentProfileID == original.alignmentProfileID)
        #expect(moved.members.map(\.skewMs) == [1.5, 0] && moved.members[1].rateTrimPPM == 13.5, "measurements stay with their DACs")
        #expect(moved.speakers.map(\.id) == original.speakers.map(\.id) && moved.speakers[0].trimDB == -1)
        #expect(moved.isValid)
    }

    @Test("One DAC moved: only it is rewritten; the one that is where it was is left alone")
    func oneMoved() throws {
        let zd3 = device(zd3Old, "Fosi ZD3", id: 10), k11 = device(k11New, "FiiO K11", id: 11)
        let moved = try #require(group(zd3Old, k11Old).followingUSBPorts(among: [zd3, k11]))
        #expect(moved.members.map(\.deviceUID) == [zd3Old, k11New])
        #expect(moved.clockLeaderUID == k11New)
    }

    @Test("Two identical DACs present: it can't be said which is which, so the group stays waiting and nothing is rewritten")
    func ambiguous() {
        let a = device("AppleUSBAudioEngine:FIIO:FiiO K11:2144400:2", "FiiO K11", id: 11)
        let b = device("AppleUSBAudioEngine:FIIO:FiiO K11:2142200:2", "FiiO K11", id: 12)
        let zd3 = device(zd3Old, "Fosi ZD3", id: 10)
        let g = group(zd3Old, k11Old)
        #expect(GroupOutput.resolve(g, among: [zd3, a, b]) == .missing(["FiiO K11"]))
        #expect(g.followingUSBPorts(among: [zd3, a, b]) == nil)
        #expect(GroupOutputRows.rows(groups: [g], devices: [zd3, a, b]).first?.isReady == false)
        #expect(GroupOutput.connectedUIDs(of: [g], connected: Set([zd3, a, b].map(\.uid))).isEmpty)
    }

    @Test("A group of two identical DACs with one present doesn't take it for both")
    func twinsOnePresent() {
        let twinA = "AppleUSBAudioEngine:FIIO:FiiO K11:140000:2", twinB = "AppleUSBAudioEngine:FIIO:FiiO K11:150000:2"
        let g = SpeakerGroup(name: "Twins", members: [SpeakerGroup.Member(deviceUID: twinA, name: "FiiO K11", channelCount: 2),
                                                      SpeakerGroup.Member(deviceUID: twinB, name: "FiiO K11", channelCount: 2)], clockLeaderUID: twinA)
        let present = device("AppleUSBAudioEngine:FIIO:FiiO K11:2144400:2", "FiiO K11", id: 11)
        #expect(g.followingUSBPorts(among: [present]) == nil)
        #expect(GroupOutput.resolve(g, among: [present]) == .missing(["FiiO K11", "FiiO K11"]))
    }

    @Test("A group of two identical DACs, one where it was and one moved: the moved one is found, the other stays")
    func twinsOneMoved() throws {
        let twinA = "AppleUSBAudioEngine:FIIO:FiiO K11:140000:2", twinB = "AppleUSBAudioEngine:FIIO:FiiO K11:150000:2"
        let g = SpeakerGroup(name: "Twins", members: [SpeakerGroup.Member(deviceUID: twinA, name: "FiiO K11", channelCount: 2),
                                                      SpeakerGroup.Member(deviceUID: twinB, name: "FiiO K11", channelCount: 2)], clockLeaderUID: twinA)
        let a = device(twinA, "FiiO K11", id: 11), b = device("AppleUSBAudioEngine:FIIO:FiiO K11:2144400:2", "FiiO K11", id: 12)
        let moved = try #require(g.followingUSBPorts(among: [a, b]))
        #expect(moved.members.map(\.deviceUID) == [twinA, b.uid])
        #expect(moved.clockLeaderUID == twinA)
    }

    @Test("A member that is there under its saved UID is never replaced, even with another of its model plugged in")
    func exactWins() {
        let zd3 = device(zd3Old, "Fosi ZD3", id: 10), k11 = device(k11Old, "FiiO K11", id: 11)
        let other = device(k11New, "FiiO K11", id: 12)
        #expect(group(zd3Old, k11Old).followingUSBPorts(among: [zd3, k11, other]) == nil)
        guard case .ready(_, let members) = GroupOutput.resolve(group(zd3Old, k11Old), among: [other, zd3, k11]) else { Issue.record("not ready"); return }
        #expect(members.map(\.uid) == [zd3Old, k11Old])
    }

    @Test("A DAC of another model on the saved one's port isn't taken for it")
    func otherModel() {
        let zd3 = device(zd3New, "Fosi ZD3", id: 10), stranger = device("AppleUSBAudioEngine:FIIO:FiiO K9:2144400:2", "FiiO K9", id: 11)
        #expect(group(zd3Old, k11Old).followingUSBPorts(among: [zd3, stranger])?.members.map(\.deviceUID) == [zd3New, k11Old])
        #expect(GroupOutput.resolve(group(zd3Old, k11Old), among: [zd3, stranger]) == .missing(["FiiO K11"]), "the ZD3 is found on its new port; the K9 isn't the K11")
    }

    @Test("A UID that isn't a USB one is only ever matched exactly")
    func nonUSBUnchanged() {
        let g = SpeakerGroup(name: "Mixed", members: [SpeakerGroup.Member(deviceUID: "fosi-uid", name: "Fosi", channelCount: 2),
                                                      SpeakerGroup.Member(deviceUID: "AA-BB-CC-DD-EE-FF:output", name: "Buds", channelCount: 2)],
                             clockLeaderUID: "fosi-uid")
        let near = [device("fosi-uid-2", "Fosi", id: 10), device("AA-BB-CC-DD-EE-00:output", "Buds", id: 11, transport: .bluetooth)]
        #expect(g.followingUSBPorts(among: near) == nil)
        #expect(GroupOutput.resolve(g, among: near) == .missing(["Fosi", "Buds"]))
        let exact = [device("fosi-uid", "Fosi", id: 10), device("AA-BB-CC-DD-EE-FF:output", "Buds", id: 11, transport: .bluetooth)]
        #expect(g.followingUSBPorts(among: exact) == nil)
        guard case .ready = GroupOutput.resolve(g, among: exact) else { Issue.record("not ready"); return }
    }

    @Test("A degraded group (set to carry on) also finds a member on another port")
    func degraded() {
        var g = group(zd3Old, k11Old)
        g.onMemberLoss = .continueOnRemaining
        let zd3 = device(zd3New, "Fosi ZD3", id: 10), k11 = device(k11New, "FiiO K11", id: 11)
        guard case .ready(_, let members) = GroupOutput.resolveDegraded(g, among: [zd3, k11]) else { Issue.record("not ready"); return }
        #expect(members.count == 2)
    }

    // MARK: Keeping it

    @Test("The book rewrites its groups once, and says so only when something changed")
    func bookFollows() {
        var book = SpeakerGroupBook(groups: [group(zd3Old, k11Old)])
        let present = [device(zd3New, "Fosi ZD3", id: 10), device(k11New, "FiiO K11", id: 11)]
        let first = book.followUSBPorts(among: present)
        #expect(first)
        #expect(book.groups[0].members.map(\.deviceUID) == [zd3New, k11New])
        let again = book.followUSBPorts(among: present)
        #expect(!again)
        let unplugged = book.followUSBPorts(among: [])
        #expect(!unplugged, "unplugged: nothing to go by, nothing changes")
        #expect(book.groups[0].members.map(\.deviceUID) == [zd3New, k11New])
    }

    @Test("The rewrite survives a save and a load")
    func persists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usbport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = SpeakerGroupBook(groups: [group(zd3Old, k11Old)])
        book.followUSBPorts(among: [device(zd3New, "Fosi ZD3", id: 10), device(k11New, "FiiO K11", id: 11)])
        let store = SpeakerGroupStore(directory: dir)
        try store.save(book.groups, unreadable: [])
        let loaded = try #require(store.load())
        #expect(loaded.groups == book.groups)
        #expect(loaded.groups[0].clockLeaderUID == k11New)
    }
}
