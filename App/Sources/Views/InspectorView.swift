//
// Vespertine — inspector: Now Playing + signal path, metadata editor, file analysis.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import VespertineAudio
import VespertineLibrary
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
        GeometryReader { geo in
        // The cover gives way so the title, badges and signal path fit the panel without scrolling
        // (about 560 pt of them); on a tall window it grows back to the full width.
        let artSide = min(geo.size.width - 40, max(160, geo.size.height - 560))
        ScrollViewReader { scroller in
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
                        .frame(width: artSide, height: artSide)
                        .shadow(color: .black.opacity(0.65), radius: 30, y: 24)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(track.title)
                            .font(Typeface.serif(24))
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        FavoriteButton(track: track, size: 15)
                    }
                    .padding(.top, 20)
                    Text(track.displayArtist).font(Typeface.ui(13.5)).foregroundStyle(Palette.brassHi).padding(.top, 6)
                    Text([track.displayAlbum, track.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).padding(.top, 2)
                    if let mark = track.formatMark {
                        FormatMarkView(mark: mark).padding(.top, 14)
                    }

                    if let path = player.signalPath {
                        StatusBadges(path: path).padding(.top, 16)
                        Hairline().padding(.top, 18)
                        SignalPathView(path: path).padding(.top, 14)
                        if path.plan.channels > 2 || path.source.channels > 2 {
                            ChannelMetersView(path: path, levels: model.player.channelLevels).padding(.top, 14)
                        }
                    } else if let system = player.systemRendering {
                        SystemRenderingView(rendering: system, device: player.outputDevice?.name).padding(.top, 16)
                    } else {
                        Text("Preparing output…").font(Typeface.mono(11)).foregroundStyle(Palette.text3).padding(.top, 16)
                    }
                    SpectrumView().frame(height: 44).padding(.top, 16).id("spectrum")
                    if player.buffering {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Buffering from the network…").font(Typeface.mono(10)).foregroundStyle(Palette.text2)
                        }
                        .padding(.top, 8)
                    }
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
        .task(id: player.signalPath != nil) {
            // QA: `-VespertineScrollInspector YES` scrolls to the meters for snapshots.
            guard player.signalPath != nil, LaunchArguments().bool(forKey: "VespertineScrollInspector") else { return }
            try? await Task.sleep(for: .milliseconds(300))
            scroller.scrollTo("spectrum", anchor: .bottom)
        }
        }
        }
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
        // One row when it fits the inspector; a long status ("SPATIAL · HEAD TRACKED") takes a row of its own.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { status; details }
            VStack(alignment: .leading, spacing: 8) { status; HStack(spacing: 8) { details } }
        }
    }
    private var status: some View { StatusBadge(text: path.statusLine, kind: path.isBitPerfect ? .perfect : .converted) }
    @ViewBuilder private var details: some View {
        StatusBadge(text: path.applied.exclusive ? "EXCLUSIVE" : "SHARED")
        StatusBadge(text: "\(path.applied.physicalBitDepth) / \(SampleRate.format(path.applied.sampleRate))")
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
        if path.plan.mode != .bitstream {
            s.append(Step(title: "Decoder", detail: path.decoderName, value: src.encoding == .lossy ? "decoded" : "lossless"))
        }

        switch path.plan.mode {
        case .dop:
            s.append(Step(title: "DSD over PCM", detail: "DSD packed into 24-bit frames with DoP markers", value: "native DSD", tone: .good))
        case .bitstream:
            s.append(Step(title: "Bitstream", detail: "\(src.codec) frames untouched in IEC 61937 bursts; the receiver decodes",
                          value: "\(SampleRate.format(path.plan.deviceSampleRate)) kHz carrier", tone: .good))
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
        if path.plan.spatial != .off {
            s.append(Step(title: "Spatial Audio",
                          detail: "\(ChannelLayouts.name(labels: src.channelLabels, channels: src.channels)) as virtual speakers · Apple spatial renderer, personalized profile if set up",
                          value: path.plan.spatial == .headTracked ? "head tracked" : "fixed", tone: .changed))
        } else if path.plan.channels < src.channels {
            s.append(Step(title: "Downmix", detail: "Standard channel-layout mix (centre and surrounds folded in)",
                          value: "\(ChannelLayouts.name(channels: src.channels)) → \(ChannelLayouts.name(channels: path.plan.channels))", tone: .changed))
        } else if src.channels > 2 {
            s.append(Step(title: "Channels", detail: "Every channel to its speaker (device layout)",
                          value: "\(ChannelLayouts.name(channels: src.channels)) discrete", tone: .good))
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
                      detail: "\(path.deviceProfile.connection) · \(a.exclusive ? "exclusive (hog)" : "shared") · \(a.physicalIsInteger ? "int" : "float") \(a.physicalBitDepth)\(a.integerMode ? " · integer mode" : "")",
                      value: "\(a.physicalBitDepth)-bit · \(SampleRate.format(a.sampleRate)) kHz",
                      tone: path.isBitPerfect ? .good : .plain))
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SignalSteps(steps: steps)
            if let note = path.deviceProfile.note, path.isResampling || !path.deviceProfile.canBeBitPerfect {
                Text(note).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private func channelName(_ n: Int) -> String {
        n > 2 ? ChannelLayouts.name(channels: n) : (n == 1 ? "mono" : "stereo")
    }
}

/// The steps of a signal path, top to bottom, joined by a line.
struct SignalSteps: View {
    let steps: [SignalPathView.Step]

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
        }
    }
}

