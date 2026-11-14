//
// Vespertine Remote: the remote for one Mac: Now Playing, the library, the queue and the outputs.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct RemoteView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: RemoteSession
    @State private var destination: RemoteDestination = .nowPlaying
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var showingSettings = false
    @State private var feedback = CommandFeedback()
    /// The library's counts and sources, for the sidebar.
    @State private var overview: LibraryOverview?

    var body: some View {
        GeometryReader { geometry in
            if RemoteLayout.usesSidebar(regularWidth: sizeClass == .regular, width: geometry.size.width) {
                splitView.accessibilityIdentifier("regular-layout")
            } else {
                VStack(spacing: 0) {
                    ConnectionBanner(session: session)
                    tabs
                }
                .accessibilityIdentifier("compact-layout")
            }
        }
        .background(Palette.base.ignoresSafeArea())
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .feedback(feedback)
        .onAppear { destination = .starting(at: model.startScreen) }
        // Again whenever a page is chosen: a heart or a scan since then shows in the counts.
        .task(id: "\(session.isConnected)#\(destination.id)") {
            if case .library(let loaded) = await session.send(.library) { overview = loaded }
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: Binding<RemoteDestination?>(get: { destination }, set: {
                if let selected = $0 { destination = selected }
            })) {
                Section {
                    sidebarLink(.nowPlaying)
                    sidebarLink(.queue)
                }
                // The Mac's sidebar: its Library pages in its order, then the playlists and the sources.
                Section("Library") {
                    sidebarLink(.library, count: overview?.albums)
                    sidebarLink(.artists, count: overview?.artists)
                    sidebarLink(.songs, count: overview?.songs)
                    sidebarLink(.genres, count: overview?.genres)
                    sidebarLink(.recentlyAdded)
                    sidebarLink(.favorites, count: overview?.favorites)
                    sidebarLink(.playlists, count: overview?.playlists)
                }
                if let sources = overview?.sources, !sources.isEmpty {
                    Section("Sources") {
                        ForEach(sources) { source in
                            NavigationLink(value: RemoteDestination.source(source.id)) { SourceLabel(source: source) }
                                .accessibilityIdentifier("sidebar-source")
                                .hoverEffect(.highlight)
                        }
                    }
                }
                Section("Mac") { sidebarLink(.output) }
            }
            .listStyle(.sidebar)
            .obsidianList()
            .navigationTitle(session.pairing.name)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Macs", systemImage: "desktopcomputer") { model.leave() }
                }
            }
        } detail: {
            VStack(spacing: 0) {
                ConnectionBanner(session: session)
                regularDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Palette.base)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    navigationMenu
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func sidebarLink(_ place: RemoteDestination, count: Int? = nil) -> some View {
        NavigationLink(value: place) { CountedLabel(title: place.title, symbol: place.symbol, count: count) }
            .accessibilityIdentifier("sidebar-" + place.id)
            .hoverEffect(.highlight)
    }

    @ViewBuilder private var regularDetail: some View {
        switch destination {
        case .nowPlaying:
            NavigationStack {
                NowPlayingView(session: session).navigationTitle("Now Playing")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .queue:
            QueueView(session: session).readablePane()
                .miniPlayer(session: session) { destination = .nowPlaying }
        case .output:
            OutputsView(session: session).readablePane()
                .miniPlayer(session: session) { destination = .nowPlaying }
        case .library, .artists, .songs, .genres, .recentlyAdded, .favorites, .playlists, .source:
            LibraryView(session: session, section: destination)
                .id(destination)
                .miniPlayer(session: session) { destination = .nowPlaying }
        }
    }

    private var tabs: some View {
        TabView(selection: Binding(get: { destination.compactTab }, set: { destination = $0 })) {
            NowPlayingView(session: session)
                .tabItem { Label("Now Playing", systemImage: "play.circle") }
                .tag(RemoteDestination.nowPlaying)
            LibraryView(session: session, section: destination.isLibrary && destination != .library ? destination : nil)
                .miniPlayer(session: session) { destination = .nowPlaying }
                .tabItem { Label("Library", systemImage: "square.stack") }
                .tag(RemoteDestination.library)
            QueueView(session: session)
                .miniPlayer(session: session) { destination = .nowPlaying }
                .tabItem { Label("Queue", systemImage: "list.bullet") }
                .tag(RemoteDestination.queue)
            OutputsView(session: session)
                .miniPlayer(session: session) { destination = .nowPlaying }
                .tabItem { Label("Output", systemImage: "hifispeaker") }
                .tag(RemoteDestination.output)
        }
    }

    private var navigationMenu: some View {
        Menu {
            Button("Now Playing") { destination = .nowPlaying }.keyboardShortcut("1")
            Button("Library") { destination = .library }.keyboardShortcut("2")
            Button("Queue") { destination = .queue }.keyboardShortcut("3")
            Button("Output") { destination = .output }.keyboardShortcut("4")
            Divider()
            Button("Play / Pause") { feedback.run(session, .playPause) }.keyboardShortcut("p")
                .disabled(!session.isConnected)
            Button("Next") { feedback.run(session, .next) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!session.isConnected)
            Button("Previous") { feedback.run(session, .previous) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!session.isConnected)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Navigation and Playback")
    }
}

/// What's playing, in one line above the tab bar; a tap opens Now Playing.
struct MiniPlayer: View {
    let session: RemoteSession
    let open: () -> Void
    @State private var feedback = CommandFeedback()

    var body: some View {
        if let track = session.shownPlayer?.nowPlaying?.track {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        ArtworkView(key: track.artworkKey, size: 160, cornerRadius: 5).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).font(.serif(.subheadline, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(Palette.text2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Now Playing: \(track.title), \(track.artist)"))
                .accessibilityHint(Text("Opens Now Playing"))
                Button { feedback.run(session, .playPause) } label: {
                    Image(systemName: session.shownPlayer?.playback == .playing ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(session.shownPlayer?.playback == .playing ? Text("Pause") : Text("Play"))
                Button { feedback.run(session, .next) } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Next"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.text)
            .disabled(!session.isConnected)
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) { MiniProgress(session: session).padding(.horizontal, 14) }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
            .frame(maxWidth: 760)
            .padding(.horizontal, 10).padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .sensoryFeedback(.impact(weight: .light), trigger: session.shownPlayer?.playback)
        }
    }
}

private struct MiniProgress: View {
    let session: RemoteSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(session.shownPlayer?.duration ?? 0, 0)
            let position = session.shownPlayer?.expectedPosition(at: context.date) ?? 0
            GeometryReader { geometry in
                Capsule().fill(Palette.brass)
                    .frame(width: duration > 0 ? geometry.size.width * min(1, position / duration) : 0, height: 1.5)
            }
            .frame(height: 1.5)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Keeps the mini player above the tab bar on this tab.
    func miniPlayer(session: RemoteSession, open: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer(session: session, open: open) }
    }
}

/// Says when the Mac isn't connected, and why.
struct ConnectionBanner: View {
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    @State private var editing = false

    var body: some View {
        Group {
            switch session.phase {
            case .connected where session.isDemo && !model.showsDemoNotice:
                EmptyView()
            case .connected where session.isDemo:
                HStack(spacing: 10) {
                    Text("Demo: a made-up library. Nothing plays.").font(.footnote)
                    Spacer(minLength: 0)
                    Button("Leave Demo") { model.leave() }.font(.footnote.weight(.medium))
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(Palette.surface)
            case .connected, .closed:
                EmptyView()
            case .connecting:
                banner(Text("Connecting to “\(session.pairing.name)”…"), busy: true)
            case .unreachable:
                unreachable
            case .unpaired:
                VStack(spacing: 8) {
                    Text("“\(session.pairing.name)” no longer knows this device. Pair it again from the Mac’s Settings › Remote.")
                    Button("Pair Again") { model.forget(session.pairing) }
                        .buttonStyle(.borderedProminent)
                }
                .font(.callout).padding().frame(maxWidth: .infinity).background(Palette.surface)
            case .incompatible:
                banner(Text("This version of Vespertine on this device doesn’t match Vespertine on the Mac. Update both to the latest version."), busy: false)
            }
        }
        .sheet(isPresented: $editing) { MacConnectionView(serverID: session.pairing.serverID) }
    }

    @ViewBuilder private var unreachable: some View {
        let name = session.pairing.name
        let hasAddress = model.pairing(serverID: session.pairing.serverID)?.address != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                Group {
                    if !model.isOnline {
                        Text("This device is offline. Vespertine connects again when the network is back.")
                    } else if hasAddress {
                        Text("Can’t reach “\(name)”. Trying again… Check that the Mac is awake with Vespertine open, and that Tailscale or your VPN is connected on both.")
                    } else {
                        Text("Can’t reach “\(name)”. Trying again… Check that the Mac is awake and Vespertine is open.")
                    }
                }
                .font(.footnote)
                Spacer(minLength: 0)
            }
            HStack {
                if !hasAddress, model.isOnline {
                    Button("Away From Home?") { editing = true }
                } else {
                    Button("Connection") { editing = true }
                }
                Spacer()
                Button("Macs") { model.leave() }
            }
            .font(.footnote.weight(.medium))
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Palette.surface)
    }

    private func banner(_ text: Text, busy: Bool) -> some View {
        HStack(spacing: 10) {
            if busy { ProgressView() }
            text.font(.footnote)
            Spacer(minLength: 0)
            Button("Macs") { model.leave() }.font(.footnote.weight(.medium))
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Palette.surface)
    }
}

/// Shows a command's failure for a moment.
@Observable
final class CommandFeedback {
    var message: String?

    func run(_ session: RemoteSession, _ command: RemoteCommand) {
        Task {
            if case .failed(let reason) = await session.run(command), !reason.isEmpty {
                message = reason
                try? await Task.sleep(for: .seconds(4))
                if message == reason { message = nil }
            }
        }
    }
}

extension View {
    func feedback(_ feedback: CommandFeedback) -> some View {
        overlay(alignment: .bottom) {
            if let message = feedback.message {
                Text(message)
                    .font(.callout).multilineTextAlignment(.center)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .accessibilityAddTraits(.isStaticText)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: feedback.message)
    }
}
