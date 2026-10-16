//
// Vespertine — Up Next and History: the queue panel beside the library, as in Apple Music.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

/// Up Next and History, on the right of the window where the Inspector goes (showing one hides the other).
struct QueuePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Up Next view", selection: $model.queueTab) {
                ForEach(QueueTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Hairline()
            switch model.queueTab {
            case .upNext: UpNextList()
            case .history: HistoryList()
            }
        }
        .background(Palette.panel)
    }
}

// MARK: - Up Next

/// What's playing, then Playing Next (songs you added), then the rest of what you started. Drag to reorder within a
/// section, Delete removes the selected songs, Return or a double-click plays one, and the menu moves songs between them.
struct UpNextList: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<UUID>()

    var body: some View {
        let player = model.player
        let playingNext = Array(player.playingNext)
        let continuing = Array(player.continuing)
        VStack(spacing: 0) {
            header(player)
            Hairline()
            if let current = player.current {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: String(localized: "Now Playing"))
                    QueueRow(entry: current, isCurrent: true)
                        .contextMenu { currentMenu(current) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            if player.upcoming.isEmpty {
                empty(player)
            } else {
                List(selection: $selection) {
                    if !playingNext.isEmpty {
                        Section {
                            ForEach(playingNext) { entry in QueueRow(entry: entry, isCurrent: false).tag(entry.id) }
                                .onMove { move($0, to: $1, in: playingNext, after: continuing.first, playingNext: true) }
                        } header: {
                            HStack {
                                SectionLabel(text: String(localized: "Playing Next"))
                                Spacer()
                                Button(String(localized: "Clear", comment: "Clears the upcoming queue")) { player.clearPlayingNext() }
                                    .buttonStyle(.plain)
                                    .font(Typeface.ui(11, weight: .medium))
                                    .foregroundStyle(Palette.brassHi)
                            }
                        }
                    }
                    if !continuing.isEmpty {
                        Section {
                            ForEach(continuing) { entry in QueueRow(entry: entry, isCurrent: false).tag(entry.id) }
                                .onMove { move($0, to: $1, in: continuing, after: nil, playingNext: false) }
                        } header: {
                            SectionLabel(text: playingNext.isEmpty ? String(localized: "Up Next") : String(localized: "Continue Playing"))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    menu(for: ids)
                } primaryAction: { ids in
                    if let id = ordered(ids).first { player.jump(to: id) }
                }
                .onDeleteCommand { remove(selection) }
                .onKeyPress(.return) {
                    guard let id = ordered(selection).first else { return .ignored }
                    player.jump(to: id)
                    return .handled
                }
            }
        }
        // Songs that have left Up Next (played, removed) don't stay selected.
        .onChange(of: player.upcoming.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }

    private func header(_ player: PlayerController) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                let upcoming = player.upcoming
                if upcoming.isEmpty {
                    Text("Nothing queued").font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                } else {
                    let length = Duration.seconds(upcoming.reduce(0) { $0 + $1.track.duration })
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                    HStack(spacing: 0) {
                        Text("\(upcoming.count) songs")
                        Text(verbatim: " · \(length)")
                    }
                    .font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").font(.system(size: 12)) }
                .buttonStyle(TransportIconStyle(active: player.shuffle))
                .help("Shuffle")
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.shuffle ? String(localized: "On", comment: "Shuffle state") : String(localized: "Off", comment: "Shuffle state"))
            Button {
                player.repeatMode = switch player.repeatMode { case .off: .all; case .all: .one; case .one: .off }
            } label: { Image(systemName: player.repeatMode.symbol).font(.system(size: 12)) }
                .buttonStyle(TransportIconStyle(active: player.repeatMode != .off))
                .help("Repeat")
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode.spokenName)
            Button(String(localized: "Clear", comment: "Clears the upcoming queue")) { player.clearUpcoming() }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(player.upcoming.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func empty(_ player: PlayerController) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet")
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(Palette.brass)
            Text("Nothing queued").font(Typeface.serif(17)).foregroundStyle(Palette.text2)
            Text("Choose Play Next or Add to Queue from any song’s menu.")
                .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func currentMenu(_ entry: QueueEntry) -> some View {
        Button("Go to Album") { model.goToAlbum(of: entry.track) }
        AddToPlaylistMenu(trackIDs: entry.track.id.map { [$0] } ?? [])
        Button(model.library.isFavorite(entry.track) ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
            model.toggleFavorite([entry.track])
        }
        Button("Show in Finder") { model.showInFinder([entry.track]) }
    }

    @ViewBuilder private func menu(for ids: Set<UUID>) -> some View {
        let player = model.player
        let entries = player.upcoming.filter { ids.contains($0.id) }
        let tracks = entries.map(\.track)
        if !entries.isEmpty {
            if entries.count == 1 { Button("Play Now") { player.jump(to: entries[0].id) } }
            Button("Play Next") { player.playNext(entries: entries.map(\.id)) }
            Divider()
            if entries.count == 1 { Button("Go to Album") { model.goToAlbum(of: tracks[0]) } }
            AddToPlaylistMenu(trackIDs: tracks.compactMap(\.id))
            Button(tracks.allSatisfy(model.library.isFavorite) ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
                model.toggleFavorite(tracks)
            }
            Button("Show in Finder") { model.showInFinder(tracks) }
            Divider()
            Button("Remove from Up Next", role: .destructive) { remove(ids) }
        }
    }

    /// The chosen entries in the order they play.
    private func ordered(_ ids: Set<UUID>) -> [UUID] { model.player.upcoming.map(\.id).filter(ids.contains) }

    private func remove(_ ids: Set<UUID>) {
        model.player.removeFromQueue(ids)
        selection.subtract(ids)
    }

    /// A drag within one section. The places are the section's as it was drawn; they're turned into entries at once,
    /// so a song ending meanwhile can't make the move take the wrong one.
    private func move(_ source: IndexSet, to destination: Int, in shown: [QueueEntry], after next: QueueEntry?, playingNext: Bool) {
        let ids = source.sorted().compactMap { shown.indices.contains($0) ? shown[$0].id : nil }
        let target = destination < shown.count ? shown[destination].id : next?.id
        model.player.moveUpcoming(ids, before: target, playingNext: playingNext)
    }
}

/// One song in Up Next: cover, title, artist, format and length, with a remove button on hover.
struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let entry: QueueEntry
    let isCurrent: Bool
    @State private var hovering = false

    var body: some View {
        let track = entry.track
        HStack(spacing: 10) {
            ArtworkView(key: model.artworkKey(track), size: 160, cornerRadius: 4).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(Typeface.ui(12.5)).foregroundStyle(isCurrent ? Palette.brassHi : Palette.text).lineLimit(1)
                Text(track.displayArtist.libraryDisplayName).font(Typeface.ui(11)).foregroundStyle(Palette.text2).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovering, !isCurrent {
                Button { model.player.removeFromQueue(entry.id) } label: {
                    Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Palette.text2)
                }
                .buttonStyle(.plain)
                .help("Remove from Up Next")
                .accessibilityHidden(true)   // an action of the row for VoiceOver (below)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(track.duration.clock).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
                    Text(track.formatSummary).font(Typeface.mono(9)).foregroundStyle(Palette.text3).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One VoiceOver stop per song: title, artist, length, format.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .modifier(QueueRowActions(entry: entry, isCurrent: isCurrent))
    }
}

private struct QueueRowActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let entry: QueueEntry
    let isCurrent: Bool

    func body(content: Content) -> some View {
        if isCurrent {
            content
        } else {
            content
                .accessibilityAction(named: "Play Now") { model.player.jump(to: entry.id) }
                .accessibilityAction(named: "Play Next") { model.player.playNext(entries: [entry.id]) }
                .accessibilityAction(named: "Remove from Up Next") { model.player.removeFromQueue(entry.id) }
        }
    }
}

// MARK: - History

/// Songs you've listened to, the most recent first, by day. Double-click or Return plays one; the menu queues them.
struct HistoryList: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [LibraryDatabase.HistoryEntry] = []
    @State private var selection = Set<Int64>()
    @State private var confirmClear = false

    private struct Day: Identifiable {
        let start: Date
        let entries: [LibraryDatabase.HistoryEntry]
        var id: Date { start }
    }

    var body: some View {
        let days = Self.days(entries)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Hairline()
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 26, weight: .ultraLight))
                        .foregroundStyle(Palette.brass)
                    Text("No history yet").font(Typeface.serif(17)).foregroundStyle(Palette.text2)
                    Text("Songs you listen to appear here, the most recent first.")
                        .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.entries) { entry in HistoryRow(entry: entry).tag(entry.id) }
                        } header: {
                            SectionLabel(text: Self.title(day.start))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: Int64.self) { ids in
                    menu(for: ids)
                } primaryAction: { ids in
                    let tracks = tracks(ids)
                    if !tracks.isEmpty { model.player.play(tracks, shuffled: false) }
                }
                .onDeleteCommand { remove(selection) }
                .onKeyPress(.return) {
                    let tracks = tracks(selection)
                    guard !tracks.isEmpty else { return .ignored }
                    model.player.play(tracks, shuffled: false)
                    return .handled
                }
            }
        }
        .task(id: "\(model.library.historyRevision)#\(model.library.revision)") {
            entries = model.library.history()
            selection.formIntersection(entries.map(\.id))
        }
        .confirmationDialog("Clear your play history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.library.clearHistory() }
        } message: {
            Text("The list of songs you’ve played is deleted. Play counts stay as they are.")
        }
    }

    @ViewBuilder private func menu(for ids: Set<Int64>) -> some View {
        let tracks = tracks(ids)
        if !tracks.isEmpty {
            Button("Play") { model.player.play(tracks, shuffled: false) }
            Button("Play Next") { model.player.playNext(tracks) }
            Button("Add to Queue") { model.player.addToQueue(tracks) }
            Divider()
            if tracks.count == 1 { Button("Go to Album") { model.goToAlbum(of: tracks[0]) } }
            AddToPlaylistMenu(trackIDs: tracks.compactMap(\.id))
            Button(tracks.allSatisfy(model.library.isFavorite) ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
                model.toggleFavorite(tracks)
            }
            Button("Show in Finder") { model.showInFinder(tracks) }
            Divider()
            Button("Remove from History", role: .destructive) { remove(ids) }
        }
    }

    /// The chosen plays' songs, in the order listed (most recent first).
    private func tracks(_ ids: Set<Int64>) -> [Track] { entries.filter { ids.contains($0.id) }.map(\.track) }

    private func remove(_ ids: Set<Int64>) {
        model.library.removeHistory(Array(ids))
        selection.subtract(ids)
    }

    private static func days(_ entries: [LibraryDatabase.HistoryEntry]) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        var current: (start: Date, entries: [LibraryDatabase.HistoryEntry])?
        for entry in entries {
            let start = calendar.startOfDay(for: entry.playedAt)
            if current?.start == start {
                current?.entries.append(entry)
            } else {
                if let current { days.append(Day(start: current.start, entries: current.entries)) }
                current = (start, [entry])
            }
        }
        if let current { days.append(Day(start: current.start, entries: current.entries)) }
        return days
    }

    /// "Today", "Yesterday", then the weekday and date (with the year when it isn't this year's).
    private static func title(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today", comment: "Play history: songs played today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday", comment: "Play history: songs played yesterday") }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return sameYear ? day.formatted(.dateTime.weekday(.wide).month(.wide).day())
                        : day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

/// One play in History: cover, title, artist and the time it was played.
struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryDatabase.HistoryEntry

    var body: some View {
        let track = entry.track
        HStack(spacing: 10) {
            ArtworkView(key: model.artworkKey(track), size: 160, cornerRadius: 4).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(Typeface.ui(12.5))
                    .foregroundStyle(model.player.current?.track.id == track.id ? Palette.brassHi : Palette.text).lineLimit(1)
                Text(track.displayArtist.libraryDisplayName).font(Typeface.ui(11)).foregroundStyle(Palette.text2).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(entry.playedAt, format: .dateTime.hour().minute())
                .font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Play") { model.player.play([track], shuffled: false) }
        .accessibilityAction(named: "Play Next") { model.player.playNext([track]) }
        .accessibilityAction(named: "Add to Queue") { model.player.addToQueue([track]) }
    }
}
