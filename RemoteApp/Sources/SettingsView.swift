//
// Vespertine Remote: the app's own settings (how things look) and what it is.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI

struct SettingsView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var shelf = KeptShelf.shared
        NavigationStack {
            Form {
                Section {
                    Toggle("Show a Record in Now Playing", isOn: $settings.vinyl)
                } header: {
                    Text("Now Playing")
                } footer: {
                    Text("The cover becomes the label of a record that turns with the music. It’s a picture of the playback position, not of the sound.")
                }
                Section {
                    Picker("Albums", selection: $settings.albumsLayout) {
                        Text("Grid").tag(AppSettings.AlbumsLayout.grid)
                        Text("Cover Flow").tag(AppSettings.AlbumsLayout.coverFlow)
                    }
                    Toggle("Tilt to Shift the Perspective", isOn: $settings.tiltParallax)
                        .disabled(reduceMotion || !model.tiltSensor.isAvailable)
                } header: {
                    Text("Library")
                } footer: {
                    if reduceMotion {
                        Text("Reduce Motion is on in the system’s Accessibility settings, so Cover Flow stays flat and doesn’t follow the device, and the record doesn’t turn.")
                    } else if !model.tiltSensor.isAvailable {
                        Text("This device has no motion sensors, so Cover Flow doesn’t follow it.")
                    } else {
                        Text("Cover Flow reads the motion sensors only while it’s on screen, to shift its perspective as you tilt the device. Nothing is recorded.")
                    }
                }
                Section {
                    Toggle("Play over Cellular Data", isOn: Binding(get: { settings.cellularPlayback }, set: { settings.cellularPlayback = $0; model.cellularSettingChanged() }))
                    LabeledContent("Fetched from the Mac", value: ByteCountFormatter.string(fromByteCount: PlayTarget.shared.bytesReceived, countStyle: .file))
                } header: {
                    Text("Playing on This Device")
                } footer: {
                    Text("When music plays on this device, its songs come from your Mac. Lossless and hi-res songs are large: an album can be several hundred megabytes. The count is since the app was opened.")
                }
                Section {
                    Toggle("Combine Stereo and Surround Versions", isOn: Binding(get: { settings.combineVersions }, set: { settings.combineVersions = $0; model.versionsSettingChanged() }))
                } footer: {
                    Text("A song you have in stereo and in surround or Dolby Atmos plays on this device as the version that fits the output: the surround one on a surround output or with Surround on Headphones, the stereo one everywhere else. From a share or a folder, such a song is listed once, and a heart on one version is a heart on the song. To hear a particular version, open the song’s copies and play it there. Off, every file plays as itself.")
                }
                Section {
                    Picker("Room for Kept Music", selection: $shelf.limitGigabytes) {
                        ForEach(KeptShelf.limitChoices, id: \.self) { gigabytes in
                            if gigabytes == 0 { Text("No Limit").tag(gigabytes) } else {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(gigabytes) * 1_000_000_000, countStyle: .file)).tag(gigabytes)
                            }
                        }
                    }
                    Toggle("Keep Smaller Copies", isOn: $shelf.smaller)
                } header: {
                    Text("Kept on This Device")
                } footer: {
                    Text("Albums and playlists you keep are fetched whole from your Mac and play without it. With smaller copies, lossless songs above 48 kHz are converted on the Mac to 44.1 or 48 kHz before they’re kept; everything else is kept as it is. This applies to what you keep from now on.")
                }
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    if let url = URL(string: "https://github.com/szeremeta1/Vespertine") {
                        Link("Source Code", destination: url)
                    }
                    NavigationLink("Licenses") { LicensesView() }
                    Text("Vespertine is free software under the GNU General Public License, version 3 or later, with an exception for the App Store. It has no accounts, no ads and no tracking, and connects only to the Macs you pair it with and the shares you add.")
                        .font(.footnote).foregroundStyle(Palette.text2)
                }
            }
            .obsidianList()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}

/// The licenses of the decoder libraries inside the app (Monkey's Audio, WavPack, Ogg, Vorbis, Opus), as each asks of a
/// copy handed on in binary form. The texts are the ones the Mac app carries (App/Licenses).
struct LicensesView: View {
    /// The library as its license names it, and the file with its text.
    private static let libraries = [("Monkey’s Audio", "MonkeysAudio"), ("WavPack", "WavPack"), ("Ogg", "Ogg"), ("Vorbis", "Vorbis"), ("Opus", "Opus")]

    static func text(_ file: String, in bundle: Bundle = .main) -> String? {
        bundle.url(forResource: file, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    var body: some View {
        List {
            ForEach(Self.libraries, id: \.1) { name, file in
                Section {
                    // A license is a legal text in English: shown as it is, never translated.
                    Text(verbatim: Self.text(file) ?? "").font(.caption.monospaced()).foregroundStyle(Palette.text2).textSelection(.enabled)
                } header: {
                    Text(verbatim: name)
                }
            }
            Section {} footer: {
                Text("Vespertine opens APE, WavPack, Ogg Vorbis and Opus files with these libraries. Each is used under its own license.")
            }
        }
        .obsidianList()
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
