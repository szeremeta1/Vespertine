//
// Vespertine — Settings › Speaker Groups › Edit: a preset to lay the speakers out with, and for each speaker where it stands and what
// that asks of it (distance, angle, delay, level) with its own level and delay trims. The numbers are `GroupReadout` in VespertineKit.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain English with `verbatim` text: these strings join the catalog together with the screens that stay.
//

import SwiftUI
import VespertineAudio

struct SpeakerPresetMenu: View {
    @Binding var group: SpeakerGroup

    var body: some View {
        let presets = GroupPresets.available(for: group)
        Menu {
            ForEach(presets) { preset in
                Button { if let laid = GroupPresets.apply(preset, to: group) { group = laid } } label: { Text(verbatim: preset.title) }
            }
        } label: { Text(verbatim: "Lay out with a preset…") }
        .disabled(presets.isEmpty)
        .help(presets.isEmpty ? Text(verbatim: "A preset needs at least four channels.") : Text(verbatim: "Places the speakers on the channels in order, around the seat."))
    }
}

struct SpeakerReadoutView: View {
    @Binding var group: SpeakerGroup
    @AppStorage("speakerGroupsUnit") private var unitName = DistanceUnit.metres.rawValue
    /// What the readout's frames are counted at: the rate the group plays at. Shown at 48 kHz until it plays.
    var sampleRate: Double = 48_000

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitName) ?? .metres }

    var body: some View {
        let rows = GroupReadout.rows(group, sampleRate: sampleRate, unit: unit)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "Speakers").font(.headline)
                Spacer()
                SpeakerPresetMenu(group: $group)
            }
            if rows.isEmpty {
                Text(verbatim: "Place the speakers on the room above, or lay them out with a preset.").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["Speaker", "Distance", "Angle", "Waits", "Level", "Level trim", "Delay trim"], id: \.self) {
                            Text(verbatim: $0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rows) { row in
                        GridRow {
                            Text(verbatim: row.role.plainName)
                            Text(verbatim: row.distance).monospacedDigit()
                            Text(verbatim: row.angle).monospacedDigit()
                            Text(verbatim: row.delay + (row.delayLimited ? " (cut to what the chain holds)" : "")).monospacedDigit()
                            Text(verbatim: row.level).monospacedDigit()
                            Stepper(value: trim(row.speakerID, \.trimDB), in: SpeakerGroup.trimRangeDB, step: 0.5) {
                                Text(verbatim: String(format: "%+.1f dB", group.speakers.first { $0.id == row.speakerID }?.trimDB ?? 0)).monospacedDigit()
                            }
                            .accessibilityLabel(Text(verbatim: "Level trim of \(row.role.plainName)"))
                            Stepper(value: trim(row.speakerID, \.delayTrimMs), in: SpeakerGroup.delayTrimRangeMs, step: 0.1) {
                                Text(verbatim: String(format: "%.1f ms", group.speakers.first { $0.id == row.speakerID }?.delayTrimMs ?? 0)).monospacedDigit()
                            }
                            .accessibilityLabel(Text(verbatim: "Delay trim of \(row.role.plainName)"))
                        }
                    }
                }
                Text(verbatim: "The speakers nearer the seat wait for the farthest one and are turned down by the difference, so nothing is ever boosted.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: GroupPolicies.playedToday)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func trim(_ id: UUID, _ keyPath: WritableKeyPath<SpeakerGroup.Speaker, Double>) -> Binding<Double> {
        Binding(get: { group.speakers.first { $0.id == id }?[keyPath: keyPath] ?? 0 },
                set: { value in
                    guard let index = group.speakers.firstIndex(where: { $0.id == id }) else { return }
                    group.speakers[index][keyPath: keyPath] = value
                })
    }
}
