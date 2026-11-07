//
// Vespertine — speaker groups: configuring the members of a group before they play together. A group is one device made of
// several; every member has to be at the same rate, and each one's own rate has to be read back from the member, because the
// aggregate's streams report the aggregate's rate even while a member silently resamples to its own.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

/// What a group can do as one device.
public enum GroupCapabilities {
    /// The members' capabilities as one device: the rates every member takes, all their channels, and the Float32 format
    /// the aggregate carries. No DSD over PCM: it can't pass a drift corrector.
    public static func combined(_ members: [DeviceCapabilities]) -> DeviceCapabilities {
        var common = members.first?.sampleRates ?? []
        for member in members.dropFirst() {
            common = common.filter { rate in member.supports(rate: rate) }
        }
        let channels = members.reduce(0) { $0 + $1.outputChannels }
        let formats = common.isEmpty ? [] : [PhysicalFormat(minRate: common.min()!, maxRate: common.max()!, bitDepth: 32, isInteger: false,
                                                            isMixable: true, channels: channels)]
        return DeviceCapabilities(sampleRates: common, physicalFormats: formats, outputChannels: channels, supportsDoP: false)
    }
}

public enum GroupMemberPlanner {
    public struct RatePlan: Equatable, Sendable {
        public var rate: Double
        /// The song's own rate. False: the group runs at another one and the music is resampled to it, as on a single device.
        public var exact: Bool
    }

    /// The rate the whole group runs at for a song at `source`, by the same rules as a single device, over the rates every
    /// member offers. nil when they have none in common (or there are no members).
    public static func rate(for source: Double, members: [DeviceCapabilities], policy: RatePolicy) -> RatePlan? {
        let combined = GroupCapabilities.combined(members)
        guard !members.isEmpty, !combined.sampleRates.isEmpty else { return nil }
        let rate = FormatPlanner.chooseRate(for: source, device: combined, policy: policy)
        return RatePlan(rate: rate, exact: abs(rate - source) < 0.5)
    }

    public enum Access: Equatable, Sendable {
        /// Free: exclusive access can be taken.
        case take
        /// Already held by this process.
        case alreadyHeld
        /// Held by another process.
        case heldByOther(pid_t)
    }

    /// Exclusive access per member, from each one's hog owner (-1: nobody).
    public static func access(owners: [pid_t], me: pid_t) -> [Access] {
        owners.map { $0 == -1 ? .take : $0 == me ? .alreadyHeld : .heldByOther($0) }
    }
}

public enum GroupMemberError: Error, Equatable, LocalizedError {
    case gone(String)
    case heldByOther(uid: String, name: String, pid: pid_t)
    case rateRefused(uid: String, name: String, rate: Double)

    public var errorDescription: String? {
        switch self {
        case .gone(let name): "\(name) is not connected."
        case .heldByOther(_, let name, _): "Another app is using \(name) exclusively."
        case .rateRefused(_, let name, let rate): "\(name) did not switch to \(Int(rate.rounded())) Hz."
        }
    }
}

/// The members of a playing group: held (when exclusive access is on) and at the group's rate, each read back from the member
/// itself. Devices are put back as they were when Vespertine quits (`DeviceRestore`), like a single device's.
public final class GroupMemberSession: @unchecked Sendable {
    public struct Member: Equatable, Sendable {
        public var uid: String
        public var deviceID: AudioObjectID
        /// The member's rate before the group changed it.
        public var rateBefore: Double
        /// The member's own nominal rate, read back from it.
        public var rate: Double
        /// The rate of each of the member's own output streams, read back from them (0: unreadable).
        public var streamRates: [Double]
        /// This process holds the member exclusively.
        public var exclusive: Bool
        /// The shallowest physical format among the member's own streams, read back from them.
        public var physicalBitDepth: Int
        public var physicalIsInteger: Bool
        /// Every one of the member's output streams gave its physical format.
        public var physicalFormatKnown: Bool

        public init(uid: String, deviceID: AudioObjectID, rateBefore: Double, rate: Double, streamRates: [Double], exclusive: Bool,
                    physicalBitDepth: Int = 0, physicalIsInteger: Bool = false, physicalFormatKnown: Bool = false) {
            self.uid = uid
            self.deviceID = deviceID
            self.rateBefore = rateBefore
            self.rate = rate
            self.streamRates = streamRates
            self.exclusive = exclusive
            self.physicalBitDepth = physicalBitDepth
            self.physicalIsInteger = physicalIsInteger
            self.physicalFormatKnown = physicalFormatKnown
        }

