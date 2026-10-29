//
// Vespertine — Room Correction: one window for everything. The output and its on/off switch, the profiles (measured
// here or imported from REW, Equalizer APO or impulse-response files), a before/after graph that morphs from the
// measurement to the predicted result, the target and range, each speaker's delay, level and filters, and the
// measurement wizard with its Room Portrait.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VespertineAudio

extension RoomSpeaker {
    var displayName: String {
        switch self {
        case .left: String(localized: "Left", comment: "Room correction speaker.")
        case .right: String(localized: "Right", comment: "Room correction speaker.")
        case .center: String(localized: "Centre", comment: "Room correction speaker.")
        case .lfe: String(localized: "LFE", comment: "Room correction speaker: the subwoofer channel.")
        case .leftSurround: String(localized: "Left surround", comment: "Room correction speaker.")
        case .rightSurround: String(localized: "Right surround", comment: "Room correction speaker.")
        }
    }

    /// Short label for the Room Portrait.
    var badge: String {
        switch self {
        case .left: "L"
        case .right: "R"
        case .center: "C"
        case .lfe: "LFE"
        case .leftSurround: "Ls"
        case .rightSurround: "Rs"
        }
    }

    var colour: Color {
        switch self {
        case .left: Color(red: 0.55, green: 0.78, blue: 1)
        case .right: Color(red: 1, green: 0.62, blue: 0.5)
        case .center: Color(red: 0.78, green: 0.9, blue: 0.6)
        case .lfe: Color(red: 0.85, green: 0.7, blue: 1)
        case .leftSurround: Color(red: 0.5, green: 0.9, blue: 0.85)
        case .rightSurround: Color(red: 1, green: 0.82, blue: 0.45)
        }
    }
}

