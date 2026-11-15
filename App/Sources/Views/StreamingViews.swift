//
// Vespertine: music servers in Settings, the sidebar and the song lists. Everything here but the switch itself shows only
// while the switch is on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineLibrary
import VespertineOpenSubsonic
import VespertineStreaming

enum StreamingSwitch {
    static var title: String {
        String(localized: "Music Servers (OpenSubsonic, beta)", comment: "Settings: the switch that lets Vespertine play music from the listener’s own music server. “OpenSubsonic” is the name of the open API such servers speak and “beta” stays as it is in your language.")
    }

    static var explanation: String {
        String(localized: "Plays the music on your own server, such as Navidrome, Gonic or Airsonic, beside your files. Off, Vespertine sends nothing to any server, reads no saved sign-in, and shows none of a server’s music.", comment: "Settings: the caption under the Music Servers (OpenSubsonic, beta) switch. Navidrome, Gonic and Airsonic are product names.")
    }

    static var sectionTitle: String {
        String(localized: "Music Servers", comment: "A heading in Settings and in the sidebar: the listener’s own music servers.")
    }
}

/// Settings › Streaming: the tab, when the switch has a tab of its own.
struct StreamingSettings: View {
    var body: some View {
        Form { StreamingSettingsSection() }.formStyle(.grouped)
    }
}

