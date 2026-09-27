//
// Nocturne — inspector: Now Playing + signal path, metadata editor, file analysis.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneAudio
import NocturneLibrary
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Hairline()
            switch model.inspectorTab {
            case .nowPlaying: NowPlayingPanel()
            case .details: TagEditorView()
            case .analysis: AnalysisPanel()
            }
        }
        .background(Palette.panel)
    }
}

// MARK: - Now Playing

struct NowPlayingPanel: View {
    @Environment(AppModel.self) private var model
    @State private var glow: Color = Color(hex: 0x3C506E)

    var body: some View {
        let player = model.player
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let entry = player.current {
                    let track = entry.track
                    HStack {
                        SectionLabel(text: "Now Playing")
                        Spacer()
                        if let i = player.currentIndex {
                            Text("\(i + 1) OF \(player.queue.count)").font(Typeface.ui(10.5, weight: .semibold)).tracking(0.9).foregroundStyle(Palette.text3)
                        }
                    }
                    ArtworkView(key: track.artworkKey, size: 600, cornerRadius: 8)
                        .shadow(color: .black.opacity(0.65), radius: 30, y: 24)
                        .padding(.top, 14)
                    Text(track.title)
                        .font(Typeface.serif(24))
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 20)
                    Text(track.displayArtist).font(Typeface.ui(13.5)).foregroundStyle(Palette.brassHi).padding(.top, 6)
                    Text([track.displayAlbum, track.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).padding(.top, 2)

                    if let path = player.signalPath {
                        StatusBadges(path: path).padding(.top, 16)
                        Hairline().padding(.top, 18)
                        SignalPathView(path: path).padding(.top, 14)
                    } else {
                        Text("Preparing output…").font(Typeface.mono(11)).foregroundStyle(Palette.text3).padding(.top, 16)
                    }
                    SpectrumView().frame(height: 44).padding(.top, 16)
                    if player.underruns > 0 {
                        Text("\(player.underruns) buffer underrun\(player.underruns == 1 ? "" : "s") this session")
                            .font(Typeface.mono(10)).foregroundStyle(Palette.copper).padding(.top, 8)
                    }
                } else {
                    IdleDevicePanel()
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            RadialGradient(colors: [glow.opacity(0.38), .clear], center: .init(x: 0.5, y: 0.25), startRadius: 0, endRadius: 320)
                .frame(height: 560)
                .blur(radius: 20)
                .allowsHitTesting(false)
        }
        .task(id: player.current?.track.artworkKey) {
            if let key = player.current?.track.artworkKey, let c = await ArtworkCache.shared.averageColor(key) {
                withAnimation(.easeInOut(duration: 0.8)) { glow = c }
            }
        }
    }
}

struct StatusBadges: View {
    let path: SignalPath
    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(text: path.statusLine, kind: path.isBitPerfect ? .perfect : .converted)
            StatusBadge(text: path.applied.exclusive ? "EXCLUSIVE" : "SHARED")
            StatusBadge(text: "\(path.applied.physicalBitDepth) / \(SampleRate.format(path.applied.sampleRate))")
        }
    }
}

struct SignalPathView: View {
    let path: SignalPath

