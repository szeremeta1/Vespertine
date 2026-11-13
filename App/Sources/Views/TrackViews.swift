//
// Vespertine: track tables: album tracklists, songs, playlists, search.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import VespertineLibrary
import SwiftUI

/// A row of a track table: a place in the table, and what is shown there now.
///
/// A row's identity and value are its place, not its song. SwiftUI applies a change of a table's rows to AppKit row by
/// row, and compares and copies every row whenever one of them changes: with a whole library re-sorted that was every
/// row moved (and, at worst, built and measured), seconds to minutes of the main thread. So a sort, or a rescan, leaves
/// the table's rows as they are and changes the songs in their slots, which only the rows on screen are watching.
nonisolated struct TrackRow: Identifiable, Hashable, Sendable {
    /// A song of the list, held by reference: sorting moves pointers, not everything the library knows about a song.
    final class Song: Sendable {
        let track: Track
        init(_ track: Track) { self.track = track }
    }

    /// What the cells of a table watch: counts the times any of its places came to show something else.
    @Observable
    final class Changes: @unchecked Sendable {
        fileprivate(set) var count = 0
    }

    /// What one place in the table shows. Read and changed on the main thread only.
    final class Slot: @unchecked Sendable {
        fileprivate var song: Song
        fileprivate var index: Int
        fileprivate let changes: Changes

        init(_ song: Song, index: Int, changes: Changes) {
            self.song = song
            self.index = index
            self.changes = changes
        }

        /// Whether the place shows something else from now on. The caller counts that in `changes`, once for the table.
        func show(_ song: Song, index: Int) -> Bool {
            guard self.song !== song || self.index != index else { return false }
            self.song = song
            self.index = index
            return true
        }
    }

    /// The row's place in the table as shown.
    let id: Int64
    let slot: Slot

    /// The song shown here. A cell that reads it is drawn again when the place shows another song.
    var track: Track { _ = slot.changes.count; return slot.song.track }
    /// The song's place in the list (in the whole playlist, for a filtered one), whatever the sort.
    var index: Int { _ = slot.changes.count; return slot.index }
    /// The same two as they are now, for passes over a whole list: nothing is watched, and no song is copied.
    var trackID: Int64? { slot.song.track.id }
    var place: Int { slot.index }

    static func == (a: TrackRow, b: TrackRow) -> Bool { a.id == b.id && a.slot === b.slot }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct TrackTable: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    var showAlbum = true
    var showArtist = true
    var reorderable: Playlist? = nil
    /// Songs the library has in several copies (a 24/192 and a vinyl transfer, stereo and 5.1): track ID → every copy,
    /// the row's among them. Their rows say how many, and open the list of them.
    var copies: [Int64: [Track]] = [:]
    /// A filtered playlist: each row's place in the whole playlist, and the whole (so edits keep what's hidden).
    var positions: [Int]? = nil
    var allTracks: [Track]? = nil

    @State private var selection = Set<Int64>()
    /// The selected songs, each with which of its copies in the list it is (a playlist can hold a song twice), so a
    /// change to the list selects the same entries again, not every copy of them.
    @State private var selectedEntries: [Int64: Set<Int>] = [:]
    /// A selection this table set itself, to follow the app's (`mirror`), not one made by clicking it.
    @State private var mirrored: Set<Int64>?
    /// The selected rows' places in the list (`TrackRow.index`), which a sort doesn't change: after one, the same
    /// entries are selected again where they are now.
    @State private var selectedPlaces = Set<Int>()
    @State private var sortOrder: [KeyPathComparator<TrackRow>] = []
    @State private var sorted = SortedRows()

    /// Album pages of multi-disc albums number tracks "2·1", "2·2"…, so disc 2 doesn't look like the list restarting.
    private func numbersDiscs(_ tracks: [Track]) -> Bool { !showAlbum && Set(tracks.compactMap(\.discNumber)).count > 1 }

    private func number(_ track: Track, discs: Bool) -> String {
        guard let n = track.trackNumber else { return "–" }
        return discs ? "\(track.discNumber ?? 1)·\(n)" : "\(n)"
    }

    var body: some View {
        // What the table shows: the list in its sort order. A long list is sorted off the main thread, and until that is
        // done the table goes on showing the rows it had, with the list they were made from.
        let content = sorted.content(tracks: self.tracks, positions: positions, allTracks: self.allTracks, order: sortOrder)
        let rows = content.rows, tracks = content.tracks, allTracks = content.allTracks
        let discs = numbersDiscs(tracks)
        // The Source column exists only while TIDAL is on and the library has a TIDAL account.
        let showsSource = model.library.tidalSource != nil
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            // Ideal widths add up to about 810 pt: what's left beside the sidebar and inspector in a 1440 pt window.
            TableColumn("#", value: \.index) { row in
                if model.player.current?.track.id == row.track.id, model.player.state != .stopped {
                    Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .rowForeground(Palette.brass)
                        .accessibilityLabel("Now Playing")
                } else {
                    Text(showAlbum ? "\(row.index + 1)" : number(row.track, discs: discs))
                        .font(Typeface.mono(11.5))
                        .rowForeground(Palette.text3)
                }
            }
            .width(discs ? 44 : 36)

            TableColumn("Title", value: \.track.title) { row in
                let unavailable = model.playability(of: row.track).reason
                Text(row.track.title)
                    .font(Typeface.ui(13))
                    .rowForeground(model.player.current?.track.id == row.track.id ? Palette.brassHi : Palette.text)
                    .opacity(row.track.isMissing || unavailable != nil ? 0.45 : 1)
                    .help(ifAny: unavailable)
            }
            .width(min: 160, ideal: 240)

            if showArtist {
                TableColumn("Artist", value: \.track.displayArtist) { row in
                    Text(row.track.displayArtist.libraryDisplayName).font(Typeface.ui(12.5)).rowForeground(Palette.text2)
                        .opacity(model.playability(of: row.track).isPlayable ? 1 : 0.45)
                }
                .width(min: 100, ideal: 140)
            }
            if showAlbum {
                TableColumn("Album", value: \.track.displayAlbum) { row in
                    Text(row.track.displayAlbum.libraryDisplayName).font(Typeface.ui(12.5)).rowForeground(Palette.text2)
                        .opacity(model.playability(of: row.track).isPlayable ? 1 : 0.45)
                }
                .width(min: 100, ideal: 150)
            }

            TableColumn("Format", value: \.track.sampleRate) { row in
                let format = row.track.formatLabel(tidal: row.track.id.flatMap { model.library.tidalRecords[$0] })
                HStack(spacing: 8) {
                    Text(format.text).font(Typeface.mono(11)).rowForeground(Palette.text2)
                        .lineLimit(1).fixedSize()
                        .opacity(model.playability(of: row.track).isPlayable ? 1 : 0.45)
                        .help(ifAny: format.help)
                    AnalysisTag(track: row.track).fixedSize()
                    if let copies = row.track.id.flatMap({ self.copies[$0] }) {
                        SongCopiesButton(model: model, track: row.track, copies: copies, list: tracks)
                    }
                }
            }
            .width(min: 150, ideal: 190)

            if showsSource {
                TableColumn("Source", value: \.track.sourceSortKey) { row in
                    SourceCell(track: row.track)
                }
                .width(min: 44, ideal: 52, max: 64)
            }

            TableColumn(Text(Image(systemName: "heart")).foregroundStyle(Palette.text3).accessibilityLabel("Favorite")) { row in
                // Selected rows show the heart through the row's own highlight (FavoriteCell), not by reading the
                // selection here: that redrew every row of the table on each click, which on a large library lagged
                // behind Shift- and Command-clicks.
                FavoriteCell(model: model, track: row.track, emphasized: model.player.current?.track.id == row.track.id)
            }
            .width(22)

            TableColumn("Time", value: \.track.duration) { row in
                Text(row.track.duration.clock).font(Typeface.mono(11.5)).rowForeground(Palette.text3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(Palette.window)
        .contextMenu(forSelectionType: Int64.self) { ids in
            let chosenRows = rows.filter { ids.contains($0.id) }
            let chosen = chosenRows.map(\.track)
            if chosen.contains(where: { $0.id == nil && $0.isTidalTrack }) {
                TidalCatalogTrackMenu(tracks: chosen)   // catalog songs with no library row
            } else if !chosen.isEmpty {
                TrackMenu(tracks: chosen, playlist: reorderable, all: allTracks ?? tracks, positions: Set(chosenRows.map(\.place)))
            }
        } primaryAction: { ids in
            // Double-clicking a row of a multi-selection gets the whole selection: play the row clicked, not whichever
            // song the set happens to list first (else the first selected, in the order shown).
            let clicked = Self.clickedRow().flatMap { rows.indices.contains($0) && ids.contains(rows[$0].id) ? $0 : nil }
            guard let index = clicked ?? rows.firstIndex(where: { ids.contains($0.id) }) else { return }
            guard model.playability(of: rows[index].track).isPlayable else { return }
            model.player.play(rows.map(\.track), startAt: index, transitions: model.library.transitions(of: reorderable))
        }
        .onAppear { mirror(Set(rows.filter { model.selectedTrackIDs.contains($0.trackID ?? -1) }.map(\.id))) }
        .onChange(of: model.selectedTrackIDs) { _, new in
            let selectedTracks = Set(rows.filter { selection.contains($0.id) }.compactMap(\.trackID))
            guard selectedTracks != new else { return }
            mirror(Set(rows.filter { new.contains($0.trackID ?? -1) }.map(\.id)))
        }
        .onChange(of: [content.list, content.arrangement]) { old, new in
            // Rows are numbered by their place in the table: when the list changes (a scan adds a song above) or is sorted,
            // select the same entries again rather than the same places, or Play, Return and Remove would act on whatever
            // moved there.
            if old.first == new.first {
                mirror(Set(rows.filter { selectedPlaces.contains($0.place) }.map(\.id)))
            } else {
                mirror(Self.rows(for: selectedEntries, in: rows.map { ($0.id, $0.trackID) }))
            }
        }
        .onChange(of: selection) { old, new in
            Self.focusClickedTable()
            // A plain click on one row of a multi-selection empties it in SwiftUI's table (macOS 27), where a list
            // should select just that row, as AppKit's own tables do; Shift-clicking after it then started from the top.
            if new.isEmpty, old.count > 1, let index = Self.clickedRow(), rows.indices.contains(index), old.contains(rows[index].id) {
                selection = [rows[index].id]
                return
            }
            selectedEntries = Self.entries(new, in: rows.map { ($0.id, $0.trackID) })
            selectedPlaces = Set(rows.filter { new.contains($0.id) }.map(\.place))
            // Only a selection made here is the app's new selection. Pages kept alive underneath (Favorites under an
            // album, Songs under search results) follow the selection too; when they wrote back their share of it, a
            // Shift- or Command-click selection on the page in front shrank to the songs both pages list.
            defer { mirrored = nil }
            guard new != mirrored else { return }
            model.selectedTrackIDs = Set(rows.filter { new.contains($0.id) }.compactMap(\.trackID))
            if !new.isEmpty, model.inspectorTab == .nowPlaying, model.player.current == nil { model.inspectorTab = .details }
        }
        .onKeyPress(.return) {
            guard let index = rows.firstIndex(where: { selection.contains($0.id) }) else { return .ignored }
            guard model.playability(of: rows[index].track).isPlayable else { return .handled }
            model.player.play(rows.map(\.track), startAt: index, transitions: model.library.transitions(of: reorderable))
            return .handled
        }
    }
}

extension TrackTable {
    /// The row under a plain click being handled now, as the table shows them (sorted), if the click is on a row.
    private static func clickedRow() -> Int? {
        guard let event = NSApp.currentEvent, event.modifierFlags.isDisjoint(with: [.command, .shift]),
              let table = clickedTable() else { return nil }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        return row >= 0 ? row : nil
    }

    /// The table under the click (plain, Shift or Command) being handled now, if there is one.
    private static func clickedTable() -> NSTableView? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp,
              var view = event.window?.contentView?.hitTest(event.locationInWindow) else { return nil }
        while !(view is NSTableView) {
            guard let parent = view.superview else { return nil }
            view = parent
        }
        return view as? NSTableView
    }

    /// Clicking a row selects it but leaves the keyboard where it was (the sidebar), so arrow keys, Return and ⌘A went
    /// there. A click on a table hands it the keyboard, as clicking an AppKit table does.
    private static func focusClickedTable() {
        guard let table = clickedTable(), let window = table.window, window.firstResponder !== table else { return }
        window.makeFirstResponder(table)
    }

    /// Selects `rows` to follow the app's selection (or keep it across a reload), without making it the app's selection.
    private func mirror(_ rows: Set<Int64>) {
        guard rows != selection else { return }
        mirrored = rows
        selection = rows
    }

    /// Each selected row (of rows in the order shown, with their songs' IDs) as its song and which copy of it it is.
    static func entries(_ selected: Set<Int64>, in rows: [(row: Int64, song: Int64?)]) -> [Int64: Set<Int>] {
        var copies: [Int64: Int] = [:], entries: [Int64: Set<Int>] = [:]
        for (row, song) in rows {
            guard let id = song else { continue }
            let copy = copies[id, default: 0]
            copies[id] = copy + 1
            if selected.contains(row) { entries[id, default: []].insert(copy) }
        }
        return entries
    }

    /// The rows that hold `entries` now.
    static func rows(for entries: [Int64: Set<Int>], in rows: [(row: Int64, song: Int64?)]) -> Set<Int64> {
        guard !entries.isEmpty else { return [] }
        var copies: [Int64: Int] = [:], selected = Set<Int64>()
        for (row, song) in rows {
            guard let id = song, let wanted = entries[id] else { continue }
            let copy = copies[id, default: 0]
            copies[id] = copy + 1
            if wanted.contains(copy) { selected.insert(row) }
        }
        return selected
    }
}

/// What a track table shows: the rows in their sort order, with the list they were made from.
struct TableContent {
    var rows: [TrackRow] = []
    var tracks: [Track] = []
    var allTracks: [Track]? = nil
    /// Counts the lists shown: other songs get a new number, the same songs in another order keep theirs.
    var list = 0
    /// Counts every change of the rows, a sort included.
    var arrangement = 0
}

/// The table's rows in their sort order, kept between evaluations of the table: one click re-evaluates it several times
/// (the selection, the inspector), and sorting a whole library each time was most of what a click cost.
///
/// A long list is sorted off the main thread (sorting 20,000 titles takes a few hundred milliseconds): the table shows
/// what it showed until the new order is ready, then is evaluated again.
@Observable
final class SortedRows {
    typealias Key = (tracks: [Track], positions: [Int]?, order: [KeyPathComparator<TrackRow>])

    /// Lists up to this long are sorted at once, on the main thread: an album, most playlists.
    nonisolated static let immediateLimit = 1000

    /// Changes when a sort done off the main thread is ready, which has the table evaluated again.
    private var landed = 0
    @ObservationIgnored private var key: Key?
    @ObservationIgnored private var shown = TableContent()
    @ObservationIgnored private var pending: (key: Key, task: Task<Void, Never>)?
    /// The list's songs as rows hold them, kept from one sort of a list to the next.
    @ObservationIgnored private var songs: (tracks: [Track], songs: [TrackRow.Song])?
    /// The table's places, kept for as long as the table: a row is the same row whatever it shows.
    @ObservationIgnored private var rows: [TrackRow] = []
    @ObservationIgnored private let changes = TrackRow.Changes()

    /// Whether a sort is being worked out off the main thread.
    var isSorting: Bool { pending != nil }

    func content(tracks: [Track], positions: [Int]?, allTracks: [Track]? = nil, order: [KeyPathComparator<TrackRow>]) -> TableContent {
        _ = landed
        // Usually the very same array as last time, which compares equal at once.
        func matches(_ key: Key) -> Bool { key.order == order && key.positions == positions && key.tracks == tracks }
        if let key, matches(key) {
            pending?.task.cancel()
            pending = nil
            shown.allTracks = allTracks
            return shown
        }
        if let pending, matches(pending.key) { return shown }
        pending?.task.cancel()
        pending = nil
        let key: Key = (tracks, positions, order)
        let known = songs.flatMap { $0.tracks == tracks ? $0.songs : nil }
        guard !order.isEmpty else {
            show(known ?? tracks.map(TrackRow.Song.init), in: nil, for: key, allTracks: allTracks)
            return shown
        }
        guard let columns = TrackSort.columns(order, tracks: tracks, positions: positions) else {
            // A sort TrackSort has no values for: compare rows of the list themselves.
            let songs = known ?? tracks.map(TrackRow.Song.init)
            let apart = TrackRow.Changes()
            let unsorted = songs.indices.map { TrackRow(id: Int64($0), slot: TrackRow.Slot(songs[$0], index: positions?[$0] ?? $0, changes: apart)) }
            show(songs, in: unsorted.sorted(using: order).map { Int($0.id) }, for: key, allTracks: allTracks)
            return shown
        }
        guard tracks.count > Self.immediateLimit else {
            show(known ?? tracks.map(TrackRow.Song.init), in: TrackSort.order(columns, count: tracks.count), for: key, allTracks: allTracks)
            return shown
        }
        let task = Task { [weak self] in
            let (sorted, songs) = await Task.detached(priority: .userInitiated) {
                (TrackSort.order(columns, count: tracks.count), known ?? tracks.map(TrackRow.Song.init))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.show(songs, in: sorted, for: key, allTracks: allTracks)
            self.landed += 1
        }
        pending = (key, task)
        return shown
    }

    /// Puts the list's songs in the table's places, in `order` (as they are, when nil).
    private func show(_ songs: [TrackRow.Song], in order: [Int]?, for key: Key, allTracks: [Track]?) {
        var changed = false
        for place in songs.indices {
            let from = order?[place] ?? place
            let index = key.positions?[from] ?? from
            if place < rows.count {
                if rows[place].slot.show(songs[from], index: index) { changed = true }
            } else {
                rows.append(TrackRow(id: Int64(place), slot: TrackRow.Slot(songs[from], index: index, changes: changes)))
            }
        }
        if changed { changes.count += 1 }
        if rows.count > songs.count { rows.removeLast(rows.count - songs.count) }
        let sameList = self.key.map { $0.positions == key.positions && $0.tracks == key.tracks } ?? false
        shown = TableContent(rows: rows, tracks: key.tracks, allTracks: allTracks, list: shown.list + (sameList ? 0 : 1), arrangement: shown.arrangement + 1)
        self.key = key
        self.songs = (key.tracks, songs)
    }
}

/// The order a sort puts a list in, worked out from the sorted columns' values alone, so it can run off the main thread
/// and never moves whole songs around while it sorts.
nonisolated enum TrackSort {
    /// One sorted column: its value in every row of the list, and the direction.
    struct Column: Sendable {
        enum Values: Sendable {
            case numbers([Double])
            case text([String])
        }
        var values: Values
        var forward: Bool
    }

    /// The columns of `order`, most significant first. nil when one of them isn't a column of the track table.
    @MainActor static func columns(_ order: [KeyPathComparator<TrackRow>], tracks: [Track], positions: [Int]?) -> [Column]? {
        var columns: [Column] = []
        for comparator in order {
            let values: Column.Values
            let keyPath = comparator.keyPath
            if keyPath == \TrackRow.index {
                values = .numbers(tracks.indices.map { Double(positions?[$0] ?? $0) })
            } else if keyPath == \TrackRow.track.sampleRate {
                values = .numbers(tracks.map(\.sampleRate))
            } else if keyPath == \TrackRow.track.duration {
                values = .numbers(tracks.map(\.duration))
            } else if keyPath == \TrackRow.track.title {
                values = .text(tracks.map(\.title))
            } else if keyPath == \TrackRow.track.displayArtist {
                values = .text(tracks.map(\.displayArtist))
            } else if keyPath == \TrackRow.track.displayAlbum {
                values = .text(tracks.map(\.displayAlbum))
            } else {
                return nil
            }
            columns.append(Column(values: values, forward: comparator.order == .forward))
        }
        return columns
    }

    /// Each string's place among the different strings, in the order the table's text columns sort by (as the Finder
    /// sorts names: "Track 9" before "Track 10"). Strings that order compares as the same share a place. Comparing
    /// places is what makes a long sort quick: the slow comparison runs once per different string, not per pair of rows.
    static func ranks(_ strings: [String]) -> [Double] {
        let comparator = String.StandardComparator.localizedStandard
        let different = Set(strings).sorted { comparator.compare($0, $1) == .orderedAscending }
        var rank: [String: Double] = [:]
        rank.reserveCapacity(different.count)
        var place = 0.0
        for (i, string) in different.enumerated() {
            if i > 0, comparator.compare(different[i - 1], string) != .orderedSame { place += 1 }
            rank[string] = place
        }
        return strings.map { rank[$0] ?? 0 }
    }

    /// The rows' places in the list, in the order `columns` sort them: rows that every column holds equal stay in the
    /// list's order, as a stable sort leaves them.
    static func order(_ columns: [Column], count: Int) -> [Int] {
        let columns: [(values: [Double], forward: Bool)] = columns.map { column in
            switch column.values {
            case .numbers(let numbers): (numbers, column.forward)
            case .text(let strings): (ranks(strings), column.forward)
            }
        }
        var order = Array(0..<count)
        order.sort { a, b in
            for column in columns {
                let x = column.values[a], y = column.values[b]
                if x != y { return column.forward ? x < y : x > y }
            }
            return a < b
        }
        return order
    }
}

/// Shows the result of a file analysis inline, only when it's worth attention.
struct AnalysisTag: View {
    let track: Track
    var body: some View {
        switch track.analysisVerdict {
        case "paddedBitDepth":
            tag("\(track.effectiveBitDepth ?? 16)-BIT", color: Palette.copper).help("Only \(track.effectiveBitDepth ?? 16) of \(track.bitDepth ?? 24) bits carry audio (zero-padded)")
        case "upsampled":
            tag("UPSAMPLED?", color: Palette.copper).help("A steep cutoff far below this file’s limit, as a 44.1/48 kHz master upsampled to a hi-res rate shows. A steep mastering low-pass or a DSD conversion filter can look the same.")
        case "possibleLossyOrigin":
            tag("LOSSY ORIGIN?", color: Palette.copper).help("A steep, consistent cutoff, as MP3, AAC and Opus encodes show. Steep mastering or anti-alias filters, FM broadcast sources and historical remasters can look the same.")
        case "bandwidthExtended":
            tag("SYNTHETIC HF?", color: Palette.copper).help("A step at a lossy-looking cutoff with a flat shelf above it that follows the music, as SBR or AI “enhancement” leaves. An exciter or noise reduction on a band-limited recording can look similar.")
        case "genuine" where (track.bitDepth ?? 0) >= 24 && track.effectiveBitDepth == track.bitDepth:
            // Only when the word length was checked (float and 32-bit files aren't).
            tag("TRUE \(track.bitDepth ?? 24)", color: Palette.brass).help("No zero padding: all \(track.bitDepth ?? 24) bits are in use")
        default:
            EmptyView()
        }
    }

    private func tag(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(Typeface.mono(8.5, weight: .semibold))
            .letterSpacing(0.6)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.foreground.opacity(0.5)))
            .rowForeground(color)
    }
}

