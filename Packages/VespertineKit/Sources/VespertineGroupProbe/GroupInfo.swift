//
// Vespertine — Phase 0 of multi-DAC speaker groups, PR 0.1: `vespertine-probe group-info`. A read-only report on a set of
// output devices: clock domains, rates, reported latencies and safety offsets, who holds them exclusively, and what that
// means for putting them in one private aggregate. It changes nothing and plays nothing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import VespertineAudio

// MARK: - Naming a device

/// Finds a device from what the user typed: the exact UID, else the exact name (any case), else a part of the name that
/// only one device has. Anything else is refused, never guessed ("BlackHole" alone can mean 2ch or 16ch).
public enum DeviceMatcher {
    public enum Result: Equatable, Sendable {
        case found(Int)
        case ambiguous([Int])
        case notFound
    }

    public static func resolve(_ query: String, in devices: [(uid: String, name: String)]) -> Result {
        if let i = devices.firstIndex(where: { $0.uid == query }) { return .found(i) }
        let exact = devices.indices.filter { devices[$0].name.caseInsensitiveCompare(query) == .orderedSame }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let part = devices.indices.filter { devices[$0].name.localizedCaseInsensitiveContains(query) }
        switch part.count {
        case 0: return .notFound
        case 1: return .found(part[0])
        default: return .ambiguous(part)
        }
    }
}

// MARK: - One device

/// What Core Audio says about one output device, as the probe read it.
public struct MemberInfo: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var transport: Transport
    public var outputChannels: Int
    /// Channels per output stream, in stream order (an aggregate spreads a device's channels across streams like this).
    public var streamChannels: [Int]
    public var nominalRate: Double
    public var rates: [Double]
    /// `kAudioDevicePropertyClockDomain`: 0 means "unknown or its own", so two zeros are two clocks.
    public var clockDomain: UInt32
    public var deviceLatencyFrames: UInt32
    public var safetyOffsetFrames: UInt32
    public var streamLatencyFrames: [UInt32]
    public var bufferFrames: UInt32
    /// Hog-mode owner: -1 when nobody holds the device.
    public var hogPID: Int32
    public var isAlive: Bool
    public var runningSomewhere: Bool
    public var hasHardwareVolume: Bool

    public init(uid: String, name: String, transport: Transport, outputChannels: Int, streamChannels: [Int], nominalRate: Double,
                rates: [Double], clockDomain: UInt32, deviceLatencyFrames: UInt32, safetyOffsetFrames: UInt32,
                streamLatencyFrames: [UInt32], bufferFrames: UInt32, hogPID: Int32, isAlive: Bool, runningSomewhere: Bool,
                hasHardwareVolume: Bool) {
        self.uid = uid; self.name = name; self.transport = transport; self.outputChannels = outputChannels
        self.streamChannels = streamChannels; self.nominalRate = nominalRate; self.rates = rates; self.clockDomain = clockDomain
        self.deviceLatencyFrames = deviceLatencyFrames; self.safetyOffsetFrames = safetyOffsetFrames
        self.streamLatencyFrames = streamLatencyFrames; self.bufferFrames = bufferFrames; self.hogPID = hogPID
        self.isAlive = isAlive; self.runningSomewhere = runningSomewhere; self.hasHardwareVolume = hasHardwareVolume
    }

    /// Device latency + safety offset + the largest stream latency: what Core Audio reports, in frames at the device's
    /// own rate. (An aggregate uses these to line its sub-devices up; the buffer size is separate.)
    public var reportedLatencyFrames: UInt32 { deviceLatencyFrames + safetyOffsetFrames + (streamLatencyFrames.max() ?? 0) }
    public var reportedLatencyMs: Double { nominalRate > 0 ? Double(reportedLatencyFrames) / nominalRate * 1000 : 0 }

    public var heldByThisProcess: Bool { hogPID == getpid() }

    /// Reads the live device. Only property reads.
    public static func read(_ device: OutputDevice) -> MemberInfo {
        let id = device.id
        let streams = ProbeHAL.outputStreams(id)
        let streamChannels = streams.map { stream -> Int in
            Int(ProbeHAL.get(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())?.mChannelsPerFrame ?? 0)
        }
        let output = kAudioObjectPropertyScopeOutput
        return MemberInfo(
            uid: device.uid, name: device.name, transport: device.transport, outputChannels: device.capabilities.outputChannels,
            streamChannels: streamChannels, nominalRate: ProbeHAL.nominalRate(id), rates: device.capabilities.sampleRates,
            clockDomain: ProbeHAL.get(id, kAudioDevicePropertyClockDomain, initial: UInt32(0)) ?? 0,
            deviceLatencyFrames: ProbeHAL.get(id, kAudioDevicePropertyLatency, scope: output, initial: UInt32(0)) ?? 0,
            safetyOffsetFrames: ProbeHAL.get(id, kAudioDevicePropertySafetyOffset, scope: output, initial: UInt32(0)) ?? 0,
            streamLatencyFrames: streams.map { ProbeHAL.get($0, kAudioStreamPropertyLatency, initial: UInt32(0)) ?? 0 },
            bufferFrames: ProbeHAL.get(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) ?? 0,
            hogPID: ProbeHAL.hogOwner(id),
            isAlive: (ProbeHAL.get(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(1)) ?? 1) != 0,
            runningSomewhere: (ProbeHAL.get(id, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) ?? 0) != 0,
            hasHardwareVolume: device.hasHardwareVolume)
    }
}

