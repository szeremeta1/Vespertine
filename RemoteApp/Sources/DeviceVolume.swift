//
// Vespertine Remote: this device's own volume as a slider, for when music plays here. iOS gives an app one way to set the
// system volume: the slider inside its MPVolumeView. That view sits in the screen unseen, and the app's own slider, drawn
// like the one for a Mac's volume, moves it.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// Where the finger put the volume, shown until iOS reports that level (or a moment passes), so the thumb stays under the
/// finger rather than jumping back to the level iOS last gave.
@Observable
final class DeviceVolume {
    static let shared = DeviceVolume()

    private(set) var held: Double?
    /// How long after the finger lifts a level is still shown when iOS never reports it.
    @ObservationIgnored var settle: Duration = .milliseconds(1200)
    /// How near iOS's level has to be to count as the one asked for.
    @ObservationIgnored var tolerance = 0.02
    /// Sets the system volume: the hidden MPVolumeView's slider, once the view is on screen.
    @ObservationIgnored var apply: ((Double) -> Void)?
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var release: Task<Void, Never>?

    /// What the slider shows when iOS reports `reported`.
    func shown(reported: Double?) -> Double { Self.clamped(held ?? reported ?? 0) }

    /// The slider moved to `level` (called for every movement of a drag).
    func drag(to level: Double) {
        dragging = true
        release?.cancel()
        release = nil
        let level = Self.clamped(level)
        held = level
        apply?(level)
    }

    /// The finger lifted: the level stays shown until iOS reports it, or for a moment if it never does.
    func end() {
        guard dragging else { return }
        dragging = false
        release?.cancel()
        release = Task { [weak self, settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.held = nil
        }
    }

    /// iOS reported its volume. Reports during a drag are older than the finger.
    func reported(_ level: Double?) {
        guard !dragging, let held, let level, abs(level - held) <= tolerance else { return }
        release?.cancel()
        release = nil
        self.held = nil
    }

    nonisolated static func clamped(_ level: Double) -> Double { level.isFinite ? min(1, max(0, level)) : 0 }

    /// The number beside the slider: the level, or a dash while iOS reports none and no finger has set one (a slider at
    /// zero with "0%" beside it would be a level nobody read).
    func label(reported: Double?) -> String {
        held == nil && reported == nil ? "—" : Self.percent(shown(reported: reported))
    }

    /// "62%".
    nonisolated static func percent(_ level: Double) -> String {
        clamped(level).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The system's volume view, in the screen but not seen: its slider is what `DeviceVolume` moves. While it is in the
/// screen iOS also leaves out its own volume overlay, which would cover the slider being dragged.
struct SystemVolumeHandle: UIViewRepresentable {
    let volume: DeviceVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 30))
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        volume.apply = { [weak view] level in
            guard let view, let slider = Self.slider(in: view) else { return }
            slider.setValue(Float(level), animated: false)
        }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    static func slider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider { return slider }
            if let slider = slider(in: subview) { return slider }
        }
        return nil
    }
}

/// The volume line when music plays on this device: a slider for the device's own volume, its level as a number (below
/// 100% a DAC doesn't get the song's samples unchanged, so the number matters), and the AirPlay button.
struct DeviceVolumeRow: View {
    /// The volume iOS reports (`AVAudioSession.outputVolume`), nil before it has said.
    let reported: Double?
    var volume = DeviceVolume.shared

    var body: some View {
        let level = volume.shown(reported: reported)
        let known = volume.held != nil || reported != nil
        HStack(spacing: 12) {
            Image(systemName: level <= 0 ? "speaker.slash.fill" : "speaker.fill")
                .frame(width: 36, height: 44)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { level }, set: { volume.drag(to: $0) }), in: 0...1,
                   onEditingChanged: { editing in if !editing { volume.end() } })
                .tint(Palette.text2)
                .accessibilityLabel(Text("Volume"))
                .accessibilityValue(known ? Text(verbatim: DeviceVolume.percent(level)) : Text("Not reported by iOS"))
                .accessibilityIdentifier("device-volume")
                .background(SystemVolumeHandle(volume: volume).frame(width: 1, height: 1).accessibilityHidden(true))
            Text(verbatim: volume.label(reported: reported))
                .font(.signal(.caption)).monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
                .accessibilityHidden(true)
            RoutePickerButton().frame(width: 44, height: 44)
                .accessibilityIdentifier("airplay")
        }
        .font(.footnote)
        .foregroundStyle(Palette.text2)
        .onChange(of: reported) { _, level in volume.reported(level) }
    }
}
