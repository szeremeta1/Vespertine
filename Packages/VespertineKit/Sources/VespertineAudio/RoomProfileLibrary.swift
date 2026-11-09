//
// Vespertine — room correction profiles as a library: named for a speaker pair, a room or a desk, renamed, duplicated,
// deleted, exported and imported, one chosen per output (and in force whenever that output is). Also what a profile can
// do on its own: play at a fraction of its strength, take hand-edited bands and trims, re-average its positions and
// redesign from its measurement. Pure and offline; the app stores the result and hands it to playback.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum RoomProfileError: Error, Equatable, LocalizedError {
    case nameEmpty
    case nameTooLong(Int)
    case nameTaken(String)
    case notFound
    case noMeasurement
    case noPositionsLeft
    case invalidBand
    case tooManyBands(Int)
    case speakerNotInProfile(RoomSpeaker)
    case missingFilters
    case unreadable
    case notOnThisOutput(needed: Int, available: Int)

    public var errorDescription: String? {
        switch self {
        case .nameEmpty: String(localized: "A profile needs a name.")
        case .nameTooLong(let n): String(localized: "A profile's name can be at most \(n) characters.")
        case .nameTaken(let name): String(localized: "Another profile for this output is already called “\(name)”.")
        case .notFound: String(localized: "That profile no longer exists.")
        case .noMeasurement: String(localized: "This profile has no measurement to work from. Imported filters can be edited, not redesigned.")
        case .noPositionsLeft: String(localized: "At least one measured position has to stay in the average.")
        case .invalidBand: String(localized: "A filter has a value that isn't a number.")
        case .tooManyBands(let n): String(localized: "A speaker can have at most \(n) filters.")
        case .speakerNotInProfile(let s): String(localized: "This profile has no \(s.rawValue) speaker.")
        case .missingFilters: String(localized: "The measured filters this profile uses are missing or damaged, so it can't be used.")
        case .unreadable: String(localized: "That file isn't a Vespertine room profile.")
        case .notOnThisOutput(let needed, let available):
            String(localized: "This profile needs an output with \(needed) channels; this one has \(available).")
        }
    }
}

/// Free-text labels that say what a profile is for. All optional.
public struct RoomProfileTags: Codable, Hashable, Sendable {
    public static let maxLength = 80

    public var speakers: String
    public var room: String
    public var position: String

    public init(speakers: String = "", room: String = "", position: String = "") {
        self.speakers = Self.clean(speakers)
        self.room = Self.clean(room)
        self.position = Self.clean(position)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(speakers: try c.decodeIfPresent(String.self, forKey: .speakers) ?? "",
                  room: try c.decodeIfPresent(String.self, forKey: .room) ?? "",
                  position: try c.decodeIfPresent(String.self, forKey: .position) ?? "")
    }

    private enum CodingKeys: String, CodingKey { case speakers, room, position }

    public var isEmpty: Bool { speakers.isEmpty && room.isEmpty && position.isEmpty }

    /// The same labels trimmed and capped, or nil when none is left.
    var cleaned: RoomProfileTags? {
        let tags = RoomProfileTags(speakers: speakers, room: room, position: position)
        return tags.isEmpty ? nil : tags
    }

    /// The labels that are filled in, joined for a list row.
    public var summary: String { [speakers, room, position].filter { !$0.isEmpty }.joined(separator: " · ") }

    static func clean(_ text: String) -> String {
        String(RoomProfileBook.tidy(text).prefix(maxLength))
    }
}

/// The saved profiles, and which one each output plays with. A value: the app keeps one and stores it.
public struct RoomProfileBook: Equatable, Sendable {
    public static let maxNameLength = 80

    public private(set) var profiles: [RoomProfile]
    /// The profile each output (by UID) uses when correction is on for it, and keeps when it is switched off.
    private var chosen: [String: UUID]
    /// Outputs with correction on.
    private var enabled: Set<String>

    public init(profiles: [RoomProfile] = []) {
        self.profiles = profiles
        chosen = [:]
        enabled = []
    }

    /// From the shape stored before the library: a list of profiles and, per output, the one that was switched on.
    public static func migrated(profiles: [RoomProfile], assignments: [String: String]) -> RoomProfileBook {
        var book = RoomProfileBook(profiles: profiles)
        for (uid, id) in assignments {
            guard let uuid = UUID(uuidString: id), profiles.contains(where: { $0.id == uuid && $0.deviceUID == uid }) else { continue }
            book.chosen[uid] = uuid
            book.enabled.insert(uid)
        }
        return book
    }

