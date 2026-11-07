//
// Vespertine — Settings › Playback › Speaker Groups (experimental). Hidden unless its switch is on; for now it lists, copies
// and removes the saved groups. Making and playing them comes with the next pieces.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain English with `verbatim` text: these strings join the catalog together with the screens that stay.
//

import SwiftUI
import VespertineAudio

struct SpeakerGroupsSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.settings.speakerGroupsFeature {
            SpeakerGroupsList(directory: model.settings.dataDirectory)
        }
    }
}

private struct SpeakerGroupsList: View {
    @State private var groups: SpeakerGroupsModel

    init(directory: URL) { _groups = State(initialValue: SpeakerGroupsModel(directory: directory)) }

    var body: some View {
        Section {
            if groups.groups.isEmpty {
                Text(verbatim: "No speaker groups yet.").foregroundStyle(.secondary)
            }
            ForEach(groups.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: group.name).font(.body.weight(.medium))
                        Spacer()
                        Button(role: .none) { groups.duplicate(group.id) } label: { Text(verbatim: "Duplicate") }
                        Button(role: .destructive) { groups.remove(group.id) } label: { Text(verbatim: "Remove") }
                    }
                    Text(verbatim: SpeakerGroupsModel.summary(group)).font(.caption).foregroundStyle(.secondary)
                    if let problem = SpeakerGroupsModel.problem(group) {
                        Text(verbatim: problem).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if groups.unreadableCount > 0 {
                Text(verbatim: "\(groups.unreadableCount) saved group(s) from another version are kept as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = groups.lastError {
                Text(verbatim: "Couldn't save: \(error)").font(.caption).foregroundStyle(.red)
            }
            Text(verbatim: "Experimental. Combining outputs into one speaker system isn't available yet; this list only shows what is saved.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(verbatim: "Speaker Groups (experimental)")
        }
    }
}
