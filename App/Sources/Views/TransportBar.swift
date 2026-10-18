//
// Vespertine — transport bar, output device picker, queue.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineAudio
import VespertineLibrary
import SwiftUI

struct TransportBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showDevices = false

    var body: some View {
        HStack(spacing: 0) {
            nowPlaying.frame(width: 320, alignment: .leading)
            Spacer(minLength: 12)
            TransportControls()
                .frame(maxWidth: 600)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                DeviceChip(showDevices: $showDevices)
                VolumeControl()
                Button { model.showQueue.toggle() } label: { Image(systemName: "list.bullet").font(.system(size: 14)) }
                    .buttonStyle(TransportIconStyle(active: model.showQueue))
                    .help("Up Next (⌥⌘U)")
                    .accessibilityLabel("Up Next")
                Button { openWindow(id: "mini") } label: { Image(systemName: "pip").font(.system(size: 14)) }
                    .buttonStyle(TransportIconStyle())
                    .help("Mini Player (⇧⌘M)")
                    .accessibilityLabel("Mini Player")
                Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right").font(.system(size: 14)) }
                    .buttonStyle(TransportIconStyle(active: model.showInspector))
                    .help("Inspector (⌥⌘I)")
                    .accessibilityLabel("Inspector")
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .frame(height: 76)
        .background(LinearGradient(colors: [Color(hex: 0x121215), Color(hex: 0x0E0E10)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { Hairline() }
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            ArtworkView(key: model.artworkKey(model.player.current?.track), size: 160, cornerRadius: 5)
                .frame(width: 46, height: 46)
            if let track = model.player.current?.track {
                Button {
                    model.sidebar = .albums
                    model.path = []
                    model.openAlbum(track.albumKey)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(Typeface.serif(14)).foregroundStyle(Palette.text).lineLimit(1)
                        Text("\(track.displayArtist.libraryDisplayName) — \(track.displayAlbum.libraryDisplayName)").font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(track.title), \(track.displayArtist.libraryDisplayName), \(track.displayAlbum.libraryDisplayName)")
                .accessibilityHint("Opens the album")
                FavoriteButton(track: track)
            } else {
                Text("Not Playing").font(Typeface.serif(14)).foregroundStyle(Palette.text3)
            }
        }
    }
}

struct TransportControls: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        @Bindable var player = model.player
        VStack(spacing: compact ? 4 : 6) {
            HStack(spacing: compact ? 14 : 22) {
                if !compact {
                    Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").font(.system(size: 13)) }
                        .buttonStyle(TransportIconStyle(active: player.shuffle)).help("Shuffle")
                        .accessibilityLabel("Shuffle")
                        .accessibilityValue(player.shuffle ? String(localized: "On", comment: "Shuffle state") : String(localized: "Off", comment: "Shuffle state"))
                }
                Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 15)) }
                    .buttonStyle(TransportIconStyle())
                    .accessibilityLabel("Previous")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying || player.waitingForDevice != nil ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 12 : 14))
                        .foregroundStyle(Color(hex: 0x1A140A))
                        .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                        .background(Palette.brassGradient, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5).blendMode(.overlay))
                        .shadow(color: Palette.brass.opacity(0.28), radius: 9, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [.option])
                .accessibilityLabel(player.isPlaying || player.waitingForDevice != nil ? String(localized: "Pause", comment: "Button: pause playback") : String(localized: "Play", comment: "Button: start playback"))
                Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 15)) }
                    .buttonStyle(TransportIconStyle())
                    .accessibilityLabel("Next")
                if !compact {
                    Button {
                        player.repeatMode = switch player.repeatMode { case .off: .all; case .all: .one; case .one: .off }
                    } label: { Image(systemName: player.repeatMode.symbol).font(.system(size: 13)) }
                        .buttonStyle(TransportIconStyle(active: player.repeatMode != .off)).help("Repeat")
                        .accessibilityLabel("Repeat")
                        .accessibilityValue(player.repeatMode.spokenName)
                }
            }
            if !compact { Scrubber() }
        }
        // Playback controls and the timeline keep their left-to-right order in right-to-left languages too, as
        // Apple's own players do: they follow the direction of time, not of the text.
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct Scrubber: View {
    @Environment(AppModel.self) private var model
    @State private var dragValue: Double?

    var body: some View {
        let player = model.player
        let duration = max(player.duration, 0.001)
        let shown = dragValue.map { $0 * duration } ?? player.position
        HStack(spacing: 10) {
            Text(shown.clock).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3).frame(width: 44, alignment: .trailing)
            BrassSlider(value: Binding(get: { dragValue ?? (player.position / duration) }, set: { dragValue = $0 }),
                        showsThumb: player.current != nil,
                        accessibilityName: String(localized: "Position", comment: "VoiceOver name of the playback position slider"),
                        accessibilityValueText: { String(localized: "\(($0 * duration).clock) of \(duration.clock)", comment: "Playback position: elapsed of total time") },
                        accessibilityStep: min(1, 5 / duration)) { editing in
                if !editing, let v = dragValue {
                    player.seek(to: v * duration)
                    dragValue = nil
                }
            }
            .disabled(player.current == nil)
            Text("\u{2066}−" + max(0, duration - shown).clock + "\u{2069}").font(Typeface.mono(10.5)).foregroundStyle(Palette.text3).frame(width: 48, alignment: .leading)
        }
    }
}