    /// The outputs that have correction on, with the profile each plays (the stored form `AppSettings` keeps).
    public var assignments: [String: String] {
        var out: [String: String] = [:]
        for uid in enabled { if let p = active(for: uid) { out[uid] = p.id.uuidString } }
        return out
    }

    /// The outputs' chosen profiles, on or off.
    public var choices: [String: String] { chosen.mapValues(\.uuidString) }

    /// Restores a book from `profiles`, `choices` and the on-switches saved by `assignments`.
    public init(profiles: [RoomProfile], choices: [String: String], assignments: [String: String]) {
        self = RoomProfileBook.migrated(profiles: profiles, assignments: assignments)
        for (uid, id) in choices {
            if let uuid = UUID(uuidString: id), profiles.contains(where: { $0.id == uuid && $0.deviceUID == uid }) { chosen[uid] = uuid }
        }
    }

    // MARK: Reading

    public func profile(_ id: UUID) -> RoomProfile? { profiles.first { $0.id == id } }

    /// The profiles made for `uid`, newest first.
    public func profiles(for uid: String) -> [RoomProfile] {
        profiles.filter { $0.deviceUID == uid }.sorted { ($0.createdAt, $1.name) > ($1.createdAt, $0.name) }
    }

    public func chosenID(for uid: String) -> UUID? {
        guard let id = chosen[uid], profiles.contains(where: { $0.id == id && $0.deviceUID == uid }) else { return nil }
        return id
    }

    public func isEnabled(_ uid: String) -> Bool { enabled.contains(uid) }

    /// The profile playing on `uid`: only while correction is on for it, and only one made for it.
    public func active(for uid: String) -> RoomProfile? {
        guard enabled.contains(uid), let id = chosenID(for: uid) else { return nil }
        return profile(id)
    }

    // MARK: Changing

    /// Adds a profile. A name already used on its output gets a number, and an id already in the library a fresh one
    /// (an imported copy of a profile never replaces the original). Its time is held to the second the file keeps.
    @discardableResult
    public mutating func add(_ profile: RoomProfile, makeChosen: Bool = true) -> RoomProfile {
        var p = profile
        if profiles.contains(where: { $0.id == p.id }) { p = p.withID(UUID()) }
        p.createdAt = p.createdAt.wholeSecond
        let cleaned = Self.tidy(p.name)
        p.name = freeName(cleaned.isEmpty ? String(localized: "Room correction") : String(cleaned.prefix(Self.maxNameLength - 6)), on: p.deviceUID, except: nil)
        p.tags = p.tags?.cleaned
        profiles.append(p)
        if makeChosen { chosen[p.deviceUID] = p.id }
        return p
    }

    public mutating func rename(_ id: UUID, to name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw RoomProfileError.notFound }
        let cleaned = Self.tidy(name)
        guard !cleaned.isEmpty else { throw RoomProfileError.nameEmpty }
        guard cleaned.count <= Self.maxNameLength else { throw RoomProfileError.nameTooLong(Self.maxNameLength) }
        if let other = profiles.first(where: { $0.id != id && $0.deviceUID == profiles[index].deviceUID && $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            throw RoomProfileError.nameTaken(other.name)
        }
        profiles[index].name = cleaned
    }

