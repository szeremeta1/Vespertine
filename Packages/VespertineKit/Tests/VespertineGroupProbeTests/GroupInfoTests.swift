//
// Vespertine: Phase 0 of multi-DAC speaker groups: `vespertine-probe group-info`, the read-only report on a set of
// output devices (clock domains, rates, latencies, hog owners) and what it means for combining them.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineGroupProbe

@Suite("Group info")
struct GroupInfoTests {
    static func member(_ name: String, uid: String? = nil, transport: Transport = .usb, channels: Int = 2, rate: Double = 48_000,
                       rates: [Double] = [44_100, 48_000, 88_200, 96_000], domain: UInt32 = 0, latency: UInt32 = 0, safety: UInt32 = 0,
                       streamLatency: [UInt32] = [0], buffer: UInt32 = 512, hog: Int32 = -1, alive: Bool = true) -> MemberInfo {
        MemberInfo(uid: uid ?? "uid-\(name)", name: name, transport: transport, outputChannels: channels, streamChannels: [channels],
                   nominalRate: rate, rates: rates, clockDomain: domain, deviceLatencyFrames: latency, safetyOffsetFrames: safety,
                   streamLatencyFrames: streamLatency, bufferFrames: buffer, hogPID: hog, isAlive: alive, runningSomewhere: false,
                   hasHardwareVolume: false)
    }

    // MARK: Naming a device

    @Test func exactUIDWins() {
        let list = [(uid: "A", name: "Fosi"), (uid: "B", name: "A")]
        #expect(DeviceMatcher.resolve("A", in: list) == .found(0))
    }

    @Test func exactNameBeatsLongerNames() {
        let list = [(uid: "u1", name: "BlackHole 2ch Extra"), (uid: "u2", name: "BlackHole 2ch")]
        #expect(DeviceMatcher.resolve("blackhole 2ch", in: list) == .found(1))
    }

    @Test func aUniquePartOfTheNameWorks() {
        let list = [(uid: "u1", name: "FiiO K11"), (uid: "u2", name: "Fosi Audio ZD3")]
        #expect(DeviceMatcher.resolve("zd3", in: list) == .found(1))
    }

    @Test func anAmbiguousNameIsRefusedNotGuessed() {
        let list = [(uid: "u1", name: "BlackHole 2ch"), (uid: "u2", name: "BlackHole 16ch")]
        #expect(DeviceMatcher.resolve("BlackHole", in: list) == .ambiguous([0, 1]))
    }

    @Test func aMissingDeviceIsReported() {
        #expect(DeviceMatcher.resolve("nope", in: [(uid: "u1", name: "FiiO K11")]) == .notFound)
    }

    // MARK: Channel map and clocks

    @Test func channelsFollowTheListOrder() {
        let report = GroupInfo.analyse([Self.member("Fosi"), Self.member("FiiO", channels: 2), Self.member("Eight", channels: 8)])
        #expect(report.channelMap.map(\.first) == [0, 2, 4])
        #expect(report.channelMap.map(\.count) == [2, 2, 8])
        #expect(report.totalChannels == 12)
    }

    @Test func separateClocksMeanTheFollowersNeedDriftCorrection() {
        let report = GroupInfo.analyse([Self.member("Fosi", domain: 0), Self.member("FiiO", domain: 0)])
        #expect(report.members.map(\.needsDriftCorrection) == [false, true])
        #expect(!report.allShareLeaderClock)
    }

    @Test func aSharedNonZeroClockDomainNeedsNoDriftCorrection() {
        let report = GroupInfo.analyse([Self.member("A", domain: 7), Self.member("B", domain: 7), Self.member("C", domain: 8)])
        #expect(report.members.map(\.needsDriftCorrection) == [false, false, true])
        #expect(!report.allShareLeaderClock)
        let shared = GroupInfo.analyse([Self.member("A", domain: 7), Self.member("B", domain: 7)])
        #expect(shared.allShareLeaderClock)
    }

    @Test func clockDomainZeroNeverCountsAsShared() {
        // Zero means "no known domain", not "one domain": two zeros are two clocks.
        #expect(!GroupInfo.analyse([Self.member("A", domain: 0), Self.member("B", domain: 0)]).allShareLeaderClock)
    }

    // MARK: Rates

    @Test func commonRatesAreTheIntersection() {
        let report = GroupInfo.analyse([Self.member("A", rates: [44_100, 48_000, 96_000, 192_000]), Self.member("B", rates: [48_000, 96_000, 384_000])])
        #expect(report.commonRates == [48_000, 96_000])
    }

    @Test func noCommonRateIsABlocker() {
        let report = GroupInfo.analyse([Self.member("A", rates: [44_100]), Self.member("B", rates: [48_000])])
        #expect(report.commonRates.isEmpty)
        #expect(report.findings.contains { $0.severity == .blocker && $0.text.contains("rate") })
    }

