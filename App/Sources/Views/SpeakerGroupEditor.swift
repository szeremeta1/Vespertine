//
// Vespertine — Settings › Speaker Groups › Edit: one saved group. Hidden with the rest of the feature. Every change is saved at once.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain English with `verbatim` text: these strings join the catalog together with the screens that stay.
//

import SwiftUI
import VespertineAudio

struct SpeakerGroupEditor: View {
    let groups: SpeakerGroupsModel
    @State private var group: SpeakerGroup
    @Environment(\.dismiss) private var dismiss

    init(groups: SpeakerGroupsModel, group: SpeakerGroup) {
        self.groups = groups
        _group = State(initialValue: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: group.name).font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RoomCanvasView(group: $group)
                    SpeakerReadoutView(group: $group)
                    ChannelMapGrid(group: $group)
                    SpeakerPoliciesView(group: $group)
                }
            }
            HStack {
                if let problem = SpeakerGroupsModel.problem(group) {
                    Text(verbatim: problem).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button { dismiss() } label: { Text(verbatim: "Done") }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .onChange(of: group) { _, new in groups.upsert(new) }
    }
}

/// Every channel of every output against the speaker on it.
struct ChannelMapGrid: View {
    @Binding var group: SpeakerGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Channels").font(.headline)
            Text(verbatim: "Choose which speaker is on each channel of each output.").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text(verbatim: "Output channel").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "Speaker").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "Polarity").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(GroupChannelMap.rows(group)) { row in
                    GridRow {
                        Text(verbatim: row.label)
                        Picker(selection: roleBinding(row)) {
                            Text(verbatim: "None").tag(SpeakerRole?.none)
                            ForEach(roles(for: row), id: \.self) { Text(verbatim: $0.plainName).tag(SpeakerRole?.some($0)) }
                        } label: { Text(verbatim: "Speaker on \(row.label)") }
                        .labelsHidden()
                        .frame(width: 190)
                        Toggle(isOn: invertedBinding(row)) { Text(verbatim: "Inverted") }
                            .disabled(row.role == nil)
                            .accessibilityLabel(Text(verbatim: "Invert polarity of \(row.label)"))
                    }
                }
            }
        }
    }

    /// The roles this channel can take: the ones not used elsewhere, and its own.
    private func roles(for row: GroupChannelMap.Row) -> [SpeakerRole] {
        let free = Set(GroupChannelMap.freeRoles(group))
        return SpeakerRole.allCases.filter { free.contains($0) || $0 == row.role }
    }

    private func roleBinding(_ row: GroupChannelMap.Row) -> Binding<SpeakerRole?> {
        Binding(get: { GroupChannelMap.rows(group).first { $0.aggregateChannel == row.aggregateChannel }?.role },
                set: { group = GroupChannelMap.assign($0, toChannel: row.channelOnDevice, of: row.deviceUID, in: group) })
    }

    private func invertedBinding(_ row: GroupChannelMap.Row) -> Binding<Bool> {
        Binding(get: { GroupChannelMap.rows(group).first { $0.aggregateChannel == row.aggregateChannel }?.inverted ?? false },
                set: { group = GroupChannelMap.setInverted($0, channel: row.channelOnDevice, of: row.deviceUID, in: group) })
    }
}
