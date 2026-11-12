//
// Vespertine: speaker groups: the private aggregate device a group plays through. Core Audio's aggregate puts the group's
// DACs behind one I/O callback, keeps them in step with drift correction, and lines up their reported latencies. The
// clock leader is the aggregate's main sub-device (what Audio MIDI Setup calls the Clock Source): it is never corrected, so
// its channels can stay bit-perfect. Every other member is corrected unless it reports the leader's own (non-zero) clock
// domain, i.e. a hardware clock link.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A private aggregate belongs to the process that made it, is invisible to other apps, and disappears when the process
// ends, so a crash leaves nothing behind. Its description is plain data (below, tested without a device); making and
// destroying one is `GroupAggregateDevice`.
//

import CoreAudio
import Foundation

public enum GroupAggregateError: Error, Equatable, LocalizedError {
    case tooFewMembers
    case duplicateMember(String)
    case leaderNotAMember(String)
    case invalidMember(String)
    case creation(OSStatus)
    case notListed(String)

    public var errorDescription: String? {
        switch self {
        case .tooFewMembers: String(localized: "A group needs at least two outputs.")
        case .duplicateMember(let uid): String(localized: "The output \(uid) is in the group twice.")
        case .leaderNotAMember(let uid): String(localized: "The clock leader \(uid) is not one of the group's outputs.")
        case .invalidMember(let uid): String(localized: "The settings for \(uid) are not valid.")
        case .creation(let status): String(localized: "macOS could not combine the outputs (\(Int(status))).")
        case .notListed: String(localized: "macOS did not list the combined output.")
        }
    }
}

public enum GroupAggregate {
    /// Every aggregate Vespertine builds has a UID starting with this. The device list leaves them out: they are not outputs to
    /// choose, they are how a group plays.
    public static let uidPrefix = "org.szeremeta.vespertine.group."

    public struct Member: Equatable, Sendable {
        public var uid: String
        /// `kAudioDevicePropertyClockDomain`: devices with the same non-zero value share a hardware clock; 0 is "unknown", which
        /// is taken to be a clock of its own.
        public var clockDomain: UInt32
        /// Core Audio's drift correction quality, 0…127.
        public var driftQuality: Int
        /// A measured skew against the leader, in frames, for the alignment to correct. Not put in the aggregate: on virtual
        /// devices Core Audio takes the `latency-out` key without error and reads 0 back, and the property is not settable
        /// afterwards (checked on macOS 27), so a skew is corrected as a delay in the room correction chain instead.
        public var extraLatencyFrames: Double
        /// The member only records (Mac Sound Output's capture side): it adds input channels, no output streams.
        public var inputOnly: Bool

        public init(uid: String, clockDomain: UInt32, driftQuality: Int = SpeakerGroup.Member.defaultDriftQuality, extraLatencyFrames: Double = 0,
                    inputOnly: Bool = false) {
            self.uid = uid
            self.clockDomain = clockDomain
            self.driftQuality = driftQuality
            self.extraLatencyFrames = extraLatencyFrames
            self.inputOnly = inputOnly
        }
    }

    public enum DriftMode: Sendable {
        /// Correct every follower that doesn't share the leader's hardware clock.
        case byClockDomain
        /// Correct none (a measurement of free-running DACs; a test).
        case off
    }

    public struct Plan: Equatable, Sendable {
        public var name: String
        public var uid: String
        /// In the group's order, which is the order of the aggregate's streams.
        public var members: [Member]
        public var leaderUID: String
        /// Whether each member is drift-corrected (resampled to follow the leader), in the same order.
        public var drift: [Bool]

        /// At least one member is resampled to keep in step, so not every channel can be the file's own.
        public var isResampled: Bool { drift.contains(true) }
        /// The members that play (every one but an input-only one).
        public var outputMemberCount: Int { members.filter { !$0.inputOnly }.count }
    }

