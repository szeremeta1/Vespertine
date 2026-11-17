//
// Vespertine Remote: the Mac's outputs, as its output list shows them; choosing one plays there.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol
import VespertineShare

struct OutputsView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: RemoteSession
    @State private var feedback = CommandFeedback()
    @State private var editingConnection = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 4) {
                        Button { PlayTarget.shared.choose(thisDevice: true) } label: {
                            HStack {
                                Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
                                    .rowIconColumn()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(PlayTarget.deviceName)
                                    Text(hereDetail).font(.caption).foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                if playsHere { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!PlayTarget.shared.canPlayHere(session))
                        .accessibilityAddTraits(playsHere ? .isSelected : [])
                        // Where this device's sound goes (AirPlay, Bluetooth, a DAC): the system's own list, a tap away.
                        if RoutePickerPlacement.shows(playsHere: playsHere) {
                            RoutePickerButton().frame(width: 44, height: 44)
                                .accessibilityIdentifier("airplay")
                        }
                    }
                    if playsHere {
                        // Head Tracked chosen on a system that can't do it is shown as what plays: Fixed.
                        Picker("Surround on Headphones", selection: Binding(get: {
                            PlayTarget.surroundChoices.contains(PlayTarget.shared.surround) ? PlayTarget.shared.surround : .fixed
                        }, set: { PlayTarget.shared.surround = $0 })) {
                            Text("Off").tag(SpatialModeChoice.off)
                            Text("Fixed").tag(SpatialModeChoice.fixed)
                            if PlayTarget.surroundChoices.contains(.headTracked) {
                                Text("Head Tracked").tag(SpatialModeChoice.headTracked)
                            }
                        }
                    }
                } footer: {
                    if session.isFolder {
                        Text("This device plays the songs from the folder itself, through its speaker, headphones or a DAC. Surround songs (5.1, 7.1) are rendered as Spatial Audio on headphones, and folded to stereo on speakers or when this is Off; Head Tracked needs AirPods or Beats that follow your head.")
                    } else if session.isShare {
                        Text("This device reads the songs from the share itself and plays them, through its speaker, headphones or a DAC. Surround songs (5.1, 7.1) are rendered as Spatial Audio on headphones, and folded to stereo on speakers or when this is Off; Head Tracked needs AirPods or Beats that follow your head.")
                    } else {
                        Text("The Mac sends the songs and this device plays them, through its speaker, headphones or a DAC. The Mac’s own playback isn’t touched. Surround songs (5.1, 7.1) are rendered as Spatial Audio on headphones, and folded to stereo on speakers or when this is Off; Head Tracked needs AirPods or Beats that follow your head.")
                    }
                }
                if playsHere {
                    Section {
                        Picker("ReplayGain", selection: Binding(get: { PlayTarget.shared.replayGain }, set: { PlayTarget.shared.replayGain = $0 })) {
                            Text("Off").tag(ReplayGainChoice.off)
                            Text("Track").tag(ReplayGainChoice.track)
                            Text("Album").tag(ReplayGainChoice.album)
                        }
                    } footer: {
                        Text("Plays songs at a matched loudness, using the ReplayGain values in their files: Track for each song by itself, Album to keep an album’s quiet and loud songs as they are. Off, no sample is changed. A song without values, and DSD sent to a DAC as DoP, play unchanged either way.")
                    }
                }
                if playsHere, let phone = session.phone, let signal = phone.signal {
                    Section {
                        ForEach(PlayTarget.report(signal, route: phone.route, dop: phone.dopDACs), id: \.label) { row in
                            LabeledContent(row.label, value: row.value)
                        }
                    } header: {
                        Text("What Reaches the Output")
                    } footer: {
                        Text("Read back from iOS while the song plays, not assumed. Vespertine asks a DAC for each song’s own rate and, for surround, an interface for a channel per output (in the order L, R, C, LFE, back pair, side pair). iOS doesn’t tell apps an output’s bit depth. With the volume below 100%, a DAC doesn’t receive the song’s samples unchanged.")
                    }
                }
                if playsHere, !session.isDemo, let phone = session.phone, DoPGate.canTest(phone.route) {
                    DoPSection(phone: phone, fromShare: session.isShare)
                }
                if session.isFolder {
                    if let folder = model.openFolder { folderSection(folder) }
                } else if session.isShare {
                    if let share = model.openShare { shareSection(share) }
                } else {
                    Section {
                        ForEach(Array((session.outputs?.outputs ?? []).enumerated()), id: \.offset) { _, output in
                            Button {
                                PlayTarget.shared.choose(thisDevice: false)
                                feedback.run(session, .selectOutput(uid: output.uid))
                            } label: {
                                HStack {
                                    Image(systemName: icon(output.kind))
                                        .rowIconColumn()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(output.name)
                                        Text(output.detail).font(.caption.monospaced()).foregroundStyle(output.ready ? Color.secondary : Color.orange)
                                    }
                                    Spacer()
                                    if output.selected, !playsHere { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(output.selected && !playsHere ? .isSelected : [])
                        }
                    } footer: {
                        Text("Choose one of these and Vespertine on the Mac plays there.")
                    }
                    // The sound of the output the Mac plays to, while the Mac is what plays.
                    if !playsHere, let player = session.player, let sound = player.sound, !sound.isEmpty {
                        MacSoundSection(session: session, sound: sound, output: player.output, feedback: feedback)
                    }
                    Section {
                        LabeledContent("Mac", value: session.server?.name ?? session.pairing.name)
                        if let version = session.server?.appVersion, !version.isEmpty {
                            LabeledContent("Vespertine", value: version)
                        }
                        if !session.isDemo {
                            Button { editingConnection = true } label: {
                                LabeledContent("Connection") {
                                    HStack(spacing: 6) {
                                        Circle().fill(session.isConnected ? Palette.brass : Palette.text3).frame(width: 7, height: 7)
                                        Text(reach)
                                    }
                                }
                            }
                            .foregroundStyle(Palette.text)
                        }
                    }
                }
                }
            .obsidianList()
            .navigationTitle("Output").screenTitleStyle()
            .toolbar {
                // On an iPad's wide window the gear and "Macs" are in the window's own bars.
                if sizeClass != .regular {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                            Button { model.leave() } label: { Label("Choose Another Mac", systemImage: "desktopcomputer") }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(Text("Settings"))
                        .accessibilityIdentifier("output-gear")
                    }
                }
            }
            .feedback(feedback)
            .sheet(isPresented: $editingConnection) { MacConnectionView(serverID: session.pairing.serverID).withoutMiniPlayer() }
            .sheet(isPresented: $showingSettings) { SettingsView().withoutMiniPlayer() }
        }
    }

    private var playsHere: Bool { session.phone != nil }

    /// The share the songs come from: where it is, whether it answers, what the last scan found, and scanning again.
    @ViewBuilder private func shareSection(_ share: SavedShare) -> some View {
        let status = model.shareStatus ?? ShareStatus()
        Section {
            LabeledContent("SMB Share", value: share.address.display)
            LabeledContent("Connection") {
                HStack(spacing: 6) {
                    Circle().fill(status.reachable == false ? Palette.text3 : Palette.brass).frame(width: 7, height: 7)
                    Text(status.reachable == false ? String(localized: "Not connected") : ShareWording.network(share.address))
                }
            }
            LabeledContent("Songs", value: status.songs.formatted())
            if status.needTheMac > 0 {
                LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
            }
            if status.unreadable > 0 {
                LabeledContent("Files that couldn’t be read", value: status.unreadable.formatted())
            }
            if let scanned = status.scanned {
                LabeledContent("Last scanned", value: scanned.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                model.rescanShare()
            } label: {
                HStack {
                    Text("Scan Again")
                    Spacer()
                    if status.scan.isRunning { ProgressView() }
                }
            }
            .disabled(status.scan.isRunning)
            .accessibilityIdentifier("share-rescan")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let trouble = status.trouble { Text(trouble) }
                Text("A scan reads only new and changed files, and runs by itself once a day when the share is opened. This device opens FLAC, ALAC, WAV, AIFF, MP3 and AAC files itself; APE, WavPack and other formats need Vespertine on a Mac to convert them, so they aren’t listed here.")
            }
        }
    }

    /// The folder the songs come from: what the last look found, looking again, and choosing the folder again.
    @ViewBuilder private func folderSection(_ folder: SavedFolder) -> some View {
        let status = model.shareStatus ?? ShareStatus()
        Section {
            LabeledContent("Folder", value: folder.name)
            LabeledContent("Songs", value: status.songs.formatted())
            if status.needTheMac > 0 {
                LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
            }
            if status.unreadable > 0 {
                LabeledContent("Files that couldn’t be read", value: status.unreadable.formatted())
            }
            if let scanned = status.scanned {
                LabeledContent("Last scanned", value: scanned.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                model.rescanShare()
            } label: {
                HStack {
                    Text("Scan Again")
                    Spacer()
                    if status.scan.isRunning { ProgressView() }
                }
            }
            .disabled(status.scan.isRunning)
            .accessibilityIdentifier("folder-rescan")
            if !folder.isOwn { ChooseFolderAgainButton(folder: folder) }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let trouble = status.trouble { Text(trouble) }
                if folder.isOwn {
                    Text("Music you open in Vespertine from another app is copied into Vespertine’s folder in the Files app and stays there until you delete it in Files. You can put music there yourself, too.")
                } else {
                    Text("Vespertine looks at the folder each time it is opened and reads only new and changed files. The music stays where it is; nothing is copied.")
                }
                Text("This device opens FLAC, ALAC, WAV, AIFF, MP3 and AAC files itself; APE, WavPack and other formats need Vespertine on a Mac to convert them, so they aren’t listed here.")
            }
        }
    }

    /// Under "This iPhone": where its sound goes now, or why it can't play here.
    private var hereDetail: String {
        if session.isDemo, session.phone == nil { return String(localized: "Plays the demo’s made-up songs with sound") }
        guard session.canStream || session.isDemo else { return String(localized: "Update Vespertine on the Mac to play here.") }
        guard let route = session.phone?.route else { return String(localized: "Plays through this device") }
        return route.sampleRate > 0 ? "\(route.name) · \(PhoneSignal.kilohertz(route.sampleRate)) kHz" : route.name
    }

    /// How the Mac is reached now.
    private var reach: String {
        guard session.isConnected else { return String(localized: "Not connected") }
        return session.reach.map(NowPlayingView.reachName) ?? String(localized: "On this network")
    }

    private func icon(_ kind: OutputKind) -> String {
        switch kind {
        case .systemDefault: "speaker.wave.2"
        case .device: "hifispeaker"
        case .speakerGroup: "hifispeaker.2"
        }
    }
}

