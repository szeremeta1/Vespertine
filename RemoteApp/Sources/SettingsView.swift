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
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    if let url = URL(string: "https://github.com/szeremeta1/Vespertine") {
                        Link("Source Code", destination: url)
                    }
                    Text("Vespertine is free software under the GNU General Public License, version 3 or later, with an exception for the App Store. It has no accounts, no ads and no tracking, and connects only to the Macs you pair it with.")
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
