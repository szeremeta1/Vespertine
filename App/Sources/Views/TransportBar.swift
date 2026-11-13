//
// Vespertine: transport bar, output device picker, queue.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineAudio
import VespertineLibrary
import VespertineUPnP
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
                TransitionsButton()
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
                    TransportPlayPauseFace(loading: player.loading, playing: player.isPlaying || player.waitingForDevice != nil, compact: compact)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [.option])
                .accessibilityLabel(player.canCancelLoading ? String(localized: "Cancel") : player.isPlaying || player.waitingForDevice != nil ? String(localized: "Pause", comment: "Button: pause playback") : String(localized: "Play", comment: "Button: start playback"))
                .accessibilityValue(player.loading ? String(localized: "BUFFERING…") : "")
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
        let renderer = model.chosenRenderer
        let path = model.player.signalPath
        Button { showDevices.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: chipSymbol(device, renderer))
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.brassHi)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chipName(device, renderer)).font(Typeface.ui(12)).foregroundStyle(Palette.text).lineLimit(1)
                    Text(chipDetail(device, path)).font(Typeface.mono(9.5))
                        .foregroundStyle(renderer == nil && device?.isInCallMode == true ? Palette.copper : chipTint(path))
                        .lineLimit(1)
                }
                .frame(maxWidth: 150, alignment: .leading)
                if let path {
                    if path.isUntouched {
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
        .help(model.bluetoothCallMode?.explanation ?? standIn.map { String(localized: "Output device: \(device?.name ?? "") plays while \($0) isn’t connected", comment: "Both are audio output device names.") }
              ?? String(localized: "Output device"))
        // Bit-perfect or converted is said in words too, not only by the colour and the dot.
        .accessibilityLabel((renderer?.name ?? device?.name).map { String(localized: "Output device, \($0)") } ?? String(localized: "Output device, none"))
        .accessibilityValue(path.map {
            $0.renderer != nil ? "\($0.statusLine), \(chipDetail(device, $0))"
                : $0.isBitPerfect ? String(localized: "Bit-perfect, \(chipDetail(device, $0))") : String(localized: "Converted, \(chipDetail(device, $0))")
        } ?? "")
        .popover(isPresented: $showDevices, arrowEdge: .top) {
            ScrollView {
                DevicePicker().environment(model)
            }
            .scrollIndicators(.visible)
            .frame(width: 360, height: 560)
        }
    }

    /// The chosen output that isn't connected, while another one plays (or would play) in its place.
    private var standIn: String? { model.activeDevice == nil ? nil : model.missingChosenOutput }

    private func chipSymbol(_ device: OutputDevice?, _ renderer: RendererDevice?) -> String {
        if renderer != nil { return "hifireceiver" }
        return device?.profile.symbol ?? (model.missingChosenOutput == nil ? "hifispeaker" : "cable.connector.slash")
    }

    private func chipName(_ device: OutputDevice?, _ renderer: RendererDevice?) -> String {
        renderer?.name ?? device?.name ?? model.missingChosenOutput ?? String(localized: "No Output")
    }

    private func chipTint(_ path: SignalPath?) -> Color {
        guard let path else { return Palette.text3 }
        return path.isUntouched ? Palette.brassHi : Palette.copper
    }

    private func chipDetail(_ device: OutputDevice?, _ path: SignalPath?) -> String {
        if let path, let renderer = path.renderer {
            return renderer.passesThrough
                ? String(localized: "\(path.deviceFormatShort) · SENT", comment: "Device chip: the format sent to a network player as the original file (short, uppercase)")
                : String(localized: "\(path.deviceFormatShort) · PROCESSED", comment: "Device chip: the format sent to a network player after Vespertine's processing (short, uppercase)")
        }
        if let renderer = model.chosenRenderer {
            return String(localized: "\(renderer.kind.protocolName.localizedUppercase) · IDLE", comment: "Device chip: a network player chosen, nothing playing (short, uppercase)")
        }
        if let path {
            return path.applied.exclusive
                ? String(localized: "\(path.deviceFormatShort) · EXCL", comment: "Device chip: format, then EXCL = exclusive access (short, uppercase)")
                : String(localized: "\(path.deviceFormatShort) · SHARED", comment: "Device chip: format, then SHARED = shared with other apps (short, uppercase)")
        }
        guard let device else { return model.missingChosenOutput == nil ? "—" : String(localized: "NOT CONNECTED", comment: "Device chip: the chosen output isn't connected (short, uppercase)") }
        let rate = SampleRate.format(device.nominalSampleRate)
        switch DeviceChipState.of(device, systemRendering: model.player.systemRendering != nil, standingIn: standIn != nil) {
        case .callMode:
            return String(localized: "\(rate) kHz · CALL MODE", comment: "Device chip: the Bluetooth headset's rate, then CALL MODE (short, uppercase): an app has its microphone open, so macOS plays at phone quality")
        case .systemRenders:
            return String(localized: "\(rate) kHz · MACOS", comment: "Device chip: the device's rate, then MACOS (short, uppercase): macOS's own renderer is playing (Dolby Atmos)")
        case .standingIn:
            return String(localized: "\(rate) kHz · STANDING IN", comment: "Device chip: the device's sample rate, then STANDING IN (short, uppercase): it plays in place of the chosen output, which isn't connected")
        case .idle:
            return String(localized: "\(rate) kHz · IDLE", comment: "Device chip: the device's sample rate, then IDLE (short, uppercase)")
        }
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
                if model.rendererChosen {
                    // A network renderer that isn't answering: nothing plays in its place.
                    deviceRow(uid, name: missing, detail: String(localized: "NOT RESPONDING", comment: "Output list: the chosen network player doesn't answer (short, uppercase)"),
                              symbol: "hifireceiver", selected: true)
                        .opacity(0.6)
                } else {
                    deviceRow(uid, name: missing,
                              detail: model.plannedDevice.map { String(localized: "NOT CONNECTED · USING \($0.name.localizedUppercase)", comment: "Output list: the chosen device is missing; %@ is the device playing in its place") }
                                  ?? String(localized: "NOT CONNECTED · WAITING FOR IT", comment: "Output list: the chosen device is missing and playback waits for it"),
                              symbol: "cable.connector.slash", selected: true)
                }
            }
            ForEach(model.devices.devices) { d in
                deviceRow(d.uid, name: d.name, detail: "\(d.profile.tag) · \(d.rangeSummary)", symbol: d.profile.symbol,
                          selected: model.settings.selectedDeviceUID == d.uid)
            }
            // Speaker groups (beta, behind their Settings switch): chosen like an output, ready when all of their outputs are connected.
            if let groups = model.speakerGroups {
                ForEach(GroupOutputRows.rows(groups: groups.groups, devices: model.devices.devices)) { row in
                    deviceRow(row.uid, name: row.name, detail: row.detail, symbol: "hifispeaker.2", selected: model.settings.selectedDeviceUID == row.uid)
                        .opacity(row.isReady ? 1 : 0.6)
                }
            }
            // Network players (UPnP Renderers (beta), behind their Settings switch).
            if let renderers = model.renderers {
                Hairline().padding(.vertical, 8)
                SectionLabel(text: String(localized: "Network players", comment: "Header of the network renderers in the output list")).padding(.horizontal, 8).padding(.bottom, 4)
                if renderers.renderers.isEmpty {
                    Text(renderers.searching ? String(localized: "SEARCHING…") : String(localized: "NONE FOUND ON THIS NETWORK"))
                        .font(Typeface.mono(9.5)).foregroundStyle(Palette.text3).padding(.horizontal, 8)
                }
                ForEach(renderers.renderers) { r in
                    deviceRow(r.uid, name: r.name, detail: RendererText.detail(r), symbol: "hifireceiver", selected: model.settings.selectedDeviceUID == r.uid)
                }
            }
            if let renderer = model.chosenRenderer {
                Hairline().padding(.vertical, 8)
                RendererDetails(renderer: renderer)
            } else if let device = model.activeDevice {
                Hairline().padding(.vertical, 8)
                DeviceSettings(device: device)
            }
        }
        .padding(12)
        .onAppear { model.renderers?.refresh() }
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
            // Put the device-specific sound correction above lower-priority controls so it remains visible in the
            // bounded output popover. This is especially useful for the AirPods Max factory default.
            EqualizerChoice(device: device)
            RoomCorrectionChoice(device: device)
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
            // Stereo and mono upmixed to 5.1 for Spatial Audio or multichannel speakers. Off by default: the original stays the default.
            // Shown only where it does something: a stereo output needs Spatial Audio on first.
            if FormatPlanner.canSpatializeStereo(on: device.capabilities, spatial: model.engineSpatialMode(for: device)) {
                Toggle(isOn: Binding(get: { settings.spatializeStereoUIDs.contains(device.uid) },
                                     set: { on in
                                         if on { settings.spatializeStereoUIDs.insert(device.uid) } else { settings.spatializeStereoUIDs.remove(device.uid) }
                                         model.syncEngine()
                                     })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Spatialize stereo").font(Typeface.ui(12))
                        (device.capabilities.outputChannels > 2 || (device.capabilities.speakerLayoutChannels ?? 0) >= 3
                             ? Text("Upmixes stereo and mono songs to 5.1 for every speaker. Off plays them as they are.")
                             : Text("Upmixes stereo and mono songs to 5.1 for Spatial Audio. Off plays them as they are."))
                            .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.mini)
            }
            if device.transport == .usb || device.transport == .thunderbolt {
                Toggle(isOn: Binding(get: { settings.isDoPOn(device.uid) },
                                     set: { on in
                                         settings.setDoP(on, for: device.uid)
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
            if let renderer = model.chosenRenderer {
                RendererVolumeControl(renderer: renderer)
            } else if device?.hasHardwareVolume == true, let v = model.devices.hardwareVolume {
                BrassSlider(value: Binding(get: { Double(v) }, set: { model.devices.setHardwareVolume(Float($0)) }),
                            tint: Palette.text2, showsThumb: false, accessibilityName: String(localized: "Hardware volume"))
                    .frame(width: 72)
                Text("HW", comment: "Short label: hardware volume").font(Typeface.mono(9.5)).fixedSize().foregroundStyle(Palette.text3).help("Hardware volume on the device; samples are untouched").accessibilityHidden(true)
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
                .accessibilityLabel("Volume control in Vespertine")
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
                .accessibilityLabel("Volume control in Vespertine")
                .popover(isPresented: $showOptions, arrowEdge: .top) { options(device) }
            }
        }
        // Volume Up, Down or Mute on an output with no volume to move: open the note that says where to set one.
        .onChange(of: model.volumeNoteRequests) { showOptions = true }
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
