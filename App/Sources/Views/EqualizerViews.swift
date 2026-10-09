//
// Vespertine — the parametric equalizer: presets, the band editor and the response curve.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VespertineAudio

/// The preset an output plays with, in the output's settings.
struct EqualizerChoice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let device: OutputDevice

    var body: some View {
        let settings = model.settings
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Equalizer").font(Typeface.ui(12))
                Text("Changes the sound, so this output isn't bit-perfect while one is on.")
                    .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("Equalizer", selection: Binding(get: { settings.eqPreset(for: device.uid)?.id },
                                                   set: { settings.setEQPreset($0, for: device.uid); model.syncEngine() })) {
                Text("Off").tag(UUID?.none)
                if !settings.eqPresets.isEmpty { Divider() }
                ForEach(settings.eqPresets) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            Button("Edit…") { openWindow(id: "equalizer") }
                .controlSize(.small)
        }
        .font(Typeface.ui(12))
    }
}

struct EqualizerWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var importing = false
    @State private var problem: String?

    var body: some View {
        let settings = model.settings
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.eqPresets) { preset in
                        HStack {
                            Text(preset.name).lineLimit(1)
                            Spacer()
                            if let device = model.activeDevice, settings.eqPreset(for: device.uid)?.id == preset.id {
                                Image(systemName: "hifispeaker.fill").font(.system(size: 10)).foregroundStyle(Palette.brass)
                                    .accessibilityLabel("Playing on \(device.name)")
                            }
                        }
                        .tag(preset.id)
                    }
                }
                .listStyle(.sidebar)
                Hairline()
                HStack(spacing: 6) {
                    Button { add(EQPreset(name: "New Preset", bands: [EQBand()])) } label: { Image(systemName: "plus") }
                        .help("New preset").accessibilityLabel("New preset")
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                        .help("Import an AutoEQ or Equalizer APO file").accessibilityLabel("Import")
                    Menu {
                        Button("Duplicate") { duplicate() }
                        Button("Export…") { export() }
                        Divider()
                        Button("Delete", role: .destructive) { delete() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(selection == nil)
                        .accessibilityLabel("More")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 220)
            .background(Palette.sidebar)
            Divider()
            Group {
                if let id = selection, settings.eqPresets.contains(where: { $0.id == id }) {
                    EqualizerEditor(preset: binding(id))
                } else {
                    EqualizerIntro(importing: $importing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.window)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { if selection == nil { selection = model.activeDevice.flatMap { settings.eqPreset(for: $0.uid)?.id } ?? settings.eqPresets.first?.id } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .alert("Couldn't import the file", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func binding(_ id: UUID) -> Binding<EQPreset> {
        let settings = model.settings
        return Binding(
            get: { settings.eqPresets.first { $0.id == id } ?? EQPreset(id: id, name: "") },
            set: { new in
                guard let index = settings.eqPresets.firstIndex(where: { $0.id == id }) else { return }
                settings.eqPresets[index] = new
                model.syncEngine()
            })
    }

    private func add(_ preset: EQPreset) {
        model.settings.eqPresets.append(preset)
        selection = preset.id
    }

    private func duplicate() {
        guard let id = selection, let preset = model.settings.eqPresets.first(where: { $0.id == id }) else { return }
        add(EQPreset(name: "\(preset.name) Copy", preampDB: preset.preampDB, bands: preset.bands.map { var b = $0; b.id = UUID(); return b }))
    }

    private func delete() {
        let settings = model.settings
        guard let id = selection else { return }
        settings.eqPresets.removeAll { $0.id == id }
        settings.eqAssignments = settings.eqAssignments.filter { $0.value != id.uuidString }
        selection = settings.eqPresets.first?.id
        model.syncEngine()
    }

    private func export() {
        guard let id = selection, let preset = model.settings.eqPresets.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(preset.name) ParametricEQ.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try preset.apoText.write(to: url, atomically: true, encoding: .utf8) }
        catch { problem = error.localizedDescription }
    }

    private func importFiles(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var name = url.deletingPathExtension().lastPathComponent
            // AutoEQ names its files "<Headphones> ParametricEQ.txt".
            for suffix in [" ParametricEQ", " ParametricEq", "ParametricEQ"] where name.hasSuffix(suffix) && name.count > suffix.count {
                name = String(name.dropLast(suffix.count))
                break
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                add(try EQPreset.parse(text, name: name))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { problem = failures.joined(separator: "\n\n") }
    }
}

/// What the window shows before there's a preset.
private struct EqualizerIntro: View {
    @Binding var importing: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "slider.vertical.3").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.brass)
            Text("Parametric Equalizer").font(Typeface.serif(24)).foregroundStyle(Palette.text)
            Text("Import a headphone correction from AutoEQ (its \u{201C}ParametricEQ.txt\u{201D} file) or an Equalizer APO configuration, or make a preset with the + button. Then choose it for an output in the output menu, or below.")
                .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Import…") { importing = true }
            Link("Find your headphones on AutoEQ", destination: URL(string: "https://autoeq.app")!)
                .font(Typeface.ui(12))
        }
        .padding(30)
    }
}

struct EqualizerEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var preset: EQPreset

    private var sampleRate: Double {
        let rate = model.player.signalPath?.applied.sampleRate ?? 48_000
        return rate > 0 ? rate : 48_000
    }

    var body: some View {
        let peak = preset.peakDB(sampleRate: sampleRate)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Name", text: $preset.name)
                        .textFieldStyle(.plain)
                        .font(Typeface.serif(24)).foregroundStyle(Palette.text)
                    Spacer()
                    if let device = model.activeDevice {
                        Toggle("Use on \(device.name)", isOn: Binding(
                            get: { model.settings.eqPreset(for: device.uid)?.id == preset.id },
                            set: { model.settings.setEQPreset($0 ? preset.id : nil, for: device.uid); model.syncEngine() }))
                            .toggleStyle(.switch).controlSize(.small)
                    }
                }
                EQResponseView(preset: preset, sampleRate: sampleRate)
                    .frame(height: 200)
                HStack(spacing: 12) {
                    Text("Preamp").font(Typeface.ui(12.5)).foregroundStyle(Palette.text)
                    Slider(value: $preset.preampDB, in: EQPreset.preampRange, step: 0.1) { Text("Preamp") }
                        .labelsHidden()
                        .accessibilityValue(String(format: "%+.1f decibels", preset.preampDB))
                    Text(String(format: "%+.1f dB", preset.preampDB)).font(Typeface.mono(11.5)).foregroundStyle(Palette.text2).frame(width: 64, alignment: .trailing)
                }
                if peak > 0.05 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.copper)
                        Text(String(format: "The curve peaks at +%.1f dB, so loud passages can clip.", peak))
                            .font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                        Button(String(format: "Set Preamp to %.1f dB", preset.preampForNoClipping(sampleRate: sampleRate))) {
                            preset.preampDB = preset.preampForNoClipping(sampleRate: sampleRate)
                        }
                        .controlSize(.small)
                    }
                    .accessibilityElement(children: .combine)
                }
                Hairline()
                bands
                Text("While an equalizer is on, the samples are changed (in 64-bit, then dithered to the DAC's word length), so the signal path no longer says BIT-PERFECT. It doesn't apply to DSD sent as DoP, to Dolby and DTS sent to a receiver, or to Dolby Atmos that macOS renders.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
    }

    private var bands: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Bands")
                Spacer()
                Button("Add Band") { preset.bands.append(EQBand()) }
                    .controlSize(.small)
                    .disabled(preset.bands.count >= EQPreset.maxBands)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("On"); Text("Type"); Text("Frequency"); Text("Gain"); Text("Q"); Text("")
                }
                .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3)
                ForEach($preset.bands) { $band in
                    GridRow {
                        Toggle("Band on", isOn: $band.enabled).labelsHidden().toggleStyle(.checkbox)
                        Picker("Type", selection: $band.kind) {
                            ForEach(EQBand.Kind.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                        unitField("Frequency", value: $band.frequency, unit: "Hz", digits: 0)
                        unitField("Gain", value: $band.gainDB, unit: "dB", digits: 1)
                            .disabled(!band.kind.hasGain)
                        unitField("Q", value: $band.q, unit: "", digits: 2)
                        Button { preset.bands.removeAll { $0.id == band.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove band").accessibilityLabel("Remove band")
                    }
                    .opacity(band.enabled ? 1 : 0.5)
                }
            }
        }
    }

    private func unitField(_ label: String, value: Binding<Double>, unit: String, digits: Int) -> some View {
        HStack(spacing: 4) {
            TextField(label, value: value, format: .number.precision(.fractionLength(0...digits)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .accessibilityLabel(label)
            if !unit.isEmpty { Text(unit).font(Typeface.ui(11)).foregroundStyle(Palette.text3) }
        }
    }
}

/// The preset's frequency response, 20 Hz to 20 kHz on a log scale.
struct EQResponseView: View {
    let preset: EQPreset
    let sampleRate: Double

    private static let frequencies = (0...300).map { 20 * pow(1000, Double($0) / 300) }

    var body: some View {
        let response = preset.responseDB(at: Self.frequencies, sampleRate: sampleRate)
        let range = max(12, ((response.map(abs).max() ?? 0) / 6).rounded(.up) * 6)
        Canvas { context, size in
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / 20) / 3) * size.width }
            func y(_ db: Double) -> CGFloat { CGFloat(0.5 - db / (2 * range)) * size.height }
            var grid = Path()
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10_000] { grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: size.height)) }
            for db in stride(from: -range, through: range, by: 6) { grid.move(to: CGPoint(x: 0, y: y(db))); grid.addLine(to: CGPoint(x: size.width, y: y(db))) }
            context.stroke(grid, with: .color(Palette.hairline), lineWidth: 1)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            context.stroke(zero, with: .color(Palette.hairlineStrong), lineWidth: 1)
            var curve = Path()
            for (i, f) in Self.frequencies.enumerated() {
                let point = CGPoint(x: x(f), y: y(response[i]))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(Palette.brass), lineWidth: 2)
            for (f, label) in [(100.0, "100"), (1000.0, "1k"), (10_000.0, "10k")] {
                context.draw(Text(label).font(Typeface.mono(9.5)).foregroundColor(Palette.text3), at: CGPoint(x: x(f) + 3, y: size.height - 8), anchor: .leading)
            }
            context.draw(Text(String(format: "+%.0f dB", range)).font(Typeface.mono(9.5)).foregroundColor(Palette.text3), at: CGPoint(x: 4, y: 8), anchor: .leading)
            context.draw(Text(String(format: "−%.0f dB", range)).font(Typeface.mono(9.5)).foregroundColor(Palette.text3), at: CGPoint(x: 4, y: size.height - 8), anchor: .leading)
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .accessibilityElement()
        .accessibilityLabel("Frequency response")
        .accessibilityValue(summary(response))
    }

    private func summary(_ response: [Double]) -> String {
        guard let hi = response.indices.max(by: { response[$0] < response[$1] }),
              let lo = response.indices.min(by: { response[$0] < response[$1] }) else { return "flat" }
        func hz(_ f: Double) -> String { f >= 1000 ? String(format: "%.1f kilohertz", f / 1000) : String(format: "%.0f hertz", f) }
        return String(format: "Highest %+.1f decibels at %@, lowest %+.1f decibels at %@",
                      response[hi], hz(Self.frequencies[hi]), response[lo], hz(Self.frequencies[lo]))
    }
}
