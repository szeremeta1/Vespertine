//
// Nocturne — transport bar, output device picker, queue.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneAudio
import NocturneLibrary
import SwiftUI

struct TransportBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showDevices = false
    @State private var showQueue = false

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
                Button { showQueue.toggle() } label: { Image(systemName: "list.bullet").font(.system(size: 14)) }
                    .buttonStyle(TransportIconStyle(active: showQueue))
                    .help("Queue")
                    .popover(isPresented: $showQueue, arrowEdge: .top) { QueueView().environment(model).frame(width: 380, height: 460) }
                Button { openWindow(id: "mini") } label: { Image(systemName: "pip").font(.system(size: 14)) }
                    .buttonStyle(TransportIconStyle())
                    .help("Mini Player (⇧⌘M)")
                Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right").font(.system(size: 14)) }
                    .buttonStyle(TransportIconStyle(active: model.showInspector))
                    .help("Inspector (⌥⌘I)")
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
            ArtworkView(key: model.player.current?.track.artworkKey, size: 160, cornerRadius: 5)
                .frame(width: 46, height: 46)
            if let track = model.player.current?.track {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(Typeface.serif(14)).foregroundStyle(Palette.text).lineLimit(1)
                    Text("\(track.displayArtist) — \(track.displayAlbum)").font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.sidebar = .albums
                    model.path = [.album(track.albumKey)]
                }
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
                }
                Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 15)) }
                    .buttonStyle(TransportIconStyle())
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
                Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 15)) }
                    .buttonStyle(TransportIconStyle())
                if !compact {
                    Button {
                        player.repeatMode = switch player.repeatMode { case .off: .all; case .all: .one; case .one: .off }
                    } label: { Image(systemName: player.repeatMode.symbol).font(.system(size: 13)) }
                        .buttonStyle(TransportIconStyle(active: player.repeatMode != .off)).help("Repeat")
                }
            }
            if !compact { Scrubber() }
        }
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
                        showsThumb: player.current != nil) { editing in
                if !editing, let v = dragValue {
                    player.seek(to: v * duration)
                    dragValue = nil
                }
            }
            .disabled(player.current == nil)
            Text("−" + max(0, duration - shown).clock).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3).frame(width: 48, alignment: .leading)
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
                Image(systemName: device?.profile.symbol ?? "hifispeaker")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.brassHi)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device?.name ?? "No Output").font(Typeface.ui(12)).foregroundStyle(Palette.text).lineLimit(1)
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
        .help("Output device")
        .popover(isPresented: $showDevices, arrowEdge: .top) {
            DevicePicker().environment(model).frame(width: 360)
        }
    }

    private func chipDetail(_ device: OutputDevice?, _ path: SignalPath?) -> String {
        if let path {
            return "\(path.deviceFormatShort) · \(path.applied.exclusive ? "EXCL" : "SHARED")"
        }
        guard let device else { return "—" }
        return "\(SampleRate.format(device.nominalSampleRate)) kHz · IDLE"
    }
}

struct DevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Output").padding(.horizontal, 8).padding(.bottom, 4)
            deviceRow(nil, name: "System Default", detail: "FOLLOWS SOUND SETTINGS", symbol: "gearshape", selected: model.settings.selectedDeviceUID == nil)
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
            LabeledContent("Sample rate") {
                Picker("", selection: Binding(get: { settings.rateChoice(for: device.uid) },
                                              set: { settings.setRateChoice($0, for: device.uid); model.syncEngine() })) {
                    Text(RateChoice.match.label).tag(RateChoice.match)
                    Text(RateChoice.maximum.label).tag(RateChoice.maximum)
                    Divider()
                    ForEach(device.capabilities.sampleRates, id: \.self) { r in
                        Text(RateChoice.fixed(r).label).tag(RateChoice.fixed(r))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .font(Typeface.ui(12))
            Toggle(isOn: Binding(get: { settings.exclusiveMode }, set: { settings.exclusiveMode = $0; model.syncEngine() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Exclusive access").font(Typeface.ui(12))
                    Text("Other apps are silenced on this device. Volume keys and the AirPods Max crown can't reach it.").font(Typeface.ui(10.5)).foregroundStyle(Palette.text3)
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            // Multichannel music (5.1, 7.1…): Spatial Audio on headphones, all channels or a downmix elsewhere.
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Spatial Audio").font(Typeface.ui(12))
                    Text(device.capabilities.outputChannels > 2
                         ? "For multichannel music. Off sends every channel to this device's speakers."
                         : "For multichannel music. Off plays a standard stereo downmix.")
                        .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: Binding(get: { model.engineSpatialMode(for: device) },
                                              set: { settings.spatialModes[device.uid] = $0.rawValue; model.syncEngine() })) {
                    ForEach(SpatialMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
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

    var body: some View {
        let device = model.activeDevice
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(Palette.text2)
            if device?.hasHardwareVolume == true, let v = model.devices.hardwareVolume {
                BrassSlider(value: Binding(get: { Double(v) }, set: { model.devices.setHardwareVolume(Float($0)) }),
                            tint: Palette.text2, showsThumb: false)
                    .frame(width: 72)
                Text("HW").font(Typeface.mono(9.5)).fixedSize().foregroundStyle(Palette.text3).help("Hardware volume on the device; samples are untouched")
            } else if model.settings.allowDigitalVolume {
                BrassSlider(value: Binding(get: { model.settings.digitalVolume }, set: { model.settings.digitalVolume = $0; model.syncEngine() }),
                            tint: Palette.copper, showsThumb: false)
                    .frame(width: 84)
                Text("DIG").font(Typeface.mono(9.5)).fixedSize().foregroundStyle(Palette.copper).help("Digital volume (64-bit, dithered). Not bit-perfect below 100%.")
            } else {
                Text("FIXED · USE DAC").font(Typeface.mono(9.5)).fixedSize().foregroundStyle(Palette.text3)
                    .help("This device has no volume control Nocturne can use. Adjust volume on your DAC or amplifier, or enable digital volume in Settings.")
            }
        }
    }
}

// MARK: - Queue

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").font(Typeface.serif(18))
                Spacer()
                Button("Clear") { player.clearUpcoming() }.buttonStyle(QuietButtonStyle(compact: true)).disabled(player.upcoming.isEmpty)
            }
            .padding(14)
            if let current = player.current {
                row(current, isCurrent: true).padding(.horizontal, 8)
                Hairline().padding(.vertical, 6)
            }
            List {
                ForEach(Array(player.upcoming)) { entry in
                    row(entry, isCurrent: false)
                        .contextMenu { Button("Remove") { player.removeFromQueue(entry.id) } }
                        .onTapGesture(count: 2) { player.jump(to: entry.id) }
                }
                .onMove { player.moveUpcoming(from: $0, to: $1) }
                .onDelete { idx in idx.map { Array(player.upcoming)[$0].id }.forEach(player.removeFromQueue) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            if player.upcoming.isEmpty {
                Text("Nothing queued").font(Typeface.ui(12)).foregroundStyle(Palette.text3).frame(maxWidth: .infinity).padding()
            }
        }
    }

    private func row(_ e: QueueEntry, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            ArtworkView(key: e.track.artworkKey, size: 160, cornerRadius: 4).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.track.title).font(Typeface.ui(12.5)).foregroundStyle(isCurrent ? Palette.brassHi : Palette.text).lineLimit(1)
                Text(e.track.displayArtist).font(Typeface.ui(11)).foregroundStyle(Palette.text2).lineLimit(1)
            }
            Spacer()
            Text(e.track.formatSummary).font(Typeface.mono(9.5)).foregroundStyle(Palette.text3)
        }
    }
}