// MARK: - Device chip & picker

struct DeviceChip: View {
    @Environment(AppModel.self) private var model
    @Binding var showDevices: Bool

    var body: some View {
        let device = model.activeDevice
        let path = model.player.signalPath
        Button { showDevices.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: device?.profile.symbol ?? (model.missingChosenOutput == nil ? "hifispeaker" : "cable.connector.slash"))
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.brassHi)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device?.name ?? model.missingChosenOutput ?? String(localized: "No Output")).font(Typeface.ui(12)).foregroundStyle(Palette.text).lineLimit(1)
                    Text(chipDetail(device, path)).font(Typeface.mono(9.5)).foregroundStyle(path.map { $0.isBitPerfect ? Palette.brassHi : Palette.copper } ?? Palette.text3)
                        .lineLimit(1)
                }
                .frame(maxWidth: 150, alignment: .leading)
                if let path {
                    if path.isBitPerfect {
                        Circle().fill(Palette.brassHi).frame(width: 6, height: 6).shadow(color: Palette.brass, radius: 4)
                    } else {
                        Circle().strokeBorder(Palette.copper, lineWidth: 1.5).frame(width: 7, height: 7)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairlineStrong))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(standIn.map { String(localized: "Output device: \(device?.name ?? "") plays while \($0) isn’t connected", comment: "Both are audio output device names.") }
              ?? String(localized: "Output device"))
        // Bit-perfect or converted is said in words too, not only by the colour and the dot.
        .accessibilityLabel(device.map { String(localized: "Output device, \($0.name)") } ?? String(localized: "Output device, none"))
        .accessibilityValue(path.map {
            $0.isBitPerfect ? String(localized: "Bit-perfect, \(chipDetail(device, $0))") : String(localized: "Converted, \(chipDetail(device, $0))")
        } ?? "")
        .popover(isPresented: $showDevices, arrowEdge: .top) {
            DevicePicker().environment(model).frame(width: 360)
        }
    }

    /// The chosen output that isn't connected, while another one plays (or would play) in its place.
    private var standIn: String? { model.activeDevice == nil ? nil : model.missingChosenOutput }

    private func chipDetail(_ device: OutputDevice?, _ path: SignalPath?) -> String {
        if let path {
            return path.applied.exclusive
                ? String(localized: "\(path.deviceFormatShort) · EXCL", comment: "Device chip: format, then EXCL = exclusive access (short, uppercase)")
                : String(localized: "\(path.deviceFormatShort) · SHARED", comment: "Device chip: format, then SHARED = shared with other apps (short, uppercase)")
        }
        guard let device else { return model.missingChosenOutput == nil ? "—" : String(localized: "NOT CONNECTED", comment: "Device chip: the chosen output isn't connected (short, uppercase)") }
        return standIn == nil
            ? String(localized: "\(SampleRate.format(device.nominalSampleRate)) kHz · IDLE", comment: "Device chip: the device's sample rate, then IDLE (short, uppercase)")
            : String(localized: "\(SampleRate.format(device.nominalSampleRate)) kHz · STANDING IN", comment: "Device chip: the device's sample rate, then STANDING IN (short, uppercase): it plays in place of the chosen output, which isn't connected")
    }
}

