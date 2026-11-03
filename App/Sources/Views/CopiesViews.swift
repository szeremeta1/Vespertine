//
// Vespertine — an album's copies on its page (which are in the library, which one plays, or all of them bundled), and
// a song's copies from its row (play one, favorite one, prefer one).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

/// Under an album's hero when the library has it more than once: a card for each copy (its format and layout, what its
/// folder calls it, how many of the album's songs it has, where it is) and one for all of them bundled. The card with
/// the brass edge is what the page lists and Play plays.
struct AlbumCopiesStrip: View {
    @Environment(AppModel.self) private var model
    let albumKey: String
    let copies: AlbumCopies
    /// The copy listed, nil when the copies are bundled.
    let selected: AlbumCopy?
    let choice: AlbumCopyChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                (Text("IN YOUR LIBRARY", comment: "Kicker above the copies of an album the library has.") + Text(verbatim: " · ") + Text("\(copies.copies.count) COPIES"))
                    .font(Typeface.mono(10.5, weight: .semibold)).letterSpacing(1.4).foregroundStyle(Palette.brass)
                Text(explanation)
                    .font(Typeface.ui(11.5)).foregroundStyle(Palette.text3).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if choice != .automatic {
                    Button("Choose Automatically") { model.library.setCopyChoice(.automatic, albumKey: albumKey) }
                        .buttonStyle(QuietButtonStyle(compact: true))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(copies.copies) { copy in
                        CopyCard(albumKey: albumKey, copy: copy, label: labels[copy.id] ?? copy.summary, isSelected: copy.id == selected?.id,
                                 isAutomatic: choice == .automatic && copy.id == selected?.id)
                    }
                    bundleCard
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 28).padding(.top, 2).padding(.bottom, 16)
    }

    private var labels: [String: String] { copies.labels(location: { model.library.albumLocation($0) }) }

    private var explanation: String {
        switch choice {
        case .bundled: String(localized: "Each song plays the copy your output supports best.")
        case .copy: String(localized: "Plays the copy you chose, on any output.")
        case .automatic: String(localized: "Showing the copy that suits this output best. Pick another to list and play it.")
        }
    }

    private var bundleCard: some View {
        let isOn = selected == nil
        return Button { model.library.setCopyChoice(.bundled, albumKey: albumKey) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 10)).foregroundStyle(isOn ? Palette.brass : Palette.text3)
                    Text("ALL COPIES, BUNDLED", comment: "A card among an album's copies: play them as one album, each song in the copy the output supports best.").font(Typeface.mono(10, weight: .semibold)).letterSpacing(0.6)
                        .foregroundStyle(isOn ? Palette.brass : Palette.text2)
                }
                Text("Plays what the output supports").font(Typeface.ui(12, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                Text("\(copies.songs.count) songs").font(Typeface.mono(9.5)).foregroundStyle(Palette.text3).lineLimit(1)
            }
            .frame(width: 214, height: 58, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? Palette.brass : Palette.hairlineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Each song plays the copy your output supports best.")
        .accessibilityLabel("ALL COPIES, BUNDLED")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One copy of an album: "FLAC · 24/96 · 5.1", what its folder calls it, "11 of 11 songs · 1.2 GB", where it is.
private struct CopyCard: View {
    @Environment(AppModel.self) private var model
    let albumKey: String
    let copy: AlbumCopy
    let label: String
    let isSelected: Bool
    let isAutomatic: Bool

    var body: some View {
        Button { model.library.setCopyChoice(.copy(copy.id), albumKey: albumKey) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    FormatLabel(summary: copy.formatSummary, highlight: copy.isHiRes).lineLimit(1).fixedSize()
                    Spacer(minLength: 4)
                    if isSelected {
                        Text(isAutomatic ? "BEST FOR THIS OUTPUT" : "CHOSEN", comment: "On the copy of an album that plays: picked for the output, or chosen by you.")
                            .font(Typeface.mono(8, weight: .semibold)).letterSpacing(0.5).foregroundStyle(Palette.brassHi).lineLimit(1)
                    }
                }
                Text(copy.edition ?? (copy.folder as NSString).lastPathComponent + (copy.place.map { " › " + $0 } ?? ""))
                    .font(Typeface.ui(12, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                Text(detail).font(Typeface.mono(9.5)).foregroundStyle(copy.isComplete ? Palette.text3 : Palette.copper).lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 270, height: 58, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Palette.brass : Palette.hairlineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.library.displayPath(copy.folder))
        .accessibilityLabel(label)
        .accessibilityValue(String(localized: "\(copy.songCount) of \(copy.albumSongCount) songs"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Play This Copy") { model.player.play(copy.tracks, shuffled: false, exactly: Set(copy.tracks.map(\.location))) }
            Button("Add This Copy to Queue") { model.player.addToQueue(copy.tracks, exactly: Set(copy.tracks.map(\.location))) }
            Divider()
            Button("Show in Finder") { model.showInFinder(Array(copy.tracks.prefix(1))) }
        }
    }

    private var detail: String {
        var parts = [copy.isComplete ? String(localized: "\(copy.songCount) songs") : String(localized: "\(copy.songCount) of \(copy.albumSongCount) songs"),
                     copy.size.byteString]
        parts.append(model.library.albumLocation(copy.folder))
        return parts.joined(separator: " · ")
    }
}

/// Beside a song in a list when the library has it in several copies: "3 COPIES", opening the list of them.
struct SongCopiesButton: View {
    let model: AppModel
    /// The row's track.
    let track: Track
    /// Every copy of the song, the row's track among them.
    let copies: [Track]
    /// The list the row is in: playing another copy from here plays it in the row's place, then goes on with the list.
    let list: [Track]
    @State private var showing = false
    @State private var hovering = false

    private var others: String { copies.filter { $0.location != track.location }.map(\.formatSummary).joined(separator: ", ") }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 3) {
                Text("\(copies.count) COPIES").font(Typeface.mono(8.5, weight: .semibold)).letterSpacing(0.6)
                Image(systemName: "chevron.down").font(.system(size: 6.5, weight: .bold))
            }
            .rowForeground(hovering || showing ? Palette.brassHi : Palette.text2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(hovering || showing ? Palette.brassLo : Palette.hairlineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize()
        .help(String(localized: "Also in your library as \(others). Click to play, favorite or prefer a copy."))
        .accessibilityLabel(Text("\(copies.count) COPIES"))
        // Developer aid: `-VespertineShowCopies "<title>"` opens the copies of the song with that title (screenshots).
        .onAppear { if LaunchArguments().string(forKey: "VespertineShowCopies") == track.title { showing = true } }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            SongCopiesPopover(model: model, track: track, copies: copies, list: list)
        }
    }
}

/// Every copy of a song: its format and layout, what its folder calls it, where it is, its length; play it, favorite
/// it, or prefer it.
struct SongCopiesPopover: View {
    let model: AppModel
    let track: Track
    let copies: [Track]
    let list: [Track]

    var body: some View {
        let analyzed = LibraryCopies.analyze(copies)
        let bundled = model.library.isBundled(albumKey: track.albumKey)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(Typeface.serif(16, weight: .medium)).foregroundStyle(Palette.text).lineLimit(2)
                (Text("\(copies.count) COPIES") + Text(verbatim: " · ") + Text("IN YOUR LIBRARY")).font(Typeface.mono(9.5, weight: .semibold)).letterSpacing(1)
                    .foregroundStyle(Palette.brass)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            Hairline()
            ForEach(copies, id: \.location) { copy in
                row(copy, edition: analyzed.copy(of: copy)?.edition)
                Hairline()
            }
            Text(bundled
                 ? "This album's copies are bundled: the song plays the starred copy when your output supports it, else the best one it supports."
                 : "Play plays that copy here, then the list goes on. A heart is for that copy only. The starred copy plays wherever this album's copies are bundled.")
                .font(Typeface.ui(11)).foregroundStyle(Palette.text3)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.raised)
    }

    private func row(_ copy: Track, edition: String?) -> some View {
        let isCurrent = model.player.current?.track.location == copy.location && model.player.state != .stopped
        let preferred = model.library.isPreferredCopy(copy)
        return HStack(spacing: 10) {
            Button { play(copy) } label: {
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.fill").font(.system(size: 10))
                    .foregroundStyle(isCurrent ? Palette.brass : Palette.text)
                    .frame(width: 24, height: 24)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairlineStrong))
            }
            .buttonStyle(.plain)
            .help("Play This Copy")
            .accessibilityLabel("Play This Copy")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    FormatLabel(summary: copy.formatSummary, highlight: copy.isHiRes).fixedSize()
                    if copy.location == track.location {
                        Text("IN THIS LIST", comment: "Beside one of a song's copies: the copy the list shows.").font(Typeface.mono(8, weight: .semibold)).letterSpacing(0.5).foregroundStyle(Palette.text3)
                    }
                    if let edition { Text(edition).font(Typeface.ui(11, weight: .medium)).foregroundStyle(Palette.text2).lineLimit(1) }
                }
                Text(model.library.displayPath((copy.filePath as NSString).deletingLastPathComponent))
                    .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(copy.duration.clock).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
            Button { model.library.setPreferredCopy(!preferred, track: copy) } label: {
                Image(systemName: preferred ? "star.fill" : "star").font(.system(size: 11))
                    .foregroundStyle(preferred ? Palette.brass : Palette.text3)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(preferred ? "Preferred copy" : "Prefer this copy")
            .accessibilityLabel(preferred ? "Preferred copy" : "Prefer this copy")
            FavoriteButton(track: copy, size: 11, appModel: model)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// Plays this copy in the row's place, then the rest of the list as it is.
    private func play(_ copy: Track) {
        var queue = list
        let index = queue.firstIndex { $0.location == track.location } ?? 0
        if queue.isEmpty { queue = [copy] } else { queue[index] = copy }
        model.player.play(queue, startAt: index, exactly: [copy.location])
    }
}

extension AlbumCopy {
    /// "FLAC · 24/96 · 5.1", as a track's format reads; a stereo copy has no layout, Dolby Atmos is its format.
    var formatSummary: String {
        switch layout {
        case .stereo, .atmos: format
        case .surround: "\(format) · \(layout.name)"
        }
    }
}
