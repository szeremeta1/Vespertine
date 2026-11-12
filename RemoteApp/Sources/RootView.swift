//
// Vespertine Remote: the Mac picker until a Mac is chosen, then the remote itself.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

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
        .overlay {
            if model.pendingLink != nil || model.isPairing {
                ProgressView("Pairing…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

/// The paired Macs, and the ones on this network to pair with.
struct MacsView: View {
    @Environment(RemoteAppModel.self) private var model
    @State private var pairing: DiscoveredMac?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            List {
                if !model.pairings.isEmpty {
                    Section("Your Macs") {
                        ForEach(model.pairings) { saved in
                            Button { model.choose(saved) } label: {
                                HStack {
                                    Label(saved.name, systemImage: "macmini")
                                    Spacer()
                                    if model.discovery.mac(serverID: saved.serverID) == nil {
                                        Text("Not found").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions {
                                Button("Forget", role: .destructive) { model.forget(saved) }
                            }
                        }
                    }
                }
                Section {
                    let unpaired = model.discovery.macs.filter { !model.isPaired($0) }
                    if unpaired.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for Macs…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(unpaired) { mac in
                        Button { pairing = mac } label: { Label(mac.name, systemImage: "macmini") }
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
                if let problem = model.discovery.problem, !problem.isEmpty {
                    Section {
                        Text("Vespertine Remote can’t look for Macs. Allow it in Settings › Privacy & Security › Local Network.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Vespertine Remote")
            .sheet(item: $pairing) { mac in CodeEntryView(mac: mac) }
            .sheet(isPresented: $scanning) {
                PairingScannerSheet { link in
                    scanning = false
                    model.pair(link: link)
                }
            }
        }
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