/// Dolby Atmos rendered by macOS: its objects become what the device can play.
struct SystemRenderingView: View {
    let rendering: SystemRendering
    let device: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    StatusBadge(text: "OBJECTS RENDERED BY MACOS", kind: .perfect)
                    if rendering.spatial { StatusBadge(text: "SPATIAL") }
                }
                StatusBadge(text: "OBJECTS RENDERED BY MACOS", kind: .perfect)
            }
            Hairline().padding(.top, 18)
            SignalSteps(steps: [
                .init(title: "Source", detail: "Dolby Digital Plus with Atmos objects (JOC) · lossy",
                      value: rendering.objectLayout.map { "up to \($0)" } ?? "objects"),
                .init(title: "Dolby Atmos renderer", detail: "macOS renders the objects for this output (the same renderer Apple Music uses)",
                      value: "objects → speakers", tone: .good),
                .init(title: rendering.spatial ? "Spatial Audio" : "Output",
                      detail: rendering.spatial ? "Head tracking and personalized profile as set in Control Center" : "The output's own speaker layout",
                      value: rendering.spatial ? "on" : "channels", tone: rendering.spatial ? .changed : .plain),
                .init(title: device ?? "Output", detail: "Frames go to macOS untouched; Vespertine's meters don't apply", value: "system"),
            ])
            .padding(.top, 14)
        }
    }
}

/// Live level of every channel Vespertine sends, labelled by speaker, plus where they go.
struct ChannelMetersView: View {
    let path: SignalPath
    let levels: [Float]

    var body: some View {
        let names = path.applied.channelNames
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: path.plan.spatial != .off ? "Channels · Spatial Audio" : "Channels")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            let level = i < levels.count ? levels[i] : 0
                            let db = level > 0 ? 20 * log10(Double(level)) : -120
                            let fraction = max(0, min(1, (db + 60) / 60))
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2).fill(Palette.surface)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(LinearGradient(colors: [Palette.brassLo, Palette.brass, Palette.brassHi], startPoint: .bottom, endPoint: .top))
                                    .frame(height: geo.size.height * fraction)
                            }
                        }
                        .frame(width: 14, height: 70)
                        Text(name).font(Typeface.mono(8.5)).foregroundStyle(Palette.text3).fixedSize()
                    }
                }
            }
            Text(summary).font(Typeface.ui(11)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        let src = ChannelLayouts.name(labels: path.source.channelLabels, channels: path.source.channels)
        if path.plan.spatial != .off {
            return "\(src) placed as virtual speakers around you and rendered for \(path.deviceName)."
        }
        if path.plan.channels < path.source.channels {
            return "\(src) folded into \(ChannelLayouts.name(channels: path.plan.channels)) by speaker position."
        }
        let speakers = path.applied.speakerNames
        var text = "\(path.plan.channels) channels to \(path.deviceName)"
        if path.applied.streamCount > 1 { text += " across \(path.applied.streamCount) outputs" }
        if !speakers.isEmpty {
            let used = Set(path.applied.channelNames)
            let silent = speakers.filter { !used.contains($0) }
            text += ", each on its matching speaker" + (silent.isEmpty ? "." : "; \(silent.joined(separator: " ")) stay silent.")
        } else {
            text += " in standard order (1 L, 2 R, 3 C, 4 LFE, 5 Ls, 6 Rs…). Set up speakers in Audio MIDI Setup to place them by position."
        }
        return text
    }
}

