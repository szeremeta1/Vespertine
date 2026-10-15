//
// Vespertine — room correction in an output's settings: import filters measured in REW (or another tool), turn them
// on and off, export them, and choose what happens to DSD.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VespertineAudio

/// Room correction for one output, in the output's settings.
struct RoomCorrectionChoice: View {
    @Environment(AppModel.self) private var model
    let device: OutputDevice
    @State private var importing = false
    /// The speaker an import is for: nil, every speaker in the file; 0, left only; 1, right only.
    @State private var importSpeaker: Int?
    @State private var problem: String?

    var body: some View {
        let settings = model.settings
        let profile = settings.roomProfiles[device.uid]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Room correction").font(Typeface.ui(12))
                    Text(profile.map(summary) ?? String(localized: "Filters for each speaker, measured in REW or another tool. Changes the sound, so this output isn't bit-perfect while it's on."))
                        .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if profile != nil {
                    Toggle("Room correction", isOn: Binding(get: { settings.roomProfiles[device.uid]?.enabled == true },
                                                            set: { on in settings.roomProfiles[device.uid]?.enabled = on; model.syncEngine() }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Menu {
                    Button("Import Filters for All Speakers…") { importSpeaker = nil; importing = true }
                    Button("Import Filters for the Left Speaker…") { importSpeaker = 0; importing = true }
                    Button("Import Filters for the Right Speaker…") { importSpeaker = 1; importing = true }
                    if profile != nil {
                        Divider()
                        Button("Export…") { export() }
                        Button("Remove", role: .destructive) {
                            settings.roomProfiles[device.uid] = nil
                            model.syncEngine()
                        }
                    }
                } label: {
                    Text(profile == nil ? String(localized: "Import…") : String(localized: "Filters", comment: "Menu of room correction filter actions"))
                }
                .fixedSize()
                .controlSize(.small)
            }
            if profile != nil, device.capabilities.supportsDoP {
                Toggle(isOn: Binding(get: { settings.roomNativeDSDUIDs.contains(device.uid) },
                                     set: { keep in
                                         if keep { settings.roomNativeDSDUIDs.insert(device.uid) } else { settings.roomNativeDSDUIDs.remove(device.uid) }
                                         model.syncEngine()
                                     })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep native DSD").font(Typeface.ui(12))
                        Text("On: DSD goes to the DAC untouched, without room correction. Off: DSD is converted to PCM so it's corrected too.")
                            .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.mini)
            }
        }
        .font(Typeface.ui(12))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { result in
            if case .success(let url) = result { importFile(url, speaker: importSpeaker) }
        }
        .alert("Couldn't import the file", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    /// "L: 8 filters, 1.20 ms · R: 7 filters" for the speakers that have any correction.
    private func summary(_ profile: RoomProfile) -> String {
        let names = [String(localized: "L", comment: "Left speaker, abbreviated"), String(localized: "R", comment: "Right speaker, abbreviated")]
        let parts = profile.channels.enumerated().compactMap { c, channel -> String? in
            guard channel.isActive else { return nil }
            var bits = [String(localized: "\(channel.bands.count) filters")]
            if channel.delayMs > 0 { bits.append(String(localized: "\(channel.delayMs.formatted(.number.precision(.fractionLength(2)))) ms")) }
            if channel.levelDB != 0 { bits.append("\(channel.levelDB.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) dB") }
            return "\(c < names.count ? names[c] : String(c + 1)): " + bits.joined(separator: ", ")
        }
        return profile.name + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · "))
    }

    private func importFile(_ url: URL, speaker: Int?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try RoomProfile.parseAPO(text, name: url.deletingPathExtension().lastPathComponent)
            let settings = model.settings
            if let speaker {
                // One speaker's filters (REW writes a file per speaker): they replace that speaker's, the others stay.
                var profile = settings.roomProfiles[device.uid] ?? RoomProfile(name: device.name)
                while profile.channels.count <= speaker { profile.channels.append(RoomChannelCorrection()) }
                var channel = parsed.channels[0]
                channel.levelDB += parsed.preampDB
                profile.channels[speaker] = channel
                settings.roomProfiles[device.uid] = profile
            } else {
                settings.roomProfiles[device.uid] = parsed
            }
            model.syncEngine()
        } catch {
            problem = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func export() {
        guard let profile = model.settings.roomProfiles[device.uid] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name) room correction.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try profile.apoText.write(to: url, atomically: true, encoding: .utf8) }
        catch { problem = error.localizedDescription }
    }
}