struct TrackMenu: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    var playlist: Playlist? = nil
    var all: [Track] = []
    var positions: Set<Int>? = nil

    var body: some View {
        // A TIDAL song that can't play now (offline, signed out, not streamable here) can't be played or queued.
        let canPlay = tracks.contains { model.playability(of: $0).isPlayable }
        Button("Play") { model.player.play(tracks, shuffled: false) }.disabled(!canPlay)
        Button("Play Next") { model.player.playNext(tracks) }.disabled(!canPlay)
        Button("Add to Queue") { model.player.addToQueue(tracks) }.disabled(!canPlay)
        AddToPlaylistMenu(trackIDs: tracks.compactMap(\.id))
        Button(tracks.allSatisfy(model.library.isFavorite) ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
            model.toggleFavorite(tracks)
        }
        Divider()
        Button("Get Info") {
            model.selectedTrackIDs = Set(tracks.compactMap(\.id))
            model.inspectorTab = .details
            model.showInspector = true
        }
        Button("Analyze Bit Depth & Spectrum") {
            // Every chosen song, not just the first: the inspector shows the first and the batch's progress.
            model.analysis.analyze(tracks)
            model.selectedTrackIDs = Set(tracks.compactMap(\.id))
            model.inspectorTab = .analysis
            model.showInspector = true
        }
        Button("Look Up on MusicBrainz…") { model.lookupTracks = tracks }
        Button("Show in Finder") { model.showInFinder(tracks) }
        TidalRowsMenu(tracks: tracks)
        if let playlist, !playlist.isSmart {
            Divider()
            Button("Remove from Playlist", role: .destructive) {
                let remove = Set(tracks.compactMap(\.id))
                let remaining = all.enumerated().filter { index, track in
                    if let positions { return !positions.contains(index) }
                    return !remove.contains(track.id ?? -1)
                }.compactMap { $0.element.id }
                model.library.setPlaylistOrder(remaining, playlist: playlist)
            }
        }
    }
}

