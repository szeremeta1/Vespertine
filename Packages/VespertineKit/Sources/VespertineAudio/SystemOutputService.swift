//
// Vespertine: Mac Sound Output (beta): what Vespertine's helper runs. It publishes the groups the user turned on as outputs of
// Vespertine's audio driver, keeps them published (the driver drops an output nobody refreshes), and plays a group whenever an app
// plays to its output. It reads only the snapshot the app writes, so it runs the same with the app quit.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Vespertine itself playing a group takes the DACs from the helper: the app asks with a distributed notification
// (`SystemOutputHandOff`), the helper lets go of that group until the app hands it back (or quits). Sound other apps send the
// group's output meanwhile is dropped, as the user chose.
//

import CoreAudio
import Foundation
import os

private let systemOutputLog = Logger(subsystem: "org.szeremeta.vespertine", category: "SystemOutput")

/// The app and the helper agree on these.
public enum SystemOutputHandOff {
    /// Posted by the app (userInfo: `groupKey` the group's UUID string, `pidKey` the app's pid) when it starts playing a group, and
    /// `returned` when it stops.
    public static let taken = Notification.Name("org.szeremeta.vespertine.systemOutput.taken")
    public static let returned = Notification.Name("org.szeremeta.vespertine.systemOutput.returned")
    /// Posted by the app after writing a new snapshot.
    public static let snapshotChanged = Notification.Name("org.szeremeta.vespertine.systemOutput.snapshotChanged")
    /// Posted by the helper after writing a new status.
    public static let statusChanged = Notification.Name("org.szeremeta.vespertine.systemOutput.statusChanged")
    public static let groupKey = "group"
    public static let pidKey = "pid"
    /// After the app gives a group back, the helper waits this long before playing it again: the app often takes it straight back
    /// (the next song at another rate opens the group again).
    public static let returnDelay: TimeInterval = 3

    /// The folder this build of Vespertine (or of the helper) meets the other in.
    public static var directory: URL { SystemOutputSnapshot.directory(development: Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true) }

    /// Vespertine is about to play `groupID` itself: if the helper plays it now, it is asked to let go, and this waits (two seconds
    /// at most) until it has. Returns at once when the helper doesn't have the group.
    public static func claim(_ groupID: UUID) {
        let statusURL = SystemOutputStatus.url(in: directory)
        func helperPlays() -> Bool {
            SystemOutputStatus.read(from: statusURL)?.groups.contains { $0.groupID == groupID && $0.state == .playing } == true
        }
        guard let status = SystemOutputStatus.read(from: statusURL), status.groups.contains(where: { $0.groupID == groupID }) else { return }
        post(taken, groupID)
        let deadline = Date().addingTimeInterval(2)
        while helperPlays(), Date() < deadline { usleep(20_000) }
    }

    /// Vespertine has stopped playing `groupID`.
    public static func giveBack(_ groupID: UUID) {
        guard SystemOutputStatus.read(from: SystemOutputStatus.url(in: directory))?.groups.contains(where: { $0.groupID == groupID }) == true else { return }
        post(returned, groupID)
    }

    private static func post(_ name: Notification.Name, _ groupID: UUID) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: [groupKey: groupID.uuidString, pidKey: NSNumber(value: getpid())], deliverImmediately: true)
    }
}

/// What the helper is doing with each published group, for the app's settings and the menu bar item.
public struct SystemOutputStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Published; nothing plays to it.
        case ready
        /// An app plays to it and the group plays.
        case playing
        /// Vespertine plays the group itself.
        case handedOff
        /// Something failed (see `message`); tried again a little later.
        case failed
    }

    public struct Group: Codable, Hashable, Sendable {
        public var groupID: UUID
        public var name: String
        public var state: State
        public var message: String?
        public var sampleRate: Double?
        public var latencyMs: Double?
        /// The output is the Mac's chosen output.
        public var isDefault: Bool
    }

    public var driverLoaded: Bool
    public var groups: [Group]
    /// The user wants the helper's menu bar item.
    public var menuBarItem: Bool
    public var updated: Date

    public static func url(in directory: URL) -> URL { directory.appendingPathComponent("Mac Sound Output status.json") }

    public static func read(from url: URL) -> SystemOutputStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SystemOutputStatus.self, from: data)
    }
}

public final class SystemOutputService: @unchecked Sendable {
    /// After this long with no app playing, the group is let go (the DACs are free again for others).
    public static let idleSeconds: TimeInterval = 30
    /// After a failed start, wait this long before trying again.
    public static let retrySeconds: TimeInterval = 10

