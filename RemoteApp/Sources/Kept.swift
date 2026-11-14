//
// Vespertine: "Keep on This Device". Albums and playlists fetched whole from the Mac, which then play with the Mac off: the
// shelf that holds them (one folder per Mac), the button that keeps an album or a playlist, and the pages that list them.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Observation
import SwiftUI
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol

@Observable
final class KeptShelf {
    static let shared = KeptShelf()
    /// Gigabytes of room to choose from; 0 is no limit.
    static let limitChoices = [0, 8, 32, 64, 128, 256]
    private static let limitKey = "keptLimitGigabytes"
    private static let smallerKey = "keptSmaller"

    /// The most room kept songs may take, in gigabytes (0: no limit). Kept between launches.
    var limitGigabytes = UserDefaults.standard.integer(forKey: KeptShelf.limitKey) {
        didSet {
            UserDefaults.standard.set(limitGigabytes, forKey: Self.limitKey)
            for keeper in keepers.values {
                keeper.limitBytes = limitBytes
                keeper.resume()
            }
        }
    }
    /// New albums and playlists are kept in their smaller form. Kept between launches.
    var smaller = UserDefaults.standard.bool(forKey: KeptShelf.smallerKey) {
        didSet { UserDefaults.standard.set(smaller, forKey: Self.smallerKey) }
    }
    /// Made the first time each Mac's kept music is asked for, often while a view is being drawn: not something views
    /// watch (each `Keeper` is observed in its own right), so filling it in never counts as a change to the screen.
    @ObservationIgnored private var keepers: [String: Keeper] = [:]

    private var limitBytes: Int64? { limitGigabytes > 0 ? Int64(limitGigabytes) * 1_000_000_000 : nil }

    private static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Kept", isDirectory: true)
    }

    private static func folder(_ serverID: String) -> URL {
        root.appendingPathComponent(String(serverID.filter { $0.isLetter || $0.isNumber || $0 == "-" }), isDirectory: true)
    }

    /// What is kept from one Mac. nil for the demo (nothing to fetch) and when the folder can't be made.
    func keeper(for session: RemoteSession) -> Keeper? {
        guard !session.isDemo else { return nil }
        let serverID = session.pairing.serverID
        if let keeper = keepers[serverID] { return keeper }
        guard let store = try? KeptStore(directory: Self.folder(serverID)) else { return nil }
        // Music that can be fetched from the Mac again doesn't belong in a backup.
        var root = Self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        let keeper = Keeper(store: store)
        keeper.limitBytes = limitBytes
        keeper.holdReason = { PlayTarget.shared.holdReason }
        keepers[serverID] = keeper
        return keeper
    }

    /// Whether anything from this Mac is here to play without it.
    func hasKept(_ session: RemoteSession) -> Bool { !(keeper(for: session)?.store.lists.isEmpty ?? true) }

    /// The Mac answered: carry on fetching, after asking it what each kept album and playlist holds now.
    func connected(_ session: RemoteSession) {
        guard session.canStream, let keeper = keeper(for: session) else { return }
        keeper.client = PhoneStreamClient(session: session)
        Task {
            for list in keeper.store.lists {
                let command: RemoteCommand
                switch list.kind {
                case .album: command = .albumTracks(key: list.reference)
                case .playlist:
                    guard let id = Int64(list.reference) else { continue }
                    command = .playlistTracks(id: id)
                }
                // An empty answer is more likely a Mac whose source is offline than a list that lost every song.
                if case .tracks(let items) = await session.send(command), !items.isEmpty { keeper.update(list.id, tracks: items) }
            }
            keeper.resume()
        }
    }

    /// The Mac was forgotten: what was kept from it goes too.
    func forget(serverID: String) {
        keepers[serverID] = nil
        try? FileManager.default.removeItem(at: Self.folder(serverID))
    }

    /// Bytes fetched to keep since the app opened (part of the data counter).
    var bytesReceived: Int64 { keepers.values.reduce(0) { $0 + $1.bytesReceived } }
}

extension PlayTarget {
    /// Plays kept songs on this device, whatever was chosen in Output. With the Mac away, only the songs that are here.
    func playKept(_ tracks: [TrackSummary], startAt index: Int, shuffled: Bool?, session: RemoteSession) {
        guard let keeper = KeptShelf.shared.keeper(for: session) else { return }
        var list = tracks
        var start = index
        if !session.isConnected {
            let here = tracks.enumerated().filter { $0.element.id.map { keeper.store.kept($0) != nil } ?? false }
            start = here.firstIndex { $0.offset >= index } ?? 0
            list = here.map(\.element)
        }
        guard !list.isEmpty else { return }
        choose(thisDevice: true)
        phone(for: session)?.playback.play(list, startAt: start, shuffled: shuffled)
    }
}

extension RemoteSession {
    /// The transport can be used: the Mac is connected, or music plays on this device (kept songs need no Mac).
    var canControl: Bool { isConnected || phone != nil }
}

/// Keeps an album or a playlist on this device, shows how far along it is, and removes it.
struct KeepButton: View {
    let session: RemoteSession
    let id: String
    /// The list as it is on screen (nil while its songs haven't loaded).
    let make: () -> KeptList?

    var body: some View {
        if let keeper = KeptShelf.shared.keeper(for: session), session.canStream || keeper.isKept(id) {
            if keeper.isKept(id) {
                let progress = keeper.progress(of: id)
                Menu {
                    if !progress.isComplete {
                        Text("Fetched \(progress.done) of \(progress.total)")
                    }
                    Button(role: .destructive) { keeper.remove(id) } label: { Label("Remove from This Device", systemImage: "trash") }
                } label: {
                    Image(systemName: progress.isComplete ? "checkmark.circle.fill" : "arrow.down.circle.dotted")
                }
                .accessibilityLabel(progress.isComplete ? Text("Kept on This Device") : Text("Fetching to Keep on This Device"))
            } else {
                Button { if let list = make() { keeper.keep(list) } } label: { Image(systemName: "arrow.down.circle") }
                    .accessibilityLabel(Text("Keep on This Device"))
                    .disabled(!session.isConnected)
            }
        }
    }
}

