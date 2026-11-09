//
// Vespertine: speaker groups and room correction. How a group's DACs were clocked while a room profile was measured on it: the
// rate, and which members the aggregate resampled to follow the leader, at what quality. A sweep from a later DAC arrives later at the
// microphone, so a profile measured on a group already holds the delay between its DACs in its own delays; while the group still runs
// the same way, the chain must not hold that delay back a second time (`GroupDelay.chain`).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public struct GroupClockContext: Codable, Hashable, Sendable {
    public struct Member: Codable, Hashable, Sendable {
        public var uid: String
        public var driftCorrected: Bool
        public var driftQuality: Int

        public init(uid: String, driftCorrected: Bool, driftQuality: Int) {
            self.uid = uid
            self.driftCorrected = driftCorrected
            self.driftQuality = driftQuality
        }
    }

    public var sampleRate: Double
    public var members: [Member]

    public init(sampleRate: Double, members: [Member]) {
        self.sampleRate = sampleRate
        self.members = members
    }

    /// The group runs now as it did when measured: the same members, each resampled or not as then (at the same quality when it is),
    /// at the same rate. False when what the aggregate resamples now is not known.
    public func holds(for group: SpeakerGroup, resampled: Set<String>?, rate: Double) -> Bool {
        guard let resampled, abs(rate - sampleRate) < 0.5, Set(members.map(\.uid)) == Set(group.members.map(\.deviceUID)),
              members.count == group.members.count else { return false }
        return members.allSatisfy { then in
            guard let now = group.members.first(where: { $0.deviceUID == then.uid }) else { return false }
            let corrected = resampled.contains(then.uid)
            return corrected == then.driftCorrected && (!corrected || now.driftQuality == then.driftQuality)
        }
    }

    /// The context of the aggregate `device` at `rate`, as Core Audio holds it; nil when it is not one of Vespertine's group aggregates.
    public static func read(aggregate device: UInt32, rate: Double) -> GroupClockContext? {
        guard let uid = HAL.getString(AudioObjectID(device), .global(kAudioDevicePropertyDeviceUID)), GroupAggregate.isGroupAggregateUID(uid) else { return nil }
        let states = GroupAggregateDevice.subDeviceStates(of: AudioObjectID(device))
        guard !states.isEmpty else { return nil }
        return GroupClockContext(sampleRate: rate, members: states.map {
            Member(uid: $0.uid, driftCorrected: $0.driftCompensation, driftQuality: $0.driftCompensation ? $0.driftQuality : 0)
        })
    }
}