    private let directory: URL
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.systemOutput", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var snapshot = SystemOutputSnapshot(entries: [])
    private var snapshotDate: Date?
    private var sessions: [UUID: SystemOutputSession] = [:]
    private var idleSince: [UUID: Date] = [:]
    private var failures: [UUID: (date: Date, message: String)] = [:]
    /// Groups Vespertine plays itself, and the pid of the app that took them.
    private var handedOff: [UUID: pid_t] = [:]
    /// When the app gave a group back (it is played again `SystemOutputHandOff.returnDelay` later, unless taken again).
    private var returnedAt: [UUID: Date] = [:]
    private var latency: [String: Int] = [:]
    private var lastStatus: SystemOutputStatus?
    /// Each output's volume across a change of its layout (macOS puts it back to 100% when it rebuilds the output).
    private var levels = SystemOutputLevelKeeper()
    private var levelCheckScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var listened: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.poke() }
    /// Called on the service's queue whenever the status changes (the menu bar item).
    public var onStatus: (@Sendable (SystemOutputStatus) -> Void)?

    /// `directory`: where the app writes the snapshot (`SystemOutputSnapshot.directory(development:)`).
    public init(directory: URL) {
        self.directory = directory
    }

    public func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: SystemOutputHandOff.snapshotChanged, object: nil, queue: nil) { [weak self] _ in self?.poke() })
        observers.append(center.addObserver(forName: SystemOutputHandOff.taken, object: nil, queue: nil) { [weak self] note in
            guard let service = self, let (group, pid) = Self.handOff(note) else { return }
            service.queue.async { service.take(group, by: pid) }
        })
        observers.append(center.addObserver(forName: SystemOutputHandOff.returned, object: nil, queue: nil) { [weak self] note in
            guard let service = self, let (group, _) = Self.handOff(note) else { return }
            service.queue.async { if service.handedOff[group] != nil { service.returnedAt[group] = Date() } }
            service.queue.asyncAfter(deadline: .now() + SystemOutputHandOff.returnDelay) {
                // Taken again meanwhile (by the same app): it stays Vespertine's.
                guard service.returnedAt[group].map({ Date().timeIntervalSince($0) >= SystemOutputHandOff.returnDelay - 0.1 }) == true else { return }
                service.returnedAt[group] = nil
                service.handedOff[group] = nil
                service.tick()
            }
        })
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: SystemOutput.refreshSeconds)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    /// Takes every output away and lets go of every group (the user turned the feature off, or the helper quits).
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            for session in sessions.values { session.stop() }
            sessions = [:]
            unlisten()
            try? SystemOutputDriver.publish([])
        }
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers = []
    }

    /// Makes the group's output the Mac's output (the menu bar item's choice).
    public func makeDefault(_ groupID: UUID) {
        queue.async { [self] in
            guard let entry = snapshot.entries.first(where: { $0.group.id == groupID }),
                  let device = SystemOutputDriver.device(uid: entry.deviceUID) else { return }
            try? HAL.set(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDefaultOutputDevice), device)
            tick()
        }
    }

    /// Look again now (a snapshot change, an app starting to play, a rate change).
    public func poke() { queue.async { [weak self] in self?.tick() } }

    private static func handOff(_ note: Notification) -> (UUID, pid_t)? {
        guard let text = note.userInfo?[SystemOutputHandOff.groupKey] as? String, let group = UUID(uuidString: text) else { return nil }
        let pid = (note.userInfo?[SystemOutputHandOff.pidKey] as? NSNumber)?.int32Value ?? 0
        return (group, pid)
    }

    private func take(_ group: UUID, by pid: pid_t) {
        handedOff[group] = pid
        returnedAt[group] = nil
        if let session = sessions.removeValue(forKey: group) {
            session.stop()
            systemOutputLog.info("Mac Sound Output: Vespertine took the group over")
        }
        tick()
    }

    // MARK: The loop

    private func tick() {
        reloadSnapshot()
        let entries = snapshot.entries.filter(\.choice.published)
        let ids = Set(entries.map(\.group.id))

        // Groups no longer published: stop.
        for (id, session) in sessions where !ids.contains(id) {
            session.stop()
            sessions[id] = nil
        }
        // An app that took a group and has gone gives it back.
        for (id, pid) in handedOff where pid > 0 && kill(pid, 0) != 0 && errno == ESRCH { handedOff[id] = nil }

        // Publish (refreshes too). The levels are read first: a layout that differs from the last one makes macOS rebuild the output,
        // and the rebuilt output comes back at 100%.
        let driverLoaded = SystemOutputDriver.isLoaded
        if driverLoaded {
            var layouts: [String: [AudioChannelLabel]] = [:]
            var read: [String: SystemOutputLevel?] = [:]
            for entry in entries.prefix(SystemOutput.maxOutputs) {
                layouts[entry.deviceUID] = Array(entry.labels.prefix(SystemOutput.maxChannels))
                read[entry.deviceUID] = SystemOutputDriver.device(uid: entry.deviceUID).flatMap { SystemOutputDriver.level($0) }
            }
            levels.beforePublish(layouts: layouts, levels: read, now: Date())
            do { try SystemOutputDriver.publish(SystemOutput.driverConfiguration(entries, latency: latency)) } catch {
                systemOutputLog.error("Mac Sound Output: publishing failed: \(error.localizedDescription, privacy: .public)")
            }
            restoreLevels(entries)
        }
        listen(entries)

        var groups: [SystemOutputStatus.Group] = []
        let now = Date()
        for entry in entries.prefix(SystemOutput.maxOutputs) {
            let id = entry.group.id
            var status = SystemOutputStatus.Group(groupID: id, name: entry.group.name, state: .ready, isDefault: false)
            guard driverLoaded, let output = SystemOutputDriver.device(uid: entry.deviceUID) else {
                groups.append(status)
                continue
            }
            status.isDefault = SystemOutputDriver.isDefaultOutput(output)
            if handedOff[id] != nil {
                status.state = .handedOff
                groups.append(status)
                continue
            }
            // A member the user chose as the Mac's output, or another app holds exclusively: let it go (stop playing the group, so
            // the DAC is free) and leave it alone until that changes.
            let claim = SystemOutputPolicy.memberClaim(group: entry.group, defaultOutputUID: SystemOutputDriver.defaultOutputUID(),
                                                       hogOwners: Self.hogOwners(entry.group), me: getpid())
            if claim != .none {
                if let session = sessions.removeValue(forKey: id) {
                    session.stop()
                    systemOutputLog.info("Mac Sound Output: let go of the group's DACs: someone else wants one")
                }
                idleSince[id] = nil
                failures[id] = nil
                status.message = Self.describe(claim, in: entry.group)
                groups.append(status)
                continue
            }
            // A session for an older version of the entry, or one that lost a DAC: start again.
            if let session = sessions[id], session.entry != entry || !session.membersPresent
                || abs(SystemOutputDriver.nominalRate(output) - session.rate) >= 0.5 {
                session.stop()
                sessions[id] = nil
            }
            let wanted = SystemOutputDriver.isRunningSomewhere(output)
            if wanted { idleSince[id] = nil } else if sessions[id] != nil, idleSince[id] == nil { idleSince[id] = now }
            if let since = idleSince[id], now.timeIntervalSince(since) >= Self.idleSeconds, let session = sessions[id] {
                session.stop()
                sessions[id] = nil
                idleSince[id] = nil
            }
            if wanted, sessions[id] == nil, failures[id].map({ now.timeIntervalSince($0.date) >= Self.retrySeconds }) ?? true {
                start(entry, output: output)
            }
            if let session = sessions[id] {
                status.state = .playing
                status.sampleRate = session.rate
                status.latencyMs = Double(session.latencyFrames) / session.rate * 1000
            } else if let failure = failures[id] {
                status.state = .failed
                status.message = failure.message
            }
            groups.append(status)
        }
        writeStatus(SystemOutputStatus(driverLoaded: driverLoaded, groups: groups, menuBarItem: snapshot.menuBarItem, updated: now))
    }

    private static func hogOwners(_ group: SpeakerGroup) -> [String: pid_t] {
        var owners: [String: pid_t] = [:]
        for member in group.members {
            if let device = SystemOutputDriver.device(uid: member.deviceUID) { owners[member.deviceUID] = DeviceControl.hogOwner(device) }
        }
        return owners
    }

    private static func describe(_ claim: SystemOutputPolicy.MemberClaim, in group: SpeakerGroup) -> String? {
        func name(_ uid: String) -> String { group.members.first { $0.deviceUID == uid }?.name ?? uid }
        switch claim {
        case .none: return nil
        case .isDefaultOutput(let uid): return String(localized: "\(name(uid)) is the Mac's output on its own, so the group is not playing.")
        case .heldByOther(let uid, _): return String(localized: "Another app is using \(name(uid)) exclusively, so the group is not playing.")
        }
    }

    /// Puts back the level of an output macOS rebuilt for a new layout, and looks again soon while one is still being watched.
    private func restoreLevels(_ entries: [SystemOutputEntry]) {
        var readings: [String: SystemOutputLevelKeeper.Reading] = [:]
        var devices: [String: AudioObjectID] = [:]
        for entry in entries.prefix(SystemOutput.maxOutputs) {
            guard let device = SystemOutputDriver.device(uid: entry.deviceUID) else { continue }
            devices[entry.deviceUID] = device
            readings[entry.deviceUID] = .init(level: SystemOutputDriver.level(device), channels: SystemOutputDriver.outputChannels(device))
        }
        for (uid, level) in levels.restores(devices: readings, now: Date()) {
            guard let device = devices[uid] else { continue }
            SystemOutputDriver.setLevel(level, on: device)
            systemOutputLog.info("Mac Sound Output: put the group's volume back after its layout changed")
        }
        if levels.isWaiting, !levelCheckScheduled {
            levelCheckScheduled = true
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.levelCheckScheduled = false
                self?.tick()
            }
        }
    }

    private func start(_ entry: SystemOutputEntry, output: AudioObjectID) {
        let id = entry.group.id
        guard let capture = SystemOutputDriver.device(uid: entry.captureUID) else { return }
        // The output's own rate, or (if the DACs won't take it) the film rate, then the CD rate; the output follows.
        let own = SystemOutputDriver.nominalRate(output)
        var lastError: Error?
        for rate in [own, 48_000, 44_100] where rate > 0 {
            if abs(rate - own) >= 0.5 { SystemOutputDriver.setNominalRate(rate, on: output) }
            do {
                let session = try SystemOutputSession(entry: entry, captureDevice: capture, rate: rate)
                sessions[id] = session
                failures[id] = nil
                if latency[entry.deviceUID] != session.latencyFrames {
                    latency[entry.deviceUID] = session.latencyFrames
                    try? SystemOutputDriver.publish(SystemOutput.driverConfiguration(snapshot.entries.filter(\.choice.published), latency: latency))
                }
                return
            } catch let error as GroupMemberError {
                lastError = error
                if case .rateRefused = error { continue }
                break
            } catch {
                lastError = error
                break
            }
        }
        let message = lastError?.localizedDescription ?? ""
        failures[id] = (Date(), message)
        systemOutputLog.error("Mac Sound Output: could not play the group: \(message, privacy: .public)")
    }

    private func reloadSnapshot() {
        let url = SystemOutputSnapshot.url(in: directory)
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard date != snapshotDate || date == nil else { return }
        snapshotDate = date
        snapshot = SystemOutputSnapshot.read(from: url) ?? SystemOutputSnapshot(entries: [])
    }

    private func writeStatus(_ status: SystemOutputStatus) {
        var comparable = status
        comparable.updated = lastStatus?.updated ?? status.updated
        guard comparable != lastStatus else { return }
        lastStatus = status
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(status) { try? data.write(to: SystemOutputStatus.url(in: directory), options: .atomic) }
        DistributedNotificationCenter.default().postNotificationName(SystemOutputHandOff.statusChanged, object: nil, userInfo: nil, deliverImmediately: true)
        onStatus?(status)
    }

    // MARK: Listening for apps starting to play

    private func listen(_ entries: [SystemOutputEntry]) {
        // The outputs (an app starting to play, a rate change), each member (someone holding it exclusively), and the Mac's chosen
        // output (the user picking a member on its own).
        var wanted: [(AudioObjectID, [AudioObjectPropertySelector])] = []
        for entry in entries {
            if let output = SystemOutputDriver.device(uid: entry.deviceUID) {
                wanted.append((output, [kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioDevicePropertyNominalSampleRate]))
            }
            for member in entry.group.members {
                if let device = SystemOutputDriver.device(uid: member.deviceUID) { wanted.append((device, [kAudioDevicePropertyHogMode])) }
            }
        }
        if !entries.isEmpty { wanted.append((AudioObjectID(kAudioObjectSystemObject), [kAudioHardwarePropertyDefaultOutputDevice])) }
        let now = Set(listened.map { Listened(device: $0.0, selector: $0.1.mSelector) })
        let next = Set(wanted.flatMap { device, selectors in selectors.map { Listened(device: device, selector: $0) } })
        guard next != now else { return }
        unlisten()
        for item in next {
            var address = AudioObjectPropertyAddress.global(item.selector)
            if AudioObjectAddPropertyListenerBlock(item.device, &address, queue, listener) == noErr { listened.append((item.device, address)) }
        }
    }

    private struct Listened: Hashable {
        var device: AudioObjectID
        var selector: AudioObjectPropertySelector
    }

    private func unlisten() {
        for (device, address) in listened {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
        }
        listened = []
    }
}
