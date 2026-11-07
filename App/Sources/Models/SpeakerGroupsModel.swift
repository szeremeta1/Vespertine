//
// Vespertine — the saved speaker groups, for the settings list. Read only when the list is shown (the feature is off for
// everyone until its switch is turned on), and every change is written at once.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The words here are plain English for now, not in the string catalog: they go in with the screens that stay (see
// SpeakerGroup.swift in VespertineKit).
//

import Foundation
import Observation
import VespertineAudio

@MainActor @Observable
final class SpeakerGroupsModel {
    private(set) var book: SpeakerGroupBook
    /// Set when the last write failed; the list still shows the change.
    private(set) var lastError: String?
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

    func duplicate(_ id: UUID) {
        if book.duplicate(id) != nil { persist() }
    }

    func remove(_ id: UUID) {
        book.remove(id)
        persist()
    }

    private func persist() {
        do {
            try store.save(book.groups, unreadable: unreadable)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "Fosi ZD3 + FiiO K11 · 4 channels"
    static func summary(_ group: SpeakerGroup) -> String {
        let names = group.members.map(\.name).joined(separator: " + ")
        let channels = group.totalChannels
        return "\(names) · \(channels) \(channels == 1 ? "channel" : "channels")"
    }

    /// Why the group can't be played yet, in a sentence, or nil when it is ready.
    static func problem(_ group: SpeakerGroup) -> String? {
        group.issues.first?.description
    }
}
