//
// Vespertine Remote: the Mac's outputs, as its output list shows them; choosing one plays there.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct OutputsView: View {
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    @State private var feedback = CommandFeedback()
    @State private var editingConnection = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array((session.outputs?.outputs ?? []).enumerated()), id: \.offset) { _, output in
                        Button { feedback.run(session, .selectOutput(uid: output.uid)) } label: {
                            HStack {
                                Image(systemName: icon(output.kind))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(output.name)
                                    Text(output.detail).font(.caption.monospaced()).foregroundStyle(output.ready ? Color.secondary : Color.orange)
                                }
                                Spacer()
                                if output.selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Vespertine on the Mac plays to the output you choose here.")
                }
                Section {
                    LabeledContent("Mac", value: session.server?.name ?? session.pairing.name)
                    if let version = session.server?.appVersion, !version.isEmpty {
                        LabeledContent("Vespertine", value: version)
                    }
                    if !session.isDemo {
                        Button { editingConnection = true } label: {
                            LabeledContent("Connection") {
                                HStack(spacing: 6) {
                                    Circle().fill(session.isConnected ? Palette.brass : Palette.text3).frame(width: 7, height: 7)
                                    Text(reach)
                                }
                            }
                        }
                        .foregroundStyle(Palette.text)
                    }
                    Button("Choose Another Mac") { model.leave() }
                }
                Section {
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .obsidianList()
            .navigationTitle("Output").screenTitleStyle()
            .feedback(feedback)
            .sheet(isPresented: $editingConnection) { MacConnectionView(serverID: session.pairing.serverID) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }

    /// How the Mac is reached now.
    private var reach: String {
        guard session.isConnected else { return String(localized: "Not connected") }
        switch session.route {
        case .nearby, nil: return String(localized: "On this network")
        case .lastKnown: return String(localized: "By its last address")
        case .address:
            let tailscale = model.pairing(serverID: session.pairing.serverID)?.address?.kind == .tailscale
            return tailscale ? String(localized: "Over Tailscale") : String(localized: "By address")
        }
    }

    private func icon(_ kind: OutputKind) -> String {
        switch kind {
        case .systemDefault: "speaker.wave.2"
        case .device: "hifispeaker"
        case .speakerGroup: "hifispeaker.2"
        }
    }
}