/// The switch and, while it is on, the servers. A section of a Settings form, wherever the switch sits.
struct StreamingSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var signingIn: SignInTarget?
    @State private var removing: LibrarySource?

    struct SignInTarget: Identifiable {
        var source: LibrarySource?
        var id: String { source?.path ?? "new" }
    }

    private let id = OpenSubsonicProvider.providerID

    var body: some View {
        let streaming = model.streaming
        Section {
            Toggle(StreamingSwitch.title, isOn: Binding(get: { streaming.isOn(id) }, set: { streaming.setOn($0, id) }))
            Text(StreamingSwitch.explanation).font(.caption).foregroundStyle(.secondary)
            if streaming.isOn(id) {
                ForEach(streaming.accounts(id), id: \.path) { source in
                    ServerRow(source: source, signIn: { signingIn = SignInTarget(source: source) }, remove: { removing = source })
                }
                Button("Add Server…") { signingIn = SignInTarget() }
                Toggle("Tell the server what I play", isOn: Binding(get: { streaming.reports(id) }, set: { streaming.setReports($0, id) }))
                Text("Off, the server is not told which songs you play. On, each song that counts as played is reported to it, as its own apps do.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Your sign-in is kept in the macOS Keychain and nowhere else, and signing out deletes it. A format the server lists is marked ≈ until the song has played.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(StreamingSwitch.sectionTitle)
        }
        .sheet(item: $signingIn) { target in ServerSignInSheet(source: target.source) }
        .alert(removing.map { String(localized: "Remove “\($0.displayName)” from the library?", comment: "%@ is the name of a music server’s account.") } ?? "",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { source in
            Button("Remove", role: .destructive) { streaming.remove(source) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its songs and playlists leave Vespertine, and its sign-in is deleted from the Keychain. Nothing on the server changes.")
        }
    }
}

/// One server in Settings: its name, what it is doing, and what can be done with it.
private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let source: LibrarySource
    let signIn: () -> Void
    let remove: () -> Void

    var body: some View {
        let state = model.streaming.state(source)
        let signedIn = { if case .signedIn = state.session { true } else { false } }()
        HStack {
            Image(systemName: "music.note.house")
            VStack(alignment: .leading) {
                Text(source.displayName)
                // The wait the server asked for runs down by itself: looked at again every few seconds while Settings shows it.
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text(ServerStatus.line(state, waitingUntil: model.streaming.waitingUntil(source)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.syncing { ProgressView().controlSize(.small) }
            Button("Refresh") { model.streaming.sync(source) }.disabled(!signedIn || state.syncing)
            if signedIn {
                Button("Sign Out") { model.streaming.signOut(source) }
            } else {
                Button("Sign In…", action: signIn)
            }
            Button("Remove", action: remove)
        }
    }
}

enum ServerStatus {
    /// What a server's row says: the wait it asked for, else what went wrong, else what it is doing, else who is signed in.
    @MainActor static func line(_ state: StreamingModel.AccountState, waitingUntil: Date?) -> String {
        if let waitingUntil {
            return StreamingError.askedToWait(seconds: waitingUntil.timeIntervalSinceNow).localizedDescription
        }
        if let problem = state.problem { return problem }
        if state.syncing {
            return String(localized: "Listing the server’s music. Songs so far: \(state.listed.formatted())", comment: "Settings: a music server’s library is being read. %@ is how many songs have been listed, as a number.")
        }
        switch state.session {
        case .signedIn(let user):
            return String(localized: "Signed in as \(user)", comment: "Settings: %@ is the user name on a music server.")
        case .signedOut:
            return String(localized: "Signed out. Its music stays listed, and plays again once you sign in.", comment: "Settings: a music server’s account has no saved sign-in.")
        case nil:
            return ""
        }
    }
}

/// Signing in to a server: a new one, or one that was signed out.
private struct ServerSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: LibrarySource?

    private enum Kind: Hashable { case password, apiKey }

    @State private var name = ""
    @State private var server = ""
    @State private var user = ""
    @State private var secret = ""
    @State private var kind = Kind.password
    @State private var busy = false
    @State private var problem: String?

    private var unencrypted: Bool { server.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") }
    private var complete: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty && !secret.isEmpty && (kind == .apiKey || !user.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                if source == nil { TextField("Name (optional)", text: $name) }
                TextField("Server address", text: $server, prompt: Text(verbatim: "https://music.example"))
                    .textContentType(.URL).autocorrectionDisabled()
                Picker("Sign in with", selection: $kind) {
                    Text("Password").tag(Kind.password)
                    Text("API key").tag(Kind.apiKey)
                }
                if kind == .password { TextField("User name", text: $user).textContentType(.username).autocorrectionDisabled() }
                SecureField(kind == .password ? String(localized: "Password") : String(localized: "API key"), text: $secret)
            }
            if unencrypted {
                Label("This address is not encrypted, so your sign-in is sent as it is. Use it only for a server on your own network.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In") { signIn() }.keyboardShortcut(.defaultAction).disabled(!complete || busy)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            // The address and name last used, from the Keychain item. The secret is typed again.
            guard let source, let remembered = await model.streaming.remembered(source) else { return }
            if server.isEmpty { server = remembered.server }
            if user.isEmpty { user = remembered.user }
        }
    }

    private func signIn() {
        busy = true
        problem = nil
        let request = ProviderSignIn(server: server, user: user.trimmingCharacters(in: .whitespaces),
                                     secret: kind == .password ? .password(secret) : .apiKey(secret))
        Task {
            let failure = await model.streaming.signIn(OpenSubsonicProvider.providerID, source: source, name: name, request: request)
            busy = false
            if let failure { problem = failure } else { dismiss() }
        }
    }
}

/// Beside a streamed song's format: that it comes from a server. One of three ways the owner picks from (`StreamingMark`).
struct StreamMarkView: View {
    let name: String

    var body: some View {
        switch StreamingMark.current {
        case .glyph:
            Image(systemName: "music.note.house")
                .font(.system(size: 10))
                .rowForeground(Palette.text3)
                .help(label)
                .accessibilityLabel(label)
        case .label:
            Text(name)
                .font(Typeface.mono(8.5, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 110)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.foreground.opacity(0.5)))
                .rowForeground(Palette.text3)
                .help(label)
        case .column:
            EmptyView()
        }
    }

    private var label: String {
        String(localized: "Streamed from \(name)", comment: "Beside a song in a list: it is not a file, it is streamed from the music server of this name.")
    }
}

/// The sidebar's entries for the servers, each opening that server's albums.
struct ServerSidebarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.streaming.anyOn, StreamingBrowse.current.showsInSidebar, !model.library.streamedAccounts.isEmpty {
            Section(StreamingSwitch.sectionTitle) {
                ForEach(model.library.streamedAccounts, id: \.path) { source in
                    if let id = source.id {
                        Label {
                            HStack {
                                Text(source.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if model.streaming.state(source).syncing { ProgressView().controlSize(.mini) }
                            }
                        } icon: {
                            Image(systemName: "music.note.house")
                        }
                        .tag(SidebarItem.source(id))
                        .contextMenu { Button("Refresh") { model.streaming.sync(source) } }
                    }
                }
            }
        }
    }
}

/// A server's page: its name, what it is doing, and its albums.
struct ServerSourceView: View {
    @Environment(AppModel.self) private var model
    let source: LibrarySource
    let sourceID: Int64

    var body: some View {
        let state = model.streaming.state(source)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName).font(Typeface.serif(26, weight: .medium)).foregroundStyle(Palette.text)
                    if let provider = source.streamedAccount?.provider, let name = model.streaming.core.descriptor(provider)?.name {
                        Text(verbatim: name.uppercased()).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
                    }
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        Text(ServerStatus.line(state, waitingUntil: model.streaming.waitingUntil(source)))
                            .font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                    }
                }
                Spacer()
                Button("Refresh") { model.streaming.sync(source) }.buttonStyle(QuietButtonStyle()).disabled(state.syncing)
            }
            .padding(24)
            Hairline()
            AlbumsGridView(scope: .sidebar(.source(sourceID)), title: String(localized: "Albums in this source"))
        }
        .background(Palette.window)
    }
}