    /// The plan for these members. The leader may be any of them, wherever it stands in the order.
    public static func plan(name: String, uid: String, members: [Member], leaderUID: String, drift mode: DriftMode = .byClockDomain) throws -> Plan {
        guard members.count >= 2 else { throw GroupAggregateError.tooFewMembers }
        var seen = Set<String>()
        for member in members {
            guard seen.insert(member.uid).inserted else { throw GroupAggregateError.duplicateMember(member.uid) }
            guard (0...127).contains(member.driftQuality), member.extraLatencyFrames.isFinite, member.extraLatencyFrames >= 0 else {
                throw GroupAggregateError.invalidMember(member.uid)
            }
        }
        guard let leader = members.first(where: { $0.uid == leaderUID }) else { throw GroupAggregateError.leaderNotAMember(leaderUID) }
        let flags = members.map { member in
            mode == .byClockDomain && member.uid != leaderUID && !(member.clockDomain != 0 && member.clockDomain == leader.clockDomain)
        }
        return Plan(name: name, uid: uid, members: members, leaderUID: leaderUID, drift: flags)
    }

    /// The plan for a saved group. `clockDomain` reads a device's clock domain by UID (see `GroupAggregateDevice.clockDomain`).
    public static func plan(for group: SpeakerGroup, clockDomain: (String) -> UInt32, drift mode: DriftMode = .byClockDomain, uid: String? = nil) throws -> Plan {
        let members = group.members.map {
            Member(uid: $0.deviceUID, clockDomain: clockDomain($0.deviceUID), driftQuality: $0.driftQuality, extraLatencyFrames: $0.extraLatencyFrames)
        }
        return try plan(name: group.name, uid: uid ?? makeUID(groupID: group.id), members: members, leaderUID: group.clockLeaderUID, drift: mode)
    }

    /// The plan for a group playing what other apps send it (Mac Sound Output): the driver's capture device `captureUID` first, so
    /// its channels are the aggregate's first input channels, then the group's members as `plan(for:)` has them. The capture
    /// device runs on a clock of its own, so it is drift-corrected to follow the group's clock leader like any other follower.
    public static func plan(for group: SpeakerGroup, capture captureUID: String, clockDomain: (String) -> UInt32) throws -> Plan {
        let members = [Member(uid: captureUID, clockDomain: 0, inputOnly: true)] + group.members.map {
            Member(uid: $0.deviceUID, clockDomain: clockDomain($0.deviceUID), driftQuality: $0.driftQuality, extraLatencyFrames: $0.extraLatencyFrames)
        }
        return try plan(name: group.name, uid: makeUID(groupID: group.id), members: members, leaderUID: group.clockLeaderUID)
    }

    /// The dictionary for `AudioHardwareCreateAggregateDevice`. Not stacked: stacked is a multi-output device, which sends the
    /// same audio to every member, where a group sends each member its own channels.
    public static func description(_ plan: Plan) -> [String: Any] {
        let subDevices: [[String: Any]] = zip(plan.members, plan.drift).map { member, corrected in
            var entry: [String: Any] = [kAudioSubDeviceUIDKey: member.uid, kAudioSubDeviceDriftCompensationKey: corrected ? 1 : 0]
            if corrected { entry[kAudioSubDeviceDriftCompensationQualityKey] = member.driftQuality }
            return entry
        }
        return [
            kAudioAggregateDeviceNameKey: plan.name,
            kAudioAggregateDeviceUIDKey: plan.uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: plan.leaderUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
    }

    /// A UID for one aggregate of a group: the group's id, and a count so a second one made while the first is still being torn
    /// down has a UID of its own.
    public static func makeUID(groupID: UUID) -> String {
        "\(uidPrefix)\(groupID.uuidString.lowercased()).\(counter.next())"
    }

    public static func isGroupAggregateUID(_ uid: String) -> Bool { uid.hasPrefix(uidPrefix) }

    private static let counter = Counter()

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
}

/// A live private aggregate. Destroying it (or letting go of it) removes it from Core Audio.
public final class GroupAggregateDevice: @unchecked Sendable {
    /// What Core Audio holds for one sub-device, read back rather than what was asked for.
    public struct SubDeviceState: Equatable, Sendable {
        public var uid: String
        public var driftCompensation: Bool
        public var driftQuality: Int
        public var extraLatencyFrames: Double
    }

    public let id: AudioObjectID
    public let plan: GroupAggregate.Plan
    private let lock = NSLock()
    private var destroyed = false

    private init(id: AudioObjectID, plan: GroupAggregate.Plan) {
        self.id = id
        self.plan = plan
    }

