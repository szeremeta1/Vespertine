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
                    Button("Choose Another Mac") { model.leave() }
                }
            }
            .navigationTitle("Output")
            .feedback(feedback)
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
