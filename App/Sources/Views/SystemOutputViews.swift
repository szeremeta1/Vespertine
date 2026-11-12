//
// Vespertine: Settings › Playback › Mac Sound Output (beta): a speaker group as an output of the Mac, under the name the user gave
// it. Shown while Speaker Groups (beta) is on and a group is saved; every group is off until turned on here. Group names are shown
// as they are.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio

struct SystemOutputSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.settings.speakerGroupsFeature, let groups = model.speakerGroups, !groups.groups.isEmpty {
            Section {
                content(groups.groups)
            } header: {
                Text("Mac Sound Output (beta)")
            }
        }
    }

    @ViewBuilder
    private func content(_ groups: [SpeakerGroup]) -> some View {
        let output = model.systemOutput
        Text("Shows a speaker group as an output of the Mac, under the name you gave it, so any app can play to it: a browser, the TV app, a video player. The volume keys set its volume. Vespertine's helper plays it, with Vespertine open or closed. Every group is off until you turn it on.")
            .font(.caption).foregroundStyle(.secondary)
        if output.isolated {
            Text("Not available while Vespertine runs on a test library.").font(.caption).foregroundStyle(.secondary)
        } else {
            DriverRow(output: output)
            if output.driver != .notInstalled {
                ForEach(groups) { group in GroupRow(output: output, group: group) }
                Toggle("Show in the menu bar", isOn: Binding(get: { output.menuBarItem }, set: { output.menuBarItem = $0 }))
                HelperNote(output: output)
            }
            Text("Most websites send stereo; the TV app and video players such as IINA and VLC send 5.1 and 7.1. While Vespertine itself plays a group, what other apps send it is not heard.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = output.lastError {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct DriverRow: View {
    let output: SystemOutputModel

    var body: some View {
        LabeledContent("Audio driver") {
            HStack {
                if output.working { ProgressView().controlSize(.small) }
                switch output.driver {
                case .notInstalled:
                    Button("Install…") { output.installDriver() }
                case .outdated:
                    Button("Update…") { output.installDriver() }
                    Button("Remove…") { output.removeDriver() }
                case .notLoaded, .ready:
                    Button("Remove…") { output.removeDriver() }
                }
            }
            .disabled(output.working)
        }
        Group {
            switch output.driver {
            case .notInstalled:
                Text("Installing asks for an administrator's password, and the Mac's sound stops for a moment while macOS restarts its audio.")
            case .notLoaded:
                Text("Installed. macOS loads it the next time its audio restarts; installing again restarts it now.")
            case .outdated:
                Text("This Vespertine has a newer driver. Updating asks for an administrator's password, and the Mac's sound stops for a moment.")
            case .ready:
                EmptyView()
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

private struct GroupRow: View {
    let output: SystemOutputModel
    let group: SpeakerGroup

    var body: some View {
        let choice = output.choice(for: group.id)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { choice.published }, set: { on in var c = choice; c.published = on; output.setChoice(c, for: group.id) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: group.name).font(.body.weight(.medium))
                    if let line = statusLine(choice) {
                        Text(verbatim: line).font(.caption).foregroundStyle(output.groupStatus(group.id)?.state == .failed ? .orange : .secondary)
                    }
                }
            }
            .disabled(!group.issues.isEmpty)
            if choice.published {
                Picker("Channels it offers", selection: Binding(get: { choice.layout }, set: { var c = choice; c.layout = $0; output.setChoice(c, for: group.id) })) {
                    Text("Automatic (\(Self.name(SystemOutputLayout.automatic(for: group))))", comment: "Mac Sound Output: the layout picked from the group's speakers, e.g. “Automatic (5.1)”.")
                        .tag(SystemOutputLayout.automatic)
                    ForEach([SystemOutputLayout.stereo, .quad, .surround51, .surround71, .surround714, .surround916], id: \.self) { layout in
                        Text(verbatim: Self.name(layout)).tag(layout)
                    }
                }
                Picker("Stereo from other apps", selection: Binding(get: { choice.stereo }, set: { var c = choice; c.stereo = $0; output.setChoice(c, for: group.id) })) {
                    Text("As the group plays music").tag(SystemOutputStereo.asGroup)
                    Text("Extended stereo").tag(SystemOutputStereo.extended)
                    Text("Upmixed to surround").tag(SystemOutputStereo.upmix)
                }
                Text(verbatim: Self.stereoExplanation(choice.stereo)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func statusLine(_ choice: SystemOutputChoice) -> String? {
        if let problem = SpeakerGroupsModel.problem(group) { return problem }
        guard choice.published, let status = output.groupStatus(group.id) else { return nil }
        switch status.state {
        case .ready: return String(localized: "Ready")
        case .playing:
            if let rate = status.sampleRate, let latency = status.latencyMs {
                let kHz = (rate / 1000).formatted(.number.precision(.fractionLength(0...1)))
                let ms = Int(latency.rounded())
                return String(localized: "Playing at \(kHz) kHz, \(ms) ms behind")
            }
            return String(localized: "Playing")
        case .handedOff: return String(localized: "Vespertine is playing this group")
        case .failed: return status.message ?? String(localized: "Could not play the group")
        }
    }

    static func name(_ layout: SystemOutputLayout) -> String {
        switch layout {
        case .automatic, .stereo: String(localized: "Stereo")
        case .quad: String(localized: "Quad")
        case .surround51: "5.1"
        case .surround71: "7.1"
        case .surround714: "7.1.4"
        case .surround916: "9.1.6"
        }
    }

    static func stereoExplanation(_ stereo: SystemOutputStereo) -> String {
        switch stereo {
        case .asGroup: String(localized: "Stereo plays as the group's stereo setting plays music.")
        case .extended: String(localized: "Left plays on every speaker on the left, right on every speaker on the right, as a receiver's all-channel stereo.")
        case .upmix: String(localized: "Stereo is upmixed to 5.1 (a centre from what both sides share, the surrounds from the ambience) and placed on the group's speakers. It adds a little delay, which video players are told about, so the picture stays in step.")
        }
    }
}

private struct HelperNote: View {
    let output: SystemOutputModel

    var body: some View {
        switch output.helper {
        case .off, .on:
            EmptyView()
        case .needsApproval:
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow Vespertine Sound Helper in System Settings › General › Login Items, so the groups play with Vespertine closed.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Open Login Items Settings…") { output.openLoginItemsSettings() }
            }
        case .failed(let reason):
            Text("The helper could not start: \(reason)", comment: "Mac Sound Output: why the background helper failed to start.")
                .font(.caption).foregroundStyle(.red)
        }
    }
}
