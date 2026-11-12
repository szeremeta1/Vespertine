//
// Vespertine: the DoP hint under the signal path and the one-tap test sheet.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio

/// Shown under the signal path while DSD is being converted to PCM on an output that isn't a known DoP DAC and offers
/// the DoP carrier rate: says so, and offers the one-tap test. The words are placeholders in `DoPTestConstants`.
struct DoPSetupCard: View {
    @Environment(AppModel.self) private var model
    let path: SignalPath

    private var device: OutputDevice? {
        guard path.plan.dsdConvertedToPCM, path.group == nil else { return nil }
        return model.devices.devices.first { $0.uid == path.deviceUID }
    }

    var body: some View {
        if let device {
            let hint = model.dopSetup.hint(for: device)
            if hint != .none {
                let words = DoPTestConstants.wording
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: words.offerTitle).font(Typeface.ui(12)).foregroundStyle(Palette.text)
                    Text(verbatim: body(for: hint, words)).font(Typeface.ui(10.5)).foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: { model.dopSetup.begin(device) }) { Text(verbatim: words.testButton) }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private func body(for hint: DoPSetupHint, _ words: DoPTestConstants.Wording) -> String {
        if case .suggestTest(let maker) = hint { return words.suggestBody.replacingOccurrences(of: "%@", with: maker) }
        return words.offerBody
    }
}

/// The test itself: plays the clip, then asks "music or hiss?". Closing it at any point stops the clip.
struct DoPTestSheet: View {
    @Environment(AppModel.self) private var model
    let device: OutputDevice

    private var setup: DoPSetupModel { model.dopSetup }

    var body: some View {
        let words = DoPTestConstants.wording
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: device.name).font(Typeface.serif(22)).foregroundStyle(Palette.text)
            switch setup.phase {
            case .idle, .starting, .playing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: words.listening).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                }
            case .question:
                Text(verbatim: words.question).font(Typeface.ui(13)).foregroundStyle(Palette.text)
            case .finished(let outcome):
                Text(verbatim: outcome == .music ? words.musicResult : words.hissResult).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            case .aborted(let message):
                Text(verbatim: message).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                switch setup.phase {
                case .question:
                    Button(action: { setup.answer(.hiss) }) { Text(verbatim: words.hissButton) }.buttonStyle(QuietButtonStyle())
                    Button(action: { setup.answer(.music) }) { Text(verbatim: words.musicButton) }.buttonStyle(BrassButtonStyle())
                case .finished, .aborted:
                    Button("Done") { setup.close() }.buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
                default:
                    Button(action: { setup.cancel() }) { Text(verbatim: words.cancelButton) }.buttonStyle(QuietButtonStyle())
                }
            }
        }
        .padding(22)
        .frame(width: 380)
        .interactiveDismissDisabled(setup.phase == .starting || setup.phase == .playing)
        .onDisappear { setup.close() }
    }
}