// MARK: - The group

public struct GroupFinding: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case info, warning, blocker }
    public var severity: Severity
    public var text: String
}

public struct GroupReport: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public var info: MemberInfo
        public var isLeader: Bool
        /// The aggregate puts this device's channels at `first`..<`first + count`, in the order the devices were listed.
        public var firstChannel: Int
        /// True when the device's clock differs from the leader's (or is unknown): the aggregate must resample it.
        public var needsDriftCorrection: Bool
        public var reportedLatencyFrames: UInt32
        public var reportedLatencyMs: Double
        /// This device's reported latency minus the leader's, in milliseconds (nil for the leader's own row).
        public var latencyVersusLeaderMs: Double?
        public var heldByThisProcess: Bool
    }
    public struct Range: Codable, Equatable, Sendable { public var first: Int; public var count: Int }

    public var members: [Member]
    public var channelMap: [Range]
    public var totalChannels: Int
    /// Rates every device offers.
    public var commonRates: [Double]
    public var allShareLeaderClock: Bool
    public var findings: [GroupFinding]
    public var canGroup: Bool
}

public enum GroupInfo {
    /// Most output channels the engine's real-time pieces carry (NRT_ROOM_MAX_CHANNELS).
    public static let maxChannels = 16

    /// The first device is the clock leader (the aggregate's main sub-device; its channels are never drift-corrected).
    public static func analyse(_ infos: [MemberInfo], processID: Int32 = getpid()) -> GroupReport {
        let leader = infos.first
        var members: [GroupReport.Member] = []
        var map: [GroupReport.Range] = []
        var next = 0
        for (i, info) in infos.enumerated() {
            let shares = i == 0 || (info.clockDomain != 0 && info.clockDomain == leader?.clockDomain)
            map.append(.init(first: next, count: info.outputChannels))
            members.append(.init(
                info: info, isLeader: i == 0, firstChannel: next, needsDriftCorrection: !shares,
                reportedLatencyFrames: info.reportedLatencyFrames, reportedLatencyMs: info.reportedLatencyMs,
                latencyVersusLeaderMs: i == 0 ? nil : leader.map { info.reportedLatencyMs - $0.reportedLatencyMs },
                heldByThisProcess: info.hogPID == processID))
            next += info.outputChannels
        }
        if !members.isEmpty { members[0].latencyVersusLeaderMs = 0 }

        var common = Set(infos.first?.rates ?? [])
        for info in infos.dropFirst() { common.formIntersection(info.rates) }

        var findings: [GroupFinding] = []
        func add(_ s: GroupFinding.Severity, _ text: String) { findings.append(.init(severity: s, text: text)) }

        if infos.count > 1 {
            if common.isEmpty { add(.blocker, "These devices share no sample rate, so they can't be combined at one rate.") }
            if Set(infos.map(\.nominalRate)).count > 1 {
                let list = infos.map { "\($0.name) \(SampleRate.format($0.nominalRate)) kHz" }.joined(separator: ", ")
                add(.warning, "The devices are at different rates now (\(list)); a group sets every member to one rate and must read each back from the member.")
            }
        }
        if next > maxChannels { add(.blocker, "\(next) output channels in total; the engine carries at most \(maxChannels).") }
        for info in infos {
            if !info.isAlive { add(.blocker, "\(info.name) is not alive (unplugged or gone).") }
            if info.hogPID != -1, info.hogPID != processID {
                add(.blocker, "\(info.name) is held exclusively by process \(info.hogPID); it can't join until that app lets go.")
            }
            switch info.transport {
            case .bluetooth, .bluetoothLE, .airPlay:
                add(.warning, "\(info.name) is \(info.transport.label): its latency is large and changes, so it can't be kept in step.")
            case .aggregate:
                add(.warning, "\(info.name) is itself an aggregate; nesting aggregates is not supported.")
            case .virtual:
                add(.info, "\(info.name) is a virtual device: fine for tests, not a real DAC.")
            case .builtIn:
                add(.info, "\(info.name) is built in: macOS processes its audio, so it is never bit-perfect.")
            default: break
            }
            if info.runningSomewhere && info.hogPID == -1 {
                add(.info, "\(info.name) is in use by another process now (shared); a group would share it too unless it is held exclusively.")
            }
        }
        let mismatch = infos.dropFirst().filter { $0.clockDomain != 0 && $0.clockDomain == leader?.clockDomain }
        if !mismatch.isEmpty {
            add(.info, "\(mismatch.map(\.name).joined(separator: ", ")) report the leader's clock domain: no drift correction needed for them.")
        }
        let shareAll = infos.count > 1 && members.dropFirst().allSatisfy { !$0.needsDriftCorrection }
        return GroupReport(members: members, channelMap: map, totalChannels: next, commonRates: common.sorted(),
                           allShareLeaderClock: shareAll, findings: findings, canGroup: !findings.contains { $0.severity == .blocker })
    }
}

