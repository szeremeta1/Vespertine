//
// Vespertine: mini player, menu bar extra, settings.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import VespertineAudio
import VespertineLibrary
import SwiftUI

// MARK: - Mini player

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    /// Visual height; the hidden title bar's inset is absorbed by ignoring the safe area.
    private let height: CGFloat = 132

    var body: some View {
        let player = model.player
        GeometryReader { geo in
            HStack(spacing: 0) {
                ArtworkView(key: model.artworkKey(player.current?.track), size: 600, cornerRadius: 0)
                    .frame(width: geo.size.height, height: geo.size.height)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(player.current?.track.title ?? String(localized: "Not Playing")).font(Typeface.serif(16)).foregroundStyle(Palette.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if let track = player.current?.track { FavoriteButton(track: track, size: 12) }
                    }
                    Text(player.current?.track.displayArtist.libraryDisplayName ?? " ").font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
                    Spacer()
                    HStack(spacing: 14) {
                        TransportControls(compact: true)
                        TransitionsButton(size: 11)
                        Spacer(minLength: 4)
                        if let path = player.signalPath {
                            // A filled disc or a ring beside the format, so bit-perfect or converted isn't colour alone.
                            HStack(spacing: 5) {
                                VerdictMark(untouched: path.isBitPerfect)
                                Text(path.isResampling
                                     ? String(localized: "\(SampleRate.format(path.plan.decodedSampleRate)) → \(SampleRate.format(path.plan.deviceSampleRate)) kHz")
                                     : path.deviceFormatShort)
                                    .font(Typeface.mono(10))
                                    .foregroundStyle(path.isBitPerfect ? Palette.brassHi : Palette.copper)
                            }
                            .help(path.isBitPerfect ? String(localized: "Bit-perfect") : String(localized: "Converted on the way to the device"))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(path.isBitPerfect ? String(localized: "Bit-perfect") : String(localized: "Converted", comment: "The audio is converted (not bit-perfect) on the way to the device"))
                            .accessibilityValue(path.deviceFormatShort)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    let fraction = player.duration > 0 ? player.position / player.duration : 0
                    Rectangle().fill(Palette.text.opacity(0.08)).frame(height: 2)
                        .overlay(alignment: .leading) {
                            GeometryReader { bar in Rectangle().fill(Palette.brass).frame(width: bar.size.width * fraction) }
                        }
                        .frame(height: 2)
                }
            }
        }
        .background(Palette.panel)
        .ignoresSafeArea()
        .frame(width: 420, height: height - 28)
        .background(WindowConfigurator(floating: model.settings.miniPlayerFloats))
    }
}

/// Makes the mini player float above other windows and be draggable by its background.
struct WindowConfigurator: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = floating ? .floating : .normal
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.player.isPlaying ? "waveform" : "hifispeaker")
            if let path = model.player.signalPath, model.player.state != .stopped {
                Text(path.deviceFormatShort).font(Typeface.mono(11))
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let player = model.player
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(key: model.artworkKey(player.current?.track), size: 160, cornerRadius: 6).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.track.title ?? String(localized: "Not Playing")).font(Typeface.serif(16)).lineLimit(1)
                    Text(player.current.map { "\($0.track.displayArtist.libraryDisplayName) — \($0.track.displayAlbum.libraryDisplayName)" } ?? "Vespertine")
                        .font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
                    if let path = player.signalPath {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            VerdictMark(untouched: path.isBitPerfect)
                            (player.buffering ? Text("BUFFERING…") : Text(verbatim: ([path.statusLine] + path.conversionBadges + [path.deviceFormatShort]).joined(separator: " · "))).font(Typeface.mono(9.5)).lineLimit(2)
                                .foregroundStyle(path.isBitPerfect ? Palette.brassHi : Palette.copper)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let track = player.current?.track { FavoriteButton(track: track) }
            }
            Scrubber()
            HStack { Spacer(); TransportControls(compact: true); Spacer() }
                .overlay(alignment: .trailing) { TransitionsButton(size: 12) }
            Hairline()
            DevicePicker()
                .padding(-12)
            Hairline()
            HStack {
                Button("Open Vespertine") {
                    NSApp.activate()
                    openWindow(id: "main")
                }
                Spacer()
                Button("Mini Player") { openWindow(id: "mini") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(QuietButtonStyle(compact: true))
        }
        .foregroundStyle(Palette.text)
        .padding(16)
        .frame(width: 360)
        .background(Palette.panel)
    }
}