/// Room correction for an output, in the output's settings (beside the equalizer).
struct RoomCorrectionChoice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let device: OutputDevice

    var body: some View {
        let settings = model.settings
        let profiles = settings.roomProfiles(for: device.uid)
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Room Correction").font(Typeface.ui(12))
                Text(profiles.isEmpty ? "Measure with a UMIK-1 or import REW filters to correct your room."
                                      : "Changes the sound, so this output isn't bit-perfect while it's on.")
                    .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if profiles.isEmpty {
                    Spacer()
                } else {
                    Picker("Room Correction", selection: Binding(get: { settings.roomProfile(for: device.uid)?.id },
                                                                 set: { settings.setRoomProfile($0, for: device.uid); model.syncEngine() })) {
                        Text("Off", comment: "Room correction choice: none").tag(UUID?.none)
                        Divider()
                        ForEach(profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(profiles.isEmpty ? "Set Up…" : "Edit…") { openWindow(id: "room-correction") }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .font(Typeface.ui(12))
    }
}

// MARK: - The window

struct RoomCorrectionWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(RoomMeasureModel.self) private var measure
    @State private var selection: UUID?
    @State private var showWizard = false
    @State private var redesigning = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var importing: RoomImportKind?
    @State private var showAfter = true

    var body: some View {
        let settings = model.settings
        let device = model.activeDevice
        let profiles = device.map { settings.roomProfiles(for: $0.uid) } ?? []
        let selected = profiles.first { $0.id == selection } ?? device.flatMap { settings.roomProfile(for: $0.uid) } ?? profiles.first
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let device {
                    outputCard(device, profiles: profiles, selected: selected)
                    actions(device, selected: selected)
                } else {
                    Text("No output is connected.").font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                }
                if let problem { message(problem, symbol: "exclamationmark.triangle.fill", colour: Palette.copper) }
                if let notice { message(notice, symbol: "checkmark.circle.fill", colour: Palette.brass) }
                if let selected {
                    profileSection(selected, profiles: profiles)
                } else if device != nil {
                    emptyState
                }
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 680)
        .background(Palette.window)
        .sheet(isPresented: $showWizard) {
            RoomMeasureWizard(device: device) { profile, turnOn in
                settings.saveRoomProfile(profile)
                if turnOn { settings.setRoomProfile(profile.id, for: profile.deviceUID) }
                selection = profile.id
                model.syncEngine()
                showWizard = false
            } close: { showWizard = false }
            .environment(measure)
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing?.types ?? [.json], allowsMultipleSelection: importing == .impulseResponses) { result in
            let kind = importing ?? .profile
            importing = nil
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            importFiles(urls, kind: kind, device: device)
        }
        .onAppear {
            let player = model.player
            measure.pausePlayback = { player.pause() }
            if measure.launch != nil || LaunchArguments().string(forKey: "VespertineOpenSheet") == "room-measure" { showWizard = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Room Correction").font(Typeface.serif(28)).foregroundStyle(Palette.text)
            Text("Lines your speakers up at your seat and tames the room's bass, per speaker. Off unless you turn it on; while it's on, playback isn't bit-perfect.")
                .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No room correction for this output yet.").font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
            Text("Measure: a UMIK-1 microphone and its calibration file. Quiet sweeps play through each speaker at five spots around your seat.")
                .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            Text("Import: filters from REW or another tool, as Equalizer APO text or impulse responses (WAV, AIFF, CAF, FLAC).")
                .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func message(_ text: String, symbol: String, colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(colour).accessibilityHidden(true)
            Text(text).font(Typeface.ui(12)).foregroundStyle(colour).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Output

    private func outputCard(_ device: OutputDevice, profiles: [RoomProfile], selected: RoomProfile?) -> some View {
        let settings = model.settings
        let on = settings.roomProfile(for: device.uid) != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(Typeface.ui(15, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(statusLine(profiles: profiles, on: on)).font(Typeface.ui(11.5)).foregroundStyle(on ? Palette.brass : Palette.text3)
                }
                Spacer()
                Toggle("Room correction", isOn: Binding(get: { on }, set: { new in
                    settings.setRoomProfile(new ? (selected ?? profiles.first)?.id : nil, for: device.uid)
                    model.syncEngine()
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(profiles.isEmpty)
                .accessibilityLabel("Room correction")
                .accessibilityHint("Turns room correction on or off for this output")
            }
            notes(device, on: on)
            if device.capabilities.supportsDoP, !profiles.isEmpty { dsdChoice(device, on: on) }
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Palette.brassLo : Palette.hairline))
    }

    private func statusLine(profiles: [RoomProfile], on: Bool) -> String {
        if profiles.isEmpty { return String(localized: "Not set up") }
        return on ? String(localized: "On") : String(localized: "Off")
    }

    @ViewBuilder
    private func notes(_ device: OutputDevice, on: Bool) -> some View {
        let path = model.player.signalPath
        if on, let path, path.deviceUID == device.uid {
            if path.roomCorrection != nil {
                note("waveform.path.ecg", String(localized: "In the signal now: the status reads ROOM CORRECTION."))
                if path.roomFiltersSkipped {
                    note("info.circle", String(localized: "A measured filter is too long to run at this sample rate, so it's left out."))
                }
            } else if path.bypassedRoomCorrection != nil {
                note("info.circle", path.equalizerBypass.map { String(localized: "Not applied: \($0.explanation)") }
                     ?? String(localized: "Not applied: this stream's channels don't match the speakers the profile was made for."))
            }
        }
        if on, model.settings.integerMode {
            note("info.circle", String(localized: "Integer mode can't apply filters: while room correction is on, music plays on the float path."))
        }
    }

    private func dsdChoice(_ device: OutputDevice, on: Bool) -> some View {
        let settings = model.settings
        let keep = settings.roomNativeDSDDeviceUIDs.contains(device.uid)
        return VStack(alignment: .leading, spacing: 3) {
            Toggle("Keep native DSD", isOn: Binding(get: { keep }, set: { new in
                if new { settings.roomNativeDSDDeviceUIDs.insert(device.uid) } else { settings.roomNativeDSDDeviceUIDs.remove(device.uid) }
                model.syncEngine()
            }))
            .toggleStyle(.checkbox)
            .font(Typeface.ui(12))
            Text(keep ? "DSD goes out natively over DoP, uncorrected." : "While room correction is on, DSD is converted to PCM so it's corrected too.")
                .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Palette.text3).accessibilityHidden(true)
            Text(text).font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func actions(_ device: OutputDevice, selected: RoomProfile?) -> some View {
        HStack(spacing: 10) {
            Button { showWizard = true } label: {
                Label(selected == nil ? "Measure…" : "Measure Again…", systemImage: "mic")
            }
            .keyboardShortcut(.defaultAction)
            Menu {
                Button("Equalizer APO or REW Filters…") { importing = .equalizerAPO }
                Button("Impulse Responses…") { importing = .impulseResponses }
                Divider()
                Button("Vespertine Room Profile…") { importing = .profile }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .fixedSize()
            .help("Bring in filters made with REW or another measurement tool")
            if let selected {
                Menu {
                    Button("Equalizer APO Text…") { export(selected, asAPO: true) }
                    Button("Vespertine Room Profile…") { export(selected, asAPO: false) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
            }
            Spacer()
            if let selected {
                Button("Delete Profile", role: .destructive) {
                    model.settings.deleteRoomProfile(selected.id)
                    selection = nil
                    model.syncEngine()
                }
            }
        }
    }

    private func importFiles(_ urls: [URL], kind: RoomImportKind, device: OutputDevice?) {
        problem = nil
        notice = nil
        let access = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, ok) in zip(urls, access) where ok { url.stopAccessingSecurityScopedResource() } }
        guard let device else { return }
        let name = urls[0].deletingPathExtension().lastPathComponent
        do {
            let profile: RoomProfile
            switch kind {
            case .equalizerAPO:
                let text = try String(contentsOf: urls[0], encoding: .utf8)
                profile = try RoomAPO.profile(text, name: name, deviceUID: device.uid)
            case .impulseResponses:
                profile = try RoomImpulseImport.profile(files: urls, name: name, deviceUID: device.uid)
            case .profile:
                profile = try RoomCorrectionCoding.decodeProfile(try Data(contentsOf: urls[0]))
            }
            model.settings.saveRoomProfile(profile)
            selection = profile.id
            if profile.deviceUID != device.uid {
                notice = String(localized: "Imported. It was measured on another output, so it only appears (and plays) when that output is selected.")
            } else {
                notice = String(localized: "Imported “\(profile.name)”. Turn room correction on to hear it.")
            }
        } catch {
            problem = String(localized: "That file couldn't be imported: \(error.localizedDescription)")
        }
    }

    private func export(_ profile: RoomProfile, asAPO: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = profile.name.replacingOccurrences(of: "/", with: "-") + (asAPO ? ".txt" : ".json")
        panel.allowedContentTypes = asAPO ? [.plainText] : [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = asAPO ? Data(RoomAPO.text(profile).utf8) : try RoomCorrectionCoding.encode(profile)
            try data.write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Profile

    @ViewBuilder
    private func profileSection(_ profile: RoomProfile, profiles: [RoomProfile]) -> some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                if profiles.count > 1 {
                    Picker("Profile", selection: Binding(get: { profile.id }, set: { id in
                        selection = id
                        if settings.roomProfile(for: profile.deviceUID) != nil { settings.setRoomProfile(id, for: profile.deviceUID); model.syncEngine() }
                    })) {
                        ForEach(profiles) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                } else {
                    Text(profile.name).font(Typeface.ui(15, weight: .semibold)).foregroundStyle(Palette.text)
                }
                Spacer()
            }
            Text(summary(profile)).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
            graph(profile)
            if let options = profile.designOptions, profile.measured != nil {
                designPickers(profile, options: options)
            }
            RoomSpeakerTable(profile: profile)
        }
    }

    private func summary(_ profile: RoomProfile) -> String {
        let date = profile.createdAt.formatted(date: .abbreviated, time: .shortened)
        let preamp = profile.filters.preampDB.formatted(.number.precision(.fractionLength(1)))
        switch profile.origin {
        case .measured: return String(localized: "Microphone \(profile.micSerial) · measured \(date) · preamp \(preamp) dB")
        case .equalizerAPO: return String(localized: "Imported from Equalizer APO or REW · \(date) · preamp \(preamp) dB")
        case .impulseResponse: return String(localized: "Impulse responses (convolution) · imported \(date)")
        }
    }

    @ViewBuilder
    private func graph(_ profile: RoomProfile) -> some View {
        if let preview = RoomCorrectionPreview(profile: profile) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Graph", selection: $showAfter.animation(.easeInOut(duration: 1.2))) {
                    Text("Before").tag(false)
                    Text("After (predicted)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                RoomCurvesView(preview: preview, reveal: showAfter ? 1 : 0).frame(height: 300)
                Text("Thin: measured. Bold: predicted after correction (calculated, not measured). Dashed: target. Measure again with correction on to check it in the room.")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                RoomCorrectionCurvesView(profile: profile).frame(height: 240)
                Text("What the imported correction does to each speaker.")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func designPickers(_ profile: RoomProfile, options: RoomFilterDesignOptions) -> some View {
        HStack(spacing: 16) {
            Picker("Target", selection: Binding(get: { options.target }, set: { redesign(profile, target: $0, range: options.range) })) {
                ForEach(RoomTargetCurve.presets) { Text($0.name).tag($0) }
            }
            .fixedSize()
            Picker("Range", selection: Binding(get: { options.isFullRange }, set: {
                redesign(profile, target: options.target, range: $0 ? RoomFilterDesignOptions.fullRange : RoomFilterDesignOptions.defaultRange)
            })) {
                Text("Bass, 20–500 Hz").tag(false)
                Text("Full range").tag(true)
            }
            .fixedSize()
            if redesigning { ProgressView().controlSize(.small) }
        }
        .disabled(redesigning)
    }

    private func redesign(_ profile: RoomProfile, target: RoomTargetCurve, range: ClosedRange<Double>) {
        guard let measured = profile.measured, var chosen = profile.designOptions else { return }
        chosen.target = target
        chosen.range = range
        let options = chosen
        redesigning = true
        problem = nil
        Task {
            do {
                let design = try await Task.detached(priority: .userInitiated) { try RoomFilterDesigner.design(channels: measured, options: options) }.value
                var updated = profile
                updated.filters = design.filterSet
                updated.target = options.target.roomTarget
                updated.designOptions = options
                model.settings.saveRoomProfile(updated)
                model.syncEngine()
            } catch {
                problem = error.localizedDescription
            }
            redesigning = false
        }
    }
}

enum RoomImportKind: Hashable {
    case equalizerAPO, impulseResponses, profile

    var types: [UTType] {
        switch self {
        case .equalizerAPO: [.plainText, .text]
        case .impulseResponses: [.wav, .aiff, .audio]
        case .profile: [.json]
        }
    }
}

// MARK: - Graphs

/// Measured, target and the speakers' response per speaker, 20 Hz to 20 kHz. `reveal` morphs the bold line from the
/// measurement (0) to the predicted result after correction (1), so the change can be watched.
struct RoomCurvesView: View, Animatable {
    let preview: RoomCorrectionPreview
    var reveal: Double

    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    private var range: (top: Double, bottom: Double) {
        let all = preview.channels.flatMap { $0.measuredDB + $0.predictedDB }
        let top: Double = max(10, ((all.max() ?? 10) / 5).rounded(.up) * 5)
        let bottom: Double = min(-20, ((all.min() ?? -20) / 5).rounded(.down) * 5)
        return (top, bottom)
    }

    var body: some View {
        let (top, bottom) = range
        let t = reveal
        Canvas { context, size in
            let plot = RoomPlot(size: size, top: top, bottom: bottom)
            plot.grid(in: &context)
            for channel in preview.channels {
                let colour = channel.speaker.colour
                let shown: [Double] = zip(channel.measuredDB, channel.predictedDB).map { m, p in m + (p - m) * t }
                plot.stroke(channel.targetDB, at: channel.frequencies, in: &context,
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]), colour: colour.opacity(0.55))
                plot.stroke(channel.measuredDB, at: channel.frequencies, in: &context,
                            style: StrokeStyle(lineWidth: 1.1), colour: colour.opacity(0.45 * t))
                plot.stroke(shown, at: channel.frequencies, in: &context, style: StrokeStyle(lineWidth: 2.4), colour: colour)
            }
            plot.legend(preview.channels.map(\.speaker), in: &context)
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .accessibilityElement()
        .accessibilityLabel("Measured and predicted room response")
        .accessibilityValue(preview.channels.map { c in
            let before = c.rmsErrorBeforeDB.formatted(.number.precision(.fractionLength(1)))
            let after = c.rmsErrorAfterDB.formatted(.number.precision(.fractionLength(1)))
            return String(localized: "\(c.speaker.displayName): deviation from target \(before) decibels measured, \(after) predicted")
        }.joined(separator: "; "))
    }
}

/// What an imported profile's correction does, per speaker.
struct RoomCorrectionCurvesView: View {
    let profile: RoomProfile
    @State private var curves: RoomCorrectionCurves?

    var body: some View {
        let drawn = curves   // read here, so the graph redraws when they arrive
        Canvas { context, size in
            guard let curves = drawn else { return }
            let all = curves.channels.flatMap(\.db)
            let top: Double = max(5, ((all.max() ?? 5) / 5).rounded(.up) * 5)
            // Down to −30 dB: a low-pass (an LFE's) falls off the bottom instead of flattening every other curve.
            let bottom: Double = max(-30, min(-20, ((all.min() ?? -20) / 5).rounded(.down) * 5))
            let plot = RoomPlot(size: size, top: top, bottom: bottom)
            plot.grid(in: &context)
            for channel in curves.channels {
                let db = channel.db.map { max($0, bottom - 1) }
                plot.stroke(db, at: channel.frequencies, in: &context, style: StrokeStyle(lineWidth: 2.2), colour: channel.speaker.colour)
            }
            plot.legend(curves.channels.map(\.speaker), in: &context)
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .task(id: profile) {
            let profile = profile
            curves = await Task.detached(priority: .userInitiated) { RoomCorrectionCurves(profile: profile) }.value
        }
        .accessibilityElement()
        .accessibilityLabel("Room correction per speaker")
    }
}

/// Log-frequency axes shared by the room graphs.
private struct RoomPlot {
    let size: CGSize
    let top: Double
    let bottom: Double

    func x(_ f: Double) -> CGFloat { CGFloat(log10(f / 20) / 3) * size.width }
    func y(_ db: Double) -> CGFloat { CGFloat((top - db) / (top - bottom)) * size.height }

    func grid(in context: inout GraphicsContext) {
        var grid = Path()
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10_000] {
            grid.move(to: CGPoint(x: x(f), y: 0))
            grid.addLine(to: CGPoint(x: x(f), y: size.height))
        }
        for db in stride(from: bottom, through: top, by: 5) {
            grid.move(to: CGPoint(x: 0, y: y(db)))
            grid.addLine(to: CGPoint(x: size.width, y: y(db)))
        }
        context.stroke(grid, with: .color(Palette.hairline), lineWidth: 1)
        let labels: [(Double, String)] = [(50, "50"), (100, "100"), (500, "500"), (1000, "1k"), (5000, "5k"), (10_000, "10k")]
        for (f, label) in labels {
            context.draw(Text(verbatim: label).font(Typeface.mono(9.5)).foregroundColor(Palette.text3),
                         at: CGPoint(x: x(f) + 3, y: size.height - 8), anchor: .leading)
        }
        context.draw(Text(verbatim: "+\(Int(top)) dB").font(Typeface.mono(9.5)).foregroundColor(Palette.text3), at: CGPoint(x: 4, y: 8), anchor: .leading)
        context.draw(Text(verbatim: "\(Int(bottom)) dB").font(Typeface.mono(9.5)).foregroundColor(Palette.text3),
                     at: CGPoint(x: 4, y: size.height - 8), anchor: .leading)
    }

    func stroke(_ values: [Double], at frequencies: [Double], in context: inout GraphicsContext, style: StrokeStyle, colour: Color) {
        var p = Path()
        for (i, f) in frequencies.enumerated() where f >= 20 && f <= 20_000 && i < values.count {
            let point = CGPoint(x: x(f), y: y(values[i]))
            if p.isEmpty { p.move(to: point) } else { p.addLine(to: point) }
        }
        context.stroke(p, with: .color(colour), style: style)
    }

    /// Each speaker's name in its colour, top right, on a panel so the curves don't run through it.
    func legend(_ speakers: [RoomSpeaker], in context: inout GraphicsContext) {
        let names = speakers.map { context.resolve(Text($0.displayName).font(Typeface.ui(11, weight: .semibold)).foregroundColor($0.colour)) }
        let width = names.map { $0.measure(in: size).width }.max() ?? 0
        let panel = CGRect(x: size.width - width - 18, y: 4, width: width + 12, height: CGFloat(names.count) * 16 + 6)
        context.fill(Path(roundedRect: panel, cornerRadius: 6), with: .color(Palette.panel.opacity(0.88)))
        for (i, name) in names.enumerated() {
            context.draw(name, at: CGPoint(x: size.width - 12, y: 15 + CGFloat(i) * 16), anchor: .trailing)
        }
    }
}

// MARK: - Speakers

/// Each speaker's delay, level, measured filter and bands.
struct RoomSpeakerTable: View {
    let profile: RoomProfile

    var body: some View {
        let entries = profile.channelMap.entries.sorted { $0.output < $1.output }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 18, alignment: .topLeading)], alignment: .leading, spacing: 16) {
            ForEach(entries, id: \.speaker) { entry in
                column(entry.speaker)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func column(_ speaker: RoomSpeaker) -> some View {
        let bands = profile.filters.channels[speaker] ?? []
        let alignment = profile.alignment(for: speaker)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(speaker.colour).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(speaker.displayName).font(Typeface.ui(12, weight: .semibold)).foregroundStyle(Palette.text)
            }
            if alignment.isActive {
                Text(alignmentLine(alignment)).font(Typeface.mono(11)).foregroundStyle(Palette.brass)
            }
            if let impulse = profile.impulses?[speaker] {
                Text("Filter: \(impulse.name) · \(impulse.frames) taps at \(Int(impulse.sampleRate)) Hz")
                    .font(Typeface.mono(11)).foregroundStyle(Palette.text2)
            }
            if bands.isEmpty, profile.impulses?[speaker] == nil {
                Text("No filters").font(Typeface.mono(11)).foregroundStyle(Palette.text3)
            }
            ForEach(bands) { b in
                Text(bandLine(b)).font(Typeface.mono(11)).foregroundStyle(Palette.text2)
            }
        }
    }

    private func alignmentLine(_ a: RoomSpeakerAlignment) -> String {
        let delay = a.delayMs.formatted(.number.precision(.fractionLength(2)))
        let level = a.levelDB.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))
        return String(localized: "Delay \(delay) ms · level \(level) dB")
    }

    /// A peak as its numbers; shelves and passes named first (passes have no gain).
    private func bandLine(_ b: EQBand) -> String {
        let f = b.frequency.formatted(.number.precision(.fractionLength(1)))
        let g = b.gainDB.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))
        let q = b.q.formatted(.number.precision(.fractionLength(2)))
        let values = b.kind.hasGain ? String(localized: "\(f) Hz  \(g) dB  Q \(q)") : String(localized: "\(f) Hz  Q \(q)")
        return b.kind == .peak ? values : String(localized: "\(b.kind.label) · \(values)")
    }
}

// MARK: - Measurement wizard

/// The measurement, step by step: setup, permission, level, sweeps at each spot (the Room Portrait shows where), and
/// the result revealed as the measurement morphs into the prediction.
struct RoomMeasureWizard: View {
    @Environment(RoomMeasureModel.self) private var model
    let device: OutputDevice?
    let save: (RoomProfile, Bool) -> Void
    let close: () -> Void
    @State private var reveal = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Measure the room").font(Typeface.serif(22)).foregroundStyle(Palette.text)
            stepper
            Hairline()
            switch model.phase {
            case .ready:
                prepare
            case .running, .needsAttention, .waitingForMic, .cancelled, .failed:
                running
            case .finished:
                result
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(22)
        .frame(width: 820, height: 700)
        .background(Palette.window)
        .onAppear {
            model.preferredOutputUID = device?.uid
            model.startIfLaunched()
        }
    }

    private enum Stage: Int, CaseIterable { case setup, allow, level, sweeps, result }

    private var stage: Stage {
        switch model.phase {
        case .ready: .setup
        case .finished: .result
        default: model.steps.contains { if case .sweep = $0.step { $0.status != .pending } else { false } } ? .sweeps
            : model.steps.isEmpty ? .allow : .level
        }
    }

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(Stage.allCases, id: \.self) { s in
                let title: LocalizedStringKey = switch s {
                case .setup: "Set Up"
                case .allow: "Allow"
                case .level: "Level"
                case .sweeps: "Sweeps"
                case .result: "Result"
                }
                Text(title)
                    .font(Typeface.ui(11.5, weight: s == stage ? .semibold : .regular))
                    .foregroundStyle(s.rawValue <= stage.rawValue ? Palette.brassHi : Palette.text3)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(s == stage ? Palette.raised : .clear, in: Capsule())
                    .accessibilityAddTraits(s == stage ? .isSelected : [])
                if s != .result { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.text3).accessibilityHidden(true) }
            }
        }
    }

    private var portrait: some View {
        RoomPortrait(layout: model.layout, positions: model.positions, current: model.currentPosition,
                     measured: model.measuredPositions, active: model.activeSpeaker,
                     moving: model.phase == .waitingForMic, running: model.phase == .running)
    }

    private var prepare: some View {
        @Bindable var model = model
        let surroundPossible = (device?.capabilities.outputChannels ?? 2) >= RoomLayout.surround51.speakers.count
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                portrait.frame(width: 300, height: 300)
                Picker("Speakers", selection: $model.layout) {
                    Text("Stereo").tag(RoomLayout.stereo)
                    Text("5.1 surround").tag(RoomLayout.surround51)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                .disabled(!surroundPossible)
                .onAppear { if !surroundPossible { model.layout = .stereo } }
                Stepper("Spots around your seat: \(model.positions)", value: $model.positions, in: 1...RoomMeasureLaunch.maxPositions)
                    .font(Typeface.ui(12))
            }
            VStack(alignment: .leading, spacing: 12) {
                instruction("1", "Place the microphone", "UMIK-1 on a stand at ear height where you sit, pointing straight up (use its 90° calibration file). Keep the room quiet.")
                instruction("2", "Allow the microphone", "macOS asks once whether Vespertine may use the microphone. Choose Allow; it only listens while a measurement runs.")
                instruction("3", "Level", "Music pauses. A quiet test plays first; the sweeps get only as loud as the microphone needs. Keep your amplifier at a comfortable level.")
                instruction("4", "Sweeps", "Each speaker plays a rising tone. Between rounds, move the microphone to the next glowing spot.")
                Text(device.map { String(localized: "Output: \($0.name), at the rate it is set to now.") } ?? String(localized: "Output: the Mac's default output."))
                    .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2)
                HStack {
                    TextField("Calibration file", text: $model.calibrationPath).textFieldStyle(.roundedBorder).font(Typeface.mono(11))
                    Button("Choose…") { model.chooseCalibration() }
                }
                Toggle("Use a simulated room (no microphone, no sound)", isOn: $model.simulate).font(Typeface.ui(12))
            }
        }
    }

    private func instruction(_ n: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(Typeface.mono(12, weight: .semibold)).foregroundStyle(Palette.brass).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typeface.ui(13, weight: .semibold)).foregroundStyle(Palette.text)
                Text(text).font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var running: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 8) {
                portrait.frame(width: 300, height: 300)
                if model.phase == .waitingForMic {
                    Text("Move the microphone to the glowing spot, then continue.")
                        .font(Typeface.ui(12, weight: .semibold)).foregroundStyle(Palette.brassHi)
                        .multilineTextAlignment(.center).frame(width: 300)
                }
            }
            RoomMeasureProgress()
        }
    }

    @ViewBuilder
    private var result: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 10) {
                Text("Measured. Here is what the filters should do.").font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
                if let preview = RoomCorrectionPreview(profile: draft) {
                    RoomCurvesView(preview: preview, reveal: reveal).frame(height: 250)
                        .onAppear { withAnimation(.easeInOut(duration: 2.2).delay(0.4)) { reveal = 1 } }
                }
                Text("Bold lines are predicted, not measured. Target: \(draft.designOptions?.target.name ?? draft.target.name).")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                RoomSpeakerTable(profile: draft)
            }
        } else {
            Text(model.headline).font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
            Text(model.detail).font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            switch model.phase {
            case .ready:
                Button("Start measurement") { model.start() }.keyboardShortcut(.defaultAction)
                Button("Close") { close() }
            case .running:
                Button("Stop") { model.cancel() }.keyboardShortcut(.cancelAction)
            case .needsAttention, .cancelled:
                Button("Try again") { model.retry() }.keyboardShortcut(.defaultAction)
                Button("Close") { model.reset(); close() }
            case .waitingForMic:
                Button("Microphone moved, continue") { model.micMoved() }.keyboardShortcut(.defaultAction)
                Button("Stop") { model.cancel() }
            case .failed:
                Button("Start over") { model.reset() }.keyboardShortcut(.defaultAction)
                Button("Close") { model.reset(); close() }
            case .finished:
                if let draft = model.draft {
                    Button("Save and turn on") { save(draft, true); model.reset() }.keyboardShortcut(.defaultAction)
                    Button("Save") { save(draft, false); model.reset() }
                }
                Button("Discard") { model.reset(); close() }
            }
            Spacer()
            if model.folder != nil { Button("Show files") { model.revealFolder() } }
        }
    }
}