    /// Changes a profile in place. If `change` throws, nothing is changed. Empty tags are dropped.
    public mutating func update(_ id: UUID, _ change: (inout RoomProfile) throws -> Void) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw RoomProfileError.notFound }
        var p = profiles[index]
        let name = p.name, device = p.deviceUID, identifier = p.id
        try change(&p)
        p.tags = p.tags?.cleaned
        // Name, output and id change through their own calls only.
        guard p.name == name, p.deviceUID == device, p.id == identifier else { return }
        profiles[index] = p
    }

    /// A copy under a free name ("Desk copy"), with its own id and the time it was made.
    @discardableResult
    public mutating func duplicate(_ id: UUID) throws -> RoomProfile {
        guard let original = profile(id) else { throw RoomProfileError.notFound }
        var copy = original.withID(UUID())
        copy.createdAt = Date().wholeSecond
        copy.name = freeName(String(Self.tidy(original.name).prefix(Self.maxNameLength - 12)) + " " + String(localized: "copy", comment: "Added to the name of a duplicated room profile: “Desk copy”."), on: original.deviceUID, except: nil)
        profiles.append(copy)
        return copy
    }

    /// Removes a profile (switching its output's correction off if it was the one chosen) and returns the measured
    /// filters no other profile uses, for the caller to delete.
    @discardableResult
    public mutating func delete(_ id: UUID) -> [RoomImpulse] {
        guard let removed = profile(id) else { return [] }
        profiles.removeAll { $0.id == id }
        for (uid, chosenID) in chosen where chosenID == id {
            chosen[uid] = nil
            enabled.remove(uid)
        }
        let kept = Set(profiles.flatMap { ($0.impulses ?? [:]).values.map(\.file) })
        var seen = Set<String>()
        return (removed.impulses ?? [:]).values.filter { !kept.contains($0.file) && seen.insert($0.file).inserted }
    }

    /// Chooses the profile `uid` uses (nil to forget the choice). A profile made for another output is ignored.
    public mutating func choose(_ id: UUID?, for uid: String) {
        guard let id else { chosen[uid] = nil; enabled.remove(uid); return }
        guard profiles.contains(where: { $0.id == id && $0.deviceUID == uid }) else { return }
        chosen[uid] = id
    }

    /// Switches correction on or off for `uid`. On with nothing chosen picks the newest profile; with none, stays off.
    public mutating func setEnabled(_ on: Bool, for uid: String) {
        guard on else { enabled.remove(uid); return }
        if chosenID(for: uid) == nil {
            guard let newest = profiles(for: uid).first else { return }
            chosen[uid] = newest.id
        }
        enabled.insert(uid)
    }

    /// Carries an output's profiles over to its new UID.
    public mutating func moveDevice(from old: String, to new: String) {
        guard old != new else { return }
        profiles = profiles.map { var p = $0; if p.deviceUID == old { p.deviceUID = new }; return p }
        if chosen[new] == nil, let id = chosen[old] { chosen[new] = id }
        if enabled.contains(old), chosen[new] != nil { enabled.insert(new) }
        chosen[old] = nil
        enabled.remove(old)
    }

    // MARK: Names

    /// Control characters become spaces, runs of white space one space, ends trimmed.
    static func tidy(_ text: String) -> String {
        let mapped = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0 }))
        return mapped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func freeName(_ base: String, on uid: String, except: UUID?) -> String {
        let taken = Set(profiles.filter { $0.deviceUID == uid && $0.id != except }.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}

private extension Date {
    /// The time to the second, as the library file stores it (ISO 8601, no fractions), so a profile kept in memory and
    /// the same profile read back after a restart are equal.
    var wholeSecond: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

// MARK: - What a profile can do

extension RoomProfile {
    func withID(_ id: UUID) -> RoomProfile {
        var p = RoomProfile(id: id, name: name, createdAt: createdAt, sessionID: sessionID, deviceUID: deviceUID, layout: layout,
                            channelMap: channelMap, micSerial: micSerial, calibrationSHA256: calibrationSHA256, target: target, filters: filters)
        p.schemaVersion = schemaVersion
        p.measured = measured; p.designOptions = designOptions; p.alignment = alignment; p.impulses = impulses; p.source = source
        p.tags = tags; p.strength = strength; p.positionCurves = positionCurves; p.excludedPositions = excludedPositions
        p.filtersEdited = filtersEdited; p.groupClock = groupClock
        return p
    }

    /// The strength played: 0 to 1, all of it when unset or damaged.
    public var effectiveStrength: Double {
        guard let strength, strength.isFinite else { return 1 }
        return min(max(strength, 0), 1)
    }

    /// Measured (impulse response) filters can't be turned down, so the control is for parametric profiles only.
    public var supportsStrength: Bool { impulses?.isEmpty ?? true }

    /// The profile as it plays: every band's gain scaled by the strength (passes are left as they are), and the preamp
    /// scaled with it, then lowered if the scaled bands still need headroom. Delays and levels are not scaled.
    public var atStrength: RoomProfile {
        let s = effectiveStrength
        guard supportsStrength, s < 1 else { return self }
        var p = self
        p.filters.channels = filters.channels.mapValues { bands in
            bands.map { b in
                guard b.kind.hasGain else { return b }
                var b = b
                b.gainDB = (b.gainDB * s * 100).rounded() / 100 + 0
                return b
            }
        }
        var preamp = (filters.preampDB * s * 100).rounded() / 100 + 0
        let peak = p.filters.channels.values.map { bands in
            bands.isEmpty ? 0 : RoomFilterDesigner.checkRates.map { EQPreset(name: "", bands: bands).peakDB(sampleRate: $0) }.max() ?? 0
        }.max() ?? 0
        if peak + preamp > 0 { preamp = -((peak + RoomFilterDesigner.headroomMarginDB) * 10).rounded(.up) / 10 }
        p.filters.preampDB = max(preamp, EQPreset.preampRange.lowerBound)
        return p
    }

    /// Replaces a speaker's bands with the listener's own. Values are held to what a band can be; one that isn't a
    /// number is refused. The shared preamp is set again from the edited bands. Nothing changes if it throws.
    public mutating func setBands(_ bands: [EQBand], for speaker: RoomSpeaker) throws {
        guard channelMap.speakers.contains(speaker) else { throw RoomProfileError.speakerNotInProfile(speaker) }
        guard bands.count <= RoomCorrectionPlayback.maxBandsPerChannel else {
            throw RoomProfileError.tooManyBands(RoomCorrectionPlayback.maxBandsPerChannel)
        }
        var clamped: [EQBand] = []
        for band in bands {
            guard band.frequency.isFinite, band.gainDB.isFinite, band.q.isFinite else { throw RoomProfileError.invalidBand }
            var b = band
            b.frequency = min(max(b.frequency, EQBand.frequencyRange.lowerBound), EQBand.frequencyRange.upperBound)
            b.gainDB = min(max(b.gainDB, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound)
            b.q = min(max(b.q, EQBand.qRange.lowerBound), EQBand.qRange.upperBound)
            clamped.append(b)
        }
        var next = filters
        next.channels[speaker] = clamped
        next.preampDB = max(next.channels.values.map { RoomFilterDesigner.preamp(for: $0) }.min() ?? 0, EQPreset.preampRange.lowerBound)
        filters = next
        filtersEdited = true
    }

    /// Sets a speaker's delay and level trim, held to what playback runs; a value that isn't a number becomes none.
    public mutating func setAlignment(_ trim: RoomSpeakerAlignment, for speaker: RoomSpeaker) {
        let safe = RoomSpeakerAlignment(delayMs: trim.delayMs.isFinite ? trim.delayMs : 0, levelDB: trim.levelDB.isFinite ? trim.levelDB : 0).clamped
        var all = alignment ?? [:]
        all[speaker] = safe
        alignment = all
    }

    /// The most positions any speaker was measured at (0 when they weren't kept).
    public var positionCount: Int { positionCurves?.values.map(\.count).max() ?? 0 }

    /// Each speaker's curves by the order they were measured in.
    public static func positionCurves(from positions: [Int: [RoomSpeaker: RoomCurve]]) -> [RoomSpeaker: [RoomCurve]] {
        var out: [RoomSpeaker: [RoomCurve]] = [:]
        for position in positions.keys.sorted() {
            for (speaker, curve) in positions[position] ?? [:] { out[speaker, default: []].append(curve) }
        }
        return out
    }

    /// Leaves positions out of (or back in) the average that `measured` holds. The filters are not refitted: call
    /// `redesigned()` after. Positions that don't exist are ignored; every speaker keeps at least one.
    public mutating func setExcludedPositions(_ excluded: Set<Int>) throws {
        guard let curves = positionCurves, !curves.isEmpty else { throw RoomProfileError.noMeasurement }
        let valid = excluded.filter { $0 >= 0 && $0 < positionCount }
        var averaged: [RoomSpeaker: RoomCurve] = [:]
        for (speaker, list) in curves {
            let kept = list.indices.filter { !valid.contains($0) }.map { list[$0] }
            guard !kept.isEmpty else { throw RoomProfileError.noPositionsLeft }
            averaged[speaker] = try RoomCurve.powerAverage(kept)
        }
        measured = averaged
        excludedPositions = valid.isEmpty ? nil : valid.sorted()
    }

    /// The filters designed again from the measurement, with `options` (or the ones it was fitted with). Name, tags,
    /// strength and trims stay; hand edits are replaced.
    public func redesigned(options: RoomFilterDesignOptions? = nil) throws -> RoomProfile {
        guard let measured, !measured.isEmpty else { throw RoomProfileError.noMeasurement }
        let chosen = (options ?? designOptions ?? .default).clamped
        let design = try RoomFilterDesigner.design(channels: measured, options: chosen)
        var p = self
        p.filters = design.filterSet
        p.target = chosen.target.roomTarget
        p.designOptions = chosen
        p.filtersEdited = nil
        return p
    }

    /// The same profile for another output, if that output has the channels it needs.
    public func retargeted(toDevice uid: String, outputChannels: Int) throws -> RoomProfile {
        let needed = (channelMap.entries.map(\.output).max() ?? -1) + 1
        guard needed <= outputChannels else { throw RoomProfileError.notOnThisOutput(needed: needed, available: outputChannels) }
        var p = self
        p.deviceUID = uid
        return p
    }
}

// MARK: - Export and import

/// A profile as a file. One with no measured filters is the plain profile JSON (older versions read it too); one with
/// impulse responses carries their samples, so it works on another Mac.
public enum RoomProfileArchive {
    private static let marker = "vespertineRoomProfileArchive"

    public static func encode(_ profile: RoomProfile, impulseDirectory: URL = RoomImpulse.defaultDirectory) throws -> Data {
        let impulses = Set((profile.impulses ?? [:]).values)
        guard !impulses.isEmpty else { return try RoomCorrectionCoding.encode(profile) }
        var files: [String: String] = [:]
        for impulse in impulses {
            guard RoomImpulse.isSafe(fileName: impulse.file), let data = try? Data(contentsOf: impulse.url(in: impulseDirectory)),
                  data.count == impulse.frames * MemoryLayout<Float>.size else { throw RoomProfileError.missingFilters }
            files[impulse.file] = data.base64EncodedString()
        }
        let object = try JSONSerialization.jsonObject(with: RoomCorrectionCoding.encode(profile))
        return try JSONSerialization.data(withJSONObject: [marker: 1, "profile": object, "impulses": files], options: [.sortedKeys, .prettyPrinted])
    }

    /// Reads an export (plain or with filters), storing any filters in `impulseDirectory` under new names. A plain
    /// profile that names filters has to find them there. Nothing is written unless everything checks out.
    public static func decode(_ data: Data, into impulseDirectory: URL = RoomImpulse.defaultDirectory) throws -> RoomProfile {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw RoomProfileError.unreadable }
        guard object[marker] != nil else {
            let profile = try RoomCorrectionCoding.decodeProfile(data)
            for impulse in (profile.impulses ?? [:]).values {
                guard RoomImpulse.isSafe(fileName: impulse.file), let attributes = try? FileManager.default.attributesOfItem(atPath: impulse.url(in: impulseDirectory).path),
                      (attributes[.size] as? Int) == impulse.frames * MemoryLayout<Float>.size else { throw RoomProfileError.missingFilters }
            }
            return profile
        }
        guard let inner = object["profile"], let payload = object["impulses"] as? [String: String] else { throw RoomProfileError.unreadable }
        var profile = try RoomCorrectionCoding.decodeProfile(try JSONSerialization.data(withJSONObject: inner))
        var renamed: [String: String] = [:]
        var staged: [(name: String, data: Data)] = []
        for impulse in (profile.impulses ?? [:]).values where renamed[impulse.file] == nil {
            guard RoomImpulse.isSafe(fileName: impulse.file), let text = payload[impulse.file], let bytes = Data(base64Encoded: text),
                  bytes.count == impulse.frames * MemoryLayout<Float>.size else { throw RoomProfileError.missingFilters }
            let name = UUID().uuidString + ".f32"
            renamed[impulse.file] = name
            staged.append((name, bytes))
        }
        profile.impulses = profile.impulses?.mapValues { var i = $0; i.file = renamed[i.file] ?? i.file; return i }
        var written: [URL] = []
        do {
            try FileManager.default.createDirectory(at: impulseDirectory, withIntermediateDirectories: true)
            for (name, bytes) in staged {
                let url = impulseDirectory.appendingPathComponent(name)
                try bytes.write(to: url, options: .atomic)
                written.append(url)
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw RoomProfileError.missingFilters
        }
        return profile
    }
}

extension RoomImpulse {
    /// A stored filter's name is a plain file name: no folders, no `..`, nothing hidden.
    static func isSafe(fileName: String) -> Bool {
        !fileName.isEmpty && fileName.count <= 80 && !fileName.hasPrefix(".")
            && fileName.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }
}