        /// Reads the member's rate and its streams' physical formats from the device now.
        public mutating func readBack(from device: AudioObjectID) {
            rate = (try? HAL.get(device, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
            let streams = DeviceQuery.outputStreams(device)
            let physicals = streams.map { try? HAL.get($0, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription()) }
            streamRates = physicals.map { $0?.mSampleRate ?? 0 }
            let read = physicals.compactMap { $0 }
            physicalFormatKnown = !streams.isEmpty && read.count == streams.count
            let shallowest = read.min { $0.mBitsPerChannel < $1.mBitsPerChannel }
            physicalBitDepth = Int(shallowest?.mBitsPerChannel ?? 0)
            physicalIsInteger = shallowest.map { $0.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 } ?? false
        }

        /// The member is at `wanted` on the device and on every one of its own streams. A stream at another rate (or none that
        /// could be read) is a path that may be resampling without saying so.
        public func isAt(_ wanted: Double) -> Bool {
            abs(rate - wanted) < 0.5 && !streamRates.isEmpty && streamRates.allSatisfy { abs($0 - wanted) < 0.5 }
        }
    }

    public private(set) var members: [Member]
    private let lock = NSLock()
    private var released = false

    private init(members: [Member]) { self.members = members }

    /// Takes exclusive access (if asked), sets the rate and reads it back, member by member in the group's order, each rate
    /// change settling before the next. If anything fails, what was taken is let go and the rates changed so far are put back.
    /// The word length asked of every member: the deepest integer format it offers. 32 bits hold any song's samples exactly, so a
    /// leader can stay bit-perfect for 16, 24 and 32-bit songs alike, and a resampled follower isn't cut to 16 bits.
    static let memberBitDepth = 32

    public static func begin(devices: [OutputDevice], rate: Double, exclusive: Bool) throws -> GroupMemberSession {
        // Before changing anything: is someone else holding a member?
        if exclusive {
            let access = GroupMemberPlanner.access(owners: devices.map { DeviceControl.hogOwner($0.id) }, me: getpid())
            for (device, access) in zip(devices, access) {
                if case .heldByOther(let pid) = access { throw GroupMemberError.heldByOther(uid: device.uid, name: device.name, pid: pid) }
            }
        }
        var done: [Member] = []
        func undo() {
            for member in done.reversed() {
                if member.exclusive { DeviceControl.releaseHog(member.deviceID) }
                if abs(member.rate - member.rateBefore) > 0.5, member.rateBefore > 0 { try? DeviceControl.setNominalRate(member.rateBefore, on: member.deviceID) }
            }
        }
        do {
            for device in devices {
                guard ((try? HAL.get(device.id, .global(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0))) ?? 0) != 0 else {
                    throw GroupMemberError.gone(device.name)
                }
                DeviceRestore.remember(device.id)
                let before = (try? HAL.get(device.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
                var held = false
                if exclusive {
                    guard DeviceControl.acquireHog(device.id) else {
                        throw GroupMemberError.heldByOther(uid: device.uid, name: device.name, pid: DeviceControl.hogOwner(device.id))
                    }
                    held = true
                }
                // Recorded before the change, so a failure puts this member back too.
                done.append(Member(uid: device.uid, deviceID: device.id, rateBefore: before, rate: before, streamRates: [], exclusive: held))
                do { try DeviceControl.setNominalRate(rate, on: device.id) } catch {
                    throw GroupMemberError.rateRefused(uid: device.uid, name: device.name, rate: rate)
                }
                // The aggregate has several streams, so the single-device format step never reaches a member: give each one its
                // best physical format here (DeviceRestore, above, puts the old one back when Vespertine quits).
                let streams = DeviceQuery.outputStreams(device.id)
                if streams.count == 1, let stream = streams.first {
                    let channels = (try? HAL.get(stream, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription()))
                        .map { Int($0.mChannelsPerFrame) } ?? device.capabilities.outputChannels
                    DeviceControl.applyBestPhysicalFormat(stream: stream, rate: rate, channels: channels, bitDepth: Self.memberBitDepth)
                }
                done[done.count - 1].readBack(from: device.id)
            }
        } catch {
            undo()
            throw error
        }
        return GroupMemberSession(members: done)
    }

    /// Lets go of the members that are held. Their rates stay as they are until Vespertine quits (`DeviceRestore`). Safe to call
    /// twice.
    /// `keepHolding`: the next group session takes over the holds (a skip to another rate), so they are not let go and taken
    /// again, which reconfigures a device more than once in a row.
    public func release(keepHolding: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        guard !keepHolding else { return }
        for member in members where member.exclusive { DeviceControl.releaseHog(member.deviceID) }
    }

    /// The members read again from the devices (rates and formats), in the group's order; for noticing a change.
    public func readAgain() -> [Member] {
        members.map { var m = $0; m.readBack(from: $0.deviceID); return m }
    }

    deinit { release() }
}
