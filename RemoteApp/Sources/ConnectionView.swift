//
// Vespertine Remote: how this device reaches one paired Mac: on this network, or by an address (its Tailscale name,
// say) from anywhere else.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

/// What the address field holds, checked as it's typed.
nonisolated enum AddressEntry: Equatable {
    /// Nothing typed: no address is saved.
    case empty
    case valid(RemoteAddress)
    case invalid

    init(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .empty
        } else if let address = RemoteAddress(parsing: text) {
            self = .valid(address)
        } else {
            self = .invalid
        }
    }

    var address: RemoteAddress? {
        if case .valid(let address) = self { address } else { nil }
    }
}

struct MacConnectionView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serverID: String
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var pairing: SavedPairing? { model.pairing(serverID: serverID) }
    private var entry: AddressEntry { AddressEntry(text) }
    private var session: RemoteSession? { model.session?.pairing.serverID == serverID ? model.session : nil }

    var body: some View {
        NavigationStack {
            Form {
                if let pairing {
                    Section {
                        row("On this network", systemImage: "wifi",
                            detail: model.discovery.mac(serverID: serverID) != nil ? String(localized: "Found") : String(localized: "Not found"),
                            good: model.discovery.mac(serverID: serverID) != nil, active: session?.route == .nearby)
                        // What the Mac said it can be reached at: its addresses at home, and on Tailscale or another VPN.
                        ForEach(pairing.advertised ?? [], id: \.self) { told in
                            row(Self.title(told.kind), systemImage: told.kind == .localNetwork ? "house" : "point.3.connected.trianglepath.dotted",
                                detail: told.text, good: true, active: session?.route != .nearby && session?.reached?.host == told.host)
                        }
                        if let address = pairing.address {
                            let ready = address.withPort(from: pairing.lastKnown).port != nil
                            row(address.kind == .tailscale ? "Tailscale" : "Address", systemImage: "point.3.connected.trianglepath.dotted",
                                detail: ready ? address.withPort(from: pairing.lastKnown).text : String(localized: "Needs the port"),
                                good: ready, active: session?.route == .address)
                        }
                        if let last = pairing.lastKnown, !(pairing.advertised ?? []).contains(where: { $0.host == last.host }) {
                            row("Last answered at", systemImage: "clock.arrow.circlepath", detail: last.text, good: true, active: session?.route == .lastKnown)
                        }
                    } header: {
                        Text("Ways to reach “\(pairing.name)”")
                    } footer: {
                        Text("Vespertine tries these together and uses the first that answers, and switches by itself when the network changes. The Mac tells this device its addresses each time they connect, so there is nothing to type. The connection is encrypted with this device’s own key either way.")
                    }

                    Section {
                        TextField("mac-name.tailnet.ts.net", text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .font(.signal(.body))
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityLabel(Text("The Mac’s address"))
                        if entry == .invalid {
                            Label("That doesn’t look like an address. Type a name or an IP address, with “:port” after it if you know the port.",
                                  systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(Palette.copper)
                        } else if let address = entry.address, address.port == nil, pairing.lastKnown?.port == nil {
                            Label("The port isn’t known yet. Connect to this Mac once on its own network and Vespertine fills it in.",
                                  systemImage: "info.circle")
                                .font(.footnote).foregroundStyle(Palette.text2)
                        }
                        if pairing.address != nil {
                            Button("Remove the Address", role: .destructive) {
                                text = ""
                                model.setAddress(nil, for: serverID)
                            }
                        }
                    } header: {
                        Text("Address for away from home")
                    } footer: {
                        Text("Usually not needed: with Tailscale on both the Mac and this device, Vespertine finds the Mac by itself once they have connected at home. Type an address only for a way the Mac can’t tell on its own, such as a forwarded port. The Mac must be awake with Vespertine open; Settings › Remote on the Mac can keep it awake.")
                    }

                    Section {
                        LabeledContent("Paired", value: pairing.pairedAt.formatted(date: .abbreviated, time: .omitted))
                        Button("Forget This Mac", role: .destructive) {
                            model.forget(pairing)
                            dismiss()
                        }
                    }
                }
            }
            .obsidianList()
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }.disabled(entry == .invalid)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = pairing?.address?.text ?? ""
            }
        }
    }

    /// What kind of network one of the Mac's addresses is on.
    static func title(_ kind: RemoteAddress.Kind) -> LocalizedStringKey {
        switch kind {
        case .localNetwork: "Home network"
        case .tailscale: "Tailscale"
        case .other: "Another network"
        }
    }

    private func save() {
        switch entry {
        case .empty: model.setAddress(nil, for: serverID)
        case .valid(let address): model.setAddress(address, for: serverID)
        case .invalid: break
        }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, detail: String, good: Bool, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(good ? Palette.brass : Palette.text3).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.signal(.caption)).foregroundStyle(Palette.text2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if active {
                Chip(text: String(localized: "IN USE"), highlighted: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
