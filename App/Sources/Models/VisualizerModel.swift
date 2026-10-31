//
// Vespertine — the visualizer window's link to the engine: the tap and the analysis run only while it's showing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineAudio
import VespertineVisualizer

@Observable
@MainActor
final class VisualizerModel {
    @ObservationIgnored let feed: VisualizerFeed
    @ObservationIgnored private let engine: PlaybackEngine
    /// Windows showing the visualizer right now (open, on screen and not minimized).
    private(set) var showing = 0

    init(engine: PlaybackEngine) {
        self.engine = engine
        feed = VisualizerFeed { [engine] left, right in
            engine.copyVisualizerTap(left: &left, right: &right).map {
                VisualizerTapRead(frames: $0.frames, position: $0.position, sampleRate: $0.sampleRate, isDSD: $0.isDSD)
            }
        }
    }

    /// A window began showing the visualizer, on a display refreshing `rate` times a second. Switches the engine's tap
    /// on and starts the analysis.
    func began(rate: Double) {
        showing += 1
        if showing == 1 { engine.setVisualizerTap(true) }
        feed.start(rate: rate)
    }

    /// The window moved to a display with another refresh rate.
    func rateChanged(_ rate: Double) {
        if showing > 0 { feed.start(rate: rate) }
    }

    /// A window stopped showing it (closed, minimized or hidden). With none left, the tap and analysis stop, so the
    /// visualizer costs nothing.
    func ended() {
        guard showing > 0 else { return }
        showing -= 1
        if showing == 0 {
            feed.stop()
            engine.setVisualizerTap(false)
        }
    }

    func apply(_ settings: VisualizerSettings) {
        var c = VisualizerAnalyzer.Configuration()
        c.bandCount = settings.bandCount
        c.sensitivity = Float(settings.sensitivity)
        c.linear = !settings.decibelScale
        feed.update(configuration: c)
    }
}
