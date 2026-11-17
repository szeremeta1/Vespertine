//
// Vespertine Remote: a playlist's page, as Apple Music has one: its covers, its name, how many songs and how long, Play and
// Shuffle, then its songs (a tap plays from that song on, in the playlist's order). A long playlist comes a page at a time,
// the first page shown at once. TestFlight feedback AOf1M7oLiLlxngkwwaWog5Y.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol

/// What a playlist page says about the playlist, and what its buttons send.
enum PlaylistFacts {
    /// The songs' total length, in whole minutes once over a minute ("1 hr, 12 min"), in the device's language.
    static func length(_ tracks: [TrackSummary], locale: Locale = .current) -> String {
        let seconds = tracks.reduce(0) { $0 + max(0, $1.duration.isFinite ? $1.duration : 0) }
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : [.hours, .minutes]
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: units, width: .abbreviated).locale(locale))
    }

    /// Play: every song in the playlist's order, from the first, shuffle off.
    static func play(_ id: Int64) -> RemoteCommand { .playPlaylist(id: id, startAt: nil, shuffled: false) }
    /// Shuffle: every song, shuffled, from a random one (the Mac, the phone and the demo each pick it).
    static func shuffle(_ id: Int64) -> RemoteCommand { .playPlaylist(id: id, startAt: nil, shuffled: true) }
}

struct PlaylistView: View {
    let session: RemoteSession
    let playlist: PlaylistSummary
    @State private var tracks: [TrackSummary] = []
    /// How many songs the playlist has (nil until the Mac answers).
    @State private var total: Int?
    @State private var loading = false
    /// Why the songs couldn't be listed.
    @State private var problem: String?
    @State private var feedback = CommandFeedback()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Every song is here (a long playlist comes in pages).
    private var complete: Bool { total.map { tracks.count >= $0 } ?? false }
    private var keepID: String { KeptList.playlistID(playlist.id) }

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            if !tracks.isEmpty {
                Section {
                    TrackRows(session: session, tracks: tracks, play: SongTap.playlist(id: playlist.id))
                    if !complete {
                        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                    }
                }
            } else if loading || (total == nil && problem == nil) {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            } else if let problem {
                emptyNote(problem)
            } else {
                emptyNote(String(localized: "This playlist has no songs."))
            }
        }
        .obsidianList()
        .accessibilityIdentifier("playlist-page")
        .navigationTitle(Text(playlist.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Kept only whole: never the first page of a long playlist still being read.
                KeepButton(session: session, id: keepID) {
                    complete && !tracks.isEmpty ? KeptList(id: keepID, kind: .playlist, reference: String(playlist.id), title: playlist.name, subtitle: "",
                                                           artworkKey: playlist.artworkKeys?.first ?? tracks.first?.artworkKey, tracks: tracks,
                                                           smaller: KeptShelf.shared.smaller) : nil
                }
            }
        }
        .feedback(feedback)
        .task(id: session.isConnected) { await load() }
        .refreshable { await load(again: true) }
    }

    private var header: some View {
        Group {
            if sizeClass == .regular && !typeSize.isAccessibilitySize {
                HStack(alignment: .bottom, spacing: 28) {
                    PlaylistCover(keys: covers).frame(width: 240, height: 240)
                    info(leading: true).frame(maxWidth: 420)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 16) {
                    PlaylistCover(keys: covers).frame(maxWidth: 240)
                    info(leading: false)
                }
            }
        }
    }

    /// Up to four covers: the Mac's choice for its tile, else the first songs' own.
    private var covers: [String] {
        if let keys = playlist.artworkKeys, !keys.isEmpty { return keys }
        var keys: [String] = []
        for key in tracks.compactMap(\.artworkKey) where !keys.contains(key) && keys.count < 4 { keys.append(key) }
        return keys
    }

    private func info(leading: Bool) -> some View {
        VStack(alignment: leading ? .leading : .center, spacing: 8) {
            Text(playlist.name).font(.serif(leading ? .title2 : .title3, weight: .semibold)).multilineTextAlignment(leading ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let count = total ?? playlist.trackCount {
                Group {
                    if complete {
                        Text("\(count) songs") + Text(verbatim: " · ") + Text(verbatim: PlaylistFacts.length(tracks))
                    } else {
                        Text("\(count) songs")
                    }
                }
                .font(.subheadline).foregroundStyle(Palette.text2)
                .accessibilityIdentifier("playlist-facts")
            }
            let buttons = RemoteLayout.albumButtonsStack(besideCover: leading, accessibilityText: typeSize.isAccessibilitySize)
                ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout())
            buttons {
                Button { feedback.run(session, PlaylistFacts.play(playlist.id)) } label: {
                    Label("Play", systemImage: "play.fill").lineLimit(1).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("playlist-play")
                Button { feedback.run(session, PlaylistFacts.shuffle(playlist.id)) } label: {
                    Label("Shuffle", systemImage: "shuffle").lineLimit(1).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("playlist-shuffle")
            }
            .frame(maxWidth: leading ? 240 : .infinity)
            .buttonStyle(.bordered)
            .disabled(!session.isConnected || (total != nil && tracks.isEmpty))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Palette.text2).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("playlist-empty")
    }

    private func load(again: Bool = false) async {
        guard !loading, again || tracks.isEmpty || !complete else { return }
        loading = true
        defer { loading = false }
        let answer = await PlaylistPages.load(id: playlist.id, ask: { await session.send($0) }) { songs, count in
            tracks = songs
            total = count
        }
        switch answer {
        case .tracks(let songs):
            tracks = songs
            total = songs.count
            problem = nil
        case .failed(let reason):
            // Not connected (yet) says nothing: the page loads when the Mac answers.
            guard session.isConnected else { return }
            if tracks.isEmpty { total = 0 }
            problem = reason.isEmpty ? String(localized: "The Mac didn’t answer.") : reason
        default:
            break
        }
    }
}

/// A playlist's covers as one square: one cover whole, or four in a grid (as the Mac's tile has them).
struct PlaylistCover: View {
    let keys: [String]
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if keys.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { tile(keys[0]); tile(keys[1]) }
                    GridRow { tile(keys[2]); tile(keys[3]) }
                }
            } else {
                ArtworkView(key: keys.first, size: 600, cornerRadius: 0)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private func tile(_ key: String) -> some View {
        ArtworkView(key: key, size: 300, cornerRadius: 0)
    }
}
