//
// Vespertine: Mac Sound Output (beta): the helper. A login item with no window or Dock icon that keeps the speaker groups the
// user published showing as outputs of the Mac, and plays a group whenever an app plays to it, with Vespertine open or not.
// Vespertine registers it (SMAppService) when the first group is published and unregisters it when the last one isn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Its menu bar item is off by default (Settings › Playback › Mac Sound Output (beta) in Vespertine turns it on).
//

import AppKit
import CoreAudio
import VespertineAudio

@main
@MainActor
final class SoundHelperApp: NSObject, NSApplicationDelegate {
    private var service: SystemOutputService?
    private var statusItem: NSStatusItem?
    private var status: SystemOutputStatus?
    private var terminationSource: DispatchSourceSignal?

    static func main() {
        let app = NSApplication.shared
        let delegate = SoundHelperApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Development builds of the helper meet development builds of Vespertine.
    private var development: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = SystemOutputService(directory: SystemOutputSnapshot.directory(development: development))
        service.onStatus = { [weak self] status in
            Task { @MainActor in self?.show(status) }
        }
        self.service = service
        service.start()

        // launchd stops a login item with SIGTERM: take the outputs away first (they would go on their own 20 s later).
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        terminationSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        service?.stop()
    }

    // MARK: The menu bar item

    private func show(_ status: SystemOutputStatus) {
        self.status = status
        guard status.menuBarItem, !status.groups.isEmpty else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let playing = status.groups.contains { $0.state == .playing }
        item.button?.image = NSImage(systemSymbolName: playing ? "hifispeaker.2.fill" : "hifispeaker.2",
                                     accessibilityDescription: String(localized: "Mac Sound Output (beta)"))
        item.menu = menu(for: status)
    }

    private func menu(for status: SystemOutputStatus) -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: String(localized: "Mac Sound Output (beta)"), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if !status.driverLoaded {
            let item = NSMenuItem(title: String(localized: "The audio driver is not installed. Turn it on in Vespertine's settings."), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for group in status.groups {
            menu.addItem(.separator())
            let name = NSMenuItem(title: group.name, action: #selector(makeDefault(_:)), keyEquivalent: "")
            name.target = self
            name.representedObject = group.groupID.uuidString
            name.state = group.isDefault ? .on : .off
            name.toolTip = String(localized: "Play the Mac's sound on this group")
            menu.addItem(name)
            let detail = NSMenuItem(title: Self.describe(group), action: nil, keyEquivalent: "")
            detail.isEnabled = false
            detail.indentationLevel = 1
            menu.addItem(detail)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: String(localized: "Open Vespertine"), action: #selector(openVespertine), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    private static func describe(_ group: SystemOutputStatus.Group) -> String {
        switch group.state {
        case .ready: return String(localized: "Ready")
        case .playing:
            if let rate = group.sampleRate, let latency = group.latencyMs {
                let kHz = (rate / 1000).formatted(.number.precision(.fractionLength(0...1)))
                let ms = Int(latency.rounded())
                return String(localized: "Playing at \(kHz) kHz, \(ms) ms behind")
            }
            return String(localized: "Playing")
        case .handedOff: return String(localized: "Vespertine is playing this group")
        case .failed: return group.message ?? String(localized: "Could not play the group")
        }
    }

    @objc private func makeDefault(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text) else { return }
        service?.makeDefault(id)
    }

    @objc private func openVespertine() {
        // The helper lives in Vespertine.app/Contents/Library/LoginItems.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
