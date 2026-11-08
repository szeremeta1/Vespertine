//
// Vespertine — Phase 0 of multi-DAC speaker groups, PR 0.2: a private aggregate device built in code (dev only), and the
// rate choice for its members. A private aggregate belongs to this process and disappears when it exits.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum GroupAggregate {
    public struct Member: Equatable, Sendable {
        public var uid: String
        public var clockDomain: UInt32
        public init(uid: String, clockDomain: UInt32) { self.uid = uid; self.clockDomain = clockDomain }
    }

    public enum DriftMode: Sendable { case byClockDomain, off }

    /// Drift correction per member: never on the leader (the first member); on for every follower unless it reports the
    /// leader's own non-zero clock domain (zero means unknown, which is a clock of its own).
    public static func driftFlags(_ members: [Member]) -> [Bool] {
        members.enumerated().map { i, m in i != 0 && !(m.clockDomain != 0 && m.clockDomain == members.first?.clockDomain) }
    }

    /// The dictionary for `AudioHardwareCreateAggregateDevice`. Sub-device order is stream order, so the first member's
    /// channels come first. `kAudioAggregateDeviceIsStackedKey` stays off: stacked means a multi-output device, which sends
    /// the same audio to every member.
    public static func description(name: String, uid: String, members: [Member], drift: DriftMode = .byClockDomain,
                                   quality: Int = Int(kAudioAggregateDriftCompensationMaxQuality)) -> [String: Any] {
        let flags = drift == .off ? members.map { _ in false } : driftFlags(members)
        let subDevices: [[String: Any]] = zip(members, flags).map { m, correct in
            var entry: [String: Any] = [kAudioSubDeviceUIDKey: m.uid, kAudioSubDeviceDriftCompensationKey: correct ? 1 : 0]
            if correct { entry[kAudioSubDeviceDriftCompensationQualityKey] = quality }
            return entry
        }
        return [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: members.first?.uid ?? "",
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
    }

    private static let counter = ProbeCounter()

    public static func makeUID() -> String { "org.szeremeta.vespertine.group-probe.\(getpid()).\(counter.next())" }
}

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

// MARK: - Rate

public enum RatePlanner {
    public struct Plan: Equatable, Sendable {
        public var rate: Double
        /// True when the rate is the source's own; false means the engine would resample (and the badge says so).
        public var exact: Bool
    }

    /// The source rate when every member offers it; else the nearest common rate above it (so nothing is thrown away),
    /// else the highest common rate below it. nil when the members share no rate.
    public static func choose(source: Double, memberRates: [[Double]]) -> Plan? {
        guard var common = memberRates.first.map(Set.init) else { return nil }
        for rates in memberRates.dropFirst() { common.formIntersection(rates) }
        if common.contains(where: { abs($0 - source) < 0.5 }) { return Plan(rate: source, exact: true) }
        if let above = common.filter({ $0 > source }).min() { return Plan(rate: above, exact: false) }
        if let below = common.max() { return Plan(rate: below, exact: false) }
        return nil
    }
}

// MARK: - The live aggregate

public enum GroupProbeError: Error, CustomStringConvertible {
    case aggregate(OSStatus)
    case notVisible(String)
    case message(String)

    public var description: String {
        switch self {
        case .aggregate(let status): "creating the private aggregate failed: \(status)"
        case .notVisible(let uid): "the aggregate \(uid) did not appear in the device list"
        case .message(let text): text
        }
    }
}

public final class PrivateAggregate: @unchecked Sendable {
    public struct SubDeviceState: Equatable, Sendable {
        public var uid: String
        public var driftCompensation: Bool
        public var quality: Int
        public var extraLatencyFrames: Double
    }

    public let id: AudioObjectID
    public let uid: String
    private let lock = NSLock()
    private var destroyed = false

    private init(id: AudioObjectID, uid: String) { self.id = id; self.uid = uid }

    /// Creates the aggregate and waits (bounded) until Core Audio lists it with its streams.
    public static func create(members: [GroupAggregate.Member], name: String, drift: GroupAggregate.DriftMode = .byClockDomain,
                              quality: Int = Int(kAudioAggregateDriftCompensationMaxQuality)) throws -> PrivateAggregate {
        let uid = GroupAggregate.makeUID()
        let description = GroupAggregate.description(name: name, uid: uid, members: members, drift: drift, quality: quality)
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else { throw GroupProbeError.aggregate(status) }
        let aggregate = PrivateAggregate(id: id, uid: uid)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if ProbeHAL.outputStreams(id).count >= members.count { return aggregate }
            usleep(20_000)
        }
        aggregate.destroy()
        throw GroupProbeError.notVisible(uid)
    }

    /// What Core Audio holds for each sub-device (read back, not what we asked for).
    public func subDeviceStates() -> [SubDeviceState] {
        let owned = ProbeHAL.getArray(id, kAudioObjectPropertyOwnedObjects, of: AudioObjectID.self)
        return owned.compactMap { object in
            guard ProbeHAL.get(object, kAudioObjectPropertyClass, initial: AudioClassID(0)) == kAudioSubDeviceClassID else { return nil }
            return SubDeviceState(
                uid: ProbeHAL.string(object, kAudioDevicePropertyDeviceUID) ?? ProbeHAL.string(object, kAudioObjectPropertyName) ?? "?",
                driftCompensation: (ProbeHAL.get(object, kAudioSubDevicePropertyDriftCompensation, initial: UInt32(0)) ?? 0) != 0,
                quality: Int(ProbeHAL.get(object, kAudioSubDevicePropertyDriftCompensationQuality, initial: UInt32(0)) ?? 0),
                extraLatencyFrames: ProbeHAL.get(object, kAudioSubDevicePropertyExtraLatency, initial: Float64(0)) ?? 0)
        }
    }

    public func destroy() {
        lock.lock(); defer { lock.unlock() }
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyAggregateDevice(id)
        // Removal is asynchronous: wait (bounded) until Core Audio no longer lists it.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, ProbeHAL.deviceID(uid: uid) != nil { usleep(20_000) }
    }

    deinit { if !destroyed { AudioHardwareDestroyAggregateDevice(id) } }
}