/// The running measurement: headline, issues and each step's state.
struct RoomMeasureProgress: View {
    @Environment(RoomMeasureModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.deviceLines, id: \.self) { Text($0).font(Typeface.ui(11)).foregroundStyle(Palette.text3) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.headline).font(Typeface.ui(15, weight: .semibold)).foregroundStyle(Palette.text)
                if !model.detail.isEmpty { Text(model.detail).font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true) }
                ForEach(model.issues, id: \.self) { Text("• " + $0).font(Typeface.ui(12.5)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true) }
            }
            if model.phase == .running { ProgressView(value: model.recordingProgress).tint(Palette.brass).accessibilityLabel("Recording") }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.steps) { row in
                        HStack(spacing: 8) {
                            Image(systemName: icon(row.status)).foregroundStyle(color(row.status)).frame(width: 18).accessibilityHidden(true)
                            Text(RoomMeasureModel.rowTitle(row.step)).font(Typeface.ui(12.5))
                                .foregroundStyle(row.status == .pending ? Palette.text3 : Palette.text)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(statusLabel(row.status))
                    }
                }
            }
        }
    }

    private func icon(_ s: RoomMeasureModel.StepRow.Status) -> String {
        switch s { case .pending: "circle"; case .active: "waveform"; case .done: "checkmark.circle.fill"; case .problem: "exclamationmark.triangle.fill" }
    }

    private func color(_ s: RoomMeasureModel.StepRow.Status) -> Color {
        switch s { case .pending: Palette.text3; case .active: Palette.brassHi; case .done: Palette.brass; case .problem: Palette.copper }
    }

    private func statusLabel(_ s: RoomMeasureModel.StepRow.Status) -> String {
        switch s {
        case .pending: String(localized: "waiting")
        case .active: String(localized: "in progress")
        case .done: String(localized: "done")
        case .problem: String(localized: "needs a look")
        }
    }
}

