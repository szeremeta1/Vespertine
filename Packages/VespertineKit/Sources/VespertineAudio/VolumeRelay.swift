//
// Vespertine — carries volume keys and Control Center to a device held with exclusive access.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AudioToolbox
import CoreAudio
import Foundation

/// macOS never makes a device another process holds exclusively the Mac's sound output: it moves the output to some
/// other device, and the volume keys, Control Center and the AirPods Max crown adjust that one instead. While Vespertine
/// holds the device it plays on, the relay ties the two together: volume and mute changes on the sound output go to
/// Vespertine's device, and the sound output takes the device's level, so the keys step from where it really is.
/// When Vespertine lets the device go, the sound output gets its own volume and mute back.
///
/// Meanwhile the sound output plays everything else at that level too, often far above its own. Muting or parking it
/// would break the keys and what they show, so its level stays and the alert volume moves the other way instead: alerts
/// and notification sounds keep the loudness they had. Other apps' ordinary audio (a browser tab, an Electron app's
/// chime) plays at the new level. What the relay changes is kept in the defaults while it relays, so the next launch
/// can put it back after a crash (`DeviceRestore.afterCrash`).
///
/// Each copy comes back as a change notification from the other side, and that notification can still carry the level
/// from before the copy. Copied back, it pulled nearly every step of the AirPods Max crown to the old level. So for a
/// moment after a write, a side showing the level it had just before or just after it is taken as an echo.
public final class VolumeRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.volume-relay")
    /// The device Vespertine plays on.
    private var target: AudioObjectID?
    /// The sound output standing in for it, with its own volume and mute to give back.
    private var standIn: (id: AudioObjectID, volume: Float32?, muted: UInt32?)?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var standInListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    /// The levels each side had just before and after the relay wrote to it, kept for `echoWindow`.
    private var written: [AudioObjectID: [(levels: Levels, at: DispatchTime)]] = [:]
    private static let echoWindow = 0.5
    /// Closer than a volume key step (1/16, or 1/64 with Option-Shift), wider than a device's rounding of a copied
    /// level (AirPods Max: 1/127).
    static let echoTolerance: Float32 = 0.01
    private var alerts = Alerts.unread
    private var alertUpdate: DispatchWorkItem?
    /// What the relay has changed, mirrored to the defaults for the next launch after a crash.
    private var changes: RelayChanges? {
        didSet { RelayChanges.store(changes) }
    }

    /// The alert volume as the relay found it and as it set it; or left alone until the relay lets go, because someone
    /// else changed it meanwhile (it's theirs now) or it can't be read.
    private enum Alerts: Equatable {
        case unread
        case kept(own: Int, set: Int)
        case leftAlone
    }

    private struct Levels {
        var volume: Float32?
        var mute: UInt32?

        func matches(_ other: Levels) -> Bool {
            mute == other.mute && {
                guard let a = volume, let b = other.volume else { return volume == other.volume }
                return abs(a - b) < VolumeRelay.echoTolerance
            }()
        }
    }

    static let volume = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    static let mute = AudioObjectPropertyAddress.output(kAudioDevicePropertyMute)

    public init() {}

    /// The device Vespertine plays on (nil: none). The relay only acts while Vespertine holds it exclusively.
    public func follow(_ device: AudioObjectID?) {
        queue.async { [self] in
            guard device != target else { return }
            retarget(device)
        }
    }

    /// Stops relaying and gives the sound output its own volume back. Blocking, for quitting.
    public func stop() {
        queue.sync { retarget(nil) }
    }

    // MARK: On the relay queue

    private func retarget(_ device: AudioObjectID?) {
        removeListeners(&listeners)
        release()
        target = device
        attach()
    }

    private func attach() {
        guard let device = target else { return }
        listen(&listeners, AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.evaluate() }
        // A device that leaves (AirPods Max taken off) loses its listeners and can come back under the same ID.
        listen(&listeners, AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDevices)) { [weak self] in self?.reattach() }
        listen(&listeners, device, .global(kAudioDevicePropertyHogMode)) { [weak self] in self?.evaluate() }
        listen(&listeners, device, Self.volume) { [weak self] in self?.changed(on: device) }
        listen(&listeners, device, Self.mute) { [weak self] in self?.changed(on: device) }
        evaluate()
    }

    private func reattach() {
        removeListeners(&listeners)
        attach()
    }

    /// Starts, moves or ends the relay after the hold or the sound output changed.
    private func evaluate() {
        guard let target, DeviceControl.hogOwner(target) == getpid(),
              let output = DeviceControl.systemOutputDevice(), output != target,
              HAL.isSettable(output, Self.volume), HAL.isSettable(target, Self.volume) else {
            release()
            return
        }
        guard standIn?.id != output else { return }
        release()
        standIn = (output, try? HAL.get(output, Self.volume, initial: Float32(0)), try? HAL.get(output, Self.mute, initial: UInt32(0)))
        changes = HAL.getString(output, .global(kAudioDevicePropertyDeviceUID)).map {
            RelayChanges(standIn: $0, volume: standIn?.volume, mute: standIn?.muted)
        }
        updateAlerts()   // first, so alerts are down before the stand-in goes up
        copyLevels(from: target, to: output)
        listen(&standInListeners, output, Self.volume) { [weak self] in self?.changed(on: output) }
        listen(&standInListeners, output, Self.mute) { [weak self] in self?.changed(on: output) }
        listen(&standInListeners, AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDefaultSystemOutputDevice)) { [weak self] in
            self?.updateAlerts()
        }
        log.notice("Volume keys now adjust the exclusively held output (through device \(output))")
    }

    /// Volume or mute changed on the device or its stand-in.
    private func changed(on device: AudioObjectID) {
        guard let target, let standIn else { return }
        let now = DispatchTime.now()
        let recent = (written[device] ?? []).filter { now.uptimeNanoseconds - $0.at.uptimeNanoseconds < UInt64(Self.echoWindow * 1e9) }
        written[device] = recent
        let levels = levels(of: device)
        if recent.contains(where: { $0.levels.matches(levels) }) { return }
        if device == standIn.id {
            changes?.relayedVolume = levels.volume
            changes?.relayedMute = levels.mute
        }
        copyLevels(from: device, to: device == target ? standIn.id : target)
        // Alerts follow once the level settles: a held key or a turning knob moves it many times a second, and each
        // update runs osascript.
        alertUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in self?.updateAlerts() }
        alertUpdate = update
        queue.asyncAfter(deadline: .now() + 0.3, execute: update)
    }

    private func levels(of device: AudioObjectID) -> Levels {
        Levels(volume: try? HAL.get(device, Self.volume, initial: Float32(0)), mute: try? HAL.get(device, Self.mute, initial: UInt32(0)))
    }

    /// Copies volume and mute from one side to the other. Unchanged values aren't written. What the stand-in is given
    /// is noted before it is written, so a crash in between leaves nothing behind the next launch doesn't know about.
    private func copyLevels(from: AudioObjectID, to: AudioObjectID) {
        let before = levels(of: to)
        var after = before
        let toStandIn = to == standIn?.id
        if let v = try? HAL.get(from, Self.volume, initial: Float32(0)), let current = before.volume, abs(v - current) > 0.0005 {
            if toStandIn { changes?.relayedVolume = v }
            try? HAL.set(to, Self.volume, v)
            after.volume = v
        }
        if let m = try? HAL.get(from, Self.mute, initial: UInt32(0)), HAL.isSettable(to, Self.mute),
           let current = before.mute, m != current {
            if toStandIn { changes?.relayedMute = m }
            try? HAL.set(to, Self.mute, m)
            after.mute = m
        }
        guard after.volume != before.volume || after.mute != before.mute else { return }
        written[to, default: []] += [(before, .now()), (after, .now())]
    }

    /// Ends relaying: the stand-in gets its own volume and mute back, and the alert volume its own value.
    private func release() {
        removeListeners(&standInListeners)
        written = [:]
        guard let standIn else { return }
        self.standIn = nil
        if let v = standIn.volume { try? HAL.set(standIn.id, Self.volume, v) }
        if let m = standIn.muted, HAL.isSettable(standIn.id, Self.mute) { try? HAL.set(standIn.id, Self.mute, m) }
        restoreAlerts()
        changes = nil
        log.notice("Volume keys back on the Mac's sound output")
    }

    /// Alerts play from the stand-in at its level times the alert volume; this sets the alert volume so they sound as
    /// loud as they did at the stand-in's own level. Only while they play there (Sound › Play sound effects through),
    /// and not again once someone else changed the alert volume. The level is read on the held device, which the
    /// stand-in follows, so it is right even before the stand-in has taken it.
    private func updateAlerts() {
        alertUpdate?.cancel()
        alertUpdate = nil
        guard let target, let standIn, alerts != .leftAlone else { return }
        let effects = try? HAL.get(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDefaultSystemOutputDevice),
                                   initial: AudioObjectID(0))
        guard effects == standIn.id, let own = standIn.volume, let level = try? HAL.get(target, Self.volume, initial: Float32(0)) else {
            restoreAlerts()
            return
        }
        if alerts == .unread {
            guard let alert = AlertVolume.get() else {
                alerts = .leftAlone
                return
            }
            alerts = .kept(own: alert, set: alert)
        }
        guard case let .kept(ownAlert, set) = alerts else { return }
        // Muted on its own, the stand-in played no alerts at all.
        let wanted = standIn.muted == 1 ? 0 : AlertVolume.compensated(ownAlert, before: Self.decibels(own, on: standIn.id),
                                                                     now: Self.decibels(level, on: standIn.id))
        guard wanted != set else { return }
        changes?.alert = ownAlert
        changes?.alertSet = wanted
        if AlertVolume.set(wanted, ifStill: set) == set {
            alerts = .kept(own: ownAlert, set: wanted)
        } else {
            alerts = .leftAlone
            changes?.alert = nil
            changes?.alertSet = nil
        }
    }

    /// Gives the alert volume its own value back, unless someone changed it since the relay set it.
    private func restoreAlerts() {
        alertUpdate?.cancel()
        alertUpdate = nil
        if case let .kept(own, set) = alerts, own != set { AlertVolume.set(own, ifStill: set) }
        alerts = .unread
        changes?.alert = nil
        changes?.alertSet = nil
    }

    /// A level of a device in decibels, on its own volume curve where it has one.
    private static func decibels(_ level: Float32, on device: AudioObjectID) -> Float32 {
        guard let element = DeviceQuery.volumeElements(device).first,
              let db = try? HAL.get(device, .output(kAudioDevicePropertyVolumeScalarToDecibels, element: element), initial: level)
        else { return AlertVolume.decibels(level) }
        return db
    }

    private func listen(_ list: inout [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)],
                        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ action: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { @Sendable _, _ in action() }
        var a = address
        guard AudioObjectAddPropertyListenerBlock(object, &a, queue, block) == noErr else { return }
        list.append((object, address, block))
    }

    private func removeListeners(_ list: inout [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)]) {
        for l in list {
            var a = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &a, queue, l.block)
        }
        list = []
    }
}

