//
// Vespertine — Room Correction: the profile each output plays with, on or off, the measured and predicted response,
// the target and range the filters were fitted to, the filters themselves, and the measurement wizard.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers
import VespertineAudio

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
                Text(profiles.isEmpty ? "Measure this output with a UMIK-1 to correct your room's bass."
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
                Button(profiles.isEmpty ? "Measure…" : "Edit…") { openWindow(id: "room-correction") }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .font(Typeface.ui(12))
    }
}

struct RoomCorrectionWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(RoomMeasureModel.self) private var measure
    @State private var selection: UUID?
    @State private var showWizard = false
    @State private var redesigning = false
    @State private var problem: String?
    @State private var importing = false

    var body: some View {
        let settings = model.settings
        let device = model.activeDevice
        let profiles = device.map { settings.roomProfiles(for: $0.uid) } ?? []
        let selected = profiles.first { $0.id == selection } ?? device.flatMap { settings.roomProfile(for: $0.uid) } ?? profiles.first
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Room Correction").font(Typeface.serif(26)).foregroundStyle(Palette.text)
                    Text("Measures each speaker at your seat, then fits filters that cut the room's bass peaks, separately for left and right. Off unless you turn it on; while it's on, the signal path says ROOM CORRECTION and playback isn't bit-perfect.")
                        .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                }
                Hairline()
                if let device {
                    outputRow(device, profiles: profiles, selected: selected)
                } else {
                    Text("No output is connected.").font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                }
                if let selected {
                    profileSection(selected)
                } else if device != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No measurement for this output yet.").font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
                        Text("You need a UMIK-1 measurement microphone and its calibration file (from miniDSP, by serial number). The measurement takes about a minute and plays quiet sweeps through each speaker.")
                            .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let problem { Text(problem).font(Typeface.ui(12)).foregroundStyle(Palette.copper) }
                HStack {
                    Button(selected == nil ? "Measure…" : "Measure again…") { showWizard = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(device == nil)
                    Button("Import Profile…") { importing = true }
                        .help("Add a room-profile.json saved by a measurement")
                    if let selected {
                        Button("Delete Profile", role: .destructive) {
                            settings.deleteRoomProfile(selected.id)
                            selection = nil
                            model.syncEngine()
                        }
                    }
                }
            }
            .padding(22)
        }
        .frame(minWidth: 720, minHeight: 640)
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let profile = try RoomCorrectionCoding.decodeProfile(try Data(contentsOf: url))
                settings.saveRoomProfile(profile)
                selection = profile.id
                problem = device.map { profile.deviceUID == $0.uid } == false
                    ? String(localized: "Imported. It was measured on another output, so it only appears (and plays) when that output is selected.") : nil
            } catch {
                problem = String(localized: "That file isn't a room correction profile: \(error.localizedDescription)")
            }
        }
        .onAppear {
            let player = model.player
            measure.pausePlayback = { player.pause() }
            if measure.launch != nil { showWizard = true }
        }
    }

    private func outputRow(_ device: OutputDevice, profiles: [RoomProfile], selected: RoomProfile?) -> some View {
        let settings = model.settings
        let on = settings.roomProfile(for: device.uid) != nil
        let path = model.player.signalPath
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(Typeface.ui(15, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(profiles.isEmpty ? String(localized: "Not measured") : String(localized: "\(profiles.count) profile(s) measured on this output"))
                        .font(Typeface.ui(11.5)).foregroundStyle(Palette.text3)
                }
                Spacer()
                Toggle("Room correction", isOn: Binding(get: { on }, set: { new in
                    settings.setRoomProfile(new ? (selected ?? profiles.first)?.id : nil, for: device.uid)
                    model.syncEngine()
                }))
                .toggleStyle(.switch)
                .disabled(profiles.isEmpty)
                .accessibilityHint("Turns room correction on or off for this output")
            }
            if on, let path, path.deviceUID == device.uid {
                if path.roomCorrection != nil {
                    note("waveform.path.ecg", String(localized: "In the signal now: the status reads ROOM CORRECTION."))
                } else if path.bypassedRoomCorrection != nil {
                    note("info.circle", path.equalizerBypass.map { String(localized: "Not applied: \($0.explanation)") }
                         ?? String(localized: "Not applied: it was measured for two channels and this stream isn't plain stereo."))
                }
            }
            if on, settings.integerMode {
                note("info.circle", String(localized: "Integer mode can't apply filters: while room correction is on, music plays on the float path."))
            }
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Palette.text3)
            Text(text).font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func profileSection(_ profile: RoomProfile) -> some View {
        let settings = model.settings
        let profiles = settings.roomProfiles(for: profile.deviceUID)
        VStack(alignment: .leading, spacing: 12) {
            if profiles.count > 1 {
                Picker("Profile", selection: Binding(get: { profile.id }, set: { id in
                    selection = id
                    if settings.roomProfile(for: profile.deviceUID) != nil { settings.setRoomProfile(id, for: profile.deviceUID); model.syncEngine() }
                })) {
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 420)
            } else {
                Text(profile.name).font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
            }
            Text("Microphone \(profile.micSerial) · measured \(profile.createdAt.formatted(date: .abbreviated, time: .shortened)) · preamp \(profile.filters.preampDB.formatted(.number.precision(.fractionLength(1)))) dB")
                .font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
            if let preview = RoomCorrectionPreview(profile: profile) {
                RoomCurvesView(preview: preview).frame(height: 300)
                Text("Thin: measured. Bold: predicted after correction (calculated, not measured). Dashed: target. Measure again with correction on to check it in the room.")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
            if let options = profile.designOptions, profile.measured != nil {
                HStack(spacing: 16) {
                    Picker("Target", selection: Binding(get: { options.target }, set: { redesign(profile, target: $0, range: options.range) })) {
                        ForEach(RoomTargetCurve.presets) { Text($0.name).tag($0) }
                    }
                    .frame(maxWidth: 240)
                    Picker("Range", selection: Binding(get: { options.isFullRange }, set: {
                        redesign(profile, target: options.target, range: $0 ? RoomFilterDesignOptions.fullRange : RoomFilterDesignOptions.defaultRange)
                    })) {
                        Text("Bass, 20–500 Hz").tag(false)
                        Text("Full range").tag(true)
                    }
                    .frame(maxWidth: 240)
                    if redesigning { ProgressView().controlSize(.small) }
                }
                .disabled(redesigning)
            }
            RoomFilterTable(profile: profile)
        }
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

/// Measured (thin), predicted (bold) and target (dashed) per speaker, 20 Hz to 20 kHz.
struct RoomCurvesView: View {
    let preview: RoomCorrectionPreview

    private static let colours: [RoomSpeaker: Color] = [.left: Color(red: 0.55, green: 0.78, blue: 1), .right: Color(red: 1, green: 0.62, blue: 0.5)]

    var body: some View {
        let all = preview.channels.flatMap { $0.measuredDB + $0.predictedDB }
        let top = max(10, ((all.max() ?? 10) / 5).rounded(.up) * 5), bottom = min(-20, ((all.min() ?? -20) / 5).rounded(.down) * 5)
        Canvas { context, size in
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / 20) / 3) * size.width }
            func y(_ db: Double) -> CGFloat { CGFloat((top - db) / (top - bottom)) * size.height }
            var grid = Path()
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10_000] { grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: size.height)) }
            for db in stride(from: bottom, through: top, by: 5) { grid.move(to: CGPoint(x: 0, y: y(db))); grid.addLine(to: CGPoint(x: size.width, y: y(db))) }
            context.stroke(grid, with: .color(Palette.hairline), lineWidth: 1)
            for channel in preview.channels {
                let colour = Self.colours[channel.speaker] ?? Palette.brass
                func line(_ values: [Double]) -> Path {
                    var p = Path()
                    for (i, f) in channel.frequencies.enumerated() where f >= 20 && f <= 20_000 {
                        let point = CGPoint(x: x(f), y: y(values[i]))
                        if p.isEmpty { p.move(to: point) } else { p.addLine(to: point) }
                    }
                    return p
                }
                context.stroke(line(channel.targetDB), with: .color(colour.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                context.stroke(line(channel.measuredDB), with: .color(colour.opacity(0.5)), lineWidth: 1.2)
                context.stroke(line(channel.predictedDB), with: .color(colour), lineWidth: 2.4)
            }
            for (f, label) in [(50.0, "50"), (100.0, "100"), (500.0, "500"), (1000.0, "1k"), (5000.0, "5k"), (10_000.0, "10k")] {
                context.draw(Text(label).font(Typeface.mono(9.5)).foregroundColor(Palette.text3), at: CGPoint(x: x(f) + 3, y: size.height - 8), anchor: .leading)
            }
            context.draw(Text("+\(Int(top)) dB").font(Typeface.mono(9.5)).foregroundColor(Palette.text3), at: CGPoint(x: 4, y: 8), anchor: .leading)
            context.draw(Text("\(Int(bottom)) dB").font(Typeface.mono(9.5)).foregroundColor(Palette.text3), at: CGPoint(x: 4, y: size.height - 8), anchor: .leading)
            var legendY = 10.0
            for channel in preview.channels {
                context.draw(Text(channel.speaker == .left ? "Left" : channel.speaker == .right ? "Right" : channel.speaker.rawValue)
                    .font(Typeface.ui(11, weight: .semibold)).foregroundColor(Self.colours[channel.speaker] ?? Palette.brass),
                             at: CGPoint(x: size.width - 8, y: legendY), anchor: .trailing)
                legendY += 16
            }
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .accessibilityElement()
        .accessibilityLabel("Measured and predicted room response")
        .accessibilityValue(preview.channels.map { c in
            String(localized: "\(c.speaker.rawValue): deviation from target \(c.rmsErrorBeforeDB.formatted(.number.precision(.fractionLength(1)))) decibels measured, \(c.rmsErrorAfterDB.formatted(.number.precision(.fractionLength(1)))) predicted")
        }.joined(separator: "; "))
    }
}

