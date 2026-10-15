//
// Vespertine — measuring a room with a microphone: each speaker plays a sweep in turn, and the recording becomes each
// speaker's delay, level and bass filters, shown before they're used.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio

struct RoomMeasurementSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: OutputDevice

    private enum Phase { case setup, measuring, results }
    @State private var phase = Phase.setup
    @State private var inputs: [AudioInput] = []
    @State private var inputUID = ""
    @State private var progress = MeasurementProgress()
    @State private var speakers: [SpeakerMeasurement] = []
    @State private var problem: String?

    private var input: AudioInput? { inputs.first { $0.uid == inputUID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Measure Your Room").font(Typeface.serif(24)).foregroundStyle(Palette.text)
                Text("Each speaker plays a sweep in turn while a microphone at your listening position records. Vespertine works out how far each speaker is, how loud it is, and filters that tame the room's bass peaks.")
                    .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)
            Hairline()
            Group {
                switch phase {
                case .setup: setup
                case .measuring: measuring
                case .results: results
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Hairline()
            footer
        }
        .frame(width: 720, height: 620)
        .background(Palette.panel)
        .interactiveDismissDisabled(phase == .measuring)
        .onAppear {
            inputs = AudioInput.all()
            inputUID = (inputs.first { $0.looksLikeMeasurementMic } ?? inputs.first)?.uid ?? ""
        }
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Microphone", selection: $inputUID) {
                ForEach(inputs) { Text($0.name).tag($0.uid) }
            }
            .frame(maxWidth: 420)
            if let input, !input.looksLikeMeasurementMic {
                Label("This doesn't look like a measurement microphone. Ordinary microphones, built-in ones included, are far from flat in the bass, so the filters would correct the microphone instead of the room. A measurement microphone such as a miniDSP UMIK-1 costs about $100.",
                      systemImage: "exclamationmark.triangle")
                    .font(Typeface.ui(12)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Before you start").font(Typeface.ui(12, weight: .semibold)).foregroundStyle(Palette.text)
                Text("Put the microphone where your head usually is, pointing at the ceiling. Set the volume to a comfortable listening level: the sweeps play 12 dB below full scale. Keep the room quiet for about \(Int(plan.seconds.rounded())) seconds.")
                    .font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                Text("Only the bass is corrected (20 to 250 Hz), with cuts of up to 15 dB and boosts of no more than 3 dB: dips are usually sound cancelling itself, and boosting them only wastes power.")
                    .font(Typeface.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Label(problem, systemImage: "xmark.octagon").font(Typeface.ui(12)).foregroundStyle(Palette.copper)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var plan: RoomMeasurementPlan {
        RoomMeasurementPlan(sampleRate: 48_000, speakers: max(1, min(device.capabilities.outputChannels, 2)))
    }

    // MARK: Measuring

    private var measuring: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measuring…").font(Typeface.serif(17)).foregroundStyle(Palette.text)
            ProgressView(value: progress.value).frame(maxWidth: 420)
            Text("Keep the room quiet until the sweeps finish.").font(Typeface.ui(12)).foregroundStyle(Palette.text2)
        }
    }

    // MARK: Results

    private var results: some View {
        let names = [String(localized: "Left"), String(localized: "Right")]
        let profile = RoomMeasurement.profile(speakers, name: device.name)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(speakers.enumerated()), id: \.offset) { c, speaker in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(c < names.count ? names[c] : String(localized: "Speaker \(c + 1)"))
                                .font(Typeface.ui(13, weight: .semibold)).foregroundStyle(Palette.text)
                            Spacer()
                            Text(detail(profile.channels[c], filters: speaker.filters.count))
                                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2)
                        }
                        ResponsePlot(before: speaker.responseDB, after: speaker.correctedDB, level: speaker.levelDB)
                            .frame(height: 150)
                    }
                }
                Text("Grey: as measured. Brass: with the filters. 20 Hz to 1 kHz.")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3)
            }
        }
    }

    private func detail(_ channel: RoomChannelCorrection, filters: Int) -> String {
        var parts = [String(localized: "\(filters) filters")]
        if channel.delayMs > 0 { parts.append(String(localized: "held back \(channel.delayMs.formatted(.number.precision(.fractionLength(2)))) ms")) }
        if channel.levelDB != 0 { parts.append("\(channel.levelDB.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) dB") }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if phase == .results {
                Button("Measure Again") { phase = .setup }
            }
            Spacer()
            Button(phase == .results ? String(localized: "Cancel") : String(localized: "Close")) { dismiss() }
                .disabled(phase == .measuring)
            if phase == .setup {
                Button("Measure") { Task { await measure() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input == nil)
            }
            if phase == .results {
                Button("Use These Filters") { use() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func measure() async {
        guard let input else { return }
        problem = nil
        guard await LoopbackPermission.check() != .denied else {
            problem = LoopbackError.permissionDenied.localizedDescription
            return
        }
        let player = model.player
        if player.isPlaying { player.togglePlayPause() }
        phase = .measuring
        progress.value = 0
        let plan = plan, device = device, settings = model.settings.engineSettings(), progress = progress
        let result: Result<[SpeakerMeasurement], any Error> = await Task.detached(priority: .userInitiated) {
            Result {
                let runner = RoomMeasurementRunner(output: device, input: input.id)
                let recording = try runner.record(plan, levelDB: -12, settings: settings) { value in
                    Task { @MainActor in progress.value = value }
                }
                return try RoomMeasurement.analyze(recording: recording, plan: plan)
            }
        }.value
        switch result {
        case .success(let measured):
            speakers = measured
            phase = .results
        case .failure(let error):
            problem = error.localizedDescription
            phase = .setup
        }
    }

    /// Saves the measurement as the output's room profile, keeping any impulse responses imported for it.
    private func use() {
        let settings = model.settings
        var profile = RoomMeasurement.profile(speakers, name: String(localized: "Measured \(Date().formatted(date: .abbreviated, time: .omitted))"))
        for (c, old) in (settings.roomProfiles[device.uid]?.channels ?? []).enumerated() where old.impulse != nil {
            while profile.channels.count <= c { profile.channels.append(RoomChannelCorrection()) }
            profile.channels[c].impulse = old.impulse
        }
        settings.roomProfiles[device.uid] = profile
        model.syncEngine()
        dismiss()
    }
}

@Observable
@MainActor
private final class MeasurementProgress {
    var value = 0.0
}

/// A response before and after correction, 20 Hz to 1 kHz on a log scale, ±15 dB around the level.
private struct ResponsePlot: View {
    let before: [Double]
    let after: [Double]
    let level: Double

    var body: some View {
        Canvas { context, size in
            let f = RoomMeasurement.frequencies
            let low = log2(20.0), high = log2(1000.0)
            func x(_ hz: Double) -> CGFloat { CGFloat((log2(hz) - low) / (high - low)) * size.width }
            func y(_ db: Double) -> CGFloat { CGFloat(0.5 - (db - level) / 30) * size.height }
            for hz in [20.0, 50, 100, 200, 500, 1000] {
                var grid = Path()
                grid.move(to: CGPoint(x: x(hz), y: 0)); grid.addLine(to: CGPoint(x: x(hz), y: size.height))
                context.stroke(grid, with: .color(Palette.hairline))
                context.draw(Text(hz >= 1000 ? "1k" : "\(Int(hz))").font(Typeface.ui(9)).foregroundStyle(Palette.text3),
                             at: CGPoint(x: x(hz) + 3, y: size.height - 6), anchor: .leading)
            }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(level))); zero.addLine(to: CGPoint(x: size.width, y: y(level)))
            context.stroke(zero, with: .color(Palette.hairlineStrong))
            for (values, color) in [(before, Palette.text3), (after, Palette.brass)] {
                var line = Path()
                for i in f.indices where f[i] <= 1000 && i < values.count {
                    let point = CGPoint(x: x(f[i]), y: min(max(y(values[i]), 0), size.height))
                    if line.isEmpty { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(color), lineWidth: 1.5)
            }
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