/// What the relay changed, and what to put back. Kept in the defaults while it relays; after a crash the next launch
/// puts back whatever nobody has changed since.
struct RelayChanges: Codable, Equatable {
    /// The stand-in's UID, and its own volume and mute.
    var standIn: String
    var volume: Float32?
    var mute: UInt32?
    /// The volume and mute it was last given while relaying, by the relay or the keys.
    var relayedVolume: Float32?
    var relayedMute: UInt32?
    /// The alert volume as the relay found it, and as it set it.
    var alert: Int?
    var alertSet: Int?

    /// What to put back, given what the stand-in and the alert volume show now: each only where it is still what the
    /// relay left, so nothing someone changed since is undone.
    func putBack(volume nowVolume: Float32?, mute nowMute: UInt32?, alert nowAlert: Int?) -> (volume: Float32?, mute: UInt32?, alert: Int?) {
        let volumeLeft = nowVolume.flatMap { now in relayedVolume.map { abs(now - $0) < VolumeRelay.echoTolerance } } ?? false
        return (volumeLeft ? volume : nil,
                nowMute != nil && nowMute == relayedMute ? mute : nil,
                nowAlert != nil && nowAlert == alertSet ? alert : nil)
    }

    /// What is still to put back after an attempt: a field that couldn't be read or set (the stand-in unplugged, the
    /// alert volume unreadable) stays; one put back, or changed by someone since, goes. Nil once nothing is left.
    func remaining(volume volumeSettled: Bool, mute muteSettled: Bool, alert alertSettled: Bool) -> RelayChanges? {
        var rest = self
        if volumeSettled { rest.volume = nil; rest.relayedVolume = nil }
        if muteSettled { rest.mute = nil; rest.relayedMute = nil }
        if alertSettled { rest.alert = nil; rest.alertSet = nil }
        let left = (rest.volume != nil && rest.relayedVolume != nil) || (rest.mute != nil && rest.relayedMute != nil)
            || (rest.alert != nil && rest.alertSet != nil)
        return left ? rest : nil
    }

    private static let key = "VespertineVolumeRelayChanges"
    private static let leftoversKey = "VespertineVolumeRelayLeftovers"

    /// What earlier launches couldn't put back yet, oldest first: kept apart from the record the relay writes, so
    /// relaying again (through another stand-in, say) doesn't overwrite it.
    static func leftovers(from defaults: UserDefaults = .standard) -> [RelayChanges] {
        defaults.data(forKey: leftoversKey).flatMap { try? JSONDecoder().decode([RelayChanges].self, from: $0) } ?? []
    }

    static func storeLeftovers(_ list: [RelayChanges], in defaults: UserDefaults = .standard) {
        if !list.isEmpty, let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: leftoversKey)
        } else {
            defaults.removeObject(forKey: leftoversKey)
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> RelayChanges? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(RelayChanges.self, from: $0) }
    }

    static func store(_ changes: RelayChanges?, in defaults: UserDefaults = .standard) {
        if let changes, let data = try? JSONEncoder().encode(changes) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