// MARK: - Source column

extension View {
    /// A tooltip when there is text for one; otherwise the view as it is (no empty tooltip).
    @ViewBuilder func help(ifAny text: String?) -> some View {
        if let text, !text.isEmpty { help(text) } else { self }
    }
}

/// Where a song comes from: a drive, a share, or the TIDAL account (a "T" in a rounded square; a check once downloaded).
struct SourceCell: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        let kind = model.trackSource(of: track)
        HStack(spacing: 3) {
            switch kind {
            case .local: Image(systemName: "internaldrive")
            case .share: Image(systemName: "server.rack")
            case .tidalStreaming: TidalGlyph()
            case .tidalDownloaded:
                TidalGlyph()
                Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold))
            }
        }
        .font(.system(size: 11))
        .rowForeground(Palette.text3)
        .opacity(model.playability(of: track).isPlayable ? 1 : 0.45)
        .help(kind.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.help)
    }
}

/// TIDAL's mark, drawn small: a "T" in a rounded square.
struct TidalGlyph: View {
    var body: some View {
        Text("T")
            .font(.system(size: 8, weight: .bold))
            .frame(width: 13, height: 13)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1))
    }
}

// MARK: - Songs / search / playlists

/// Songs with their filter facts, loaded together.
struct SongList {
    var tracks: [Track] = []
    var facts: [FilterFacts] = []
    /// Pages that list a song once, however many versions it has (Favorites): each track's song, as an index
    /// into `songs`, and every song's versions. nil on pages that list every file.
    var songOf: [Int]? = nil
    var songs: [[Track]] = []
    /// Every copy of each song in the library, listed or not.
    var allCopies: [[Track]] = []