struct DevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: String(localized: "Output", comment: "Header of the output device list")).padding(.horizontal, 8).padding(.bottom, 4)
            deviceRow(nil, name: String(localized: "System Default"), detail: String(localized: "FOLLOWS SOUND SETTINGS"), symbol: "gearshape", selected: model.settings.selectedDeviceUID == nil)
            if let missing = model.missingChosenOutput, let uid = model.settings.selectedDeviceUID {
                // Still the chosen one: playback goes back to it when it's connected again.
                deviceRow(uid, name: missing,
                          detail: model.plannedDevice.map { String(localized: "NOT CONNECTED · USING \($0.name.localizedUppercase)", comment: "Output list: the chosen device is missing; %@ is the device playing in its place") }
                              ?? String(localized: "NOT CONNECTED · WAITING FOR IT", comment: "Output list: the chosen device is missing and playback waits for it"),
                          symbol: "cable.connector.slash", selected: true)
            }
            ForEach(model.devices.devices) { d in
                deviceRow(d.uid, name: d.name, detail: "\(d.profile.tag) · \(d.rangeSummary)", symbol: d.profile.symbol,
                          selected: model.settings.selectedDeviceUID == d.uid)
            }
            if let device = model.activeDevice {
                Hairline().padding(.vertical, 8)
                DeviceSettings(device: device)
            }
        }
        .padding(12)
    }

    private func deviceRow(_ uid: String?, name: String, detail: String, symbol: String, selected: Bool) -> some View {
        Button { model.selectDevice(uid) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Palette.brassHi : Palette.text2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Typeface.ui(12.5)).foregroundStyle(Palette.text)
                    Text(detail).font(Typeface.mono(9.5)).foregroundStyle(Palette.text3).lineLimit(1)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.brassHi) }
            }
            .padding(8)
            .background(selected ? Palette.brass.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DeviceSettings: View {
    @Environment(AppModel.self) private var model
    let device: OutputDevice

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: device.name)
            if let note = device.profile.note {
                Text(note).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Sample rate").layoutPriority(1)
                Spacer()
                Picker("Sample rate", selection: Binding(get: { settings.rateChoice(for: device.uid) },
                                              set: { settings.setRateChoice($0, for: device.uid); model.syncEngine() })) {
                    Text(RateChoice.match.label).tag(RateChoice.match)
                    Text(RateChoice.maximum.label).tag(RateChoice.maximum)
                    Divider()
                    ForEach(device.capabilities.sampleRates, id: \.self) { r in
                        Text(RateChoice.fixed(r).label).tag(RateChoice.fixed(r))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 120)
            }
            .font(Typeface.ui(12))
            Toggle(isOn: Binding(get: { settings.exclusiveMode }, set: { settings.exclusiveMode = $0; model.syncEngine() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Exclusive access").font(Typeface.ui(12))
                    (device.alwaysShared
                         ? Text("Not on the Mac's own speakers and headphone jack: they always play shared, so the volume keys keep working.")
                         : settings.relayVolumeKeys
                         ? Text("Other apps are silenced on this device. Volume keys and Control Center still adjust it.")
                         : Text("Other apps are silenced on this device. Volume keys adjust it only when Settings › Playback allows it."))
                        .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            if !device.hasHardwareVolume {
                AppVolumeToggle(device: device)
            }
            EqualizerChoice(device: device)
            // Multichannel music (5.1, 7.1…): Spatial Audio on headphones, all channels or a downmix elsewhere.
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Spatial Audio").font(Typeface.ui(12))
                    (device.capabilities.outputChannels > 2
                         ? Text("For multichannel music. Off sends every channel to this device's speakers.")
                         : Text("For multichannel music. Off plays a standard stereo downmix."))
                        .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer()
                Picker("Spatial Audio", selection: Binding(get: { model.engineSpatialMode(for: device) },
                                              set: { settings.spatialModes[device.uid] = $0.rawValue; model.syncEngine() })) {
                    ForEach(SpatialMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(minWidth: 120)
            }
            .font(Typeface.ui(12))
            if device.transport == .usb || device.transport == .thunderbolt {
                Toggle(isOn: Binding(get: { settings.dopDeviceUIDs.contains(device.uid) },
                                     set: { on in
                                         if on { settings.dopDeviceUIDs.insert(device.uid) } else { settings.dopDeviceUIDs.remove(device.uid) }
                                         model.syncEngine()
                                     })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DSD over PCM (DoP)").font(Typeface.ui(12))
                        Text("Only turn this on if your DAC supports DoP. Otherwise DSD is converted to PCM.").font(Typeface.ui(10.5)).foregroundStyle(Palette.text3)
                    }
                }
                .toggleStyle(.switch).controlSize(.mini)
            }
            if [.hdmi, .displayPort, .usb, .thunderbolt, .pci, .fireWire].contains(device.transport) {
                Toggle(isOn: Binding(get: { settings.bitstreamDeviceUIDs.contains(device.uid) },
                                     set: { on in
                                         if on { settings.bitstreamDeviceUIDs.insert(device.uid) } else { settings.bitstreamDeviceUIDs.remove(device.uid) }
                                         model.syncEngine()
                                     })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Send Dolby and DTS to a receiver (bitstream)").font(Typeface.ui(12))
                        Text("For an AV receiver or soundbar on HDMI or optical: it decodes Dolby Digital, Dolby Digital Plus (Atmos included, HDMI only) and DTS itself. Only turn this on if one is connected; anything else plays the bitstream as loud noise.")
                            .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3)
                    }
                }
                .toggleStyle(.switch).controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
    }
}

struct VolumeControl: View {
    @Environment(AppModel.self) private var model
    @State private var showOptions = false

    var body: some View {
        let device = model.activeDevice
        let settings = model.settings
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(Palette.text2)
            if device?.hasHardwareVolume == true, let v = model.devices.hardwareVolume {
                BrassSlider(value: Binding(get: { Double(v) }, set: { model.devices.setHardwareVolume(Float($0)) }),
                            tint: Palette.text2, showsThumb: false, accessibilityName: String(localized: "Hardware volume"))
                    .frame(width: 72)
                Text("HW", comment: "Short label: hardware volume").font(Typeface.mono(9.5)).fixedSize().foregroundStyle(Palette.text3).help("Hardware volume on the device; samples are untouched")
            } else if let device, settings.usesAppVolume(device.uid) {
                BrassSlider(value: Binding(get: { settings.appVolumeLevel(for: device.uid) },
                                           set: { settings.setAppVolumeLevel($0, for: device.uid); model.syncEngine() }),
                            tint: Palette.copper, showsThumb: false, accessibilityName: String(localized: "Digital volume"))
                    .frame(width: 84)
                Button { showOptions.toggle() } label: {
                    HStack(spacing: 3) {
                        Text("DIG", comment: "Short label: digital volume").font(Typeface.mono(9.5)).fixedSize().foregroundStyle(Palette.copper)
                        Image(systemName: "chevron.up").font(.system(size: 7, weight: .semibold)).foregroundStyle(Palette.copper)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Digital volume (64-bit, dithered). Not bit-perfect below 100%.")
                .popover(isPresented: $showOptions, arrowEdge: .top) { options(device) }
            } else if let device {
                // A fixed-volume output (HDMI, optical, a line-out DAC): the way to Vespertine's own volume.
                Button { showOptions.toggle() } label: {
                    HStack(spacing: 3) {
                        Text("FIXED · USE DAC").font(Typeface.mono(9.5)).fixedSize().foregroundStyle(Palette.text3)
                        Image(systemName: "chevron.up").font(.system(size: 7, weight: .semibold)).foregroundStyle(Palette.text3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("This output has no volume control of its own. Click to set the volume in Vespertine instead (not bit-perfect below 100%).")
                .popover(isPresented: $showOptions, arrowEdge: .top) { options(device) }
            }
        }
    }

    private func options(_ device: OutputDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: device.name)
            AppVolumeToggle(device: device)
        }
        .padding(14)
        .frame(width: 320)
        .environment(model)
    }
}

/// "Volume control in Vespertine" for an output with no volume of its own, such as HDMI or a line-out DAC.
struct AppVolumeToggle: View {
    @Environment(AppModel.self) private var model
    let device: OutputDevice

    var body: some View {
        let settings = model.settings
        Toggle(isOn: Binding(get: { settings.usesAppVolume(device.uid) },
                             set: { settings.setUsesAppVolume($0, for: device.uid); model.syncEngine() })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Volume control in Vespertine").font(Typeface.ui(12))
                Text("This output has no volume of its own. On: set the level with Vespertine's slider, in 64-bit with dither; below 100% the output is no longer bit-perfect. Off: the signal stays untouched, and you set the level on the DAC, amplifier or TV.")
                    .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch).controlSize(.mini)
    }
}
