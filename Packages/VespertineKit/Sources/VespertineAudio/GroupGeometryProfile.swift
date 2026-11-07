//
// Vespertine — speaker groups: the drawing of the room as a room profile of its own kind. Delays and levels worked out from where
// the speakers and the seat stand (`SpeakerGeometry`), no filters, so a group can be aligned without a microphone; chosen,
// duplicated and exported like any profile. A measurement replaces it, and the two are checked against each other.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupGeometryProfile {
    /// The name of the profile made from the drawing.
    public static let name = "From the drawing"

    /// The profile for `group` as drawn: each speaker's wait for the farthest one and its level below it, to the hundredth of a
    /// millisecond and the tenth of a dB. A speaker's own delay and level trims are not in it: the group's chain adds the delay
    /// trims (`GroupDelay`), so counting them here too would count them twice. nil when no speaker is wired to an output; a speaker
    /// that can't be placed (at the seat, or not at a number) is in the channel map and has no alignment.
    public static func make(for group: SpeakerGroup, id: UUID = UUID(), createdAt: Date = Date()) -> RoomProfile? {
        guard let fit = RoomLayout.layout(for: group) else { return nil }
        var alignment: [RoomSpeaker: RoomSpeakerAlignment] = [:]
        for placed in SpeakerGeometry.alignment(for: group, sampleRate: 48_000) {
            guard let speaker = group.speakers.first(where: { $0.id == placed.speakerID }), let room = fit.speakers[placed.role] else { continue }
            let delay = ((placed.delayMs - speaker.delayTrimMs) * 100).rounded() / 100 + 0
            let level = (placed.geometryGainDB * 10).rounded() / 10 + 0
            alignment[room] = RoomSpeakerAlignment(delayMs: delay, levelDB: level).clamped
        }
        var profile = RoomProfile(id: id, name: name, createdAt: createdAt, sessionID: UUID(), deviceUID: group.outputUID, layout: fit.layout,
                                  channelMap: fit.channelMap, micSerial: "", calibrationSHA256: nil, target: .flat,
                                  filters: RoomFilterSet(version: 1, channels: [:]))
        profile.alignment = alignment
        profile.source = .geometry
        return profile
    }

    /// Brings the drawing's profile in `book` up to date with `group`, or adds it the first time. The numbers, the layout and
    /// the channel map change; the id, the name and what the output has chosen do not. Measured and imported profiles are never
    /// touched. nil when the group has no profile to make.
    @discardableResult
    public static func refresh(in book: inout RoomProfileBook, for group: SpeakerGroup) -> RoomProfile? {
        guard let fresh = make(for: group) else { return nil }
        if let existing = book.profiles(for: group.outputUID).first(where: { $0.origin == .geometry }) {
            try? book.update(existing.id) { profile in
                profile.layout = fresh.layout
                profile.channelMap = fresh.channelMap
                profile.alignment = fresh.alignment
            }
            return book.profile(existing.id)
        }
        return book.add(fresh, makeChosen: false)
    }
}

/// One speaker whose measured place is not where the room is drawn.
public struct GeometryDisagreement: Equatable, Sendable {
    public var speaker: RoomSpeaker
    public var measuredDelayMs: Double
    public var geometryDelayMs: Double
    /// Measured less drawn, once the difference every speaker shares is taken out: positive means the measurement has the speaker
    /// nearer than the drawing does.
    public var differenceMs: Double
    /// The same as a distance in the air, in centimetres.
    public var distanceCm: Double
}

/// A measurement and the drawing, against each other. Both are delays that bring every speaker to the seat together, each
/// relative to the speaker that arrives last in its own run, so only the differences between speakers mean anything.
public enum GeometryCheck {
    /// How far a speaker may be from its drawn place before the two disagree: a little more than the creep the follower showed
    /// in the hardware session (0.2 ms in 15 s) and far more than the measurement's own noise (73 µs).
    public static let toleranceMs = 0.25

    /// The speakers whose delay differs between `measured` and `geometry` by more than the tolerance, after the difference
    /// common to all of them (the median) is taken out. Needs two speakers that both profiles have an alignment for.
    public static func disagreements(measured: RoomProfile, geometry: RoomProfile) -> [GeometryDisagreement] {
        let common = RoomSpeaker.allCases.filter { measured.alignment?[$0] != nil && geometry.alignment?[$0] != nil }
        guard common.count >= 2 else { return [] }
        let differences = common.map { measured.alignment(for: $0).delayMs - geometry.alignment(for: $0).delayMs }
        let sorted = differences.sorted()
        let middle = sorted.count / 2
        let shared = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        var found: [GeometryDisagreement] = []
        for (speaker, difference) in zip(common, differences) {
            let residual = difference - shared
            guard abs(residual) > toleranceMs + 1e-6 else { continue }
            found.append(GeometryDisagreement(speaker: speaker, measuredDelayMs: measured.alignment(for: speaker).delayMs,
                                              geometryDelayMs: geometry.alignment(for: speaker).delayMs, differenceMs: residual,
                                              distanceCm: abs(residual) * SpeakerGeometry.defaultSpeedOfSound / 10))
        }
        return found
    }

    /// The words for the room-correction window; nil when nothing disagrees.
    public static func warning(_ found: [GeometryDisagreement]) -> String? {
        guard !found.isEmpty else { return nil }
        let list = found.map { String(format: "%@ by %.1f ms (%.0f cm)", $0.speaker.plainName, abs($0.differenceMs), $0.distanceCm) }.joined(separator: ", ")
        return "The measurement and the drawing disagree by more than \(toleranceMs) ms: \(list). The drawing or the cabling may be off."
    }
}

extension GroupRoomProfile {
    /// The warning for `group`: its bound profile, if measured or imported, against the room as drawn now. A drawn profile, or
    /// none, raises nothing.
    public static func geometryWarning(for group: SpeakerGroup, in book: RoomProfileBook) -> String? {
        guard let chosen = chosen(for: group, in: book), chosen.origin != .geometry, let drawn = GroupGeometryProfile.make(for: group) else { return nil }
        return GeometryCheck.warning(GeometryCheck.disagreements(measured: chosen, geometry: drawn))
    }

    /// The profile a group should play with: the one it is bound to; else the newest measured or imported one that fits (a
    /// measurement replaces the drawing); else the drawing's; else none.
    public static func suggested(for group: SpeakerGroup, in book: RoomProfileBook) -> RoomProfile? {
        if let bound = chosen(for: group, in: book) { return bound }
        let fitting = profiles(for: group, in: book)
        return fitting.first { $0.origin != .geometry } ?? fitting.first
    }
}
