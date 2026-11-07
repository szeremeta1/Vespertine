//
// Vespertine — Settings › Speaker Groups › Edit: what a stereo song does on more than two speakers, what becomes of the subwoofer
// channel, and what happens when an output goes away. The options and their words are `GroupPolicies` in VespertineKit.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain English with `verbatim` text: these strings join the catalog together with the screens that stay.
//

import SwiftUI
import VespertineAudio

struct SpeakerPoliciesView: View {
    @Binding var group: SpeakerGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stereo
            lfe
            loss
        }
    }

    private var stereo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Stereo songs").font(.headline)
            Picker(selection: Binding(get: { GroupPolicies.stereoChoice(group) }, set: { group = GroupPolicies.setStereo($0, in: group) })) {
                ForEach(GroupPolicies.StereoChoice.allCases) { Text(verbatim: $0.title).tag($0) }
            } label: { Text(verbatim: "Stereo songs") }
            .labelsHidden().pickerStyle(.radioGroup)
            Text(verbatim: GroupPolicies.stereoChoice(group).detail).font(.caption).foregroundStyle(.secondary)
            if let trim = GroupPolicies.mirrorTrim(group) {
                Stepper(value: Binding(get: { trim }, set: { group = GroupPolicies.setMirrorTrim($0, in: group) }), in: GroupPolicies.levelRange, step: 1) {
                    Text(verbatim: "Back pair level: \(Int(trim)) dB").monospacedDigit()
                }
            }
            Text(verbatim: GroupPolicies.stereoNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lfe: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Subwoofer channel").font(.headline)
            Picker(selection: Binding(get: { GroupPolicies.lfeChoice(group) }, set: { group = GroupPolicies.setLFE($0, in: group) })) {
                ForEach(GroupPolicies.LFEChoice.allCases) { Text(verbatim: $0.title).tag($0) }
            } label: { Text(verbatim: "Subwoofer channel") }
            .labelsHidden().pickerStyle(.radioGroup)
            Text(verbatim: GroupPolicies.lfeChoice(group).detail).font(.caption).foregroundStyle(.secondary)
            if let level = GroupPolicies.lfeLevel(group) {
                Stepper(value: Binding(get: { level }, set: { group = GroupPolicies.setLFELevel($0, in: group) }), in: GroupPolicies.levelRange, step: 1) {
                    Text(verbatim: "Level: \(Int(level)) dB").monospacedDigit()
                }
            }
            if case .toSpeaker(let chosen) = group.lfePolicy {
                Picker(selection: Binding(get: { chosen }, set: { group = GroupPolicies.setLFESpeaker($0, in: group) })) {
                    ForEach(group.speakers) { Text(verbatim: $0.role.plainName).tag($0.id) }
                } label: { Text(verbatim: "Speaker") }
            }
            Text(verbatim: GroupPolicies.lfeNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var loss: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "If an output goes away").font(.headline)
            Picker(selection: Binding(get: { GroupPolicies.lossChoice(group) }, set: { group = GroupPolicies.setLoss($0, in: group) })) {
                ForEach(GroupPolicies.LossChoice.allCases) { Text(verbatim: $0.title).tag($0) }
            } label: { Text(verbatim: "If an output goes away") }
            .labelsHidden().pickerStyle(.radioGroup)
            Text(verbatim: GroupPolicies.lossChoice(group).detail).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: GroupPolicies.lossNote).font(.caption).foregroundStyle(.secondary)
        }
    }
}
