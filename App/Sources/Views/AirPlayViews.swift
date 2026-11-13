//
// Vespertine: AirPlay receivers (AirPlay Players (beta)): the Settings switch, the receiver's details under the output list, its
// volume (the receiver's own by default, Vespertine's digital volume on request), and its signal path. None of it shows while
// the switch is off.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAirPlay
import VespertineAudio

struct AirPlaySettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle(AirPlaySwitch.title, isOn: Binding(get: { model.settings.airPlayPlayersFeature }, set: { model.setAirPlayFeature($0) }))
            Text(AirPlaySwitch.explanation).font(.caption).foregroundStyle(.secondary)
            if let airPlay = model.airPlay {
                Group {
                    if airPlay.searching, airPlay.devices.isEmpty {
                        Text("Looking for AirPlay receivers…")
                    } else if airPlay.devices.isEmpty {
                        Text("No AirPlay receivers found. Check it's on and on the same network as this Mac.")
                    } else {
                        Text("AirPlay receivers found: \(ListFormatter.localizedString(byJoining: airPlay.devices.map(\.name))). Choose one in the output list.",
                             comment: "%@ is a list of AirPlay receiver names.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(AirPlaySwitch.title)
        }
    }
}

enum AirPlayText {
    /// The output list's second line for a receiver.
    static func detail(_ device: AirPlayDevice) -> String {
        switch device.support {
        case .supported(.none): String(localized: "AIRPLAY · ALAC 16/44.1", comment: "Output list: an AirPlay receiver Vespertine sends ALAC 16-bit / 44.1 kHz to (short, uppercase)")
        case .supported(.rsa): String(localized: "AIRPLAY · ALAC 16/44.1 · ENCRYPTED", comment: "Output list: an AirPlay receiver that asks for encrypted audio (short, uppercase)")
        case .unsupported(let reason): reason.localizedUppercase
        }
    }

    static var advice: [String] {
        [
            String(localized: "AirPlay carries 16-bit / 44.1 kHz. CD-quality files go exactly as they are; for hi-res, a network player (UPnP) receives the original file."),
            String(localized: "The receiver keeps in step with this Mac's clock by adding or dropping samples now and then. On shairport-sync (moOde, Volumio), “disable_synchronization” or the pipe backend leaves them alone."),
            String(localized: "Use a hardware mixer or no volume on the receiver (shairport-sync: “ignore_volume_control” or a hardware “mixer_control_name”): software volume there changes the samples Vespertine sent."),
            String(localized: "On shairport-sync, the metadata “sdsc” and “odsc” say what it received and what it plays out."),
        ]
    }
}

/// Under the output list while an AirPlay receiver is the chosen output.
struct AirPlayDetails: View {
    @Environment(AppModel.self) private var model
    let device: AirPlayDevice

    var body: some View {
        let raop = device.raop
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: device.name)
            Text(DeviceProfile.networkRenderer(protocolName: "AirPlay").note ?? "")
                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                row(String(localized: "Model"), device.model ?? "")
                row(String(localized: "Protocol"), String(localized: "AirPlay 1 (RAOP)"))
                row(String(localized: "Sent as"), String(localized: "ALAC 16-bit / 44.1 kHz, stereo"))
                row(String(localized: "Encryption"), device.support == .supported(.rsa) ? String(localized: "RSA / AES (the receiver asks for it)") : String(localized: "None"))
                row(String(localized: "Titles"), raop?.metadata.contains(0) == true ? String(localized: "Sent") : String(localized: "Not taken by the receiver"))
                if let version = raop?.version { row(String(localized: "Version"), version) }
                row(String(localized: "Device ID"), device.deviceID)
            }
            if let warnings = model.player.signalPath?.renderer?.warnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(Typeface.ui(11)).foregroundStyle(Palette.copper)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            RendererEqualizerChoice(uid: device.uid)
            VStack(alignment: .leading, spacing: 4) {
                Text("For the best result").font(Typeface.ui(12))
                ForEach(AirPlayText.advice, id: \.self) { line in
                    Text("· " + line).font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typeface.ui(11)).foregroundStyle(Palette.text3).frame(width: 96, alignment: .leading)
            Text(verbatim: value.isEmpty ? "—" : value).font(Typeface.mono(10.5)).foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The volume for an AirPlay receiver. By default the level is the receiver's own volume, sent as AirPlay metadata, so
/// Vespertine's samples stay as they are (the lock is closed); on request Vespertine sets it digitally (the song is converted)
/// and the receiver stays at full volume.
struct AirPlayVolumeControl: View {
    @Environment(AppModel.self) private var model
    let device: AirPlayDevice
    @State private var showOptions = false

    var body: some View {
        let settings = model.settings
        let digital = settings.airPlayDigitalVolume.contains(device.uid)
        BrassSlider(value: Binding(get: { settings.airPlayLevel(uid: device.uid) },
                                   set: { settings.setAppVolumeLevel($0, for: device.uid); model.syncEngine() }),
                    tint: digital ? Palette.copper : Palette.text2, showsThumb: false,
                    accessibilityName: digital ? String(localized: "Digital volume") : String(localized: "Receiver volume"))
            .frame(width: 84)
        Button { showOptions.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: digital ? "lock.open" : "lock.fill").font(.system(size: 9, weight: .semibold))
                Text(digital ? String(localized: "DIG", comment: "Short label: digital volume") : String(localized: "AIR", comment: "Short label: the AirPlay receiver's own volume"))
                    .font(Typeface.mono(9.5)).fixedSize()
                Image(systemName: "chevron.up").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(digital ? Palette.copper : Palette.brassHi)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(digital ? String(localized: "Digital volume in Vespertine: the song is converted. Click to give the volume back to the receiver.")
                      : String(localized: "The receiver's own volume: Vespertine's samples are sent as they are. Click for options."))
        .accessibilityLabel(digital ? String(localized: "Volume control in Vespertine") : String(localized: "Receiver volume"))
        .popover(isPresented: $showOptions, arrowEdge: .top) { options(digital: digital) }
        .onChange(of: model.volumeNoteRequests) { showOptions = true }
    }

    private func options(digital: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: device.name)
            Text(digital
                 ? "Vespertine sets the volume: each song's level is changed in 64-bit and dithered to 16 bits, so it is converted. The receiver stays at full volume."
                 : "The slider sets the receiver's own volume, sent as AirPlay metadata: the samples Vespertine sends stay as they are. The receiver may change them when it lowers the volume itself (most do, in software).")
                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            Button(digital ? String(localized: "Use the Receiver's Volume") : String(localized: "Use Vespertine's Volume")) {
                model.settings.setAirPlayDigitalVolume(!digital, for: device.uid)
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
    /// The signal path of a song sent to an AirPlay receiver: what Vespertine did to reach ALAC 16/44.1, then the receiver,
    /// with what can't be known about it.
    static func airPlaySteps(_ path: SignalPath, _ r: SignalPath.RendererStage) -> [Step] {
        var s: [Step] = []
        let src = path.source
        let format = src.bitDepth.map { String(localized: "\($0)-bit · \(SampleRate.format(src.sampleRate)) kHz") } ?? "\(SampleRate.format(src.sampleRate)) kHz"
        s.append(Step(title: String(localized: "Source", comment: "First step of the signal path: the file being played"), detail: src.codec, value: src.dsdName ?? format))
        if !path.decoderName.isEmpty {
            s.append(Step(title: String(localized: "Decoder"), detail: path.decoderName, value: String(localized: "decoded")))
        }
        let changed = String(localized: "on", comment: "A signal path step (equalizer, Spatial Audio) is switched on")
        for step in r.processing {
            switch step {
            case .roomCorrection: s.append(Step(title: String(localized: "Room correction"), detail: path.roomCorrection ?? "", value: changed, tone: .changed))
            case .equalizer: s.append(Step(title: String(localized: "Equalizer"), detail: String(localized: "\(path.equalizer ?? "") · 64-bit parametric"), value: changed, tone: .changed))
            case .volume:
                if case .digital(let db) = path.volume {
                    s.append(Step(title: String(localized: "Volume"), detail: String(localized: "64-bit digital"), value: "\(db.formatted(.number.precision(.fractionLength(1)))) dB", tone: .changed))
                }
            case .replayGain:
                s.append(Step(title: "ReplayGain", detail: String(localized: "Loudness normalisation"),
                              value: "\((path.replayGainDB ?? 0).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) dB", tone: .changed))
            case .dsdToPCM: s.append(Step(title: String(localized: "DSD to PCM"), detail: String(localized: "The engine's DSD conversion"), value: "PCM", tone: .changed))
            case .resampled: s.append(Step(title: String(localized: "Resampled"), detail: String(localized: "Mastering-quality sample rate converter"), value: "44.1 kHz", tone: .changed))
            case .downmix: s.append(Step(title: String(localized: "Downmix"), detail: String(localized: "\(ChannelLayouts.name(channels: src.channels)) to stereo"), value: "2.0", tone: .changed))
            case .dithered: s.append(Step(title: String(localized: "Dithered"), detail: String(localized: "To 16 bits with TPDF dither"), value: "16-bit", tone: .changed))
            case .format: break
            }
        }
        s.append(Step(title: String(localized: "Sent as"),
                      detail: r.passesThrough ? String(localized: "The file's own samples, unchanged, from Vespertine (Apple Lossless)") : String(localized: "Apple Lossless, from Vespertine"),
                      value: "ALAC \(r.sentFormatShort)", tone: r.passesThrough ? .good : .changed))
        s.append(Step(title: r.name, detail: String(localized: "AirPlay receiver · follows this Mac's clock by adding or dropping samples; may apply its own volume"),
                      value: String(localized: "not verified", comment: "Signal path: what a network player does with the stream isn't verified (it can't be read back)")))
        for warning in r.warnings {
            s.append(Step(title: String(localized: "Receiver", comment: "Signal path: something the AirPlay receiver does"), detail: warning, value: "", tone: .changed))
        }
        return s
    }
}