    @Test func differentCurrentRatesAreFlagged() {
        let report = GroupInfo.analyse([Self.member("A", rate: 44_100), Self.member("B", rate: 96_000)])
        #expect(report.findings.contains { $0.severity == .warning && $0.text.contains("different rates") })
    }

    // MARK: Latency

    @Test func latencyIsTheSumOfWhatTheDeviceReportsAndComparedInMilliseconds() {
        // Leader: 48 kHz, 96 + 32 + 16 = 144 frames = 3 ms. Follower: 96 kHz, 480 + 64 + 48 = 592 frames = 6.1667 ms.
        let report = GroupInfo.analyse([Self.member("Fosi", rate: 48_000, latency: 96, safety: 32, streamLatency: [16]),
                                        Self.member("FiiO", rate: 96_000, latency: 480, safety: 64, streamLatency: [48])])
        #expect(report.members[0].reportedLatencyFrames == 144)
        #expect(abs(report.members[0].reportedLatencyMs - 3.0) < 1e-9)
        #expect(abs(report.members[1].reportedLatencyMs - 592.0 / 96.0) < 1e-9)
        #expect(abs((report.members[1].latencyVersusLeaderMs ?? 0) - (592.0 / 96.0 - 3.0)) < 1e-9)
        #expect(report.members[0].latencyVersusLeaderMs == 0)
    }

    @Test func theLargestStreamLatencyCounts() {
        let m = Self.member("Multi", latency: 10, safety: 5, streamLatency: [1, 7, 3])
        #expect(m.reportedLatencyFrames == 22)
    }

    // MARK: Who can join

    @Test func aDeviceHeldByAnotherAppCannotJoin() {
        let report = GroupInfo.analyse([Self.member("Fosi"), Self.member("FiiO", hog: 4242)], processID: 100)
        #expect(report.findings.contains { $0.severity == .blocker && $0.text.contains("4242") && $0.text.contains("FiiO") })
    }

    @Test func aDeviceHeldByThisProcessIsFine() {
        let report = GroupInfo.analyse([Self.member("Fosi", hog: 100), Self.member("FiiO")], processID: 100)
        #expect(!report.findings.contains { $0.severity == .blocker })
        #expect(report.members[0].heldByThisProcess)
    }

    @Test func aDeviceThatIsGoneIsABlocker() {
        let report = GroupInfo.analyse([Self.member("Fosi"), Self.member("FiiO", alive: false)])
        #expect(report.findings.contains { $0.severity == .blocker && $0.text.contains("FiiO") })
        #expect(!report.canGroup)
    }

    @Test func moreThanSixteenChannelsIsABlocker() {
        let report = GroupInfo.analyse([Self.member("A", channels: 10), Self.member("B", channels: 8)])
        #expect(report.findings.contains { $0.severity == .blocker && $0.text.contains("16") })
        #expect(!report.canGroup)
    }

    @Test func bluetoothAndAirPlayAreWarnedAbout() {
        let report = GroupInfo.analyse([Self.member("Fosi"), Self.member("Buds", transport: .bluetooth), Self.member("TV", transport: .airPlay)])
        #expect(report.findings.filter { $0.severity == .warning && ($0.text.contains("Buds") || $0.text.contains("TV")) }.count == 2)
    }

    @Test func aCleanPairCanGroup() {
        let report = GroupInfo.analyse([Self.member("Fosi", domain: 1), Self.member("FiiO", domain: 2)])
        #expect(report.canGroup)
        #expect(report.members[1].needsDriftCorrection)
    }

    @Test func aSingleDeviceIsReportedWithoutGroupFindings() {
        let report = GroupInfo.analyse([Self.member("Fosi")])
        #expect(report.members.count == 1)
        #expect(report.members[0].needsDriftCorrection == false)
        #expect(report.canGroup)
    }

    // MARK: Output

    @Test func theReportRoundTripsThroughJSON() throws {
        let report = GroupInfo.analyse([Self.member("Fosi", domain: 3, latency: 12), Self.member("FiiO", hog: 55)], processID: 1)
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(GroupReport.self, from: data) == report)
    }

    @Test func theTextNamesEveryDeviceAndSaysWhatIsMeasuredNotAssumed() {
        let text = GroupInfo.analyse([Self.member("Fosi"), Self.member("FiiO")]).text
        #expect(text.contains("Fosi") && text.contains("FiiO"))
        #expect(text.contains("clock leader"))
        #expect(text.contains("drift correction"))
    }

    // MARK: Real Core Audio (reads only; any output device will do)

    @Test func theLiveReaderFillsEveryFieldForARealDevice() throws {
        let device = try #require(OutputDevices.list().first, "no output device on this Mac")
        let info = MemberInfo.read(device)
        #expect(info.uid == device.uid)
        #expect(info.name == device.name)
        #expect(info.nominalRate > 0)
        #expect(info.outputChannels >= 1)
        #expect(!info.streamChannels.isEmpty)
        #expect(info.isAlive)
    }
}
