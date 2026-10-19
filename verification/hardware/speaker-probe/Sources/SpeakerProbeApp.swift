//
// Speaker probe — plays the test signals and shows the route readout while they play.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import AVKit
import SwiftUI

@main
struct SpeakerProbeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

@MainActor @Observable
final class ProbeModel {
    let player = AVPlayer()
    private(set) var signal: TestSignal?
    private(set) var error: String?

    init() {
        do { try RouteReport.prepareSession() } catch { self.error = error.localizedDescription }
    }

    func play(_ signal: TestSignal) {
        do {
            let url = try signal.fileURL()
            self.signal = signal
            error = nil
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
            print("Playing \(signal.title)\n\(RouteReport.current())")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        signal = nil
    }

    func routeChanged() {
        do { try RouteReport.prepareSession() } catch { self.error = error.localizedDescription }
        print("Route changed\n\(RouteReport.current())")
    }

    var nowPlaying: String {
        guard let signal else { return "Nothing playing" }
        let time = player.currentTime().seconds
        let speaker = signal.channel(at: time) ?? "—"
        return "\(signal.title) · \(String(format: "%.1f", time)) s · now: \(speaker)"
    }
}

struct ContentView: View {
    @State private var model = ProbeModel()

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Vespertine speaker probe").font(.title2)
                ForEach(TestSignal.all) { signal in
                    Button(signal.title) { model.play(signal) }
                }
                Button("Stop") { model.stop() }
                #if os(macOS)
                RoutePicker(player: model.player).frame(width: 40, height: 30)
                #endif
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.nowPlaying).font(.headline)
                    Text(RouteReport.current()).font(.system(.body, design: .monospaced))
                }
            }
        }
        .padding(60)
        #if os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            model.routeChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.renderingModeChangeNotification)) { _ in
            print("Rendering mode changed\n\(RouteReport.current())")
        }
        #endif
    }
}

#if os(macOS)
/// AirPlay picker bound to the probe's own player, so the signals go out through AVFoundation's AirPlay
/// rather than the system output device.
struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player
    }
}
#endif
