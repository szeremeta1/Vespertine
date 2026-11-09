//
// Vespertine: Room Correction, for a speaker group's output: the profile made from the drawing and the warning when a measurement and
// the drawing disagree. Hidden with the rest of the feature (only a group's output shows it).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain English with `verbatim` text: these strings join the catalog together with the screens that stay.
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
            Text(verbatim: "Speaker group · \(group.name)").font(Typeface.ui(13, weight: .semibold)).foregroundStyle(Palette.text)
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
                    .help(Text(verbatim: "Delays and levels worked out from where the speakers and the seat are drawn; no microphone needed"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

    static func explanation(_ state: GroupDrawingState) -> String {
        switch state {
        case .unavailable: "Put the speakers on the outputs in the group's editor, and the room you draw can line them up without a microphone."
        case .notMade: "Line the speakers up from the room you drew: nearer speakers wait for the farthest and are turned down to match. No microphone needed; a measurement replaces it."
        case .available: "A profile from the drawing is saved. It follows the drawing when you move a speaker."
        case .inUse: "Playing with the drawing's alignment. It follows the drawing when you move a speaker."
        }
    }

    static func buttonTitle(_ state: GroupDrawingState) -> String? {
        switch state {
        case .notMade: "Use the Drawing"
        case .available: "Use the Drawing Instead"
        case .unavailable, .inUse: nil
        }
    }
}
