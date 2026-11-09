//
// Vespertine: Room Correction, for a speaker group's output: the profile made from the drawing and the warning when a measurement and
// the drawing disagree. Hidden with the rest of the feature (only a group's output shows it).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio

struct SpeakerGroupAlignmentCard: View {
    @Environment(AppModel.self) private var model
    let group: SpeakerGroup

    var body: some View {
        let book = model.settings.roomBook
        let state = GroupRoomProfile.drawingState(for: group, in: book)
        VStack(alignment: .leading, spacing: 8) {
            Text("Speaker group · \(group.name)", comment: "Room Correction card title for a speaker group output: the group's name follows.").font(Typeface.ui(13, weight: .semibold)).foregroundStyle(Palette.text)
            if let warning = GroupRoomProfile.geometryWarning(for: group, in: book) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.copper).accessibilityHidden(true)
                    Text(verbatim: warning).font(Typeface.ui(12)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Text(verbatim: Self.explanation(state)).font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            if let label = Self.buttonTitle(state) {
                Button { model.useDrawing(of: group) } label: { Text(verbatim: label) }
                    .controlSize(.small)
                    .help(Text("Delays and levels worked out from where the speakers and the seat are drawn; no microphone needed"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

    static func explanation(_ state: GroupDrawingState) -> String {
        switch state {
        case .unavailable: String(localized: "Put the speakers on the outputs in the group's editor, and the room you draw can line them up without a microphone.", comment: "Room Correction card for a speaker group.")
        case .notMade: String(localized: "Line the speakers up from the room you drew: nearer speakers wait for the farthest and are turned down to match. No microphone needed; a measurement replaces it.", comment: "Room Correction card for a speaker group.")
        case .available: String(localized: "A profile from the drawing is saved. It follows the drawing when you move a speaker.", comment: "Room Correction card for a speaker group.")
        case .inUse: String(localized: "Playing with the drawing's alignment. It follows the drawing when you move a speaker.", comment: "Room Correction card for a speaker group.")
        }
    }

    static func buttonTitle(_ state: GroupDrawingState) -> String? {
        switch state {
        case .notMade: String(localized: "Use the Drawing", comment: "Button: makes a room correction profile from the speaker group's drawing.")
        case .available: String(localized: "Use the Drawing Instead", comment: "Button: plays with the drawing's alignment instead of the measured profile.")
        case .unavailable, .inUse: nil
        }
    }
}