/// Points multichannel users at Audio MIDI Setup when no speaker layout is configured.
struct SpeakerSetupHint: View {
    let configured: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: configured ? "hifispeaker.2.fill" : "exclamationmark.circle").foregroundStyle(configured ? Palette.brass : Palette.copper)
            Text(configured
                 ? "Multichannel music goes to each speaker by position."
                 : "No speaker layout is set up, so channels go out in standard order. Set one up to place each channel on its speaker.")
                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(configured ? "Speakers…" : "Configure Speakers…") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
            }
            .buttonStyle(QuietButtonStyle(compact: true))
        }
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
                    if d.capabilities.outputChannels > 2 {
                        let speakers = d.speakerNames
                        GridRow {
                            key("Speakers")
                            val(speakers.isEmpty ? "Not set up" : "\(ChannelLayouts.name(channels: speakers.count)) · \(speakers.joined(separator: " "))")
                        }
                    }
                    GridRow { key("Current rate"); val("\(SampleRate.format(d.nominalSampleRate)) kHz") }
                    GridRow { key("Volume"); val(d.hasHardwareVolume ? "Hardware" : "Fixed") }
                    GridRow { key("DoP"); val(d.capabilities.supportsDoP ? "Enabled" : "Off") }
                }
                if let note = d.profile.note {
                    Text(note).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                }
                if d.capabilities.outputChannels > 2 {
                    SpeakerSetupHint(configured: !d.speakerNames.isEmpty)
                }
            }
            Text("Choose something to play. Vespertine will switch this device to each file's native format.")
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
        guard let path = model.player.signalPath, path.plan.mode != .bitstream,
              let rate = model.player.engine.copyTap(into: &buffer) else {
            bands = bands.map { $0 * 0.85 }
            return
        }
        // DoP levels come from the DSD bits: past 20 kHz they're mostly the modulator's noise, not music.
        let fresh = analyzer.bands(buffer, sampleRate: rate, count: bands.count, highHz: min(rate / 2, path.plan.mode == .dop ? 20_000 : 40_000))
        bands = zip(bands, fresh).map { old, new in new > old ? new : old * 0.82 + new * 0.18 }
    }
}

// MARK: - Analysis

struct AnalysisPanel: View {
    @Environment(AppModel.self) private var model
    /// nil = automatic (whichever changed last); otherwise pinned to the selection or playback.
    @State private var pinned: Subject?
    @State private var stored: LibraryDatabase.StoredAnalysis?

    enum Subject { case selection, playing }

    private var selected: Track? { model.selectedTracks.first }
    private var playing: Track? { model.player.current?.track }

    private var subject: Subject? {
        switch (selected, playing) {
        case (nil, nil): return nil
        case (_?, nil): return .selection
        case (nil, _?): return .playing
        case (_?, _?):
            if let pinned { return pinned }
            return model.selectionChangedAt > model.player.trackStartedAt ? .selection : .playing
        }
    }
    private var track: Track? { subject == .selection ? selected : subject == .playing ? playing : nil }

