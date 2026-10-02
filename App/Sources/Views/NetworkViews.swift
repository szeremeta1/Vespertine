//
// Vespertine — connecting to network shares, and the Network settings tab.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

// MARK: - Connect to Server

struct ConnectServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address = LaunchArguments().string(forKey: "VespertineConnectAddress") ?? ""
    @State private var asGuest = false
    @State private var user = ""
    @State private var password = ""
    @State private var remember = true
    @State private var readOnly = true
    @State private var name = ""
    @State private var connecting = false
    @State private var error: String?

    /// The address with the name field applied (a user typed in the address wins).
    private var share: NetworkShare? {
        guard var share = NetworkShare(string: address) else { return nil }
        if share.kind == .nfs { return share }
        if asGuest { share.user = nil } else if share.user == nil, !user.isEmpty { share.user = user }
        return share
    }

    private var savedPassword: Bool {
        guard let share, share.user != nil else { return false }
        return NetworkCredentials.hasPassword(for: share)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect to a Server").font(Typeface.serif(24)).foregroundStyle(Palette.text)
                    Text("Play music from a NAS, a file server or another Mac, at home or from anywhere over Tailscale or a VPN. Vespertine keeps the share connected and indexes it in the background.")
                        .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 16)
            Hairline()

            Form {
                Section {
                    TextField("Server address", text: $address, prompt: Text("smb://server/share/folder"))
                        .textContentType(.URL)
                        .onSubmit(connect)
                    Text("Also accepts \\\\server\\share, nfs://server/export and https://server/path (WebDAV). A folder after the share name limits Vespertine to that folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if share?.kind != .nfs {
                    Section {
                        Picker("Connect as", selection: $asGuest) {
                            Text("Registered User").tag(false)
                            Text("Guest").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if !asGuest {
                            if NetworkShare(string: address)?.user == nil {
                                TextField("Name", text: $user)
                            }
                            SecureField("Password", text: $password, prompt: Text(savedPassword ? "Saved in Keychain" : "Required"))
                            Toggle("Remember this password in my keychain", isOn: $remember)
                        }
                    }
                }
                Section {
                    TextField("Name in library", text: $name, prompt: Text(share?.defaultName ?? "Optional"))
                    Toggle("Read-only (recommended)", isOn: $readOnly)
                    Text(readOnly
                         ? "Vespertine never changes files on the share. Tag edits stay in the library."
                         : "Tag edits are written to the files on the server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(connecting)

            Hairline()
            HStack(spacing: 10) {
                if connecting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                } else if let error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.copper)
                    Text(error).font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button("Connect", action: connect)
                    .buttonStyle(BrassButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(share == nil || connecting)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 560)
        .background(Palette.panel)
        .onAppear {
            if let prefill = model.connectPrefill {
                address = prefill
                model.connectPrefill = nil
            }
        }
    }

    private func connect() {
        guard let share, !connecting else {
            if share == nil { error = NetworkShareError.invalidAddress.localizedDescription }
            return
        }
        connecting = true
        error = nil
        Task {
            do {
                try await model.shares.add(share, password: asGuest ? nil : password, remember: remember,
                                           name: name, writable: !readOnly)
                if let source = model.library.sources.first(where: { $0.remoteURL == share.urlString }), let id = source.id {
                    model.sidebar = .source(id)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

// MARK: - Settings: Network

struct NetworkSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var removingSource: LibrarySource?

    private static let limits: [Double] = [5, 10, 20, 50, 100, 250, 500]

    var body: some View {
        @Bindable var s = model.settings
        let usage = model.shares.cacheUsage
        Form {
            Section("Shares") {
                if model.shares.sources.isEmpty {
                    Text("No network shares yet. Connect to a NAS, file server or another Mac, on your network or over Tailscale.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.shares.sources) { source in
                    ShareRow(source: source, removing: $removingSource)
                }
                Button("Connect to Server…") { openWindow(id: "main"); model.showConnectServer = true }   // its sheet is on the main window
            }
            Section {
                Toggle("Keep local copies of music played from shares", isOn: $s.networkCache)
                Picker("Copy ahead", selection: $s.networkPrefetch) {
                    Text("Only the playing track").tag(0)
                    ForEach([1, 2, 3, 5, 10], id: \.self) { n in Text("\(n) upcoming track\(n == 1 ? "" : "s")").tag(n) }
                }
                .disabled(!s.networkCache)
                Picker("Cache size", selection: $s.networkCacheLimitGB) {
                    ForEach(Self.limits, id: \.self) { gb in Text("\(Int(gb)) GB").tag(gb) }
                }
                .disabled(!s.networkCache)
                LabeledContent("Using") {
                    Text(usageText(usage)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Button("Clear Cache") { model.shares.cache.clear(includingOffline: false) }
                        .disabled(usage.cachedFiles == 0)
                    Button("Remove Offline Albums") { model.shares.cache.clear(includingOffline: true) }
                        .disabled(usage.offlineFiles == 0)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.shares.cache.directory]) }
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("Tracks start instantly from the share. Local copies make the next play, gapless transitions and seeking independent of the network. Albums you choose to Keep Offline play even when the server can’t be reached, and don’t count toward the cache size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.networkCacheLimitGB) { model.shares.applyCacheLimit() }
        .onAppear { model.shares.refreshUsage() }
        .modifier(RemoveSourceAlert(source: $removingSource))
    }

    private func usageText(_ u: NetworkCache.Usage) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        var parts = ["\(f.string(fromByteCount: u.cachedBytes)) cached (\(u.cachedFiles) file\(u.cachedFiles == 1 ? "" : "s"))"]
        if u.offlineFiles > 0 { parts.append("\(f.string(fromByteCount: u.offlineBytes)) offline") }
        if u.downloading + u.queued > 0 { parts.append("copying \(u.downloading + u.queued)") }
        return parts.joined(separator: " · ")
    }
}

struct ShareRow: View {
    @Environment(AppModel.self) private var model
    let source: LibrarySource
    /// The share whose removal is being confirmed (the alert belongs to the settings page).
    @Binding var removing: LibrarySource?

    var body: some View {
        let status = model.shares.status(of: source)
        HStack(spacing: 10) {
            Image(systemName: "server.rack").foregroundStyle(status.isConnected ? Palette.brass : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(source.networkShare?.displayString ?? "").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                ShareStatusText(status: status)
            }
            Spacer()
            if case .offline = status {
                Button("Reconnect") { Task { await model.shares.connect(source) } }
            } else {
                Button("Rescan") { Task { await model.library.scan(source) } }.disabled(!status.isConnected)
            }
            Button("Remove") { removing = source }
        }
    }
}

struct ShareStatusText: View {
    let status: NetworkShareManager.Status

    var body: some View {
        switch status {
        case .connecting:
            Text("Connecting…").font(.caption).foregroundStyle(.secondary)
        case .connected:
            Text("Connected").font(.caption).foregroundStyle(.green.opacity(0.8))
        case .offline(let reason):
            Text(reason.isEmpty ? "Offline" : "Offline: \(reason)").font(.caption).foregroundStyle(Palette.copper)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
