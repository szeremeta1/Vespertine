//
// Vespertine Remote: the Mac picker until a Mac is chosen, then the remote itself.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VespertineRemoteClient
import VespertineRemoteProtocol
import VespertineShare

struct RootView: View {
    @Environment(RemoteAppModel.self) private var model

    var body: some View {
        Group {
            if let session = model.session {
                RemoteView(session: session)
            } else {
                MacsView()
            }
        }
        .animation(.default, value: model.session == nil)
        .overlay {
            if model.pendingLink != nil || model.isPairing {
                ProgressView("Pairing…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        // A file opened in Vespertine from another app that it can't play.
        .alert(Text(verbatim: model.openedFileTrouble ?? ""), isPresented: Binding(get: { model.openedFileTrouble != nil },
                                                                                set: { if !$0 { model.openedFileTrouble = nil } })) {
            Button("Done") { model.openedFileTrouble = nil }
        }
    }
}

/// The paired Macs, and the ones on this network to pair with.
struct MacsView: View {
    @Environment(RemoteAppModel.self) private var model
    @State private var pairing: DiscoveredMac?
    @State private var scanning = false
    @State private var connection: SavedPairing?
    @State private var showingSettings = false
    @State private var addingShare = false
    @State private var editingShare: SavedShare?
    @State private var choosingFolder = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if !model.pairings.isEmpty {
                    Section("Your Macs") {
                        ForEach(model.pairings) { saved in
                            HStack(spacing: 4) {
                                Button { model.choose(saved) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: SavedPairing.symbol(portable: saved.portable)).foregroundStyle(Palette.brass).rowIconColumn()
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(saved.name).font(.serif(.body, weight: .medium)).foregroundStyle(Palette.text)
                                            Text(reach(saved)).font(.caption).foregroundStyle(Palette.text2)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button { connection = saved } label: {
                                    Image(systemName: "info.circle").font(.title3)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Connection for “\(saved.name)”"))
                            }
                            .swipeActions {
                                Button("Forget", role: .destructive) { model.forget(saved) }
                            }
                        }
                    }
                }
                if !model.shares.isEmpty {
                    Section("Your Shares") {
                        ForEach(model.shares) { share in
                            HStack(spacing: 4) {
                                Button { model.choose(share) } label: { ShareRow(share: share) }
                                    .buttonStyle(.plain)
                                Button { editingShare = share } label: {
                                    Image(systemName: "info.circle").font(.title3)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Settings for “\(share.name)”"))
                            }
                            .swipeActions {
                                Button("Forget", role: .destructive) { model.forget(share) }
                            }
                        }
                    }
                }
                if !model.shownFolders.isEmpty {
                    Section("Your Folders") {
                        ForEach(model.shownFolders) { folder in
                            Button { model.choose(folder) } label: { FolderRow(folder: folder) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("folder-row")
                                .swipeActions {
                                    // The app's own folder is emptied in Files, where its music can be seen.
                                    if !folder.isOwn { Button("Forget", role: .destructive) { model.forget(folder) } }
                                }
                        }
                    }
                }
                Section {
                    let unpaired = model.unpairedMacs
                    let blocked = model.discovery.problem?.isEmpty == false
                    let found = model.discovery.macs.count
                    switch DiscoveryPatience.row(stage: model.search.stage, unpaired: unpaired.count, discovered: found, blocked: blocked) {
                    case .none:
                        EmptyView()
                    case .spinner:
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for Macs on this network…").foregroundStyle(Palette.text2)
                        }
                    case .advice:
                        // The search carries on behind this: a Mac that turns up later still appears here.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No Macs found on this network.").foregroundStyle(Palette.text)
                            Text("Check that this device is on the same Wi-Fi as your Mac, and that Vespertine is open on the Mac with “Let phones control Vespertine” turned on. If the Mac still doesn’t appear, allow Local Network for Vespertine in Settings › Privacy & Security.")
                                .font(.footnote)
                                .foregroundStyle(Palette.text2)
                        }
                        .accessibilityElement(children: .combine)
                        Button { model.lookAgain() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    }
                    ForEach(unpaired) { mac in
                        Button { pairing = mac } label: { Label(mac.name, systemImage: SavedPairing.symbol(portable: mac.portable)) }
                    }
                    Button { scanning = true } label: { Label("Scan the Pairing Code", systemImage: "qrcode.viewfinder") }
                } header: {
                    Text("Pair with a Mac")
                } footer: {
                    Text("On the Mac, open Vespertine › Settings › Remote, turn on “Let phones control Vespertine”, and choose Pair a Phone. Then scan its code, or choose the Mac here and type the 6 digits.")
                }
                if let error = model.pairingError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button { choosingFolder = true } label: { Label("Add a Folder from Files", systemImage: "folder.badge.plus") }
                        .accessibilityIdentifier("add-folder")
                } header: {
                    Text("Play Without a Mac")
                } footer: {
                    Text("Music in a folder in the Files app plays on this device by itself: a folder on this device, in iCloud Drive or on a drive plugged in. The music stays where it is.")
                }
                Section {
                    Button { addingShare = true } label: { Label("Add an SMB Share", systemImage: "externaldrive.badge.plus") }
                        .accessibilityIdentifier("add-share")
                } footer: {
                    Text("Music in a shared folder on a NAS or another computer plays on this device by itself, with no Mac running. Away from home, the share is reached over Tailscale or another VPN.")
                }
                Section {
                    Button { model.tryDemo() } label: { Label("Try the Demo", systemImage: "play.rectangle") }
                } footer: {
                    Text("No Mac nearby? Try Vespertine with a made-up library. Choose this device in Output to hear it play.")
                }
                if let problem = model.discovery.problem, !problem.isEmpty {
                    Section {
                        Label {
                            Text("Vespertine can’t look for Macs. Allow it in Settings › Privacy & Security › Local Network.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.copper)
                        }
                        .foregroundStyle(Palette.text2)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open Settings", destination: url)
                        }
                    }
                }
            }
            .obsidianList()
            .readablePane(maxWidth: 760)
            .onChange(of: model.unpairedMacs.count, initial: true) { model.searchChanged() }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text("Settings"))
                }
            }
            .sheet(item: $pairing) { mac in CodeEntryView(mac: mac) }
            .sheet(item: $connection) { saved in MacConnectionView(serverID: saved.serverID) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $addingShare) { ShareEditView() }
            .sheet(item: $editingShare) { ShareEditView(editing: $0) }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.add(folderAt: url) }
            }
            .sheet(isPresented: $scanning) {
                PairingScannerSheet { link in
                    scanning = false
                    model.pair(link: link)
                }
            }
            .onAppear {
                if model.startScreen == "connection" { connection = model.pairings.last; model.startScreen = nil }
                if model.startScreen == "settings" { showingSettings = true; model.startScreen = nil }
                if model.startScreen == "addShare" { addingShare = true; model.startScreen = nil }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Crescent()
                .fill(LinearGradient(colors: [Palette.brassHi, Palette.brass, Palette.brassLo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .shadow(color: Palette.brass.opacity(0.35), radius: 18)
                .accessibilityHidden(true)
            Text(verbatim: "vespertine")
                .font(.system(size: 30, weight: .light, design: .serif))
                .foregroundStyle(Palette.text)
            Text("The companion to Vespertine on your Mac")
                .font(.footnote).foregroundStyle(Palette.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    /// How a paired Mac can be reached now, in a few words.
    private func reach(_ saved: SavedPairing) -> String {
        if model.discovery.mac(serverID: saved.serverID) != nil { return String(localized: "On this network") }
        if let address = saved.address {
            return address.kind == .tailscale ? String(localized: "By Tailscale: \(address.host)") : String(localized: "By address: \(address.host)")
        }
        return String(localized: "Not on this network")
    }
}

/// Typing the 6-digit code the Mac shows.
struct CodeEntryView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mac: DiscoveredMac
    @State private var code = ""
    @FocusState private var focused: Bool

    private var digits: String { PairingSecret.normalizedCode(code) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("123 456", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .focused($focused)
                } footer: {
                    Text("Type the code under the QR code on “\(mac.name)”.")
                }
                if let error = model.pairingError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .obsidianList()
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        Task {
                            await model.pair(mac, secret: digits, viaLink: false)
                            if model.pairingError == nil { dismiss() }
                        }
                    }
                    .disabled(digits.count != 6 || model.isPairing)
                }
            }
            .onAppear { focused = true; model.pairingError = nil }
        }
    }
}