    struct Step: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let value: String
        var tone: Tone = .plain
        enum Tone { case plain, good, changed }
    }

    var steps: [Step] {
        var s: [Step] = []
        let src = path.source
        let srcValue: String = if let dsd = src.dsdName {
            "\(dsd) · \(String(format: "%.1f", src.sampleRate / 1_000_000)) MHz"
        } else if let bits = src.bitDepth {
            "\(bits)-bit · \(SampleRate.format(src.sampleRate)) kHz"
        } else {
            "\(SampleRate.format(src.sampleRate)) kHz"
        }
        let kind = src.encoding == .lossy ? "lossy" : (src.encoding == .dsd ? "1-bit" : "lossless")
        s.append(Step(title: "Source", detail: "\(src.codec) · \(kind) · \(channelName(src.channels))", value: srcValue))
        s.append(Step(title: "Decoder", detail: path.decoderName, value: src.encoding == .lossy ? "decoded" : "lossless"))

        switch path.plan.mode {
        case .dop:
            s.append(Step(title: "DSD over PCM", detail: "DSD packed into 24-bit frames with DoP markers", value: "native DSD", tone: .good))
        case .pcm:
            if path.plan.dsdConvertedToPCM {
                s.append(Step(title: "DSD → PCM", detail: "Decimated to \(SampleRate.format(path.plan.decodedSampleRate)) kHz, 32-bit float",
                              value: "converted", tone: .changed))
            }
            if path.isResampling {
                s.append(Step(title: "Sample rate converter", detail: "Apple mastering-quality SRC",
                              value: "\(SampleRate.format(path.plan.decodedSampleRate)) → \(SampleRate.format(path.plan.deviceSampleRate)) kHz", tone: .changed))
            } else {
                s.append(Step(title: "Sample rate", detail: "Device switched to match source",
                              value: "\(SampleRate.format(path.applied.sampleRate)) kHz · native", tone: .good))
            }
        }
        if let rg = path.replayGainDB, rg != 0 {
            s.append(Step(title: "ReplayGain", detail: "Loudness normalisation", value: String(format: "%+.1f dB", rg), tone: .changed))
        }
        switch path.volume {
        case .hardware:
            s.append(Step(title: "Volume", detail: "DAC hardware control", value: "unity · 0.0 dB", tone: .good))
        case .fixed:
            s.append(Step(title: "Volume", detail: "Fixed output; use the DAC or amplifier", value: "unity · 0.0 dB", tone: .good))
        case .digital(let db):
            s.append(Step(title: "Volume", detail: "64-bit digital, TPDF dither", value: db == 0 ? "unity · 0.0 dB" : String(format: "%.1f dB", db),
                          tone: db == 0 ? .good : .changed))
        }
        let a = path.applied
        s.append(Step(title: path.deviceName,
                      detail: "\(path.deviceProfile.tag.capitalized) · \(a.exclusive ? "exclusive (hog)" : "shared") · \(a.physicalIsInteger ? "int" : "float") \(a.physicalBitDepth)",
                      value: "\(a.physicalBitDepth)-bit · \(SampleRate.format(a.sampleRate)) kHz",
                      tone: path.isBitPerfect ? .good : .plain))
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Signal Path").padding(.bottom, 10)
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    ZStack(alignment: .top) {
                        if index < steps.count - 1 {
                            Rectangle().fill(LinearGradient(colors: [Palette.brassLo, Palette.brassLo.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                                .frame(width: 1)
                                .padding(.top, 11)
                        }
                        Circle().strokeBorder(Palette.brass, lineWidth: 1.5).background(Circle().fill(Palette.panel))
                            .frame(width: 8, height: 8).padding(.top, 4)
                    }
                    .frame(width: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).font(Typeface.ui(12)).foregroundStyle(Palette.text)
                        Text(step.detail).font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Text(step.value)
                        .font(Typeface.mono(11))
                        .foregroundStyle(step.tone == .good ? Palette.brassHi : step.tone == .changed ? Palette.copper : Palette.text2)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.bottom, 9)
            }
            if let note = path.deviceProfile.note, path.isResampling || !path.deviceProfile.canBeBitPerfect {
                Text(note).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private func channelName(_ n: Int) -> String {
        switch n { case 1: "mono"; case 2: "stereo"; default: "\(n) ch" }
    }
}

/// Shown when nothing is playing: what the current device can do.
struct IdleDevicePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Output Device")
            if let d = model.activeDevice {
                HStack(spacing: 10) {
                    Image(systemName: d.profile.symbol).font(.system(size: 22, weight: .light)).foregroundStyle(Palette.brassHi)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(Typeface.serif(20)).foregroundStyle(Palette.text)
                        Text("\(d.profile.tag) · \(d.manufacturer)").font(Typeface.mono(10)).foregroundStyle(Palette.text3)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { key("Sample rates"); val(d.capabilities.sampleRates.map { SampleRate.format($0) }.joined(separator: " · ") + " kHz") }
                    GridRow { key("Bit depths"); val(bitDepths(d)) }
                    GridRow { key("Channels"); val("\(d.capabilities.outputChannels)") }
                    GridRow { key("Current rate"); val("\(SampleRate.format(d.nominalSampleRate)) kHz") }
                    GridRow { key("Volume"); val(d.hasHardwareVolume ? "Hardware" : "Fixed") }
                    GridRow { key("DoP"); val(d.capabilities.supportsDoP ? "Enabled" : "Off") }
                }
                if let note = d.profile.note {
                    Text(note).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Choose something to play. Nocturne will switch this device to each file's native format.")
                .font(Typeface.ui(12)).foregroundStyle(Palette.text3).padding(.top, 8)
        }
    }

    private func key(_ s: String) -> some View { Text(s).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3) }
    private func val(_ s: String) -> some View { Text(s).font(Typeface.mono(11)).foregroundStyle(Palette.text2) }

    private func bitDepths(_ d: OutputDevice) -> String {
        let ints = Set(d.capabilities.physicalFormats.filter(\.isInteger).map(\.bitDepth)).sorted()
        if !ints.isEmpty { return ints.map(String.init).joined(separator: " / ") + "-bit integer" }
        let floats = Set(d.capabilities.physicalFormats.map(\.bitDepth)).sorted()
        return floats.isEmpty ? "—" : floats.map(String.init).joined(separator: " / ") + "-bit float"
    }
}

