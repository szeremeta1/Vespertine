//
// Vespertine Remote: the Mac's outputs, as its output list shows them; choosing one plays there.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol

struct OutputsView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: RemoteSession
    @State private var feedback = CommandFeedback()
    @State private var editingConnection = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { PlayTarget.shared.choose(thisDevice: true) } label: {
                        HStack {
                            Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PlayTarget.deviceName)
                                Text(hereDetail).font(.caption).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            if playsHere { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!PlayTarget.shared.canPlayHere(session))
                    .accessibilityAddTraits(playsHere ? .isSelected : [])
                    if playsHere {
                        Picker("Surround on Headphones", selection: Binding(get: { PlayTarget.shared.surround }, set: { PlayTarget.shared.surround = $0 })) {
                            Text("Off").tag(SpatialModeChoice.off)
                            Text("Fixed").tag(SpatialModeChoice.fixed)
                            Text("Head Tracked").tag(SpatialModeChoice.headTracked)
                        }
                    }
                } footer: {
                    Text("The Mac sends the songs and this device plays them, through its speaker, headphones or a DAC. The Mac’s own playback isn’t touched. Surround songs (5.1, 7.1) are rendered as Spatial Audio on headphones, and folded to stereo on speakers or when this is Off; Head Tracked needs AirPods or Beats that follow your head.")
                }
                Section {
                    ForEach(Array((session.outputs?.outputs ?? []).enumerated()), id: \.offset) { _, output in
                        Button {
                            PlayTarget.shared.choose(thisDevice: false)
                            feedback.run(session, .selectOutput(uid: output.uid))
                        } label: {
                            HStack {
                                Image(systemName: icon(output.kind))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(output.name)
                                    Text(output.detail).font(.caption.monospaced()).foregroundStyle(output.ready ? Color.secondary : Color.orange)
                                }
                                Spacer()
                                if output.selected, !playsHere { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Choose one of these and Vespertine on the Mac plays there.")
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
                }
            }
            .obsidianList()
            .navigationTitle("Output").screenTitleStyle()
            .toolbar {
                // On an iPad's wide window the gear and "Macs" are in the window's own bars.
                if sizeClass != .regular {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                            Button { model.leave() } label: { Label("Choose Another Mac", systemImage: "desktopcomputer") }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(Text("Settings"))
                        .accessibilityIdentifier("output-gear")
                    }
                }
            }
            .feedback(feedback)
            .sheet(isPresented: $editingConnection) { MacConnectionView(serverID: session.pairing.serverID).withoutMiniPlayer() }
            .sheet(isPresented: $showingSettings) { SettingsView().withoutMiniPlayer() }
        }
    }

    private var playsHere: Bool { session.phone != nil }

    /// Under "This iPhone": where its sound goes now, or why it can't play here.
    private var hereDetail: String {
        if session.isDemo, session.phone == nil { return String(localized: "Plays the demo’s made-up songs with sound") }
        guard session.canStream || session.isDemo else { return String(localized: "Update Vespertine on the Mac to play here.") }
        guard let route = session.phone?.route else { return String(localized: "Plays through this device") }
        return route.sampleRate > 0 ? "\(route.name) · \(PhoneSignal.kilohertz(route.sampleRate)) kHz" : route.name
    }

    /// How the Mac is reached now.
    private var reach: String {
        guard session.isConnected else { return String(localized: "Not connected") }
        return session.reach.map(NowPlayingView.reachName) ?? String(localized: "On this network")
    }

    private func icon(_ kind: OutputKind) -> String {
        switch kind {
        case .systemDefault: "speaker.wave.2"
        case .device: "hifispeaker"
        case .speakerGroup: "hifispeaker.2"
        }
    }
}