    var body: some View {
        let track = self.track
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let selected, let playing, selected.id != playing.id {
                    Picker("", selection: Binding(get: { subject ?? .playing }, set: { pinned = $0 })) {
                        Text("Playing").tag(Subject.playing)
                        Text("Selected").tag(Subject.selection)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if let track {
                    Text(track.title).font(Typeface.serif(20)).foregroundStyle(Palette.text)
                    Text("\(track.formatSummary) · \(track.displayArtist)").font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
                    content(for: track)
                } else {
                    Text("Select or play a track to analyze it.").font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                }
                if model.analysis.batchTotal > 1 { batchProgress }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: selected?.id) { pinned = nil }
        .onChange(of: playing?.id) { pinned = nil }
        .task(id: "\(track?.id ?? -1)-\(model.analysis.revision)") {
            stored = track.flatMap { model.library.storedAnalysis(for: $0) }
            if LaunchArguments().bool(forKey: "VespertineRunAnalysis"), let track, stored?.isCurrent != true,
               !model.analysis.isAnalyzing(track) { model.analysis.analyzeNow([track]) }
        }
    }

    @ViewBuilder
    private func content(for track: Track) -> some View {
        let busy = model.analysis.isAnalyzing(track)
        if track.isDSD || !track.isLossless {
            Text(track.isDSD ? "DSD sources don't have a PCM word length to check." : "Lossy files are what they say they are; analysis is for lossless files.")
                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
        } else if let stored {
            results(stored.analysis)
            HStack(spacing: 10) {
                Text(stored.isCurrent ? "Analyzed \(stored.analyzedAt.formatted(.relative(presentation: .named)))"
                                      : "From an older analysis or an earlier version of the file")
                    .font(Typeface.ui(10.5)).foregroundStyle(stored.isCurrent ? Palette.text3 : Palette.copper)
                Spacer()
                if busy { ProgressView().controlSize(.small).tint(Palette.brass) }
                Button(stored.isCurrent ? "Re-analyze" : "Update") { model.analysis.analyzeNow([track]) }
                    .buttonStyle(QuietButtonStyle(compact: true)).disabled(busy)
            }
        } else {
            Text("Decodes the file at its native rate and checks for zero-padded bits, upsampling, lossy origins and synthesized high frequencies. Nothing is modified.")
                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(busy ? "Analyzing…" : "Analyze") { model.analysis.analyzeNow([track]) }
                    .buttonStyle(BrassButtonStyle()).disabled(busy)
                if busy { ProgressView().controlSize(.small).tint(Palette.brass) }
            }
        }
    }

    private var batchProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Analyzing library").font(Typeface.ui(11, weight: .medium)).foregroundStyle(Palette.text2)
                Spacer()
                Text("\(model.analysis.completed)/\(model.analysis.batchTotal)").font(Typeface.mono(10)).foregroundStyle(Palette.text3)
                Button("Stop") { model.analysis.cancel() }.buttonStyle(QuietButtonStyle(compact: true))
            }
            ProgressView(value: Double(model.analysis.completed), total: Double(max(1, model.analysis.batchTotal)))
                .progressViewStyle(.linear).tint(Palette.brass)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func results(_ r: FileAnalysis) -> some View {
        let ok = r.verdict == .genuine
        // Two badges side by side when they fit the inspector, stacked otherwise.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { verdictBadges(r, ok: ok) }
            VStack(alignment: .leading, spacing: 6) { verdictBadges(r, ok: ok) }
        }
        Text(r.summary).font(Typeface.ui(12.5)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow { k("Claimed"); v(r.claimedBitDepth.map { "\($0)-bit" } ?? "—") }
            GridRow { k("Effective"); v(r.effectiveBitDepth.map { "\($0)-bit" } ?? "not checked") }
            GridRow { k("Recorded to"); v(String(format: "%.1f kHz of %@ kHz", r.bandwidthHz / 1000, SampleRate.format(r.sampleRate / 2))) }
            if let f = r.forensics {
                if let hz = f.cliffHz, f.cliffDropDB >= 12 {
                    GridRow { k("Steepest cutoff"); v(String(format: "%.1f kHz, %.0f dB drop in %d%% of frames", hz / 1000, f.cliffDropDB, Int(f.cliffConsistency * 100))) }
                }
                if r.verdict == .bandwidthExtended, let shelf = f.shelfHz {
                    let follows = f.shelfTracking.map { String(format: ", follows the music (r %.2f)", $0) } ?? ""
                    GridRow { k("Shelf"); v(String(format: "%.1f–%.1f kHz, %.1f dB/kHz", shelf / 1000, f.shelfEndHz / 1000, f.shelfSlope) + follows) }
                }
            }
            GridRow { k("Peak"); v(r.peakDBFS.isFinite ? String(format: "%.2f dBFS", r.peakDBFS) : "silent") }
            GridRow { k("Clipped samples"); v("\(r.clippedSamples)") }
            GridRow { k("Decoded"); v(String(format: "%.0f s", r.secondsAnalyzed)) }
        }
        SectionLabel(text: "Long-term spectrum").padding(.top, 6)
        SpectrumPlot(values: r.spectrum, nyquist: r.sampleRate / 2,
                     markers: markers(r)).frame(height: 140)
    }

    @ViewBuilder
    private func verdictBadges(_ r: FileAnalysis, ok: Bool) -> some View {
        StatusBadge(text: AnalysisVerdictText.badge(r.verdict), kind: ok ? .perfect : .converted)
        if r.version >= 2, r.verdict != .notApplicable {
            // Results from before version 3 weren't capped: a spectrum alone is never shown as high confidence.
            let confidence = r.version < 3 && r.verdict != .paddedBitDepth ? min(r.confidence, FileAnalyzer.spectralConfidenceCap) : r.confidence
            StatusBadge(text: confidence >= 0.8 ? "HIGH CONFIDENCE" : confidence >= 0.6 ? "LIKELY" : "POSSIBLE")
        }
    }

    private func markers(_ r: FileAnalysis) -> [SpectrumPlot.Marker] {
        guard let f = r.forensics, r.verdict != .genuine else { return [] }
        var m: [SpectrumPlot.Marker] = []
        if r.verdict == .bandwidthExtended, let shelf = f.shelfHz {
            m.append(.init(hz: shelf, label: "cutoff"))
            if f.shelfEndHz > shelf { m.append(.init(hz: f.shelfEndHz, label: "")) }
        } else if let hz = f.cliffHz {
            m.append(.init(hz: hz, label: "cutoff"))
        }
        return m
    }

    private func k(_ s: String) -> some View { Text(s).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3) }
    private func v(_ s: String) -> some View {
        Text(s).font(Typeface.mono(11)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
    }
}