/// The menu bar extra's panel takes the menu bar's appearance, and `preferredColorScheme(.dark)` doesn't reach it, so in
/// Light Mode the text and controls that use the system colors came out black on the dark panel (issue #68). Pin the
/// panel itself to the dark appearance.
struct DarkWindowAppearance: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance = NSAppearance(named: .darkAqua)
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Settings

/// The Settings window's tabs; `AppModel.settingsTab` is the one showing (the setup assistant opens Settings on one).
enum SettingsTab: Hashable {
    case playback, library, network, online, remote, updates, about
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            PlaybackSettings().tabItem { Label("Playback", systemImage: "hifispeaker.2") }.tag(SettingsTab.playback)
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }.tag(SettingsTab.library)
            NetworkSettings().tabItem { Label("Network", systemImage: "server.rack") }.tag(SettingsTab.network)
            OnlineSettings().tabItem { Label("Online", systemImage: "globe") }.tag(SettingsTab.online)
            RemoteSettingsView().tabItem { Label("Remote", systemImage: "iphone") }.tag(SettingsTab.remote)
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(SettingsTab.updates)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 560, height: 460)
    }
}

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimFlashing = false
    @State private var askingStrobe = false

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Output") {
                Picker("When the chosen output isn't connected, play on", selection: $s.outputFallback) {
                    ForEach(OutputFallback.allCases) { Text($0.label).tag($0) }
                }
                Text(fallbackNote(s.outputFallback)).font(.caption).foregroundStyle(.secondary)
                Toggle("Exclusive access (hog mode)", isOn: $s.exclusiveMode)
                (!s.exclusiveMode
                     ? Text("Off: Vespertine still sets the device's format for each track and plays bit-perfect, and says so, unless another app plays through the same device at the same time. Volume keys and headphone controls work normally. DSD over DoP always takes exclusive access.")
                     : s.relayVolumeKeys
                     ? Text("Vespertine takes sole control of the device; other apps are silent on it while Vespertine plays. macOS then won't let it be the Mac's sound output, so Vespertine passes the volume keys, Control Center and the AirPods Max Digital Crown on to it. The Mac's own speakers and headphone jack always play shared.")
                     : Text("Vespertine takes sole control of the device; other apps are silent on it while Vespertine plays. macOS then won't let it be the Mac's sound output, so the volume keys, Control Center and the AirPods Max Digital Crown adjust another output instead, unless the setting below is on. The Mac's own speakers and headphone jack always play shared."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Volume keys control the device held exclusively", isOn: $s.relayVolumeKeys)
                    .disabled(!s.exclusiveMode)
                Text("With exclusive access, macOS moves the Mac's sound output to another device while Vespertine holds the DAC. With this on, the volume keys, Control Center and the AirPods Max Digital Crown change the DAC's volume by way of that output, which then plays other apps' sounds at the DAC's level. Off: that output keeps its own volume.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Integer mode", isOn: $s.integerMode)
                    .disabled(!s.exclusiveMode)
                Text("With exclusive access, on DACs that offer it (such as the FiiO K11): music that needs no processing goes to the DAC as 32-bit integers, with no floating-point step, so 32-bit recordings arrive exact. Anything with volume, ReplayGain, resampling or Spatial Audio still uses the floating-point path.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Match 16-bit sources", isOn: $s.matchSixteenBit)
                    .disabled(!s.exclusiveMode)
                Text("With exclusive access: a 16-bit file goes to a DAC that has a 16-bit mode at its sample rate as 16-bit, instead of padded with zeros to 24 or 32 bits. The samples are the same either way; some DACs show or handle 16-bit input differently. Not for the Mac's own outputs, DSD, or anything with volume, EQ, ReplayGain, resampling or Spatial Audio. The signal path says when a DAC has no 16-bit mode at a rate.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Release device after pausing for", selection: $s.releaseAfterPause) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("2 minutes").tag(120.0)
                    Text("10 minutes").tag(600.0)
                }
                .disabled(!s.exclusiveMode)
                Picker("When Vespertine quits, set the device to", selection: $s.deviceOnQuit) {
                    ForEach(DeviceOnQuit.allCases) { Text($0.label).tag($0) }
                }
                Text("\u{201C}Put it back as it was\u{201D} restores each device Vespertine switched to the sample rate and bit depth it had before, so other apps (and tools like LosslessSwitcher) take over from where they left off.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Software path") {
                    Button("Loopback Test…") { openWindow(id: "main"); model.showLoopbackTest = true }
                }
                Text("Plays a test signal through a virtual loopback device and checks every sample comes back unchanged. A check of Vespertine's software path, not of your DAC.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TransitionsSettingsSection()
            SpeakerGroupsSettingsSection()
            SystemOutputSettingsSection()
            Section("Surround formats") {
                Picker("Dolby Atmos", selection: $s.atmosBySystem) {
                    Text("Rendered by macOS (objects)").tag(true)
                    Text("Channel bed through Vespertine").tag(false)
                }
                (s.atmosBySystem
                     ? Text("macOS renders the Atmos objects for the output, as Apple Music does: Apple's Spatial Audio renderer on AirPods (head-tracked where macOS provides it), height channels on a multichannel device. The spectrum, channel meters and Visualizer show the 5.1 or 7.1 bed from a separate decode (not the objects), which never touches what macOS plays.")
                     : Text("Vespertine decodes the Dolby Digital Plus 5.1 or 7.1 bed itself (without the Atmos objects), with its own signal path, meters and Spatial Audio."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Stereo and surround versions", selection: $s.versionPreference) {
                    Text("Match the output").tag(TrackVersions.Preference.matchOutput)
                    Text("Always stereo").tag(TrackVersions.Preference.stereo)
                    Text("Always surround").tag(TrackVersions.Preference.multichannel)
                }
                .onChange(of: s.versionPreference) { model.player.resolveVersions() }
                Text("For albums that have each song in stereo and in surround, such as an SACD's two layers. Matching the output plays surround on a multichannel device or with Spatial Audio on, and stereo on a stereo DAC or with Spatial Audio off. Upcoming songs switch when you change outputs.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bundle copies of an album", isOn: $s.bundleCopies)
                    .onChange(of: s.bundleCopies) { model.library.bundlesCopiesByDefault = s.bundleCopies; model.player.resolveVersions() }
                Text("When your library has an album more than once (a 24/192 download and a vinyl transfer, a stereo and a 5.1 mix, a WAV and a FLAC), its page lists every copy. Off, one copy plays: the one you pick there, or the best for the output, and a heart is for that copy only. On, the copies play as one album, each song in the copy the output supports best. Each album can also choose on its page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Volume") {
                Toggle("Mac sound output follows Vespertine while playing", isOn: $s.systemOutputFollowsPlayback)
                    .disabled(s.exclusiveMode)
                Text("Volume keys and headphone controls, such as the AirPods Max Digital Crown, act on the Mac's sound output. With this on, they adjust the device Vespertine is playing to instead of another one selected in Control Center.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow digital volume when the device has no hardware control", isOn: $s.allowDigitalVolume)
                Text("Applied in 64-bit with TPDF dither at the DAC's word length. At anything below 100% the output is no longer bit-perfect, and Vespertine says so.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Visualizer") {
                Toggle("Visualizer window", isOn: $s.visualizerEnabled)
                Text("Adds Window > Visualizer (⌥⌘V) and a toolbar button: the album on a spinning record, a spectrum analyzer, a spectrogram, club lights, a stereo scope, VU and PPM meters, a particle field and mirrored bars, in a window of its own that can go full screen on another display. It reads a copy of what plays and never changes the sound. With the window closed, it costs nothing.")
                    .font(.caption).foregroundStyle(.secondary)
                StrobeToggle(settings: $s.visualizer, asking: $askingStrobe, reduceMotion: reduceMotion, dimFlashing: dimFlashing,
                             label: "Beat strobe in the Club style")
                    .disabled(!s.visualizerEnabled)
                Text("The beat strobe flashes the whole screen on strong beats. Flashing lights may trigger seizures in people with photosensitive epilepsy. If you or anyone watching has epilepsy or has ever had a seizure, leave it off. If you feel dizzy or unwell while it flashes, look away and turn it off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ReplayGain") {
                Picker("Mode", selection: $s.replayGain) { ForEach(ReplayGainMode.allCases) { Text($0.label).tag($0) } }
                Slider(value: $s.replayGainPreampDB, in: -12...6, step: 0.5) { Text("Pre-amp \(s.replayGainPreampDB, specifier: "%+.1f") dB") }
                    .disabled(s.replayGain == .off)
                Text("Off by default. Any gain other than 0 dB changes the samples, so bit-perfect playback is lost while ReplayGain is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.exclusiveMode) { model.syncEngine() }
        .onChange(of: s.outputFallback) { model.syncEngine() }
        .onChange(of: s.atmosBySystem) { model.syncEngine() }
        .onChange(of: s.integerMode) { model.syncEngine() }
        .onChange(of: s.matchSixteenBit) { model.syncEngine() }
        .onChange(of: s.releaseAfterPause) { model.syncEngine() }
        .onChange(of: s.allowDigitalVolume) { s.appVolumeChoices = [:]; model.syncEngine() }
        .onChange(of: s.replayGain) { model.player.refreshReplayGain() }
        .onChange(of: s.replayGainPreampDB) { model.player.refreshReplayGain() }
        .readsDimFlashingLights($dimFlashing)
        .strobeWarning(isPresented: $askingStrobe, settings: $s.visualizer)
    }

    private func fallbackNote(_ fallback: OutputFallback) -> String {
        switch fallback {
        case .bestAvailable:
            String(localized: "Vespertine remembers the output you chose and plays on it whenever it's connected. Until then it uses the most capable one connected: an external DAC first, then the Mac's sound output. Playback moves back to your output when you connect it. One that drops out mid-song (AirPods reconnecting) is waited for.")
        case .systemDefault:
            String(localized: "Vespertine remembers the output you chose and plays on it whenever it's connected. Until then it uses the Mac's sound output. Playback moves back to your output when you connect it. One that drops out mid-song (AirPods reconnecting) is waited for.")
        case .waitForChosen:
            String(localized: "Nothing plays until the output you chose is connected again.")
        }
    }
}

struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var removingSource: LibrarySource?

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Sources") {
                ForEach(model.library.sources) { source in
                    HStack {
                        Image(systemName: source.isNetwork ? "server.rack" : (source.mode == .managed ? "tray.full" : "folder"))
                        VStack(alignment: .leading) {
                            Text(source.displayName)
                            (source.isNetwork ? Text("Network share") : (source.mode == .managed ? Text("Managed", comment: "Library source kind: Vespertine organizes the files") : Text("Referenced in place")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rescan") { Task { await model.library.scan(source, restart: true) } }
                        Button("Remove") { removingSource = source }
                    }
                }
                // Their panels belong to the main window: bring it forward, or they open behind Settings.
                HStack {
                    Button("Add Folder…") { openWindow(id: "main"); model.presentImporter(.reference) }
                    Button("Import & Organize…") { openWindow(id: "main"); model.presentImporter(.copyAndOrganize) }
                    Button("Connect to Server…") { openWindow(id: "main"); model.showConnectServer = true }
                }
            }
            Section("Importing") {
                Picker("When adding music", selection: $s.defaultImportMode) {
                    Text("Reference files in place").tag(ImportMode.reference)
                    Text("Copy & organize into managed folder").tag(ImportMode.copyAndOrganize)
                }
                Text("What Find Music on This Mac starts with. Add Folder always references files in place, and Import & Organize always copies.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Managed folder") {
                    Text((s.managedFolderPath as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                }
                Toggle("Scan for new music automatically", isOn: Binding(get: { s.watchFolders }, set: {
                    s.watchFolders = $0
                    model.library.automaticScanningChanged()
                    if $0 { Task { await model.shares.rescanStale() } }   // shares connected and due a look catch up too
                }))
                Text("Watches your folders, looks again at launch and rechecks network shares now and then. When it’s off, use Rescan Library.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Skip voice recordings and short clips", isOn: $s.skipNonMusic)
                    .onChange(of: s.skipNonMusic) { model.library.setSkipsNonMusic(s.skipNonMusic) }
                Button("Find Music on This Mac…") { openWindow(id: "main"); model.showFindMusic = true }
            }
            Section {
                Toggle("Analyze new music automatically", isOn: $s.autoAnalyze)
                    .onChange(of: s.autoAnalyze) { if s.autoAnalyze { model.analysis.analyzeLibrary() } }
                Toggle("Include network shares", isOn: $s.analyzeNetworkShares)
                    .disabled(!s.autoAnalyze)
                HStack {
                    Button(model.analysis.isRunning ? String(localized: "Stop", comment: "Stops the library analysis") : String(localized: "Analyze Library Now")) {
                        if model.analysis.isRunning { model.analysis.cancel() } else { model.analysis.analyzeLibrary(includeNetwork: true) }
                    }
                    if model.analysis.isRunning {
                        ProgressView(value: Double(model.analysis.completed), total: Double(max(1, model.analysis.batchTotal))).frame(width: 120)
                        Text("\(model.analysis.completed) of \(model.analysis.batchTotal)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                ForEach(model.shares.sources.filter { $0.id.map(model.analysis.serverIndexed.contains) ?? false }, id: \.id) { source in
                    let name = source.name ?? String(localized: "Network share")
                    LabeledContent("\(name) (analyzed on the server)") {
                        Text(serverLine(source)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } header: {
                Text("Analysis")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Checks each lossless file for zero-padded bits, upsampling, lossy origins and synthesized (\u{201C}enhanced\u{201D}) high frequencies, in the background. Results are saved; unchanged files are never analyzed twice. Network shares are left out by default because each file is read in full, except shares whose server runs vespertine-analyze: their results come from the server, without reading the music over the network.")
                    Text("Analyze Library Now includes network shares, and pauses while music plays from one.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library data") {
                LabeledContent("Location") {
                    Button((s.dataDirectory.path as NSString).abbreviatingWithTildeInPath) {
                        NSWorkspace.shared.activateFileViewerSelecting([s.dataDirectory])
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .modifier(RemoveSourceAlert(source: $removingSource))
    }

    private func serverLine(_ source: LibrarySource) -> String {
        guard let id = source.id, let st = model.analysis.serverStatus[id] else { return String(localized: "Results found") }
        let updated = st.updated.formatted(.relative(presentation: .named))
        if st.isRunning { return String(localized: "Running · \(st.done) of \(st.total) · \(updated)", comment: "Server analysis progress; last value: when it was last updated, e.g. 2 minutes ago") }
        return st.failures > 0
            ? String(localized: "Up to date · \(st.failures) couldn't be read · \(updated)", comment: "Server analysis; last value: when it was last updated, e.g. 2 minutes ago")
            : String(localized: "Up to date · \(updated)", comment: "Server analysis; value: when it was last updated, e.g. 2 minutes ago")
    }
}

struct OnlineSettings: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var validation: String?

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("MusicBrainz") {
                Toggle("Fetch cover art from the Cover Art Archive", isOn: $s.fetchArtworkOnline)
                Text("Lookups only happen when you ask for them. Nothing is sent in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ListenBrainz scrobbling") {
                Toggle("Submit listens", isOn: $s.scrobble)
                SecureField("User token", text: $token)
                HStack {
                    Button("Save & Verify") {
                        Task {
                            guard await ListenBrainzClient.shared.saveToken(token) == errSecSuccess else {
                                validation = String(localized: "Couldn’t save the token to the keychain")
                                return
                            }
                            let user = try? await ListenBrainzClient.shared.validate(token: token)
                            validation = user.map { String(localized: "Connected as \($0)") } ?? String(localized: "Token not accepted")
                        }
                    }
                    if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Your token is stored in the macOS Keychain. Find it at listenbrainz.org → Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show what’s playing as my Discord status", isOn: $s.discordPresence)
                    .onChange(of: s.discordPresence) { model.player.syncDiscord() }
                Toggle("Show album covers", isOn: $s.discordArtwork)
                    .disabled(!s.discordPresence)
                    .onChange(of: s.discordArtwork) { model.player.syncDiscord() }
                if s.discordPresence {
                    Text(discordLine).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Discord")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("While a song plays, your status shows its title, artist, album, format and progress, through the Discord app on this Mac. It clears when you pause or quit. Discord shows it to everyone who can see your activity, if Activity Privacy in Discord’s settings allows it.")
                    Text("Covers are found by album name on the Cover Art Archive or in Apple’s music catalog, because Discord can only show images from the web. Your own files are never uploaded.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("TIDAL integration", isOn: Binding(get: { model.settings.tidalEnabled }, set: { model.setTidalEnabled($0) }))
            } footer: {
                Text("Stream, sync and download from your TIDAL account. Off: Vespertine shows only your own music.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { token = await ListenBrainzClient.shared.savedToken() }
    }

    private var discordLine: String {
        switch model.player.discord.connection {
        case .idle: String(localized: "Your status appears while a song plays.")
        case .waitingForDiscord: String(localized: "Discord isn’t open. Your status appears once it is.")
        case .connected(let user?): String(localized: "Connected to Discord as \(user)", comment: "%@ is the name of a Discord account.")
        case .connected(nil): String(localized: "Connected to Discord")
        case .refused(let reason): String(localized: "Discord didn’t accept the status: \(reason)", comment: "%@ is Discord's own reason, in English.")
        }
    }
}

struct UpdateSettings: View {
    @Environment(AppUpdater.self) private var updater
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updater = updater
        @Bindable var s = model.settings
        Form {
            Section("Software Update") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                Toggle("Automatically download and install updates", isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
                HStack {
                    Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                    if let last = updater.lastCheck {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Updates come from Vespertine's GitHub releases. Each one is signed by the developer and verified before it is installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("DoP DACs") {
                Toggle("Update the list of DoP DACs", isOn: $s.dopListUpdates)
                    .onChange(of: s.dopListUpdates) { if s.dopListUpdates { model.dopSetup.refreshList() } }
                Text("Once a day, Vespertine downloads the list of DACs known to play DSD over PCM (DoP) from its GitHub releases, so a newly confirmed DAC plays DSD natively without an app update. The list is signed by the developer and checked before it is used. Nothing about you or your Mac is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    /// "1.1.0 (68)": the marketing version and the build number, as macOS's own About panels show them.
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "–"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(verbatim: "Vespertine").font(Typeface.serif(28))
            Text("Version \(Self.version)")
                .font(Typeface.mono(11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Free software under the GNU General Public License v3.\nDecoding by SFBAudioEngine (MIT), libFLAC, WavPack, Monkey's Audio, libopus, libvorbis, mpg123, TagLib.\nDatabase by GRDB (MIT).")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Made with ❤️ in Boston")
                .font(Typeface.serif(12).italic()).foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
