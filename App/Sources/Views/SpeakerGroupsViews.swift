//
// Vespertine: Settings › Playback › Speaker Groups (beta): its switch (off by default) and, while it is on, the list of saved
// groups, to copy, remove and make. Group, output and device names are shown as they are.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio

struct SpeakerGroupsSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var making = false
    @State private var editing: SpeakerGroup?

    var body: some View {
        Section {
            ForEach(SpeakerGroupsSwitch.rows(featureOn: model.settings.speakerGroupsFeature), id: \.self) { row in
                switch row {
                case .toggle:
                    Toggle(SpeakerGroupsSwitch.title, isOn: Binding(get: { model.settings.speakerGroupsFeature }, set: { model.setSpeakerGroupsFeature($0) }))
                case .explanation:
                    Text(SpeakerGroupsSwitch.explanation).font(.caption).foregroundStyle(.secondary)
                case .groups:
                    if let groups = model.speakerGroups { SpeakerGroupsList(groups: groups, making: $making, editing: $editing) }
                }
            }
        } header: {
            Text(SpeakerGroupsSwitch.title)
        }
        .sheet(isPresented: $making) { if let groups = model.speakerGroups { NewSpeakerGroupSheet(groups: groups) } }
        .sheet(item: $editing) { group in if let groups = model.speakerGroups { SpeakerGroupEditor(groups: groups, group: group) } }
    }
}

private struct SpeakerGroupsList: View {
    let groups: SpeakerGroupsModel
    @Binding var making: Bool
    @Binding var editing: SpeakerGroup?

    var body: some View {
        Group {
            if groups.groups.isEmpty {
                Text("No speaker groups yet.").foregroundStyle(.secondary)
            }
            ForEach(groups.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: group.name).font(.body.weight(.medium))
                        Spacer()
                        Button { editing = group } label: { Text("Edit…") }
                        Button(role: .none) { groups.duplicate(group.id) } label: { Text("Duplicate") }
                        Button(role: .destructive) { groups.remove(group.id) } label: { Text("Remove") }
                    }
                    Text(verbatim: SpeakerGroupsModel.summary(group)).font(.caption).foregroundStyle(.secondary)
                    if let problem = SpeakerGroupsModel.problem(group) {
                        Text(verbatim: problem).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if groups.unreadableCount > 0 {
                Text("\(groups.unreadableCount) saved groups from another version are kept as they are.", comment: "Speaker Groups settings: groups a newer version saved, which this version keeps untouched. Plural by the count.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { making = true } label: { Text("New Group…") }
            if let error = groups.lastError {
                Text("Couldn't save: \(error)", comment: "Speaker Groups settings: the reason saving the group list failed.").font(.caption).foregroundStyle(.red)
            }
            Text("Beta: tested with virtual devices and by hand on a real pair of DACs (Fosi Audio ZD3 and FiiO K11). Only the clock leader's channels can be bit-perfect.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
            Text("New Speaker Group").font(.title3.weight(.semibold))
            TextField(text: $draft.name, prompt: Text("Name")) { Text("Name") }
            Text("Outputs to combine").font(.headline)
            List(candidates) { candidate in
                HStack(alignment: .firstTextBaseline) {
                    Toggle(isOn: Binding(get: { draft.isChosen(candidate.uid) }, set: { _ in draft.toggle(candidate) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: candidate.name)
                            Text("\(candidate.channels) channels · \(candidate.transport.label)", comment: "New Speaker Group: an output's channel count (plural by the count), a dot, then how it connects (USB, built-in).")
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
                            .accessibilityLabel(Text("Move \(candidate.name) earlier", comment: "Accessibility label: moves this output earlier in the group's order."))
                        Button { draft.move(candidate.uid, by: 1) } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel(Text("Move \(candidate.name) later", comment: "Accessibility label: moves this output later in the group's order."))
                    }
                }
            }
            .frame(minHeight: 160)
            if draft.chosen.count >= 2 {
                Picker(selection: Binding(get: { draft.leaderUID ?? "" }, set: { draft.setLeader($0) })) {
                    ForEach(draft.chosen) { Text(verbatim: $0.name).tag($0.uid) }
                } label: { Text("Clock leader") }
                Text(verbatim: SpeakerGroupDraft.leaderExplanation).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(draft.problemsWhileChoosing, id: \.self) {
                Text(verbatim: $0).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { Text("Cancel") }
                Button { groups.create(draft); dismiss() } label: { Text("Create") }
                    .keyboardShortcut(.defaultAction).disabled(!draft.canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { candidates = GroupCandidates.list(from: OutputDevices.list()) }
    }
}
