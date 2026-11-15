//
// Vespertine: Play to Vespertine (UPnP, beta): the Settings switch with its few choices, and what shows while a control app's
// music plays. None of it shows while the switch is off. A control app's name is shown as it gave it, cleaned.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio
import VespertineUPnP

struct ReceiverSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle(ReceiverSwitch.title, isOn: Binding(get: { model.settings.upnpReceiverFeature }, set: { model.setReceiverFeature($0) }))
            Text(ReceiverSwitch.explanation).font(.caption).foregroundStyle(.secondary)
            if let receiver = model.receiver {
                TextField(String(localized: "Name on the network", comment: "Settings › Playback › Play to Vespertine: the name other apps show for this Mac."),
                          text: $name, prompt: Text(verbatim: ReceiverSwitch.defaultName))
                    .onSubmit { rename(receiver) }
                    .onAppear { name = model.settings.upnpReceiverName }
                Group {
                    switch receiver.status {
                    case .starting:
                        Text("Starting…", comment: "Settings › Playback › Play to Vespertine: the receiver is being started.")
                    case .running:
                        Text("On. Apps on this network see this Mac as “\(receiver.name)”.", comment: "Settings › Playback › Play to Vespertine. %@ is the name shown to other apps.")
                    case .failed(let reason):
                        Text(verbatim: reason).foregroundStyle(.red)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Toggle(String(localized: "Let those apps set the volume", comment: "Settings › Playback › Play to Vespertine: other apps may change Vespertine’s volume."),
                       isOn: $settings.upnpReceiverVolume)
                    .onChange(of: settings.upnpReceiverVolume) { receiver.volumeAllowedChanged() }
                Text("Off, the volume stays where you set it. On, an output with no volume of its own uses Vespertine’s volume, which changes the samples below 100%.",
                     comment: "Settings › Playback › Play to Vespertine: caption under “Let those apps set the volume”.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(String(localized: "Only from this Mac’s own networks", comment: "Settings › Playback › Play to Vespertine: accept control only from devices on the same networks as this Mac."),
                       isOn: $settings.upnpReceiverOwnNetworks)
                    .onChange(of: settings.upnpReceiverOwnNetworks) { receiver.restart() }
                Text("On, only devices on the same network as this Mac can send music. Off, any device with a private address can, such as one reaching this Mac through a VPN.",
                     comment: "Settings › Playback › Play to Vespertine: caption under “Only from this Mac’s own networks”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(ReceiverSwitch.title)
        }
    }

    private func rename(_ receiver: ReceiverModel) {
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard cleaned != model.settings.upnpReceiverName else { return }
        model.settings.upnpReceiverName = cleaned
        name = cleaned
        receiver.restart()
    }
}

/// "FROM MCONNECT", beside the song, while a control app's music plays (one of the ways to show it: `ReceiverPresentation`).
struct ReceiverChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if ReceiverPresentation.current == .chip, let session = model.player.receiverSession {
            StatusBadge(text: ReceiverText.chip(session.app))
                .help(ReceiverText.playingFrom(session.app))
        }
    }
}

/// A line above the queue while a control app's music plays, with the way back to the listener's own queue.
struct ReceiverBanner: View {
    @Environment(AppModel.self) private var model
    let session: PlayerController.ReceiverSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12)).foregroundStyle(Palette.brassHi)
                .accessibilityHidden(true)
            Text(ReceiverText.playingFrom(session.app)).font(Typeface.ui(12, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
            Spacer(minLength: 4)
            if session.current != nil {
                Button(ReceiverText.backToQueue) { model.player.endReceiverSession(telling: .tookOver) }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.brass.opacity(0.10))
    }
}

/// The listener's own queue while a control app plays: as it was, dimmed, and still theirs to change. Choosing a song from it
/// plays it and ends the control app's session.
struct KeptQueueList: View {
    @Environment(AppModel.self) private var model
    let session: PlayerController.ReceiverSession

    var body: some View {
        let songs = (session.current.map { [$0] } ?? []) + Array(session.upcoming)
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: ReceiverText.yourQueue).padding(.horizontal, 16).padding(.top, 12)
            List {
                ForEach(songs) { entry in
                    QueueRow(entry: entry, isCurrent: false)
                        .opacity(0.55)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.player.jump(to: entry.id) })
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}