/// The fitted bands per speaker.
struct RoomFilterTable: View {
    let profile: RoomProfile

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(profile.channelMap.entries.sorted { $0.output < $1.output }, id: \.speaker) { entry in
                let bands = profile.filters.channels[entry.speaker] ?? []
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.speaker == .left ? "Left" : entry.speaker == .right ? "Right" : entry.speaker.rawValue)
                        .font(Typeface.ui(12, weight: .semibold)).foregroundStyle(Palette.text)
                    if bands.isEmpty {
                        Text("No filters").font(Typeface.mono(11)).foregroundStyle(Palette.text3)
                    }
                    ForEach(bands) { b in
                        Text("\(b.frequency.formatted(.number.precision(.fractionLength(1)))) Hz  \(b.gainDB.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) dB  Q \(b.q.formatted(.number.precision(.fractionLength(2))))")
                            .font(Typeface.mono(11)).foregroundStyle(Palette.text2)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The measurement, step by step: microphone placement, permission, level, sweeps, result.
struct RoomMeasureWizard: View {
    @Environment(RoomMeasureModel.self) private var model
    let device: OutputDevice?
    let save: (RoomProfile, Bool) -> Void
    let close: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Measure the room").font(Typeface.serif(22)).foregroundStyle(Palette.text)
            stepper
            Hairline()
            switch model.phase {
            case .ready:
                prepare
            case .running, .needsAttention, .waitingForMic, .cancelled, .failed:
                RoomMeasureProgress()
            case .finished:
                result
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(22)
        .frame(width: 680, height: 640)
        .background(Palette.window)
        .onAppear {
            model.preferredOutputUID = device?.uid
            model.startIfLaunched()
        }
    }

    private enum Stage: Int, CaseIterable { case placement, allow, level, sweeps, result }

    private var stage: Stage {
        switch model.phase {
        case .ready: .placement
        case .finished: .result
        default: model.steps.contains { if case .sweep = $0.step { $0.status != .pending } else { false } } ? .sweeps
            : model.steps.isEmpty ? .allow : .level
        }
    }

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(Stage.allCases, id: \.self) { s in
                let title: LocalizedStringKey = switch s {
                case .placement: "Microphone"
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

    private var prepare: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            instruction("1", "Place the microphone", "UMIK-1 on a stand at ear height where you sit, pointing straight up (use its 90° calibration file). Keep the room quiet.")
            instruction("2", "Allow the microphone", "macOS asks once whether Vespertine may use the microphone. Choose Allow; it only listens while a measurement runs.")
            instruction("3", "Level", "Music pauses. A quiet test plays first; the sweeps get only as loud as the microphone needs. Keep your amplifier at a comfortable level.")
            instruction("4", "Sweeps", "Each speaker plays a short rising tone, left then right. Don't move or talk for about a minute.")
            Text(device.map { String(localized: "Output: \($0.name), at the rate it is set to now.") } ?? String(localized: "Output: the Mac's default output."))
                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2)
            HStack {
                TextField("Calibration file", text: $model.calibrationPath).textFieldStyle(.roundedBorder).font(Typeface.mono(11))
                Button("Choose…") { model.chooseCalibration() }
            }
            Stepper("Positions: \(model.positions)", value: $model.positions, in: 1...RoomMeasureLaunch.maxPositions)
            Toggle("Use a simulated room (no microphone, no sound)", isOn: $model.simulate)
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

    @ViewBuilder
    private var result: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 10) {
                Text("Measured. Here is what the filters should do.").font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
                if let preview = RoomCorrectionPreview(profile: draft) { RoomCurvesView(preview: preview).frame(height: 240) }
                Text("Bold lines are predicted, not measured. Target: \(draft.designOptions?.target.name ?? draft.target.name).")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3)
                RoomFilterTable(profile: draft)
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