    init() {}
    @MainActor init(_ tracks: [Track], model: AppModel) {
        self.tracks = tracks
        facts = model.trackFacts(tracks)
    }

    /// `tracks` as songs, in the order the songs first appear: each listed once, by the copies of it among `tracks` (a
    /// favorite is the copy hearted; where an album's copies are bundled, all of them are), with every copy of it in the
    /// library a click away (`allCopies`).
    @MainActor init(songs tracks: [Track], model: AppModel) {
        var listed: [Track] = [], songOf: [Int] = []
        for song in model.library.songs(listing: tracks) {
            listed += song.listed
            songOf += Array(repeating: songs.count, count: song.listed.count)
            songs.append(song.listed)
            allCopies.append(song.all)
        }
        self.tracks = listed
        self.songOf = songOf
        facts = model.trackFacts(listed)
    }
}

/// A page of songs with its filter bar: Songs, Favorites, a playlist.
struct SongsPage<Extra: View, Empty: View>: View {
    @Environment(AppModel.self) private var model
    let scope: FilterScope
    let title: String
    let list: SongList
    /// Whether the subtitle counts them as songs rather than tracks.
    var countsSongs = false
    var kicker = ""
    var playlist: Playlist? = nil
    @ViewBuilder var extra: Extra
    @ViewBuilder var empty: Empty