// MARK: - Text

extension GroupReport {
    public var text: String {
        var lines: [String] = []
        for (i, m) in members.enumerated() {
            let info = m.info
            lines.append("\(i == 0 ? "■" : "□") \(info.name)  [\(info.uid)]  (\(m.isLeader ? "clock leader" : "follower"))")
            lines.append("   \(info.transport.label) · \(info.outputChannels) ch (streams \(info.streamChannels.map(String.init).joined(separator: "+"))) · channels \(m.firstChannel)–\(m.firstChannel + info.outputChannels - 1) in the aggregate")
            lines.append("   rate \(SampleRate.format(info.nominalRate)) kHz · offers \(info.rates.map { SampleRate.format($0) }.joined(separator: " "))")
            lines.append("   clock domain \(info.clockDomain)\(info.clockDomain == 0 ? " (unknown/own)" : "") · "
                + (m.isLeader ? "never drift-corrected" : m.needsDriftCorrection ? "needs drift correction (resampled to follow the leader)" : "shares the leader's clock domain: no drift correction"))
            lines.append(String(format: "   latency %u fr = device %u + safety %u + stream %u → %.3f ms · buffer %u fr",
                                m.reportedLatencyFrames, info.deviceLatencyFrames, info.safetyOffsetFrames, info.streamLatencyFrames.max() ?? 0,
                                m.reportedLatencyMs, info.bufferFrames)
                + (m.latencyVersusLeaderMs.map { m.isLeader ? "" : String(format: " (%+.3f ms vs leader)", $0) } ?? ""))
            lines.append("   hog owner \(info.hogPID == -1 ? "none" : m.heldByThisProcess ? "this process" : "process \(info.hogPID)") · alive \(info.isAlive) · running somewhere \(info.runningSomewhere) · hw volume \(info.hasHardwareVolume)")
        }
        lines.append("")
        lines.append("total \(totalChannels) channels · common rates: \(commonRates.isEmpty ? "none" : commonRates.map { SampleRate.format($0) }.joined(separator: " ")) kHz")
        if members.count > 1 {
            lines.append(allShareLeaderClock ? "All members share the leader's clock domain: drift correction can stay off."
                                              : "Different clocks: every follower above is resampled continuously by the aggregate (drift correction).")
        }
        lines.append(contentsOf: findings.map { "\($0.severity.rawValue.uppercased()): \($0.text)" })
        lines.append(canGroup ? "Can be grouped (no blockers)." : "Can NOT be grouped yet (see BLOCKER lines).")
        lines.append("Reported latency is what Core Audio says; the real skew between DACs is measured with group-skew.")
        return lines.joined(separator: "\n")
    }
}