/// DSD on a DAC plugged into this device: whether it is sent as DSD (DoP), and the short listening test that decides.
/// Nothing is assumed from the DAC's name: it gets DoP only after you heard the test sound as music on it.
private struct DoPSection: View {
    let phone: PhoneRemote
    /// The songs come from a share, read by this device itself: it, not a Mac, converts DSD when the DAC takes no DoP.
    let fromShare: Bool
    @State private var probe: DoPProbe

    init(phone: PhoneRemote, fromShare: Bool = false) {
        self.phone = phone
        self.fromShare = fromShare
        _probe = State(initialValue: DoPProbe(remote: phone))
    }

    var body: some View {
        Section {
            if let status { Text(status).foregroundStyle(Color.secondary) }
            // Which rates this DAC played the chord at: there whether or not a song is playing.
            if !probe.isBusy {
                ForEach(PlayTarget.dopRows(phone.dopDACs, route: phone.route), id: \.label) { row in
                    LabeledContent(row.label, value: row.value)
                }
            }
            Button { probe.run() } label: {
                HStack {
                    Text("Test DoP")
                    if probe.isBusy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(probe.isBusy)
            .accessibilityIdentifier("dop-test")
            .alert("Did you hear music or hiss?", isPresented: Binding(get: { probe.phase == .asking }, set: { if !$0, probe.phase == .asking { probe.cancel() } })) {
                Button("Music") { probe.answer(.music) }
                Button("Hiss") { probe.answer(.hiss) }
                Button("Cancel", role: .cancel) { probe.cancel() }
            } message: {
                // The chord is played at each rate in turn: which one the question is about.
                Text("\(PhoneSignal.kilohertz(probe.carrier)) kHz")
            }
        } header: {
            Text("Play DSD natively?")
        } footer: {
            if fromShare {
                Text("DSD is converted to PCM on this device unless this DAC takes DSD over PCM (DoP). A short, quiet test can tell: it plays a soft chord as DSD and asks what you heard. Music stops for the test, and the volume has to be at 100%.")
            } else {
                Text("DSD is converted to PCM on the Mac unless this DAC takes DSD over PCM (DoP). A short, quiet test can tell: it plays a soft chord as DSD and asks what you heard. Music stops for the test, and the volume has to be at 100%.")
            }
        }
        .onDisappear { if probe.isBusy { probe.cancel() } }
    }

    /// What the test is doing, how it ended, or what this DAC's answer was.
    private var status: String? {
        switch probe.phase {
        case .preparing, .playing:
            return String(localized: "Playing a short, quiet test…", comment: "DoP test sheet while the test sound plays.")
        case .failed(.volume):
            return String(localized: "The test needs the volume at 100%.", comment: "DoP test on the iPhone: the test wasn't started because the device's volume isn't at its top.")
        case .failed(.changed):
            return String(localized: "The test stopped because an audio device changed. Nothing was saved.", comment: "DoP test ended early: an output was plugged in or out, or the default output changed.")
        case .failed:
            return String(localized: "The test couldn't play as DoP on this output, so nothing was saved.", comment: "DoP test ended early: the engine didn't send the test sound as DoP.")
        case .idle, .asking, .answered:
            break
        }
        switch phone.dopDACs.answer(for: phone.route?.uid) {
        case .music?:
            if let volume = phone.outputVolume, volume < DoPGate.fullVolume {
                return String(localized: "DSD is sent as PCM while the volume is below 100%.", comment: "iPhone Output screen, for a DAC that passed the DoP test: with the device volume turned down, DSD songs are converted to PCM instead of being sent as DSD.")
            }
            return String(localized: "DoP is on for this DAC.", comment: "DoP test result after the listener answered Music.")
        case .hiss?:
            return String(localized: "DoP stays off for this DAC. DSD keeps playing as PCM.", comment: "DoP test result after the listener answered Hiss.")
        case nil:
            return nil
        }
    }
}
