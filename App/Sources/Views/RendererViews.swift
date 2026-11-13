//
// Vespertine: network renderers (UPnP Renderers (beta)): the Settings switch, the renderer's details under the output list,
// its volume lock, and its signal path. None of it shows while the switch is off. Renderer names are shown as they are.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio
import VespertineUPnP

struct RendererSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle(RendererSwitch.title, isOn: Binding(get: { model.settings.upnpRenderersFeature }, set: { model.setRenderersFeature($0) }))
            Text(RendererSwitch.explanation).font(.caption).foregroundStyle(.secondary)
            if let renderers = model.renderers {
                Group {
                    if renderers.searching {
                        Text("Looking for network players…")
                    } else if renderers.renderers.isEmpty {
                        Text("No network players found. They appear in the output list when they are on and on the same network.")
                    } else {
                        Text("Network players found: \(ListFormatter.localizedString(byJoining: renderers.renderers.map(\.name))). Choose one in the output list.",
                             comment: "%@ is a list of network player names.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let failure = renderers.failure {
                    Text(verbatim: failure).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text(RendererSwitch.title)
        }
    }
}

enum RendererText {
    /// The output list's second line for a renderer.
    static func detail(_ renderer: RendererDevice) -> String {
        renderer.kind.gapless
            ? String(localized: "\(renderer.kind.protocolName.localizedUppercase) · GAPLESS", comment: "Output list: a network player's protocol (OPENHOME, UPNP AV), then GAPLESS (short, uppercase)")
            : String(localized: "\(renderer.kind.protocolName.localizedUppercase) · GAPLESS NOT GUARANTEED", comment: "Output list: a network player's protocol, then that it may leave gaps between songs (short, uppercase)")
    }

    static var gaplessNotGuaranteed: String {
        String(localized: "Gapless: not guaranteed on this renderer", comment: "A network player without SetNextAVTransportURI: it may leave a gap between songs.")
    }

    /// Advice for any renderer, MPD-based ones named only as an example.
    static var advice: [String] {
        [
            String(localized: "Turn off resampling on the renderer, so it plays each song at its own rate."),
            String(localized: "Use its hardware volume, or none: software volume on the renderer changes the samples Vespertine sent (on MPD-based players such as moOde or Volumio, set the mixer to “hardware” or “none”)."),
            String(localized: "Turn off ReplayGain on the renderer; Vespertine applies its own when you ask it to."),
            String(localized: "Vespertine says what it sent. What the renderer then does can't be read back from here."),
        ]
    }
}

/// Under the output list while a network renderer is the chosen output: what it is, what it can do, and the advice.
struct RendererDetails: View {
    @Environment(AppModel.self) private var model
    let renderer: RendererDevice

    var body: some View {
        let d = renderer.description
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: renderer.name)
            Text(DeviceProfile.networkRenderer(protocolName: renderer.kind.protocolName).note ?? "")
                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                row(String(localized: "Model"), [d.manufacturer, d.modelName, d.modelNumber ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
                row(String(localized: "Address"), renderer.host)
                row(String(localized: "Control"), renderer.kind.protocolName)
                row(String(localized: "Services"), renderer.serviceNames.joined(separator: ", "))
                row(String(localized: "Gapless"), renderer.kind.gapless ? String(localized: "Yes") : RendererText.gaplessNotGuaranteed)
                row(String(localized: "Highest format"), maxFormat)
                if !renderer.capabilities.acceptedFormats.isEmpty {
                    row(String(localized: "Formats"), renderer.capabilities.acceptedFormats.joined(separator: ", "))
                }
            }
            if let warnings = model.player.signalPath?.renderer?.warnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(Typeface.ui(11)).foregroundStyle(Palette.copper)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            RendererEqualizerChoice(uid: renderer.uid)
            VStack(alignment: .leading, spacing: 4) {
                Text("For the best result").font(Typeface.ui(12))
                ForEach(RendererText.advice, id: \.self) { line in
                    Text("· " + line).font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var maxFormat: String {
        let caps = renderer.capabilities
        guard let rate = caps.maxSampleRate else { return String(localized: "Not stated by the renderer") }
        return caps.maxChannels.map { String(localized: "\(SampleRate.format(Double(rate))) kHz, \($0) channels (as stated)") }
            ?? String(localized: "\(SampleRate.format(Double(rate))) kHz (as stated)")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typeface.ui(11)).foregroundStyle(Palette.text3).frame(width: 96, alignment: .leading)
            Text(verbatim: value.isEmpty ? "—" : value).font(Typeface.mono(10.5)).foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The equalizer for a renderer, as for a device: on, the stream is processed (24-bit FLAC), off, the original file goes.
struct RendererEqualizerChoice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let uid: String

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Equalizer").font(Typeface.ui(12))
                Text("On, Vespertine sends the equalized song as 24-bit FLAC (lossless after processing) instead of the original file.")
                    .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker("Equalizer", selection: Binding(get: { settings.eqPreset(for: uid)?.id },
                                                       set: { settings.setEQPreset($0, for: uid); model.syncEngine() })) {
                    Text("Off", comment: "Equalizer choice: no equalizer").tag(UUID?.none)
                    if !settings.eqPresets.isEmpty { Divider() }
                    ForEach(settings.eqPresets) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit…") { openWindow(id: "equalizer") }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .font(Typeface.ui(12))
    }
}

/// The volume control for a renderer: locked at 100% (the original file goes, the renderer's volume is left alone), or
/// unlocked, Vespertine's digital volume (the stream is processed).
struct RendererVolumeControl: View {
    @Environment(AppModel.self) private var model
    let renderer: RendererDevice
    @State private var showOptions = false

    var body: some View {
        let settings = model.settings
        let unlocked = settings.rendererVolumeUnlocked.contains(renderer.uid)
        if unlocked {
            BrassSlider(value: Binding(get: { settings.appVolumeLevel(for: renderer.uid) },
                                       set: { settings.setAppVolumeLevel($0, for: renderer.uid); model.syncEngine() }),
                        tint: Palette.copper, showsThumb: false, accessibilityName: String(localized: "Digital volume"))
                .frame(width: 84)
        }
        Button { showOptions.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: unlocked ? "lock.open" : "lock.fill").font(.system(size: 9, weight: .semibold))
                Text(unlocked ? String(localized: "DIG", comment: "Short label: digital volume") : String(localized: "100% · LOCKED", comment: "Short label: a network player's volume is locked at 100% so the original file is sent"))
                    .font(Typeface.mono(9.5)).fixedSize()
                Image(systemName: "chevron.up").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(unlocked ? Palette.copper : Palette.brassHi)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(unlocked ? String(localized: "Digital volume in Vespertine: the song is sent processed (24-bit FLAC). Click to lock it at 100% again.")
                       : String(localized: "Volume locked at 100%: the original file is sent and the renderer's volume is left alone. Click to unlock."))
        .accessibilityLabel(unlocked ? String(localized: "Volume control in Vespertine") : String(localized: "Volume locked at 100%"))
        .popover(isPresented: $showOptions, arrowEdge: .top) { options(unlocked: unlocked) }
        .onChange(of: model.volumeNoteRequests) { showOptions = true }
    }

    private func options(unlocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: renderer.name)
            Text(unlocked
                 ? "Vespertine sets the volume: each song is decoded, its level changed in 64-bit with dither, and sent as 24-bit FLAC. Lock it to send the original files again."
                 : "Locked at 100%: Vespertine sends the original files and never touches the renderer's own volume. Set the level on your amplifier or the renderer. Unlocking lets Vespertine set it, which means decoding and re-encoding each song (lossless 24-bit FLAC), so it is no longer the original file.")
                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            Button(unlocked ? String(localized: "Lock at 100%") : String(localized: "Unlock Volume")) {
                model.settings.setRendererVolumeUnlocked(!unlocked, for: renderer.uid)
                model.syncEngine()
                showOptions = false
            }
        }
        .padding(14)
        .frame(width: 320)
        .environment(model)
    }
}

extension SignalPathView {
    /// The signal path of a song sent to a network renderer: what Vespertine did and sent; the renderer itself last, with what
    /// can't be known about it.
    static func rendererSteps(_ path: SignalPath, _ r: SignalPath.RendererStage) -> [Step] {
        var s: [Step] = []
        let src = path.source
        let format = src.bitDepth.map { String(localized: "\($0)-bit · \(SampleRate.format(src.sampleRate)) kHz") } ?? "\(SampleRate.format(src.sampleRate)) kHz"
        s.append(Step(title: String(localized: "Source", comment: "First step of the signal path: the file being played"), detail: src.codec, value: src.dsdName ?? format))
        let sent = r.sentBitDepth.map { "\($0)/\(SampleRate.format(r.sentSampleRate))" } ?? SampleRate.format(r.sentSampleRate)
        if r.passesThrough {
            s.append(Step(title: String(localized: "Sent as"), detail: String(localized: "The original file's bytes, untouched, from Vespertine's server"),
                          value: "\(r.sentCodec) \(sent)", tone: src.encoding == .lossy ? .plain : .good))
        } else {
            if !path.decoderName.isEmpty {
                s.append(Step(title: String(localized: "Decoder"), detail: path.decoderName, value: String(localized: "decoded")))
            }
            if let room = path.roomCorrection {
                s.append(Step(title: String(localized: "Room correction"), detail: room, value: String(localized: "on", comment: "A signal path step (equalizer, Spatial Audio) is switched on"), tone: .changed))
            }
            if let eq = path.equalizer {
                s.append(Step(title: String(localized: "Equalizer"), detail: String(localized: "\(eq) · 64-bit parametric"),
                              value: String(localized: "on", comment: "A signal path step (equalizer, Spatial Audio) is switched on"), tone: .changed))
            }
            if case .digital(let db) = path.volume {
                s.append(Step(title: String(localized: "Volume"), detail: String(localized: "64-bit digital, TPDF dither"),
                              value: "\(db.formatted(.number.precision(.fractionLength(1)))) dB", tone: .changed))
            }
            if let rg = path.replayGainDB, rg != 0 {
                s.append(Step(title: "ReplayGain", detail: String(localized: "Loudness normalisation"),
                              value: "\(rg.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) dB", tone: .changed))
            }
            s.append(Step(title: String(localized: "Sent as"), detail: String(localized: "24-bit FLAC at the source rate, lossless after processing"),
                          value: "FLAC \(sent)", tone: .changed))
        }
        s.append(Step(title: r.name, detail: "\(r.protocolName) · " + (r.gapless ? String(localized: "gapless") : RendererText.gaplessNotGuaranteed),
                      value: String(localized: "not read back", comment: "Signal path: what a network player does with the stream can't be read back")))
        for warning in r.warnings {
            s.append(Step(title: String(localized: "Renderer limit"), detail: warning, value: "", tone: .changed))
        }
        return s
    }
}