    /// Makes the aggregate and waits (a few seconds at most) until Core Audio lists it with a stream for every member.
    public static func create(_ plan: GroupAggregate.Plan) throws -> GroupAggregateDevice {
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(GroupAggregate.description(plan) as CFDictionary, &id)
        guard status == noErr, id != 0 else { throw GroupAggregateError.creation(status) }
        let device = GroupAggregateDevice(id: id, plan: plan)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if DeviceQuery.outputStreams(id).count >= plan.outputMemberCount,
               DeviceQuery.inputStreams(id).count >= plan.members.count - plan.outputMemberCount { return device }
            usleep(20_000)
        }
        device.destroy()
        throw GroupAggregateError.notListed(plan.uid)
    }

    /// The aggregate's sub-devices as Core Audio holds them.
    public func subDeviceStates() -> [SubDeviceState] { Self.subDeviceStates(of: id) }

    /// The sub-devices of the aggregate `id` as Core Audio holds them (none for a device that isn't an aggregate).
    public static func subDeviceStates(of id: AudioObjectID) -> [SubDeviceState] {
        let owned = (try? HAL.getArray(id, .global(kAudioObjectPropertyOwnedObjects), of: AudioObjectID.self)) ?? []
        return owned.compactMap { object in
            guard (try? HAL.get(object, .global(kAudioObjectPropertyClass), initial: AudioClassID(0))) == kAudioSubDeviceClassID else { return nil }
            return SubDeviceState(
                uid: HAL.getString(object, .global(kAudioDevicePropertyDeviceUID)) ?? "",
                driftCompensation: ((try? HAL.get(object, .global(kAudioSubDevicePropertyDriftCompensation), initial: UInt32(0))) ?? 0) != 0,
                driftQuality: Int((try? HAL.get(object, .global(kAudioSubDevicePropertyDriftCompensationQuality), initial: UInt32(0))) ?? 0),
                extraLatencyFrames: (try? HAL.get(object, .global(kAudioSubDevicePropertyExtraLatency), initial: Float64(0))) ?? 0)
        }
    }

    /// The UID of the sub-device that is the aggregate's time base.
    public func mainSubDeviceUID() -> String? {
        HAL.getString(id, .global(kAudioAggregateDevicePropertyMainSubDevice))
    }

    /// Removes the aggregate and waits (a couple of seconds at most) until Core Audio no longer lists it. Safe to call twice.
    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyAggregateDevice(id)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, Self.deviceID(uid: plan.uid) != nil { usleep(20_000) }
    }

    deinit {
        if !destroyed { AudioHardwareDestroyAggregateDevice(id) }
    }

    // MARK: Devices by UID

    /// The device with this UID, if Core Audio lists it.
    public static func deviceID(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress.global(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != 0 && device != AudioObjectID(kAudioObjectUnknown) ? device : nil
    }

    /// The clock domain of the device with this UID; 0 (unknown) for a device that is not there or doesn't say.
    public static func clockDomain(uid: String) -> UInt32 {
        guard let device = deviceID(uid: uid) else { return 0 }
        return (try? HAL.get(device, .global(kAudioDevicePropertyClockDomain), initial: UInt32(0))) ?? 0
    }
}

// MARK: A member gone from a running aggregate

extension GroupAggregateDevice {
    /// The UIDs of the members Core Audio has active in the aggregate `id` now; empty for a device that is not an aggregate.
    public static func activeMemberUIDs(of id: AudioObjectID) -> [String] {
        let active = (try? HAL.getArray(id, .global(kAudioAggregateDevicePropertyActiveSubDeviceList), of: AudioObjectID.self)) ?? []
        return active.compactMap { HAL.getString($0, .global(kAudioDevicePropertyDeviceUID)) }
    }

    /// An aggregate outlives a member that goes away, so its own "alive" says nothing about the member: every member active when it
    /// started (`atStart`) must still be active in it (`now`) and still connected.
    public static func membersPresent(atStart: [String], now: [String], connected: (String) -> Bool) -> Bool {
        let active = Set(now)
        return atStart.allSatisfy { active.contains($0) && connected($0) }
    }

    /// The device with this UID is listed and says it is alive.
    public static func isConnected(uid: String) -> Bool {
        guard let device = deviceID(uid: uid) else { return false }
        return ((try? HAL.get(device, .global(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0))) ?? 0) != 0
    }
}