/// Verdict wording shared by the inspector, track tags and filters. Spectral verdicts are questions: the
/// same evidence has innocent explanations, which each summary names.
enum AnalysisVerdictText {
    static func badge(_ v: FileAnalysis.Verdict) -> String {
        switch v {
        case .genuine: "GENUINE"
        case .paddedBitDepth: "PADDED BIT DEPTH"
        case .upsampled: "UPSAMPLED?"
        case .possibleLossyOrigin: "LOSSY ORIGIN?"
        case .bandwidthExtended: "SYNTHETIC HIGH FREQUENCIES?"
        case .notApplicable: "INCONCLUSIVE"
        }
    }
}

struct SpectrumPlot: View {
    struct Marker { var hz: Double; var label: String }
    let values: [Float]
    let nyquist: Double
    var markers: [Marker] = []

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let lo: Float = -150, hi: Float = -20
            func y(_ v: Float) -> CGFloat { size.height * (1 - CGFloat((max(lo, min(hi, v)) - lo) / (hi - lo))) }
            // Frequency gridlines (on to 40 and 80 kHz in hi-res files, so the empty range above a cutoff reads).
            // A label is left out where it would run into a marker or off the plot.
            let markerXs = markers.filter { $0.hz > 20 && $0.hz < nyquist }.map { size.width * CGFloat(log($0.hz / 20) / log(nyquist / 20)) }
            for f in [100.0, 1_000, 10_000, 20_000, 40_000, 80_000] where f < nyquist {
                let x = size.width * CGFloat(log(f / 20) / log(nyquist / 20))
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Palette.hairlineStrong), lineWidth: 1)
                let label = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
                let end = x + 3 + CGFloat(label.count) * 5.5
                guard end < size.width - 2, !markerXs.contains(where: { $0 > x - 3 && $0 < end + 3 }) else { continue }
                ctx.draw(Text(label).font(Typeface.mono(8.5)).foregroundStyle(Palette.text3),
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
            for m in markers where m.hz > 20 && m.hz < nyquist {
                let x = size.width * CGFloat(log(m.hz / 20) / log(nyquist / 20))
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Palette.copper), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if !m.label.isEmpty {
                    ctx.draw(Text(m.label).font(Typeface.mono(8.5)).foregroundStyle(Palette.copper),
                             at: CGPoint(x: x - 3, y: 8), anchor: .trailing)
                }
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
