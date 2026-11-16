//
// Vespertine Remote: the sound of the output the Mac plays to (its equalizer, room correction, Spatial Audio and
// balance), as the Mac's own output panel has them. Shown only for a Mac that says them, and only the ones it offers
// for this output.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct MacSoundSection: View {
    let session: RemoteSession
    let sound: SoundState
    /// The output these belong to, as the Mac names it.
    let output: String?
    let feedback: CommandFeedback

    /// Where the balance slider is while a finger moves it, and until the Mac says the value it took.
    @State private var balanceHeld: Double?
    @State private var balanceSent = Date.distantPast
    @State private var balanceMoving = false

    var body: some View {
        Section {
            if let equalizer = sound.equalizer {
                Picker("Equalizer", selection: Binding(get: { Self.listed(equalizer.selected, in: equalizer.presets) },
                                                       set: { feedback.run(session, .setEqualizer(preset: $0)) })) {
                    Text("Off").tag(String?.none)
                    ForEach(equalizer.presets) { Text($0.name).tag(String?.some($0.id)) }
                }
                .accessibilityIdentifier("mac-sound-equalizer")
                if let note = equalizer.bypassed { Text(note).font(.caption).foregroundStyle(Color.secondary) }
            }
            // With no profile measured on this output there is nothing to switch on: measuring is done at the Mac.
            if let room = sound.room, !room.profiles.isEmpty {
                Picker("Room Correction", selection: Binding(get: { Self.listed(room.selected, in: room.profiles) },
                                                             set: { feedback.run(session, .setRoomCorrection(profile: $0)) })) {
                    Text("Off").tag(String?.none)
                    ForEach(room.profiles) { Text($0.name).tag(String?.some($0.id)) }
                }
                .accessibilityIdentifier("mac-sound-room")
            }
            if let spatial = sound.spatial {
                Picker("Spatial Audio", selection: Binding(get: { spatial.mode }, set: { feedback.run(session, .setSpatialMode(mode: $0)) })) {
                    Text("Off").tag(SpatialModeValue.off)
                    Text("Fixed").tag(SpatialModeValue.fixed)
                    Text("Head Tracked").tag(SpatialModeValue.headTracked)
                }
                .accessibilityIdentifier("mac-sound-spatial")
                if let on = spatial.spatializeStereo {
                    Toggle("Spatialize stereo", isOn: Binding(get: { on }, set: { feedback.run(session, .setSpatializeStereo(on: $0)) }))
                        .accessibilityIdentifier("mac-sound-spatialize")
                }
            }
            if let balance = sound.balance { balanceRows(balance) }
        } header: {
            if let output { Text(output) }
        }
        // The Mac's value takes over once it is the one the slider was left at (while a finger moves the slider, and
        // until the Mac has caught up, its older values would pull the knob back).
        .onChange(of: sound.balance?.value) { _, new in
            if !balanceMoving, let held = balanceHeld, let new, abs(new - held) < 0.005 { balanceHeld = nil }
        }
    }

    /// `selected` while it is one of `choices`; nil (Off) for one the list no longer has.
    static func listed(_ selected: String?, in choices: [SoundChoice]) -> String? {
        choices.contains { $0.id == selected } ? selected : nil
    }

    /// "Centered", "20% left", "35% right".
    static func caption(_ value: Double) -> String {
        let points = BalanceState.points(value)
        if points == 0 { return String(localized: "Centered") }
        return points < 0 ? String(localized: "\(-points)% left") : String(localized: "\(points)% right")
    }

    @ViewBuilder private func balanceRows(_ balance: BalanceState) -> some View {
        let shown = balanceHeld ?? balance.value
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Balance")
                Spacer()
                Text(Self.caption(shown)).foregroundStyle(Color.secondary).monospacedDigit()
            }
            .accessibilityHidden(true)
            // Left is the left speaker in every language: this row never mirrors.
            HStack(spacing: 10) {
                Text("Left").font(.caption).foregroundStyle(Color.secondary).accessibilityHidden(true)
                Slider(value: Binding(get: { shown }, set: { move(to: $0) }), in: -1...1) { editing in
                    if !editing { letGo() }
                }
                // Neither side of the knob is "filled": this is a position, not a level.
                .tint(Color(uiColor: .systemGray4))
                .accessibilityLabel(Text("Balance"))
                .accessibilityValue(Text(Self.caption(shown)))
                .accessibilityIdentifier("mac-sound-balance")
                Text("Right").font(.caption).foregroundStyle(Color.secondary).accessibilityHidden(true)
            }
            .environment(\.layoutDirection, .leftToRight)
            .disabled(balance.bypassed != nil)
            if let note = balance.bypassed { Text(note).font(.caption).foregroundStyle(Color.secondary) }
        }
        Button("Center Balance") {
            balanceHeld = 0
            feedback.run(session, .setBalance(value: 0))
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if balanceHeld == 0, !balanceMoving { balanceHeld = nil }
            }
        }
        .disabled(shown == 0)
        .accessibilityIdentifier("mac-sound-balance-center")
    }

    /// While the slider moves the Mac follows, a few times a second, so the change is heard as it is made.
    private func move(to value: Double) {
        balanceHeld = value
        balanceMoving = true
        guard Date().timeIntervalSince(balanceSent) > 0.15 else { return }
        balanceSent = Date()
        Task { _ = await session.run(.setBalance(value: value)) }
    }

    /// Let go: the Mac gets where the slider settled (the center, when it was left next to it).
    private func letGo() {
        balanceMoving = false
        guard let held = balanceHeld else { return }
        let settled = BalanceState.settled(held)
        balanceHeld = settled
        feedback.run(session, .setBalance(value: settled))
        // The Mac's next state takes over; if it says nothing new (it already had this value), let go of ours.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if balanceHeld == settled, !balanceMoving { balanceHeld = nil }
        }
    }
}
