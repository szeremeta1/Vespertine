//
// Nocturne — mini player, menu bar extra, settings.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import NocturneAudio
import NocturneLibrary
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
                ArtworkView(key: player.current?.track.artworkKey, size: 600, cornerRadius: 0)
                    .frame(width: geo.size.height, height: geo.size.height)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.track.title ?? "Not Playing").font(Typeface.serif(16)).foregroundStyle(Palette.text).lineLimit(1)
                    Text(player.current?.track.displayArtist ?? " ").font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
                    Spacer()
                    HStack(spacing: 14) {
                        TransportControls(compact: true)
                        Spacer(minLength: 4)
                        if let path = player.signalPath {
                            Text(path.isResampling
                                 ? "\(SampleRate.format(path.plan.decodedSampleRate)) → \(SampleRate.format(path.plan.deviceSampleRate)) kHz"
                                 : path.deviceFormatShort)
                                .font(Typeface.mono(10))
                                .foregroundStyle(path.isBitPerfect ? Palette.brassHi : Palette.copper)
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
                ArtworkView(key: player.current?.track.artworkKey, size: 160, cornerRadius: 6).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.track.title ?? "Not Playing").font(Typeface.serif(16)).lineLimit(1)
                    Text(player.current.map { "\($0.track.displayArtist) — \($0.track.displayAlbum)" } ?? "Nocturne")
                        .font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
                    if let path = player.signalPath {
                        Text("\(path.statusLine) · \(path.deviceFormatShort)").font(Typeface.mono(9.5))
                            .foregroundStyle(path.isBitPerfect ? Palette.brassHi : Palette.copper)
                    }
                }
            }
            Scrubber()
            HStack { Spacer(); TransportControls(compact: true); Spacer() }
            Hairline()
            DevicePicker()
                .padding(-12)
            Hairline()
            HStack {
                Button("Open Nocturne") {
                    NSApp.activate()
                    openWindow(id: "main")
                }
                Spacer()
                Button("Mini Player") { openWindow(id: "mini") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(QuietButtonStyle(compact: true))
        }
        .padding(16)
        .frame(width: 360)
        .background(Palette.panel)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            PlaybackSettings().tabItem { Label("Playback", systemImage: "hifispeaker.2") }
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }
            OnlineSettings().tabItem { Label("Online", systemImage: "globe") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
    }
}

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Output") {
                Toggle("Exclusive access (hog mode)", isOn: $s.exclusiveMode)
                Text("Nocturne takes sole control of the DAC and sets its format for each track. Other apps are silent on that device while Nocturne plays.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Release device after pausing for", selection: $s.releaseAfterPause) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("2 minutes").tag(120.0)
                    Text("10 minutes").tag(600.0)
                }
            }
            Section("Volume") {
                Toggle("Allow digital volume when the device has no hardware control", isOn: $s.allowDigitalVolume)
                Text("Applied in 64-bit with TPDF dither at the DAC's word length. At anything below 100% the output is no longer bit-perfect, and Nocturne says so.")
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
        .onChange(of: s.releaseAfterPause) { model.syncEngine() }
        .onChange(of: s.allowDigitalVolume) { model.syncEngine() }
        .onChange(of: s.replayGain) { model.player.refreshReplayGain() }
        .onChange(of: s.replayGainPreampDB) { model.player.refreshReplayGain() }
    }
}

struct LibrarySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Sources") {
                ForEach(model.library.sources) { source in
                    HStack {
                        Image(systemName: source.mode == .managed ? "tray.full" : "folder")
                        VStack(alignment: .leading) {
                            Text(source.displayName)
                            Text(source.mode == .managed ? "Managed" : "Referenced in place").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rescan") { Task { await model.library.scan(source) } }
                        Button("Remove") { model.library.removeSource(source) }
                    }
                }
                HStack {
                    Button("Add Folder…") { model.presentImporter(.reference) }
                    Button("Import & Organize…") { model.presentImporter(.copyAndOrganize) }
                }
            }
            Section("Importing") {
                Picker("When adding music", selection: $s.defaultImportMode) {
                    Text("Reference files in place").tag(ImportMode.reference)
                    Text("Copy & organize into managed folder").tag(ImportMode.copyAndOrganize)
                }
                LabeledContent("Managed folder") {
                    Text((s.managedFolderPath as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                }
                Toggle("Watch folders for changes", isOn: Binding(get: { s.watchFolders }, set: {
                    s.watchFolders = $0; model.library.updateWatcher()
                }))
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
    }
}

struct OnlineSettings: View {
    @Environment(AppModel.self) private var model
    @State private var token = Keychain.read("listenbrainz-token") ?? ""
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
                        Keychain.write(token, account: "listenbrainz-token")
                        Task {
                            let user = try? await ListenBrainzClient.shared.validate(token: token)
                            validation = user.map { "Connected as \($0)" } ?? "Token not accepted"
                        }
                    }
                    if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Your token is stored in the macOS Keychain. Find it at listenbrainz.org → Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct UpdateSettings: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
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
                Text("Updates come from Nocturne's GitHub releases. Each one is signed by the developer and verified before it is installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Nocturne").font(Typeface.serif(28))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                .font(Typeface.mono(11)).foregroundStyle(.secondary)
            Text("Free software under the GNU General Public License v3.\nDecoding by SFBAudioEngine (MIT), libFLAC, WavPack, Monkey's Audio, libopus, libvorbis, mpg123, TagLib.\nDatabase by GRDB (MIT).")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
