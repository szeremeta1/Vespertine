//
// Vespertine — a bit-perfect audio player for macOS.
// Copyright © 2026 Vespertine contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit

/// The standard About panel, with the bundled Credits.html below a small localized sign-off.
enum AboutPanel {
    @MainActor static func show() {
        let credits = NSMutableAttributedString()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 10
        let base = NSFont.systemFont(ofSize: 12)
        let serif = base.fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.italic)
        credits.append(NSAttributedString(
            string: String(localized: "Made with ❤️ in Boston") + "\n",
            attributes: [
                .font: serif.flatMap { NSFont(descriptor: $0, size: 12) } ?? base,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centered,
            ]))
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "html"),
           let html = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.html],
                                              documentAttributes: nil) {
            credits.append(html)
        }
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
