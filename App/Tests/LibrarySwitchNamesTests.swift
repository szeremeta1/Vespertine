// Vespertine: every switch in Settings › Library has a name VoiceOver can read (the real pane, in a window).
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Vespertine

/// The pane is hosted in a window and its accessibility tree is read the way VoiceOver reads it. A switch with no name is
/// announced as "switch, off" and nothing else.
@Suite("Settings › Library: switch names for VoiceOver", .serialized) @MainActor
struct LibrarySwitchNamesTests {
    /// What the pane offers with Music Servers off and Local Library on: six switches.
    static let expected = [
        LocalLibrarySwitch.title,
        StreamingSwitch.title,
        String(localized: "Scan for new music automatically"),
        String(localized: "Skip voice recordings and short clips"),
        String(localized: "Analyze new music automatically"),
        String(localized: "Include network shares"),
    ]

    /// One getter of the accessibility protocol, asked by name: SwiftUI's own nodes answer these methods without
    /// declaring NSAccessibilityProtocol, so a cast to it finds nothing.
    private func ask(_ object: Any, _ getter: String) -> Any? {
        guard let object = object as? NSObject, object.responds(to: NSSelectorFromString(getter)) else { return nil }
        return object.value(forKey: getter)
    }

    /// Every accessibility element under `root` (a view or one of SwiftUI's nodes), depth first.
    private func elements(under root: Any, depth: Int = 0) -> [Any] {
        guard depth < 60 else { return [] }
        let children = ask(root, "accessibilityChildren") as? [Any] ?? (root as? NSView)?.subviews ?? []
        return [root] + children.flatMap { elements(under: $0, depth: depth + 1) }
    }

    private func isSwitch(_ element: Any) -> Bool {
        ask(element, "accessibilityRole") as? String == NSAccessibility.Role.checkBox.rawValue
            || ask(element, "accessibilitySubrole") as? String == NSAccessibility.Subrole.switch.rawValue
    }

    /// What VoiceOver says for the element: its label (AXDescription), else its title.
    private func name(of element: Any) -> String {
        [ask(element, "accessibilityLabel"), ask(element, "accessibilityTitle")]
            .compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    @Test("Each of the six switches in Settings › Library has a name, and the names are the ones on the screen")
    func everySwitchIsNamed() async throws {
        for _ in 0..<600 where LibraryStartup.current?.model == nil { try? await Task.sleep(for: .seconds(0.05)) }
        let model = try #require(LibraryStartup.current?.model, "the host app has its library open")
        try #require(model.settings.localLibrary, "the host app starts with Local Library on")
        try #require(!model.streaming.isOn("opensubsonic"), "the host app starts with Music Servers off")
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 640, height: 720), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: LibrarySettings().environment(model))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        // SwiftUI builds its accessibility tree only once an assistive app has said it is there, which is what VoiceOver
        // does with this attribute. Put back afterwards.
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true as NSNumber, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false as NSNumber, forAttribute: assistive) }

        var switches: [Any] = []
        for _ in 0..<200 {   // the tree follows the first layout: a bound, not a measure
            host.layoutSubtreeIfNeeded()
            switches = elements(under: host).filter(isSwitch)
            if switches.count >= Self.expected.count { break }
            try? await Task.sleep(for: .seconds(0.05))
        }
        let names = switches.map(name(of:))
        #expect(switches.count == Self.expected.count, "switches found: \(names)")
        #expect(!names.contains(""), "a switch has no name: \(names)")
        for title in Self.expected { #expect(names.contains(title), "no switch named “\(title)” in \(names)") }
    }
}