    var body: some View {
        let filter = model.filter(scope)
        let favorites = model.library.favoriteIDs
        let indices = filter.isEmpty || list.facts.count != list.tracks.count ? Array(list.tracks.indices)
            : list.tracks.indices.filter { filter.matches(list.facts[$0], favorite: favorites.contains(list.tracks[$0].id ?? -1)) }
        let (shown, others): ([Track], [Int64: [Track]]) = list.songOf.map { oneVersionEach(indices, songOf: $0) } ?? (indices.map { list.tracks[$0] }, [:])
        VStack(spacing: 0) {
            PageHeader(title: title, meta: meta(shown, filtered: !filter.isEmpty)) {
                extra
                PlayShuffleButtons(disabled: shown.isEmpty) { shuffled in
                    model.player.play(shown, shuffled: shuffled, allowing: model.allowing(filter, perAlbum: false))
                }
            }
            if list.tracks.isEmpty {
                empty
            } else {
                FilterBar(scope: scope, items: .songs(list.tracks, facts: list.facts, model: model))
                    .padding(.bottom, 10)
                if shown.isEmpty {
                    NoMatchesView(title: "No songs match these filters") { model.setFilter(LibraryFilter(), for: scope) }
                    Spacer(minLength: 0)
                } else {
                    // A filtered playlist keeps its own numbers, and edits through it keep the songs out of view.
                    let partial = !filter.isEmpty && playlist?.isSmart == false
                    TrackTable(tracks: shown, reorderable: playlist, copies: others,
                               positions: partial ? indices : nil, allTracks: partial ? list.tracks : nil)
                }
            }
        }
        .background(Palette.window)
    }

