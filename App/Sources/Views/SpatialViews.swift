//
// Vespertine — exporting multichannel music for Spatial Audio listening elsewhere.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import VespertineAudio
import VespertineLibrary
import SwiftUI

struct SpatialExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]

    @State private var kind: MultichannelExport.Kind = .spatialStereo
    @State private var folder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vespertine Spatial", isDirectory: true)
    @State private var running = false
    @State private var current = 0
    @State private var fraction = 0.0
    @State private var result: SpatialExporter.Result?

    private var eligible: [Track] { tracks.filter { $0.isMultichannel && $0.isLossless && !$0.isDSD } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "airpods.max").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.brass).frame(width: 34)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Export for Spatial Audio").font(Typeface.serif(24)).foregroundStyle(Palette.text)
                    Text("\(eligible.count) multichannel track\(eligible.count == 1 ? "" : "s")\(tracks.count > eligible.count ? " (stereo tracks are skipped)" : ""). Your originals aren't changed.")
                        .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                }
            }
            .padding([.horizontal, .top], 22).padding(.bottom, 16)
            Hairline()
            Form {
                Picker("Format", selection: $kind) {
                    Text("Spatial stereo (binaural)").tag(MultichannelExport.Kind.spatialStereo)
                    Text("Multichannel lossless").tag(MultichannelExport.Kind.multichannelALAC)
                }
                .pickerStyle(.radioGroup)
                Text(kind == .spatialStereo
                     ? "Rendered with Apple's spatial audio renderer (your personalized profile, if set up) into 24-bit ALAC. Sounds spatial on any AirPods or headphones, on any device or player. Head tracking needs live playback, so the virtual speakers stay in front of you."
                     : "Every channel, losslessly, as 24-bit ALAC (.m4a) with its speaker layout, for Apple devices and players that render surround or spatialize it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Save to") {
                    HStack {
                        Text((folder.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).disabled(running)
            Hairline()
            HStack(spacing: 10) {
                if running {
                    ProgressView(value: (Double(current) + fraction) / Double(max(1, eligible.count))).frame(width: 180).tint(Palette.brass)
                    Text("\(min(current + 1, eligible.count)) of \(eligible.count)").font(Typeface.mono(11)).foregroundStyle(Palette.text3)
                } else if let result {
                    Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.failures.isEmpty ? Palette.brass : Palette.copper)
                    Text("\(result.written.count) exported\(result.failures.isEmpty ? "" : ", \(result.failures.count) failed: \(result.failures[0].message)")")
                        .font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineLimit(2)
                }
                Spacer()
                if let result, !result.written.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(result.written) }.buttonStyle(QuietButtonStyle())
                }
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(QuietButtonStyle()).disabled(running)
                if result == nil {
                    Button("Export", action: export).buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
                        .disabled(running || eligible.isEmpty)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 560)
        .background(Palette.panel)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func export() {
        running = true
        let tracks = eligible, kind = kind, folder = folder, artwork = model.library.artwork
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                SpatialExporter.export(tracks, kind: kind, to: folder, artwork: artwork) { index, f in
                    Task { @MainActor in current = index; fraction = f }
                }
            }.value
            result = r
            running = false
        }
    }
}
