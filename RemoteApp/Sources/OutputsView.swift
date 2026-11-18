//
// Vespertine Remote: the Output screen: who plays (the Mac or this device), and what belongs to whoever does: the Mac's
// outputs as its output list shows them, or this device's own output and sound.
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
                // Only what belongs to whoever plays: this device's own output and sound while it plays, the Mac's
                // outputs while the Mac does. The switch above the list is the one place that changes who plays.
                if OutputLayout.showsThisDevice(playsHere: playsHere, share: session.isShare) {
                Section {
                    HStack(spacing: 4) {
                        HStack {
                            Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
                                .rowIconColumn()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hereName)
                                if let rate = hereRate { Text(rate).font(.caption.monospaced()).foregroundStyle(Color.secondary) }
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                        // Where this device's sound goes (AirPlay, Bluetooth, a DAC): the system's own list, a tap away.
                        if RoutePickerPlacement.shows(playsHere: playsHere) {
                            RoutePickerButton().frame(width: 44, height: 44)
                                .accessibilityIdentifier("airplay")
                        }
                    }
                    .accessibilityIdentifier("output-this-device")
                    if playsHere {
                        // Off, or Spatial Audio: iOS renders it, Fixed or Head Tracked as chosen in Control Center.
                        Picker("Surround on Headphones", selection: Binding(get: {
                            PlayTarget.pickerValue(PlayTarget.shared.surround)
                        }, set: { PlayTarget.shared.surround = $0 })) {
                            Text("Off").tag(SpatialModeChoice.off)
                            Text("Spatial Audio").tag(SpatialModeChoice.fixed)
                        }
                    }
                } header: {
                    Text(verbatim: PlayTarget.deviceName)
                } footer: {
                    if session.isFolder {
                        Text("This device plays the songs from the folder itself, through its speaker, headphones or a DAC. Surround songs (5.1, 7.1, Dolby Atmos) go to iOS with all their channels, and iOS plays them as Spatial Audio on AirPods and Beats that have it on, as Apple Music does; choose Fixed or Head Tracked in Control Center (touch and hold the volume slider). Other headphones get Vespertine’s own fixed rendering. On speakers, or when this is Off, they’re folded to stereo.")
                    } else if session.isShare {
                        Text("This device reads the songs from the share itself and plays them, through its speaker, headphones or a DAC. Surround songs (5.1, 7.1, Dolby Atmos) go to iOS with all their channels, and iOS plays them as Spatial Audio on AirPods and Beats that have it on, as Apple Music does; choose Fixed or Head Tracked in Control Center (touch and hold the volume slider). Other headphones get Vespertine’s own fixed rendering. On speakers, or when this is Off, they’re folded to stereo.")
                    } else {
                        Text("The Mac sends the songs and this device plays them, through its speaker, headphones or a DAC. The Mac’s own playback isn’t touched. Surround songs (5.1, 7.1, Dolby Atmos) go to iOS with all their channels, and iOS plays them as Spatial Audio on AirPods and Beats that have it on, as Apple Music does; choose Fixed or Head Tracked in Control Center (touch and hold the volume slider). Other headphones get Vespertine’s own fixed rendering. On speakers, or when this is Off, they’re folded to stereo.")
                    }
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
                        ForEach(PlayTarget.report(signal, route: phone.route, dop: phone.dopDACs, dsdAsPCM: phone.playback.dsdAsPCM), id: \.label) { row in
                            LabeledContent(row.label, value: row.value)
                        }
                    } header: {
                        Text("What Reaches the Output")
                    } footer: {
                        Text("Read back from iOS while the song plays, not assumed. Vespertine asks a DAC for each song’s own rate and, for surround, an interface for a channel per output (in the order L, R, C, LFE, back pair, side pair). iOS doesn’t tell apps an output’s bit depth. With the volume below 100%, a DAC doesn’t receive the song’s samples unchanged. On AirPods, iOS makes the two channels your ears get from the channels it was sent, so the output itself always has two.")
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
                    if OutputLayout.showsMacOutputs(playsHere: playsHere, share: session.isShare) {
                    Section {
                        ForEach(Array((session.outputs?.outputs ?? []).enumerated()), id: \.offset) { _, output in
                            Button {
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
                                    if output.selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(output.selected ? .isSelected : [])
                        }
                    } header: {
                        Text(verbatim: macName)
                    } footer: {
                        Text("Choose one of these and Vespertine on the Mac plays there.")
                    }
                    // The sound of the output the Mac plays to.
                    if let player = session.player, let sound = player.sound, !sound.isEmpty {
                        MacSoundSection(session: session, sound: sound, output: player.output, feedback: feedback)
                    }
                    }
                    Section {
                        LabeledContent("Mac", value: macName)
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
            // Above the list, not a row of it: a row is cut to the list's own rounded corners, which sliced the ends off
            // the switch. Here it keeps its shape and stays in sight while the list scrolls.
            .safeAreaInset(edge: .top, spacing: 0) {
                if PlayMode.offersSwitch(share: session.isShare) { switchBar }
            }
            .navigationTitle("Output").screenTitleStyle()
            .toolbar {
                // On an iPad's wide window the gear and "Libraries" are in the window's own bars.
                if sizeClass != .regular {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                            Button { model.leave() } label: { Label("Choose Another Library", systemImage: "music.note.house") }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(Text("Settings"))
                        .accessibilityIdentifier("output-gear")
                    }
                }
            }
            .feedback(feedback)
            // The screen that speaks about the output reads it as it comes up, not from whatever was last heard.
            .onAppear { _ = session.phone?.readOutput?(.shown) }
            .sheet(isPresented: $editingConnection) { MacConnectionView(serverID: session.pairing.serverID).withoutMiniPlayer() }
            .sheet(isPresented: $showingSettings) { SettingsView().withoutMiniPlayer() }
        }
    }

    private var playsHere: Bool { session.phone != nil }
    private var macName: String { session.server?.name ?? session.pairing.name }

    /// "Music Plays On", the Mac / This iPhone switch, and a line on what the chosen one means.
    private var switchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Music Plays On")
                .font(.footnote.weight(.semibold)).foregroundStyle(Palette.text2)
                .accessibilityAddTraits(.isHeader)
            PlayModeSwitch(session: session)
            Text(switchNote)
                .font(.footnote).foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dynamicTypeSize(...RemoteLayout.bannerLargestText)
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Palette.base)
    }

    /// Under the switch: what the chosen side means, or why this device can't be chosen.
    private var switchNote: String {
        if session.isConnected, !PlayTarget.shared.canPlayHere(session) { return String(localized: "Update Vespertine on the Mac to play here.") }
        return PlayModeSwitch.explanation(PlayMode.current(playsHere: playsHere), mac: macName)
    }

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
                if status.needs.isEmpty {
                    LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
                } else {
                    NavigationLink {
                        MacNeededView(needs: status.needs)
                    } label: {
                        LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
                    }
                    .accessibilityIdentifier("share-mac-needed")
                }
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
                Text("A scan reads only new and changed files, and runs by itself once a day when the share is opened. This device opens FLAC, ALAC, WAV, AIFF, MP3 and AAC files itself; DTS, TrueHD and other formats need Vespertine on a Mac to convert them, so they aren’t listed here.")
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
                if status.needs.isEmpty {
                    LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
                } else {
                    NavigationLink {
                        MacNeededView(needs: status.needs)
                    } label: {
                        LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
                    }
                    .accessibilityIdentifier("folder-mac-needed")
                }
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
                Text("This device opens FLAC, ALAC, WAV, AIFF, MP3 and AAC files itself; DTS, TrueHD and other formats need Vespertine on a Mac to convert them, so they aren’t listed here.")
            }
        }
    }

    /// Where this device's sound goes now: the output's name as iOS gives it.
    private var hereName: String { session.phone?.route?.name ?? String(localized: "Plays through this device") }

    /// The rate that output runs at, when iOS says.
    private var hereRate: String? {
        guard let route = session.phone?.route, route.sampleRate > 0 else { return nil }
        return String(localized: "\(PhoneSignal.kilohertz(route.sampleRate)) kHz", comment: "Signal chip: a sample rate.")
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
            // The chord was heard with iOS's volume below the top: that volume changes nothing this DAC gets.
            if !probe.isBusy, DoPGate.level(phone.output, dacs: phone.dopDACs) == .dac {
                Text(verbatim: PlayTarget.volumeOnDAC).foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("dop-volume-on-dac")
            }
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
            .alert("What did you hear?", isPresented: Binding(get: { probe.phase == .asking }, set: { if !$0, probe.phase == .asking { probe.cancel() } })) {
                Button("Music") { probe.answer(.music) }
                Button("Hiss or noise") { probe.answer(.noise) }
                // Silence is its own answer: it is never kept as a failed test.
                Button("Heard nothing") { probe.answer(.nothing) }
                Button("Play again") { probe.answer(.again) }
                Button("Cancel", role: .cancel) { probe.cancel() }
            } message: {
                // The chord is played at each rate in turn: which one the question is about, as the DAC's display names it.
                Text(verbatim: PlayTarget.dopRate(carrier: probe.carrier))
            }
        } header: {
            Text("Play DSD natively?")
        } footer: {
            if fromShare {
                Text("DSD is converted to PCM on this device unless this DAC takes DSD over PCM (DoP). A short, quiet test can tell: it plays a soft chord as DSD and asks what you heard. Music stops for the test. If you hear no chord while the volume is below 100%, set it to 100%, then test again.")
            } else {
                Text("DSD is converted to PCM on the Mac unless this DAC takes DSD over PCM (DoP). A short, quiet test can tell: it plays a soft chord as DSD and asks what you heard. Music stops for the test. If you hear no chord while the volume is below 100%, set it to 100%, then test again.")
            }
        }
        .onDisappear { if probe.isBusy { probe.cancel() } }
    }

    /// What the test is doing, how it ended, or what this DAC's answer was.
    private var status: String? {
        switch probe.phase {
        case .preparing, .playing:
            return String(localized: "Playing a short, quiet test…", comment: "DoP test sheet while the test sound plays.")
        case .failed(.changed):
            return String(localized: "The test stopped because an audio device changed. Nothing was saved.", comment: "DoP test ended early: an output was plugged in or out, or the default output changed.")
        case .failed:
            return String(localized: "The test couldn't play as DoP on this output, so nothing was saved.", comment: "DoP test ended early: the engine didn't send the test sound as DoP.")
        case .answered(let ending):
            // A run that ended with nothing to keep says so, and what to do.
            if let words = PlayTarget.dopEnding(ending, carrier: probe.carrier) { return words }
        case .idle, .asking:
            break
        }
        return PlayTarget.dopResult(phone.dopDACs, output: phone.output)
    }
}

/// The files on the share that this device can't open by itself, by what they are: DTS, TrueHD, DSD in surround…
struct MacNeededView: View {
    let needs: [MacNeed.Count]

    var body: some View {
        List {
            Section {
                ForEach(needs, id: \.need) { count in
                    LabeledContent {
                        Text(verbatim: count.files.formatted())
                    } label: {
                        Text(verbatim: count.need.label)
                    }
                }
            } footer: {
                Text("This device can’t open these files by itself, so they aren’t in its library. Vespertine on a Mac can open them: add them to the Mac’s library, then play them there or from the Mac on this device.")
            }
        }
        .obsidianList()
        .navigationTitle("Files that need the Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}
