//
// Vespertine Remote: the remote for one Mac: Now Playing, the library, the queue and the outputs.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct RemoteView: View {
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession

    var body: some View {
        TabView {
            NowPlayingView(session: session)
                .tabItem { Label("Now Playing", systemImage: "play.circle") }
            LibraryView(session: session)
                .tabItem { Label("Library", systemImage: "square.stack") }
            QueueView(session: session)
                .tabItem { Label("Queue", systemImage: "list.bullet") }
            OutputsView(session: session)
                .tabItem { Label("Output", systemImage: "hifispeaker") }
        }
        .safeAreaInset(edge: .top) {
            ConnectionBanner(session: session)
        }
    }
}

/// Says when the Mac isn't connected, and why.
struct ConnectionBanner: View {
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession

    var body: some View {
        switch session.phase {
        case .connected, .closed:
            EmptyView()
        case .connecting:
            banner(Text("Connecting to “\(session.pairing.name)”…"), busy: true)
        case .unreachable:
            banner(Text("Can’t reach “\(session.pairing.name)”. Trying again… Check that the Mac is awake and Vespertine is open."), busy: true)
        case .unpaired:
            VStack(spacing: 8) {
                Text("“\(session.pairing.name)” no longer knows this iPhone. Pair it again from the Mac’s Settings › Remote.")
                Button("Pair Again") { model.forget(session.pairing) }
                    .buttonStyle(.borderedProminent)
            }
            .font(.callout).padding().frame(maxWidth: .infinity).background(.thinMaterial)
        case .incompatible:
            banner(Text("This version of Vespertine Remote doesn’t match Vespertine on the Mac. Update both to the latest version."), busy: false)
        }
    }

    private func banner(_ text: Text, busy: Bool) -> some View {
        HStack(spacing: 10) {
            if busy { ProgressView() }
            text.font(.callout)
            Spacer(minLength: 0)
            Button("Macs") { model.leave() }.font(.callout)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.thinMaterial)
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
                    .transition(.opacity)
            }
        }
        .animation(.default, value: feedback.message)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