/// The albums and playlists kept from this Mac.
struct KeptListsView: View {
    let session: RemoteSession

    var body: some View {
        List {
            if let keeper = KeptShelf.shared.keeper(for: session) {
                if keeper.store.lists.isEmpty {
                    Text("Nothing is kept yet. Open an album or a playlist and choose Keep on This Device; it then plays here without the Mac.")
                        .font(.callout).foregroundStyle(Palette.text2)
                }
                ForEach(keeper.store.lists) { list in
                    NavigationLink { KeptListPage(session: session, id: list.id) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(key: list.artworkKey ?? list.tracks.first?.artworkKey, size: 160, cornerRadius: 4).frame(width: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.title).font(.serif(.body, weight: .medium)).lineLimit(1)
                                if !list.subtitle.isEmpty { Text(list.subtitle).font(.caption).foregroundStyle(Palette.text2).lineLimit(1) }
                                Text(Self.count(keeper.progress(of: list.id))).font(.signal(.caption2)).foregroundStyle(Palette.text3)
                            }
                        }
                    }
                    .swipeActions { Button("Remove", role: .destructive) { keeper.remove(list.id) } }
                }
                Section {
                    LabeledContent("In Use", value: ByteCountFormatter.string(fromByteCount: keeper.store.bytes, countStyle: .file))
                } footer: {
                    KeptStatus(keeper: keeper, session: session)
                }
            }
        }
        .obsidianList()
        .navigationTitle("On This Device").screenTitleStyle()
        .accessibilityIdentifier("kept-lists")
    }

    static func count(_ progress: KeptProgress) -> String {
        progress.isComplete ? String(localized: "Songs: \(progress.total)") : String(localized: "Songs: \(progress.done) of \(progress.total)")
    }
}

/// Why fetching isn't moving, when it isn't.
private struct KeptStatus: View {
    let keeper: Keeper
    let session: RemoteSession

    var body: some View {
        if keeper.isFull {
            Text("There’s no more room for kept music. Remove something, or give it more room in Settings.")
        } else if let notice = keeper.notice {
            Text(notice)
        } else if !keeper.store.missing.isEmpty, !session.isConnected {
            Text("The rest is fetched when the Mac is connected.")
        } else if !keeper.unavailable.isEmpty {
            Text("Some songs can’t be kept: they play on the Mac only, or aren’t in its library any more.")
        }
    }
}

/// One kept album or playlist: its songs, playable here.
struct KeptListPage: View {
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession
    let id: String

    var body: some View {
        List {
            if let keeper = KeptShelf.shared.keeper(for: session), let list = keeper.store.list(id) {
                Section {
                    VStack(spacing: 14) {
                        ArtworkView(key: list.artworkKey ?? list.tracks.first?.artworkKey, size: 600, cornerRadius: 10).frame(maxWidth: 240)
                        Text(list.title).font(.serif(.title3, weight: .semibold)).multilineTextAlignment(.center)
                        if !list.subtitle.isEmpty { Text(list.subtitle).foregroundStyle(Palette.text2) }
                        FlowLayout(spacing: 6, lineSpacing: 6, centered: true) {
                            Chip(text: KeptListsView.count(keeper.progress(of: id)))
                            if list.smaller { Chip(text: String(localized: "SMALLER COPIES", comment: "Chip on a kept album: its songs were kept in the smaller form.")) }
                        }
                        HStack {
                            Button { PlayTarget.shared.playKept(list.tracks, startAt: 0, shuffled: false, session: session) } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            Button { PlayTarget.shared.playKept(list.tracks, startAt: 0, shuffled: true, session: session) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(keeper.progress(of: id).done == 0 && !session.isConnected)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(Array(list.tracks.enumerated()), id: \.offset) { index, track in
                        let here = track.id.map { keeper.store.kept($0) != nil } ?? false
                        Button { PlayTarget.shared.playKept(list.tracks, startAt: index, shuffled: nil, session: session) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).lineLimit(1)
                                    Text(list.kind == .album ? track.format : "\(track.artist) — \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                state(of: track, here: here, keeper: keeper)
                                Text(formatTime(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!here && !session.isConnected)
                        .opacity(here || session.isConnected ? 1 : 0.5)
                    }
                } footer: {
                    KeptStatus(keeper: keeper, session: session)
                }
            }
        }
        .obsidianList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { KeepButton(session: session, id: id) { nil } }
        }
        .onChange(of: KeptShelf.shared.keeper(for: session)?.isKept(id)) { _, kept in if kept == false { dismiss() } }
    }

    @ViewBuilder private func state(of track: TrackSummary, here: Bool, keeper: Keeper) -> some View {
        if let id = track.id, !here {
            if let fetching = keeper.fetching, fetching.song == id {
                ProgressView(value: fetching.fraction).progressViewStyle(.circular).controlSize(.small)
                    .accessibilityLabel(Text("Fetching"))
            } else if keeper.unavailable.contains(id) {
                Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(Palette.copper)
                    .accessibilityLabel(Text("Can’t be kept"))
            } else {
                Image(systemName: "arrow.down.circle.dotted").font(.caption).foregroundStyle(Palette.text3)
                    .accessibilityLabel(Text("Not fetched yet"))
            }
        }
    }
}
