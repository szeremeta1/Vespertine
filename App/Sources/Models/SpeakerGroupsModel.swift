//
// Vespertine: the saved speaker groups, for the settings list. Read only when the list is shown (the feature is off for
// everyone until its switch is turned on), and every change is written at once.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineAudio

@MainActor @Observable
final class SpeakerGroupsModel {
    private(set) var book: SpeakerGroupBook
    /// Set when the last write failed; the list still shows the change.
    private(set) var lastError: String?
    /// Called after every change is written, so the engine hears of it.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called for a group just made (created, or duplicated from another), before it is written.
    @ObservationIgnored var onNewGroup: ((_ new: SpeakerGroup, _ copiedFrom: SpeakerGroup?) -> Void)?
    @ObservationIgnored private let store: SpeakerGroupStore
    /// Groups a newer Vespertine wrote, or that are damaged: shown as a count and written back as they were.
    @ObservationIgnored private var unreadable: [Any]

    init(directory: URL) {
        store = SpeakerGroupStore(directory: directory)
        let loaded = store.load()
        book = SpeakerGroupBook(groups: loaded?.groups ?? [])
        unreadable = loaded?.unreadable ?? []
    }

    var groups: [SpeakerGroup] { book.groups }
    var unreadableCount: Int { unreadable.count }

    func upsert(_ group: SpeakerGroup) {
        book.upsert(group)
        persist()
    }

    /// Saves the group a finished draft makes; nil when the draft isn't ready.
    @discardableResult
    func create(_ draft: SpeakerGroupDraft) -> SpeakerGroup? {
        guard var group = draft.makeGroup() else { return nil }
        // Speakers placed from the start (the editor's presets), so the group plays as soon as it is made.
        if let preset = GroupPresets.startingPreset(for: group), let placed = GroupPresets.apply(preset, to: group) { group = placed }
        onNewGroup?(group, nil)
        upsert(group)
        return group
    }

    func duplicate(_ id: UUID) {
        let original = book.group(id)
        if let copy = book.duplicate(id) {
            onNewGroup?(copy, original)
            persist()
        }
    }

    func remove(_ id: UUID) {
        book.remove(id)
        persist()
    }

    /// A DAC plugged into another USB port has another UID: the groups that found their members that way are saved with the new UIDs,
    /// so they stay connected (and the engine hears of it like of any change).
    func followUSBPorts(amongUIDs uids: [String]) {
        var next = book
        guard next.followUSBPorts(amongUIDs: uids) else { return }
        book = next
        persist()
    }

    private func persist() {
        do {
            try store.save(book.groups, unreadable: unreadable)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        onChange?()
    }

    /// "Fosi ZD3 + FiiO K11 · 4 channels"
    static func summary(_ group: SpeakerGroup) -> String {
        let names = group.members.map(\.name).joined(separator: " + ")
        let channels = group.totalChannels
        return String(localized: "\(names) · \(channels) channels", comment: "Speaker Groups list: the group's outputs, a dot, then its channel count (plural by the count).")
    }

    /// Why the group can't be played yet, in a sentence, or nil when it is ready.
    static func problem(_ group: SpeakerGroup) -> String? {
        group.issues.first?.description
    }
}
