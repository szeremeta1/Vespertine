//
// Vespertine: Settings › Remote: the remote server's switch, pairing a phone, the paired phones, and the options for a
// Mac without a screen. Every switch here is off until turned on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import VespertineRemoteProtocol

struct RemoteSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPairing = false
    @State private var loginItemOn = RemoteLoginItem.isEnabled
    @State private var loginItemNeedsApproval = RemoteLoginItem.needsApproval
    @State private var loginItemError: String?
    @State private var wakeBusy = false
    @State private var wakeError: String?
    @State private var removing: PairedRemote?

    private var server: RemoteServer { model.remote }
    private var store: RemoteStore { model.remote.store }

    var body: some View {
        Form {
            Section {
                Toggle("Let phones control Vespertine", isOn: Binding(get: { store.enabled }, set: { store.enabled = $0; server.apply() }))
                if store.enabled { Text(statusLine).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Remote")
            } footer: {
                Text("Control playback, the queue, your library and the output from the Vespertine Remote app on an iPhone or iPad. Phones connect over your local network only, encrypted, and only after you pair them here. Volume follows the same rules as on this Mac: an output with a fixed volume stays fixed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if store.enabled {
                Section("Paired phones") {
                    if store.devices.isEmpty {
                        Text("No phones yet.").foregroundStyle(.secondary)
                    }
                    ForEach(store.devices.sorted { $0.pairedAt < $1.pairedAt }) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(detail(device)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove…") { removing = device }
                        }
                    }
                    Button("Pair a Phone…") {
                        server.beginPairing()
                        showPairing = true
                    }
                    .disabled(!server.isRunning)
                }
            }

            Section {
                Toggle("Open Vespertine at login", isOn: Binding(get: { loginItemOn }, set: setLoginItem))
                if loginItemNeedsApproval {
                    HStack {
                        Text("macOS needs you to allow Vespertine in Login Items.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { RemoteLoginItem.openLoginItemsSettings() }
                    }
                }
                if let loginItemError { Text(loginItemError).font(.caption).foregroundStyle(.secondary) }
                Toggle("Keep this Mac awake while the remote is on", isOn: Binding(get: { store.keepAwake }, set: { store.keepAwake = $0; server.apply() }))
                Toggle("Wake for network access", isOn: Binding(get: { store.wakeForNetwork }, set: setWakeForNetwork))
                    .disabled(wakeBusy)
                if let wakeError { Text(wakeError).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Mac without a screen")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("For a Mac mini by the hi-fi. A Mac needs someone logged in to play, so turn on automatic login in System Settings › Users & Groups too (macOS allows it only with FileVault off).")
                    Text("Keeping the Mac awake stops it sleeping while paused; the display can still sleep. Wake for network access asks for an administrator’s password, and lets a phone wake the Mac when an Apple TV or HomePod is on the same network. Turning it off here puts back the setting it had before.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairing, onDismiss: { server.endPairing() }) {
            RemotePairingSheet(server: server) { showPairing = false }
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { server.remove(removing.id) }
                removing = nil
            }
        } message: {
            Text("It won’t be able to control this Mac until you pair it again.")
        }
        .onAppear {
            loginItemOn = RemoteLoginItem.isEnabled
            loginItemNeedsApproval = RemoteLoginItem.needsApproval
        }
    }

    private var removeTitle: String {
        removing.map { String(localized: "Remove “\($0.name)”?", comment: "Settings › Remote: confirm removing a paired phone; %@ is its name.") } ?? ""
    }

    private var statusLine: String {
        switch server.status {
        case .off, .starting: String(localized: "Starting…")
        case .running:
            server.connected.isEmpty
                ? String(localized: "On. Phones on this network see this Mac as “\(RemoteServer.computerName)”.", comment: "Settings › Remote: %@ is the Mac's name.")
                : String(localized: "On. Phones connected: \(server.connected.count)", comment: "Settings › Remote: how many paired phones are connected now.")
        case .failed(let reason): String(localized: "The remote couldn’t start: \(reason)", comment: "Settings › Remote: %@ is macOS's reason.")
        }
    }

    private func detail(_ device: PairedRemote) -> String {
        if server.connected.contains(device.id) { return String(localized: "Connected", comment: "Settings › Remote: a paired phone is connected now.") }
        guard let seen = device.lastSeen else { return String(localized: "Not connected yet", comment: "Settings › Remote: a paired phone hasn't connected since pairing.") }
        return String(localized: "Last connected \(seen.formatted(.relative(presentation: .named)))", comment: "Settings › Remote: %@ is a relative time, e.g. “2 hours ago”.")
    }

    private func setLoginItem(_ on: Bool) {
        loginItemError = RemoteLoginItem.set(on)
        loginItemOn = RemoteLoginItem.isEnabled
        loginItemNeedsApproval = RemoteLoginItem.needsApproval
    }

    private func setWakeForNetwork(_ on: Bool) {
        wakeBusy = true
        wakeError = nil
        Task {
            defer { wakeBusy = false }
            if on {
                let before = await RemoteWakeForNetwork.current()
                guard await RemoteWakeForNetwork.set(true) else {
                    wakeError = String(localized: "Wake for network access wasn’t changed.", comment: "Settings › Remote: the administrator prompt was cancelled or refused.")
                    return
                }
                store.wakeForNetworkBefore = before
                store.wakeForNetwork = true
            } else {
                // Put back what it was before Vespertine turned it on (on stays on if it was already on).
                if store.wakeForNetworkBefore != true {
                    guard await RemoteWakeForNetwork.set(false) else {
                        wakeError = String(localized: "Wake for network access wasn’t changed.", comment: "Settings › Remote: the administrator prompt was cancelled or refused.")
                        return
                    }
                }
                store.wakeForNetworkBefore = nil
                store.wakeForNetwork = false
            }
        }
    }
}

/// The pairing sheet: the QR code for the phone's camera, the code to type instead, and how long they're good for.
struct RemotePairingSheet: View {
    let server: RemoteServer
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let paired = server.justPaired, server.pairing == nil {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("Paired with “\(paired)”", comment: "Pairing sheet: %@ is the phone's name.").font(.title3)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            } else if let pairing = server.pairing {
                Text("Pair a Phone").font(.title3)
                Text("In the Vespertine Remote app, scan this code, or choose this Mac and type the code under it.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let image = Self.qrImage(pairing.link.url.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .accessibilityLabel(Text("Pairing QR code"))
                }
                Text(Self.spaced(pairing.code)).font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .accessibilityLabel(Text("Pairing code \(pairing.code)"))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(pairing.expires.timeIntervalSince(context.date)))
                    Text("Good for \(left / 60):\(String(format: "%02d", left % 60))", comment: "Pairing sheet: minutes and seconds the code stays valid.")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
            } else {
                Text("Pairing has ended.").font(.title3)
                HStack {
                    Button("Close", action: done).keyboardShortcut(.cancelAction)
                    Button("Start Again") { server.beginPairing() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    /// "123 456"
    static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
