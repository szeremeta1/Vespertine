//
// Vespertine Remote: the remote for one Mac: Now Playing, the library, the queue and the outputs.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct RemoteView: View {
    enum Tab: String, Hashable { case nowPlaying, library, queue, output }

    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    @State private var tab: Tab = .nowPlaying

    var body: some View {
        TabView(selection: $tab) {
            NowPlayingView(session: session)
                .tabItem { Label("Now Playing", systemImage: "play.circle") }
                .tag(Tab.nowPlaying)
            LibraryView(session: session)
                .miniPlayer(session: session) { tab = .nowPlaying }
                .tabItem { Label("Library", systemImage: "square.stack") }
                .tag(Tab.library)
            QueueView(session: session)
                .miniPlayer(session: session) { tab = .nowPlaying }
                .tabItem { Label("Queue", systemImage: "list.bullet") }
                .tag(Tab.queue)
            OutputsView(session: session)
                .miniPlayer(session: session) { tab = .nowPlaying }
                .tabItem { Label("Output", systemImage: "hifispeaker") }
                .tag(Tab.output)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ConnectionBanner(session: session)
        }
        .onAppear {
            switch model.startScreen {
            case "library", "albums", "coverFlow", "album", "artists": tab = .library
            case "queue": tab = .queue
            case "output": tab = .output
            default: break
            }
        }
    }
}

/// What's playing, in one line above the tab bar; a tap opens Now Playing.
struct MiniPlayer: View {
    let session: RemoteSession
    let open: () -> Void
    @State private var feedback = CommandFeedback()

    var body: some View {
        if let track = session.player?.nowPlaying?.track {
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
                    Image(systemName: session.player?.playback == .playing ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel(session.player?.playback == .playing ? Text("Pause") : Text("Play"))
                Button { feedback.run(session, .next) } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 36, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Next"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.text)
            .disabled(!session.isConnected)
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) { MiniProgress(session: session).padding(.horizontal, 14) }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
            .padding(.horizontal, 10).padding(.bottom, 6)
            .sensoryFeedback(.impact(weight: .light), trigger: session.player?.playback)
        }
    }
}

private struct MiniProgress: View {
    let session: RemoteSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(session.player?.duration ?? 0, 0)
            let position = session.player?.expectedPosition(at: context.date) ?? 0
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
                    Text("“\(session.pairing.name)” no longer knows this iPhone. Pair it again from the Mac’s Settings › Remote.")
                    Button("Pair Again") { model.forget(session.pairing) }
                        .buttonStyle(.borderedProminent)
                }
                .font(.callout).padding().frame(maxWidth: .infinity).background(Palette.surface)
            case .incompatible:
                banner(Text("This version of Vespertine Remote doesn’t match Vespertine on the Mac. Update both to the latest version."), busy: false)
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
                        Text("This iPhone is offline. Vespertine Remote connects again when the network is back.")
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
            if case .failed(let reason) = await session.send(command), !reason.isEmpty {
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