    /// A song in several copies shows once: the copy listed (a favorite copy, on Favorites) that plays on this output among
    /// those the filter lets through (the 5.1 one when the page asks for multichannel), its other copies a click away.
    private func oneVersionEach(_ indices: [Int], songOf: [Int]) -> ([Track], [Int64: [Track]]) {
        var order: [Int] = []
        var passing: [Int: [Track]] = [:]
        for i in indices {
            if passing[songOf[i]] == nil { order.append(songOf[i]) }
            passing[songOf[i], default: []].append(list.tracks[i])
        }
        let shown = order.map { model.listedCopy(of: passing[$0] ?? []) }
        let all = order.map { list.allCopies.indices.contains($0) ? list.allCopies[$0] : list.songs[$0] }
        return (shown, Dictionary(zip(shown, all).compactMap { t, copies in
            guard let id = t.id, copies.count > 1 else { return nil }
            return (id, copies)
        }, uniquingKeysWith: { a, _ in a }))
    }

    private func meta(_ shown: [Track], filtered: Bool) -> String {
        let n = shown.count
        let total = list.songOf == nil ? list.tracks.count : list.songs.count
        let count = switch (filtered, countsSongs) {
        case (true, true): String(localized: "\(n) of \(total) songs")
        case (true, false): String(localized: "\(n) of \(total) tracks")
        case (false, true): String(localized: "\(n) songs")
        case (false, false): String(localized: "\(n) tracks")
        }
        return "\(kicker)\(count) · \(shown.reduce(0) { $0 + $1.duration }.longDuration)"
    }
}

