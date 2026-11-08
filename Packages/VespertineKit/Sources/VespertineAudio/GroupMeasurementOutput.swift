//
// Vespertine — speaker groups: the output a measurement plays to. The group's members are configured at the measurement's rate and
// held, and combined into a private aggregate (as for playback). A hold keeps the aggregate running, on silence, from the moment
// the measurement begins through every capture, so the followers' drift correction is settled and stays settled: each capture's own
// player then starts and stops on a device that never stopped.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public final class GroupMeasurementOutput: @unchecked Sendable {
    private let resources: GroupSessionResources
    private var hold: GroupSilenceHold?
    private let lock = NSLock()

    /// The aggregate's Core Audio ID: what the measurement plays to.
    public var deviceID: AudioObjectID { resources.aggregate.id }
    public var uid: String { resources.aggregate.plan.uid }
    public let rate: Double
    /// All the group's output channels, in the group's order.
    public let channels: Int
    /// The members the aggregate drift-corrects (not the clock leader, nor one that shares its hardware clock).
    public var correctedMemberUIDs: Set<String> {
        let plan = resources.aggregate.plan
        return Set(zip(plan.members, plan.drift).filter(\.1).map(\.0.uid))
    }

    private init(resources: GroupSessionResources, rate: Double, channels: Int) {
        self.resources = resources
        self.rate = rate
        self.channels = channels
    }

    /// Configures `devices` (the group's members, in the group's order) at `rate` and combines them. Throws, leaving nothing held and
    /// no aggregate behind, when a member can't be held or can't run at the rate.
    public static func open(group: SpeakerGroup, devices: [OutputDevice], rate: Double, exclusive: Bool = true) throws -> GroupMeasurementOutput {
        let resources = try GroupSessionResources.open(group: group, devices: devices, rate: rate, exclusive: exclusive)
        return GroupMeasurementOutput(resources: resources, rate: rate, channels: group.totalChannels)
    }

    /// Starts the aggregate playing silence; it runs until `release()`. Safe to call again.
    public func startHold() throws {
        lock.lock(); defer { lock.unlock() }
        guard hold == nil else { return }
        let next = GroupSilenceHold(device: deviceID)
        try next.start()
        hold = next
    }

    public var isHolding: Bool { lock.withLock { hold != nil } }

    /// Whether Core Audio says the aggregate is running.
    public var isRunning: Bool { ((try? HAL.get(deviceID, .global(kAudioDevicePropertyDeviceIsRunning), initial: UInt32(0))) ?? 0) != 0 }

    /// Stops the hold, takes the aggregate out of Core Audio and frees the members (their rates and holds as they were).
    public func release() {
        lock.lock()
        hold?.stop()
        hold = nil
        lock.unlock()
        resources.release()
    }

    deinit { release() }
}

/// An I/O proc that writes silence, to keep a device running.
final class GroupSilenceHold: @unchecked Sendable {
    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.group-hold", qos: .userInteractive)

    init(device: AudioObjectID) { self.device = device }

    func start() throws {
        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, device, queue) { _, _, _, outputData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
        }
        guard status == noErr, let id else { throw RoomHardwareError("The group's output couldn't be kept running (\(status)).") }
        procID = id
        let started = AudioDeviceStart(device, id)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, id)
            procID = nil
            throw RoomHardwareError("The group's output couldn't be started (\(started)).")
        }
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }

    deinit { stop() }
}
