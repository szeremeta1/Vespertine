//
// Vespertine: Settings › TIDAL: the account, the client file, streaming quality, downloads and the sync's status.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VespertineTidal

struct TidalSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showLogin = false
    @State private var changingCredentials = false
    @State private var pasted = ""
    @State private var details = TidalClientCredentials(clientId: "", clientSecret: "", pkceClientId: "", pkceClientSecret: "")
    @State private var showDetails = false
    @State private var credentialsError: String?
    @State private var importing = false

    private var tidal: TidalModel { model.tidal }

    /// The quality picker's choices (UX amendment 7: no "Max"), as TIDAL's `audioquality` values.
    static let qualities: [(value: String, label: LocalizedStringKey)] = [
        ("HI_RES_LOSSLESS", "Hi-Res Lossless (up to 24/192)"),
        ("LOSSLESS", "Lossless (16/44.1)"),
        ("HIGH", "High (AAC 320)"),
        ("LOW", "Low (AAC 96)"),
    ]

    var body: some View {
        @Bindable var s = model.settings
        Form {
            account
            if tidal.state == .missingCredentials || changingCredentials { credentials }
            Section {
                Picker("Streaming quality", selection: $s.tidalQuality) {
                    ForEach(Self.qualities, id: \.value) { Text($0.label).tag($0.value) }
                }
                .onChange(of: s.tidalQuality) { tidal.qualityChanged() }
            } header: {
                Text("Playback")
            } footer: {
                Text("Downloads use the same quality. TIDAL sends less when the song or your subscription doesn’t have it; the signal path shows what arrived.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Downloads folder") {
                    HStack {
                        Button((s.tidalDownloadsFolder as NSString).abbreviatingWithTildeInPath) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.tidalDownloadsFolder)])
                        }
                        .buttonStyle(.link)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Add downloads folder to the library", isOn: $s.tidalAddDownloadsToLibrary)
                    .onChange(of: s.tidalAddDownloadsToLibrary) { if s.tidalAddDownloadsToLibrary { model.addTidalDownloadsFolder() } }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Only what you download is kept. Streamed songs are never saved: they are read into a temporary file while they play, then deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if tidal.state.isSignedIn { status }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLogin) { TidalLoginSheet() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            save { try TidalClientCredentials.parse(Data(contentsOf: url)) }
        }
        .onAppear { openRequestedLogin() }
        .onChange(of: tidal.wantsLoginSheet) { openRequestedLogin() }
    }

    private func openRequestedLogin() {
        guard tidal.wantsLoginSheet else { return }
        tidal.wantsLoginSheet = false
        if tidal.state == .signedOut { showLogin = true }
    }

    // MARK: Account

    @ViewBuilder private var account: some View {
        Section {
            switch tidal.state {
            case .missingCredentials:
                LabeledContent("Account") { Text("Not set up").foregroundStyle(.secondary) }
            case .signedOut, .signingIn:
                LabeledContent("Account") {
                    HStack {
                        Text("Not signed in").foregroundStyle(.secondary)
                        Button("Sign In…") { showLogin = true }
                    }
                }
            case .signedIn(let name):
                LabeledContent {
                    Button("Sign Out") { tidal.signOut() }
                } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: name)
                        if let country = tidal.countryCode {
                            Text(verbatim: Locale.current.localizedString(forRegionCode: country) ?? country)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if tidal.state != .missingCredentials && !changingCredentials {
                LabeledContent("Client credentials") {
                    Button("Change…") { changingCredentials = true }
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Sign-in happens on TIDAL’s own page. Vespertine keeps the session in your Keychain, never your password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Credentials

    @ViewBuilder private var credentials: some View {
        Section {
            HStack {
                Button("Import Client File…") { importing = true }
                if changingCredentials { Button("Cancel") { changingCredentials = false; credentialsError = nil } }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Or paste its contents").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pasted)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                HStack {
                    Spacer()
                    Button("Save") { save { try TidalClientCredentials.parse(Data(pasted.utf8)) } }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            DisclosureGroup("Show Details", isExpanded: $showDetails) {
                SecureField("Client ID", text: $details.clientId)
                SecureField("Client secret", text: $details.clientSecret)
                SecureField("PKCE client ID", text: $details.pkceClientId)
                SecureField("PKCE client secret", text: $details.pkceClientSecret)
                HStack {
                    Spacer()
                    Button("Save") {
                        save { try TidalClientCredentials.parse(JSONEncoder().encode(details)) }
                    }
                }
            }
            if let problem = credentialsError ?? tidal.credentialsProblem {
                Text(verbatim: problem).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Client credentials")
        } footer: {
            Text("TIDAL needs a client file, tidal-client.json, with clientId, clientSecret, pkceClientId and pkceClientSecret. It is saved in Application Support, readable only by you, and never leaves this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save(_ parse: () throws -> TidalClientCredentials) {
        do {
            try tidal.saveCredentials(try parse())
            credentialsError = nil
            changingCredentials = false
            pasted = ""
            details = TidalClientCredentials(clientId: "", clientSecret: "", pkceClientId: "", pkceClientSecret: "")
            if tidal.state == .signedOut { showLogin = true }
        } catch {
            credentialsError = error.localizedDescription
        }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        Section("Status") {
            LabeledContent("Last sync") {
                HStack {
                    if tidal.isRefreshing { ProgressView().controlSize(.small) }
                    Text(tidal.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Never", comment: "TIDAL last sync: none yet"))
                        .foregroundStyle(.secondary)
                    Button("Refresh Now") { Task { await tidal.refresh() } }
                        .disabled(tidal.isRefreshing || !tidal.isOnline)
                }
            }
            if let notice = tidal.backoffNotice {
                Text(verbatim: notice).font(.caption).foregroundStyle(.orange)
            }
            if !tidal.isReachable {
                Text("Offline. Vespertine syncs again when the network is back.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = tidal.lastError {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
            }
            ForEach(tidal.syncWarnings, id: \.self) { warning in
                Text(verbatim: warning).font(.caption).foregroundStyle(.orange)
            }
            ForEach(tidal.skippedOps, id: \.self) { skipped in
                Text(verbatim: skipped).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.settings.tidalDownloadsFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.tidalDownloadsFolder = url.path
        tidal.downloadsFolderChanged()
        if model.settings.tidalAddDownloadsToLibrary { model.addTidalDownloadsFolder() }
    }
}