struct SongsView: View {
    @Environment(AppModel.self) private var model
    @State private var list = SongList()

    var body: some View {
        SongsPage(scope: .sidebar(.songs), title: String(localized: "Songs"), list: list) { EmptyView() } empty: { Spacer() }
            .task(id: model.library.revision) {
                // A scan changes the library many times a second: read it once things settle, and off the main thread.
                if !list.tracks.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled else { return }
                let database = model.library.database
                let tracks = await Task.detached(priority: .userInitiated) { (try? database.allTracks()) ?? [] }.value
                guard !Task.isCancelled else { return }
                list = SongList(tracks, model: model)
            }
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var results = SongList()
    @State private var albums: [Album] = []
    @State private var artists: [LibraryDatabase.ArtistSummary] = []
    @State private var genres: [GenreSummary] = []
    private let scope = FilterScope.search

    var body: some View {
        let filter = model.filter(scope)
        let favorites = model.library.favoriteIDs
        let songs = filter.isEmpty || results.facts.count != results.tracks.count ? results.tracks
            : results.tracks.indices.filter { filter.matches(results.facts[$0], favorite: favorites.contains(results.tracks[$0].id ?? -1)) }.map { results.tracks[$0] }
        // Albums by their own facts; artists and genres when one of their albums passes.
        let albums = model.filtered(self.albums, by: filter)
        let albumFamilies = AlbumFamilies.visibleGroups(albums, among: model.library.albums)
        let artists = filter.isEmpty ? self.artists : {
            let keep = Set(model.artists(filter).map { $0.name.lowercased() })
            return self.artists.filter { keep.contains($0.name.lowercased()) }
        }()
        let genres = filter.isEmpty ? self.genres : {
            let keep = Set(model.genres(filter).map(\.key))
            return self.genres.filter { keep.contains($0.key) }
        }()
        let found = !(results.tracks.isEmpty && self.albums.isEmpty && self.artists.isEmpty && self.genres.isEmpty)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: String(localized: "\u{201C}\(query)\u{201D}", comment: "Search results title: the search text in quotation marks"), meta: meta(genres: genres.count, artists: artists.count, albums: albumFamilies.count, songs: songs.count)) {
                PlayShuffleButtons(disabled: songs.isEmpty) { shuffled in
                    model.player.play(songs, shuffled: shuffled, allowing: model.allowing(filter, perAlbum: false))
                }
            }
            if !found {
                Text("Nothing matches.").font(Typeface.ui(13)).foregroundStyle(Palette.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FilterBar(scope: scope, items: .songs(results.tracks, facts: results.facts, model: model, alsoOffering: self.albums.map(\.facts)))
                    .padding(.bottom, 12)
                if songs.isEmpty && albums.isEmpty && artists.isEmpty && genres.isEmpty {
                    NoMatchesView(title: "No results match these filters") { model.setFilter(LibraryFilter(), for: scope) }
                    Spacer(minLength: 0)
                }
                if !genres.isEmpty {
                    shelf("Genres", count: genres.count) {
                        ForEach(genres) { GenreTile(genre: $0, filter: filter).frame(width: 120) }
                    }
                }
                if !artists.isEmpty {
                    shelf("Artists", count: artists.count) {
                        ForEach(artists) { ArtistTile(artist: $0, filter: filter).frame(width: 136) }
                    }
                }
                if !albumFamilies.isEmpty {
                    shelf("Albums", count: albumFamilies.count) {
                        ForEach(albumFamilies) { family in
                            if family.editions.count > 1 {
                                AlbumFamilyCard(family: family).frame(width: 150)
                            } else {
                                AlbumCard(album: family.representative).frame(width: 150)
                            }
                        }
                    }
                }
                if !songs.isEmpty {
                    sectionTitle("Songs", count: songs.count).padding(.top, 6)
                    TrackTable(tracks: songs)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .background(Palette.window)
        .task(id: "\(query)#\(model.library.revision)") {
            try? await Task.sleep(for: .milliseconds(120))
            // Typing on, or a scan changing the library again, cancels this and starts another: only the last one searches.
            guard !Task.isCancelled else { return }
            results = SongList(model.library.search(query), model: model)
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            func matches(_ text: String) -> Bool { words.allSatisfy { text.localizedStandardContains($0) } }
            func startsWith(_ text: String) -> Int { text.localizedStandardRange(of: query)?.lowerBound == text.startIndex ? 0 : 1 }
            // Albums match on title, artist, genre and year ("jazz", "1977", "miles 1959").
            self.albums = model.library.albums
                .filter { matches("\($0.title) \($0.artist) \(Genres.split($0.genre).joined(separator: " ")) \($0.year.map(String.init) ?? "")") }
                .sorted { (startsWith($0.title), $0.title) < (startsWith($1.title), $1.title) }
            self.genres = model.library.genres.filter { matches($0.name) || Genres.key($0.name).contains(Genres.key(query)) }
            self.artists = model.library.artists
                .filter { matches($0.name) }
                .sorted { (startsWith($0.name), -$0.trackCount) < (startsWith($1.name), -$1.trackCount) }
        }
    }

    private func meta(genres: Int, artists: Int, albums: Int, songs: Int) -> String {
        // Each count is what its shelf shows. An artist who matches only as a song's artist, or a search that matches
        // albums across fields ("miles 1959"), has no artist shelf, so a zero is left out rather than shown as "0 artists".
        let parts: [String] = (genres == 0 ? [] : [String(localized: "\(genres) genres")])
            + (artists == 0 ? [] : [String(localized: "\(artists) artists")])
            + (albums == 0 ? [] : [String(localized: "\(albums) albums")])
            + (songs == 0 ? [] : [String(localized: "\(songs) songs")])
        return parts.isEmpty ? String(localized: "\(songs) songs") : parts.joined(separator: " · ")
    }

    private func sectionTitle(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Typeface.serif(18)).foregroundStyle(Palette.text)
            Text("\(count)").font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private func shelf<Content: View>(_ title: LocalizedStringKey, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(title, count: count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) { content() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
    }
}

struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlistID: Int64
    @State private var list = SongList()

    var body: some View {
        let playlist = model.library.playlists.first { $0.id == playlistID }
        Group {
            if let playlist {
                SongsPage(scope: .sidebar(.playlist(playlistID)), title: playlist.name.libraryDisplayName, list: list,
                          kicker: playlist.isSmart ? String(localized: "SMART", comment: "Before a smart playlist's song count") + " · " : "", playlist: playlist) {
                    if playlist.isSmart {
                        Button("Edit Rules…") { model.smartEditorPlaylist = playlist }.buttonStyle(QuietButtonStyle())
                    }
                } empty: {
                    VStack(spacing: 8) {
                        (playlist.isSmart ? Text("No tracks match these rules yet.") : Text("Drag albums or tracks here."))
                            .font(Typeface.serif(18)).foregroundStyle(Palette.text2)
                        (playlist.isSmart ? Text("Run an analysis or adjust the rules.") : Text("You can also use “Add to Playlist” in any context menu."))
                            .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Palette.window)
        .task(id: "\(playlistID)#\(model.library.revision)#\(playlist?.smartRules.hashValue ?? 0)#\(favoritesKey(playlist))") {
            if let playlist { list = SongList(model.library.tracks(in: playlist), model: model) }
        }
    }

    /// Smart playlists with an "Is Favorite" rule follow favorites as they change.
    private func favoritesKey(_ playlist: Playlist?) -> Int {
        playlist?.smartRules?.rules.contains { $0.field == .isFavorite } == true ? model.library.favoriteIDs.hashValue : 0
    }
}
