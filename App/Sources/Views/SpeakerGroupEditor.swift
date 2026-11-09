//
// Vespertine: Settings › Speaker Groups › Edit: one saved group. Hidden with the rest of the feature. Every change is saved at once.
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
                    MemberVolumeView(group: group)
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
    @Environment(AppModel.self) private var model
    @Binding var group: SpeakerGroup
    @State private var identifier = GroupIdentifier()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Channels").font(.headline)
            Text(verbatim: "Choose which speaker is on each channel of each output. Identify plays a quiet tone on that channel only. Inverted turns that speaker's signal over in playback, for a speaker wired the other way round.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text(verbatim: "Output channel").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "Speaker").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "Polarity").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "Identify").font(.caption).foregroundStyle(.secondary)
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
                        Button { identifier.identify(row, in: group, outputInUseUID: model.player.outputDevice?.uid) } label: {
                            Image(systemName: identifier.playing == row.aggregateChannel ? "speaker.wave.2.fill" : "speaker.wave.2")
                        }
                        .buttonStyle(.borderless)
                        .help(Text(verbatim: "Play a quiet tone on this channel only"))
                        .accessibilityLabel(Text(verbatim: "Identify \(row.label)"))
                    }
                }
            }
            if let problem = identifier.problem {
                Text(verbatim: problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { identifier.stop() }
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

/// The Identify buttons' player: one tone at a time, on one channel of one DAC, quiet, and never while the group's output is in use.
@MainActor @Observable
final class GroupIdentifier {
    /// The aggregate channel whose tone is sounding.
    private(set) var playing: Int?
    private(set) var problem: String?
    @ObservationIgnored private var player: GroupIdentifyPlayer?
    @ObservationIgnored private var reset: Task<Void, Never>?

    func identify(_ row: GroupChannelMap.Row, in group: SpeakerGroup, outputInUseUID: String?) {
        stop()
        if let refusal = GroupIdentify.refusal(for: group, outputInUseUID: outputInUseUID) { problem = refusal; return }
        guard let plan = GroupIdentify.plan(group: group, aggregateChannel: row.aggregateChannel) else { return }
        do {
            let player = try GroupIdentifyPlayer(plan: plan, deviceName: row.deviceName)
            try player.start()
            self.player = player
            playing = row.aggregateChannel
            reset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(IdentifyTone.seconds + 0.3))
                if !Task.isCancelled { self?.stop() }
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        reset?.cancel()
        reset = nil
        player?.stop()
        player = nil
        playing = nil
        problem = nil
    }
}

/// The group's volume: the choice between each DAC's own knob and Vespertine's volume for all of them (saved per output, like the
/// transport bar's), then each DAC's own volume: shown for the ones that have a volume Core Audio can set, written when the slider is
/// let go. The DACs' levels are never changed by Vespertine on its own.
struct MemberVolumeView: View {
    @Environment(AppModel.self) private var model
    let group: SpeakerGroup
    @State private var members: [GroupVolume.Member] = []
    @State private var editing: [String: Float] = [:]

    private var choice: Binding<GroupVolumeChoice> {
        Binding(get: { GroupVolumeChoice.current(in: model.settings, for: group) },
                set: { $0.apply(to: model.settings, for: group); model.syncEngine() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volume").font(.headline)
            Picker(selection: choice) {
                Text("Hardware volume (each DAC's knob)").tag(GroupVolumeChoice.hardware)
                Text("Software volume (set both DACs once, control here)").tag(GroupVolumeChoice.software)
            } label: { Text("Volume") }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            (choice.wrappedValue == .software
                ? Text("Set each DAC to one fixed level, then control the volume in Vespertine: the volume slider, or Volume Up and Down in the Controls menu. Below 100%, playback is not bit-perfect.")
                : Text("Set each DAC's level on the DAC or with the sliders below. Vespertine does not touch the samples, so playback stays bit-perfect."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: GroupVolume.note).font(.caption).foregroundStyle(.secondary)
            ForEach(members) { member in
                HStack {
                    Text(verbatim: member.name).frame(width: 190, alignment: .leading)
                    if let level = member.level {
                        Slider(value: Binding(get: { Double(editing[member.uid] ?? level) }, set: { editing[member.uid] = Float($0) }),
                               in: 0...1) { done in
                            if !done, let value = editing[member.uid] {
                                GroupVolume.setLevel(value, ofDeviceUID: member.uid)
                                members = GroupVolume.members(of: group)
                                editing[member.uid] = nil
                            }
                        }
                        .frame(width: 220)
                        .accessibilityLabel(Text(verbatim: "Volume of \(member.name)"))
                        Text(verbatim: "\(Int(((editing[member.uid] ?? level) * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "No volume to set here (use the DAC's own control)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { members = GroupVolume.members(of: group) }
    }
}
