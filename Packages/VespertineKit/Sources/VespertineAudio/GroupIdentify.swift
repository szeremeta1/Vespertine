//
// Vespertine: speaker groups: the Identify button. Plays the quiet tone (`IdentifyTone`) on one channel of one of the group's DACs, so
// that a person can hear which speaker that is. It plays on the DAC itself, one-shot, on the channel the DAC has, and not through
// the group (an aggregate exists only while music plays) and not while the group's output is in use.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum GroupIdentify {
    /// What to play: this stimulus on this channel of this DAC.
    public struct Plan: Equatable, Sendable {
        public var deviceUID: String
        public var channelOnDevice: Int
        public var stimulus: RoomStimulus
    }

    /// The plan for the channel `aggregateChannel` of `group` (its place in the group's outputs, from 0); nil when the group has no
    /// such channel. The stimulus has one track, on the channel of the DAC that has it.
    public static func plan(group: SpeakerGroup, aggregateChannel: Int, rate: Double = 48_000) -> Plan? {
        guard let row = GroupChannelMap.rows(group).first(where: { $0.aggregateChannel == aggregateChannel }) else { return nil }
        let samples = IdentifyTone.samples(channel: 0, channels: 1, rate: rate)
        guard !samples.isEmpty else { return nil }
        return Plan(deviceUID: row.deviceUID, channelOnDevice: row.channelOnDevice,
                    stimulus: RoomStimulus(tracks: [.init(channel: row.channelOnDevice, samples: samples)]))
    }

    /// Why the tone can't play now, or nil. The group's DACs are held while its output is in use.
    public static func refusal(for group: SpeakerGroup, outputInUseUID: String?) -> String? {
        guard outputInUseUID == group.outputUID else { return nil }
        return String(localized: "Stop playback first: the group's outputs are in use.")
    }
}

/// Plays an Identify plan once on its DAC. `start()` returns at once; the tone ends by itself after `IdentifyTone.seconds`.
public final class GroupIdentifyPlayer: @unchecked Sendable {
    private let player: RoomStimulusPlayer
    private var stopWork: DispatchWorkItem?
    private let lock = NSLock()

    /// Throws `RoomHardwareError` in words when the DAC isn't connected, isn't on Float32 or has no such channel.
    public init(plan: GroupIdentify.Plan, deviceName: String, rate: Double = 48_000) throws {
        guard let device = GroupAggregateDevice.deviceID(uid: plan.deviceUID) else { throw RoomHardwareError("\(deviceName) isn't connected.") }
        player = try RoomStimulusPlayer(device: device, stimulus: plan.stimulus, rate: rate)
    }

    public func start() throws {
        try player.start()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        lock.lock(); stopWork = work; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + IdentifyTone.seconds + 0.3, execute: work)
    }

    public func stop() {
        lock.lock(); stopWork?.cancel(); stopWork = nil; lock.unlock()
        player.stop()
    }

    deinit { player.stop() }
}
