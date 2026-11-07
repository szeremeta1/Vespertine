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
        if model.settings.speakerGroupsFeature, let groups = model.speakerGroups {
            SpeakerGroupsList(groups: groups)
        }
    }
}

private struct SpeakerGroupsList: View {
    let groups: SpeakerGroupsModel
    @State private var making = false
    @State private var editing: SpeakerGroup?

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
                        Button { editing = group } label: { Text(verbatim: "Edit…") }
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
            Button { making = true } label: { Text(verbatim: "New Group…") }
            if let error = groups.lastError {
                Text(verbatim: "Couldn't save: \(error)").font(.caption).foregroundStyle(.red)
            }
            Text(verbatim: "Experimental. Combining outputs into one speaker system isn't available yet; this list only shows what is saved.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(verbatim: "Speaker Groups (experimental)")
        }
        .sheet(isPresented: $making) { NewSpeakerGroupSheet(groups: groups) }
        .sheet(item: $editing) { SpeakerGroupEditor(groups: groups, group: $0) }
    }
}

/// The sheet that makes a group: a name, the outputs to combine (with the reason when one can't join), their order, and which one
/// leads the clock.
private struct NewSpeakerGroupSheet: View {
    let groups: SpeakerGroupsModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SpeakerGroupDraft()
    @State private var candidates: [GroupCandidate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "New Speaker Group").font(.title3.weight(.semibold))
            TextField(text: $draft.name, prompt: Text(verbatim: "Name")) { Text(verbatim: "Name") }
            Text(verbatim: "Outputs to combine").font(.headline)
            List(candidates) { candidate in
                HStack(alignment: .firstTextBaseline) {
                    Toggle(isOn: Binding(get: { draft.isChosen(candidate.uid) }, set: { _ in draft.toggle(candidate) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: candidate.name)
                            Text(verbatim: "\(candidate.channels) \(candidate.channels == 1 ? "channel" : "channels") · \(candidate.transport.label)")
                                .font(.caption).foregroundStyle(.secondary)
                            switch candidate.eligibility {
                            case .ok: EmptyView()
                            case .warning(let note): Text(verbatim: note).font(.caption).foregroundStyle(.orange)
                            case .refused(let reason): Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!candidate.isSelectable)
                    if draft.isChosen(candidate.uid) {
                        Spacer()
                        Button { draft.move(candidate.uid, by: -1) } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel(Text(verbatim: "Move \(candidate.name) earlier"))
                        Button { draft.move(candidate.uid, by: 1) } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel(Text(verbatim: "Move \(candidate.name) later"))
                    }
                }
            }
            .frame(minHeight: 160)
            if draft.chosen.count >= 2 {
                Picker(selection: Binding(get: { draft.leaderUID ?? "" }, set: { draft.setLeader($0) })) {
                    ForEach(draft.chosen) { Text(verbatim: $0.name).tag($0.uid) }
                } label: { Text(verbatim: "Clock leader") }
                Text(verbatim: SpeakerGroupDraft.leaderExplanation).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(draft.problems.filter { draft.chosen.count > 0 || $0 != "Choose at least two outputs." }, id: \.self) {
                Text(verbatim: $0).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { Text(verbatim: "Cancel") }
                Button { groups.create(draft); dismiss() } label: { Text(verbatim: "Create") }
                    .keyboardShortcut(.defaultAction).disabled(!draft.canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { candidates = GroupCandidates.list(from: OutputDevices.list()) }
    }
}