/// Live spectrum of exactly what the DAC receives.
struct SpectrumView: View {
    @Environment(AppModel.self) private var model
    @State private var bands = [Float](repeating: 0, count: 32)
    @State private var buffer = [Float](repeating: 0, count: 4096)
    private let analyzer = SpectrumAnalyzer(size: 4096)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.player.isPlaying)) { context in
            Canvas { ctx, size in
                let n = bands.count
                let gap: CGFloat = 2
                let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                for (i, v) in bands.enumerated() {
                    let h = max(2, CGFloat(v) * size.height)
                    let rect = CGRect(x: CGFloat(i) * (w + gap), y: size.height - h, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .linearGradient(Gradient(colors: [Palette.brassHi, Palette.brassLo]),
                                                   startPoint: CGPoint(x: 0, y: size.height - h), endPoint: CGPoint(x: 0, y: size.height)))
                }
            }
            .opacity(0.85)
            .onChange(of: context.date) { update() }
        }
    }

    private func update() {
        guard let path = model.player.signalPath, path.plan.mode == .pcm,
              let rate = model.player.engine.copyTap(into: &buffer) else {
            bands = bands.map { $0 * 0.85 }
            return
        }
        let fresh = analyzer.bands(buffer, sampleRate: rate, count: bands.count, highHz: min(rate / 2, 40_000))
        bands = zip(bands, fresh).map { old, new in new > old ? new : old * 0.82 + new * 0.18 }
    }
}

// MARK: - Analysis

struct AnalysisPanel: View {
    @Environment(AppModel.self) private var model
    @State private var result: FileAnalysis?
    @State private var running = false
    @State private var analyzedID: Int64?

    var body: some View {
        let track = model.selectedTracks.first ?? model.player.current?.track
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let track {
                    Text(track.title).font(Typeface.serif(20)).foregroundStyle(Palette.text)
                    Text("\(track.formatSummary) · \(track.displayArtist)").font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
                    Text("Decodes the file at its native rate and looks for padding, upsampling and lossy origins. Nothing is modified.")
                        .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    Button(running ? "Analyzing…" : "Analyze") { run(track) }
                        .buttonStyle(BrassButtonStyle())
                        .disabled(running || track.isDSD || !track.isLossless)
                    if running { ProgressView().controlSize(.small).tint(Palette.brass) }
                    if let result, analyzedID == track.id {
                        results(result)
                    }
                } else {
                    Text("Select a track to analyze.").font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .task(id: track?.id) {
            if UserDefaults.standard.bool(forKey: "NocturneRunAnalysis"), let track, result == nil { run(track) }
        }
    }

    private func run(_ track: Track) {
        running = true
        let url = track.fileURL
        Task {
            let r = try? await Task.detached(priority: .userInitiated) { try FileAnalyzer.analyze(url: url) }.value
            running = false
            result = r
            analyzedID = track.id
            if let r, let id = track.id { model.library.saveAnalysis(r, trackID: id) }
        }
    }

    @ViewBuilder
    private func results(_ r: FileAnalysis) -> some View {
        let ok = r.verdict == .genuine
        StatusBadge(text: verdictLabel(r.verdict), kind: ok ? .perfect : .converted)
        Text(r.summary).font(Typeface.ui(12.5)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow { k("Claimed"); v(r.claimedBitDepth.map { "\($0)-bit" } ?? "—") }
            GridRow { k("Effective"); v(r.effectiveBitDepth.map { "\($0)-bit" } ?? "—") }
            GridRow { k("Bandwidth"); v(String(format: "%.1f kHz of %@ kHz", r.bandwidthHz / 1000, SampleRate.format(r.sampleRate / 2))) }
            GridRow { k("Peak"); v(r.peakDBFS.isFinite ? String(format: "%.2f dBFS", r.peakDBFS) : "silent") }
            GridRow { k("Clipped samples"); v("\(r.clippedSamples)") }
        }
        SectionLabel(text: "Long-term spectrum").padding(.top, 6)
        SpectrumPlot(values: r.spectrum, nyquist: r.sampleRate / 2).frame(height: 140)
    }

    private func verdictLabel(_ v: FileAnalysis.Verdict) -> String {
        switch v {
        case .genuine: "GENUINE"
        case .paddedBitDepth: "PADDED BIT DEPTH"
        case .upsampled: "LIKELY UPSAMPLED"
        case .possibleLossyOrigin: "POSSIBLE LOSSY ORIGIN"
        case .notApplicable: "N/A"
        }
    }

    private func k(_ s: String) -> some View { Text(s).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3) }
    private func v(_ s: String) -> some View { Text(s).font(Typeface.mono(11)).foregroundStyle(Palette.text2) }
}

struct SpectrumPlot: View {
    let values: [Float]
    let nyquist: Double

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let lo: Float = -150, hi: Float = -20
            func y(_ v: Float) -> CGFloat { size.height * (1 - CGFloat((max(lo, min(hi, v)) - lo) / (hi - lo))) }
            // Frequency gridlines.
            for f in [100.0, 1_000, 10_000, 20_000] where f < nyquist {
                let x = size.width * CGFloat(log(f / 20) / log(nyquist / 20))
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Palette.hairlineStrong), lineWidth: 1)
                ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(Typeface.mono(8.5)).foregroundStyle(Palette.text3),
                         at: CGPoint(x: x + 3, y: size.height - 6), anchor: .leading)
            }
            var line = Path()
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: y(v))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                fill.addLine(to: p)
            }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [Palette.brass.opacity(0.35), .clear]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(Palette.brassHi), lineWidth: 1.2)
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