// MARK: - Room Portrait

/// A top-down sketch of the room: the speakers, the seat, and the microphone spots around it. Measured spots fill in,
/// the current one glows with the microphone on it, and the speaker playing sends its sound toward the seat.
struct RoomPortrait: View {
    let layout: RoomLayout
    let positions: Int
    let current: Int
    let measured: Set<Int>
    let active: RoomSpeaker?
    let moving: Bool
    let running: Bool

    /// Spots in the order they're measured: the seat, then left, right, in front and behind, about a head's width out.
    static let spots: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)]

    private static func place(_ speaker: RoomSpeaker) -> CGPoint {
        switch speaker {
        case .left: CGPoint(x: 0.22, y: 0.14)
        case .right: CGPoint(x: 0.78, y: 0.14)
        case .center: CGPoint(x: 0.5, y: 0.1)
        case .lfe: CGPoint(x: 0.64, y: 0.09)
        case .leftSurround: CGPoint(x: 0.12, y: 0.62)
        case .rightSurround: CGPoint(x: 0.88, y: 0.62)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(running || moving))) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, phase: phase)
            }
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairlineStrong))
        .accessibilityElement()
        .accessibilityLabel("Room Portrait")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        let spot = current + 1
        return String(localized: "Microphone spot \(spot) of \(positions); \(measured.count) measured")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let w = size.width, h = size.height
        // Walls.
        let room = Path(roundedRect: CGRect(x: 10, y: 10, width: w - 20, height: h - 20), cornerRadius: 10)
        context.stroke(room, with: .color(Palette.hairlineStrong), lineWidth: 1.5)
        let head = CGPoint(x: w * 0.5, y: h * 0.55)
        // Seat, behind the spots.
        let seat = CGRect(x: w * 0.32, y: h * 0.74, width: w * 0.36, height: h * 0.11)
        context.fill(Path(roundedRect: seat, cornerRadius: 8), with: .color(Palette.raised))
        context.draw(Text("Seat").font(Typeface.ui(10)).foregroundColor(Palette.text3), at: CGPoint(x: seat.midX, y: seat.maxY + 10))
        // Speakers, the one playing glowing, with its sound heading for the seat.
        for speaker in layout.speakers {
            let at = Self.place(speaker)
            let centre = CGPoint(x: at.x * w, y: at.y * h)
            let box = CGRect(x: centre.x - 14, y: centre.y - 11, width: 28, height: 22)
            let playing = speaker == active
            if playing { drawWaves(from: centre, to: head, colour: speaker.colour, phase: phase, in: &context) }
            context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(playing ? speaker.colour : Palette.surface))
            context.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(speaker.colour.opacity(playing ? 1 : 0.6)), lineWidth: 1.2)
            let label = Text(verbatim: speaker.badge).font(Typeface.ui(10, weight: .semibold))
            context.draw(label.foregroundColor(playing ? Palette.window : speaker.colour), at: centre)
        }
        // Microphone spots.
        let step = min(w, h) * 0.12
        for i in 0..<min(positions, Self.spots.count) {
            let offset = Self.spots[i]
            let p = CGPoint(x: head.x + offset.x * step, y: head.y + offset.y * step)
            let dot = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
            if measured.contains(i) {
                context.fill(Path(ellipseIn: dot), with: .color(Palette.brass))
            } else {
                context.stroke(Path(ellipseIn: dot), with: .color(Palette.text3), lineWidth: 1.2)
            }
            if i == current {
                let pulse = (running || moving) ? 0.5 + 0.5 * sin(phase * 4) : 1
                let ring = dot.insetBy(dx: -5 - 3 * pulse, dy: -5 - 3 * pulse)
                context.stroke(Path(ellipseIn: ring), with: .color(Palette.brassHi.opacity(0.4 + 0.6 * pulse)), lineWidth: 2)
                let mic = Image(systemName: "mic.fill")
                context.draw(Text(mic).font(.system(size: 10)).foregroundColor(Palette.brassHi), at: CGPoint(x: p.x, y: p.y - 18))
            }
        }
    }

    private func drawWaves(from source: CGPoint, to target: CGPoint, colour: Color, phase: Double, in context: inout GraphicsContext) {
        let dx = target.x - source.x, dy = target.y - source.y
        let angle = atan2(dy, dx), reach = hypot(dx, dy)
        for k in 0..<3 {
            let progress = (phase * 0.6 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
            let radius = CGFloat(progress) * reach
            var arc = Path()
            arc.addArc(center: source, radius: radius, startAngle: .radians(angle - 0.35), endAngle: .radians(angle + 0.35), clockwise: false)
            context.stroke(arc, with: .color(colour.opacity(0.7 * (1 - progress))), lineWidth: 1.6)
        }
    }
}
